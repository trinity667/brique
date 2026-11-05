import { Router } from 'express';
import { z } from 'zod';
import { ah, conflict, notFound } from '../lib/errors.js';
import { renameAccount } from '../services/accounts.js';
import { logAudit } from '../lib/audit.js';
import { hashPin, pinSchema } from '../lib/pin.js';
import { resetPin } from '../services/accounts.js';

const uuid = z.string().uuid();

/**
 * Un superviseur EST l'un des ouvriers : l'admin choisit un ouvrier déjà
 * enregistré et lui attribue un code PIN. Il se connecte ensuite avec son nom
 * et ce code, et voit les autres membres de son équipe.
 */
export function supervisorsRouter({ db, auth, admin, pinCost }) {
  const r = Router();
  r.use(auth, admin);

  r.get('/', ah(async (_req, res) => {
    const { rows } = await db.query(
      `select u.id, u.name, u.active, u.worker_id, u.must_change_pin, w.team_id, t.name as team_name,
              (select array_agg(tt.name order by tt.name) from teams tt where tt.chief_id = u.id) as chief_of,
              (select array_agg(tt.name order by tt.name) from teams tt where tt.interim_id = u.id) as interim_of
         from users u join workers w on w.id = u.worker_id left join teams t on t.id = w.team_id
        where u.role = 'chief' order by u.name`,
    );
    res.json(rows.map((u) => ({
      id: u.id, name: u.name, active: u.active, workerId: u.worker_id, mustChangePin: u.must_change_pin,
      teamId: u.team_id, teamName: u.team_name,
      chiefOf: u.chief_of ?? [], interimOf: u.interim_of ?? [],
    })));
  }));

  r.post('/', ah(async (req, res) => {
    const { workerId, pin } = z.object({ workerId: uuid, pin: pinSchema }).parse(req.body);
    const pinHash = await hashPin(pin, pinCost);
    const user = await db.tx(async (q) => {
      const w = (await q.query('select id, full_name, team_id, active from workers where id = $1 for update', [workerId])).rows[0];
      if (!w || !w.active) throw notFound('Ouvrier actif introuvable.');
      if ((await q.query('select 1 from users where worker_id = $1', [workerId])).rowCount) {
        throw conflict('Cet ouvrier a déjà un accès.');
      }
      const u = (await q.query(
        "insert into users (name, role, worker_id, pin_hash, must_change_pin) values ($1, 'chief', $2, $3, true) returning id, name",
        [w.full_name, workerId, pinHash],
      )).rows[0];
      let teamName = null;
      if (w.team_id) {
        const t = (await q.query('select name, chief_id from teams where id = $1 for update', [w.team_id])).rows[0];
        teamName = t.name;
        if (!t.chief_id) await q.query('update teams set chief_id = $2 where id = $1', [w.team_id, u.id]);
      }
      await logAudit(q, req.user, { action: 'Création de superviseur', object: u.name, newValue: teamName });
      return u;
    });
    // Code initial provisoire : le superviseur devra choisir le sien à sa première connexion.
    res.status(201).json({ id: user.id, name: user.name });
  }));

  // Réinitialisation du code (récupération d'accès, tracée) : le serveur génère un code PROVISOIRE aléatoire, montré
  // une seule fois à l'admin. Le superviseur devra choisir le sien à sa connexion ; ses connexions ouvertes sont fermées.
  r.post('/:id/reset-pin', ah(async (req, res) => {
    const out = await db.tx(async (q) => {
      const u = (await q.query("select id, name from users where id = $1 and role = 'chief'", [req.params.id])).rows[0];
      if (!u) throw notFound('Superviseur introuvable.');
      return { name: u.name, pin: await resetPin(q, req.user, u, { pinCost }) };
    });
    res.set('Cache-Control', 'no-store').json(out);
  }));

  // Modifier un compte superviseur : renommer (nom de connexion, et fiche de l'ouvrier qui est ce superviseur)
  // et/ou activer / désactiver. Tracé dans l'audit.
  r.patch('/:id', ah(async (req, res) => {
    const b = z.object({ name: z.string().trim().min(2).max(100).optional(), active: z.boolean().optional() })
      .refine((o) => Object.keys(o).length > 0, 'Aucune modification fournie.').parse(req.body);
    await db.tx(async (q) => {
      const u = (await q.query("select id, name, active, worker_id from users where id = $1 and role = 'chief' for update", [req.params.id])).rows[0];
      if (!u) throw notFound('Superviseur introuvable.');
      if (b.name !== undefined) await renameAccount(q, req.user, u, b.name);
      if (b.active !== undefined && b.active !== u.active) {
        await q.query('update users set active = $2 where id = $1', [u.id, b.active]);
        await logAudit(q, req.user, { action: b.active ? 'Réactivation de compte' : 'Désactivation de compte', object: u.name });
      }
    });
    res.json({ ok: true });
  }));

  return r;
}
