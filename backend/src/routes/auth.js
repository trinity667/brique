import bcrypt from 'bcryptjs';
import { Router } from 'express';
import rateLimit from 'express-rate-limit';
import { z } from 'zod';
import { ah, badRequest, unauthorized, HttpError } from '../lib/errors.js';
import { logAudit } from '../lib/audit.js';
import { hashPin, strongPinSchema, verifyPin } from '../lib/pin.js';
import { signToken } from '../middleware/auth.js';

export const MAX_ATTEMPTS = 5;
export const LOCK_SECONDS = 30;

const loginSchema = z.object({ name: z.string().trim().min(1).max(100), pin: z.string().min(1).max(12) });

// Hash factice : on compare toujours un PIN pour ne pas révéler si le nom existe (timing).
const DUMMY = bcrypt.hashSync('hash-factice', 10);

const userDto = (u) => ({
  id: u.id, name: u.name, role: u.role, workerId: u.worker_id, isPresident: u.is_president, mustChangePin: u.must_change_pin,
});

export function authRouter({ db, config, auth, pinCost }) {
  const r = Router();

  const limiter = rateLimit({
    windowMs: 60_000,
    limit: 20,
    standardHeaders: true,
    legacyHeaders: false,
    message: { error: 'Trop de requêtes. Patientez une minute.', code: 'rate_limited' },
  });

  /** Code faux : compteur d'essais, verrouillage temporaire au bout de MAX_ATTEMPTS, tracé (événement de sécurité). */
  async function registerFailure(u, actor) {
    const attempts = u.failed_attempts + 1;
    const lock = attempts >= MAX_ATTEMPTS;
    await db.query(
      'update users set failed_attempts = $2, locked_until = $3 where id = $1',
      [u.id, lock ? 0 : attempts, lock ? new Date(Date.now() + LOCK_SECONDS * 1000) : null],
    );
    await logAudit(db, actor, {
      action: 'Échec de connexion',
      object: u.name,
      reason: `Tentative ${attempts}/${MAX_ATTEMPTS}`,
      security: true,
    });
    return { attempts, lock };
  }

  const lockedError = (u) => {
    const s = Math.ceil((new Date(u.locked_until) - new Date()) / 1000);
    return new HttpError(423, `Compte verrouillé. Réessayez dans ${s} s.`, 'locked');
  };

  // Connexion : nom + code PIN. Message identique si le nom est inconnu ou le code faux.
  r.post('/login', limiter, ah(async (req, res) => {
    const { name, pin } = loginSchema.parse(req.body);
    const { rows } = await db.query('select * from users where lower(name) = lower($1) and active', [name]);
    const u = rows[0];

    if (!u) {
      await verifyPin(pin, DUMMY);
      throw unauthorized('Nom ou code incorrect.');
    }
    if (u.locked_until && new Date(u.locked_until) > new Date()) throw lockedError(u);

    const actor = { id: u.id, name: u.name, role: u.role };
    if (!(await verifyPin(pin, u.pin_hash))) {
      const { attempts, lock } = await registerFailure(u, actor);
      if (lock) throw new HttpError(423, `Trop de tentatives. Compte verrouillé ${LOCK_SECONDS} s.`, 'locked');
      throw unauthorized(`Nom ou code incorrect (${MAX_ATTEMPTS - attempts} essai(s) restant(s)).`);
    }

    await db.query('update users set failed_attempts = 0, locked_until = null, last_seen_at = now() where id = $1', [u.id]);
    await logAudit(db, actor, { action: 'Connexion', object: u.name });
    // mustChangePin : code provisoire, l'application impose le choix d'un nouveau code avant tout le reste.
    res.json({ token: signToken(config, u), user: userDto(u) });
  }));

  // Déconnexion : l'utilisateur n'apparaît plus comme « connecté ».
  r.post('/logout', auth, ah(async (req, res) => {
    await db.query('update users set last_seen_at = null where id = $1', [req.user.id]);
    await logAudit(db, req.user, { action: 'Déconnexion', object: req.user.name });
    res.json({ ok: true });
  }));

  r.get('/me', auth, ah(async (req, res) => {
    const { rows } = await db.query(
      `select t.id, t.name, (t.chief_id = $1) as is_chief
         from teams t where t.chief_id = $1 or t.interim_id = $1 order by t.name`,
      [req.user.id],
    );
    res.json({
      user: req.user,
      teams: rows.map((t) => ({ id: t.id, name: t.name, role: t.is_chief ? 'titulaire' : 'remplaçant' })),
    });
  }));

  // Changement de son propre PIN (volontaire, ou obligatoire après un code provisoire).
  // Le nouveau code doit être différent et pas trop simple. Les autres connexions ouvertes avec l'ancien code
  // sont fermées ; la réponse contient le jeton à utiliser désormais. Un code actuel faux compte comme un échec de connexion.
  r.put('/pin', auth, ah(async (req, res) => {
    const { currentPin, newPin } = z.object({ currentPin: z.string().min(1).max(12), newPin: strongPinSchema }).parse(req.body);
    if (newPin === currentPin) throw badRequest("Le nouveau code doit être différent de l'actuel.");
    const u = (await db.query('select * from users where id = $1', [req.user.id])).rows[0];
    if (u.locked_until && new Date(u.locked_until) > new Date()) throw lockedError(u);
    if (!(await verifyPin(currentPin, u.pin_hash))) {
      const { lock } = await registerFailure(u, req.user);
      if (lock) throw new HttpError(423, `Trop de tentatives. Compte verrouillé ${LOCK_SECONDS} s.`, 'locked');
      // 422 (et non 401) : l'application ne doit pas fermer la session pour un code actuel mal saisi.
      throw new HttpError(422, 'Code actuel incorrect.', 'wrong_pin');
    }
    const updated = (await db.query(
      `update users set pin_hash = $2, must_change_pin = false, token_version = token_version + 1, pin_changed_at = now(),
                        failed_attempts = 0, locked_until = null
        where id = $1 returning *`,
      [u.id, await hashPin(newPin, pinCost)],
    )).rows[0];
    await logAudit(db, req.user, { action: 'Changement de PIN', object: u.name, newValue: u.must_change_pin ? 'après code provisoire' : null });
    res.json({ ok: true, token: signToken(config, updated), user: userDto(updated) });
  }));

  return r;
}
