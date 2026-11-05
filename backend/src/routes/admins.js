import { Router } from 'express';
import { z } from 'zod';
import { ah, badRequest, forbidden, notFound } from '../lib/errors.js';
import { logAudit } from '../lib/audit.js';
import { renameAccount, resetPin } from '../services/accounts.js';

/**
 * Comptes des administrateurs : réservé au PRÉSIDENT.
 *  - Il voit les autres admins (le trésorier…) et peut réinitialiser leur code (code provisoire, comme pour un superviseur).
 *  - Le code du président lui-même ne se réinitialise PAS ici : un autre admin pourrait sinon prendre son compte.
 *    En cas d'oubli, la récupération se fait sur le serveur (accès à la base).
 */
export function adminsRouter({ db, auth, president, pinCost }) {
  const r = Router();
  r.use(auth, president);

  r.get('/', ah(async (_req, res) => {
    const { rows } = await db.query(
      "select id, name, active, is_president, must_change_pin from users where role = 'admin' order by is_president desc, name",
    );
    res.json(rows.map((u) => ({ id: u.id, name: u.name, active: u.active, isPresident: u.is_president, mustChangePin: u.must_change_pin })));
  }));

  r.post('/:id/reset-pin', ah(async (req, res) => {
    const out = await db.tx(async (q) => {
      const u = (await q.query("select id, name, is_president from users where id = $1 and role = 'admin'", [req.params.id])).rows[0];
      if (!u) throw notFound('Administrateur introuvable.');
      if (u.id === req.user.id) throw badRequest("Pour changer votre propre code, utilisez « Mon compte ».");
      if (u.is_president) throw forbidden('Le code du président se récupère sur le serveur.');
      return { name: u.name, pin: await resetPin(q, req.user, u, { pinCost }) };
    });
    res.set('Cache-Control', 'no-store').json(out);
  }));

  // Renommer ou activer / désactiver un autre admin (le trésorier…). Ni soi-même ni le président : leurs comptes
  // ne se modifient pas ici. Désactiver coupe l'accès tout de suite (le compte est relu à chaque requête).
  r.patch('/:id', ah(async (req, res) => {
    const b = z.object({ name: z.string().trim().min(2).max(100).optional(), active: z.boolean().optional() })
      .refine((o) => Object.keys(o).length > 0, 'Aucune modification fournie.').parse(req.body);
    await db.tx(async (q) => {
      const u = (await q.query("select id, name, active, is_president, worker_id from users where id = $1 and role = 'admin' for update", [req.params.id])).rows[0];
      if (!u) throw notFound('Administrateur introuvable.');
      if (u.id === req.user.id) throw badRequest('Vous ne pouvez pas modifier votre propre compte ici.');
      if (u.is_president) throw forbidden('Le compte du président ne se modifie pas ici.');
      if (b.name !== undefined) await renameAccount(q, req.user, u, b.name);
      if (b.active !== undefined && b.active !== u.active) {
        await q.query('update users set active = $2, token_version = token_version + 1, last_seen_at = null where id = $1', [u.id, b.active]);
        await logAudit(q, req.user, { action: b.active ? 'Réactivation de compte' : 'Désactivation de compte', object: u.name });
      }
    });
    res.json({ ok: true });
  }));

  return r;
}
