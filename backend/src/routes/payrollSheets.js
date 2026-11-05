import { Router } from 'express';
import { z } from 'zod';
import { ah, badRequest, conflict, forbidden, notFound } from '../lib/errors.js';
import { frDate, todayStr } from '../lib/dates.js';
import { logAudit } from '../lib/audit.js';
import { buildPayrollSheet } from './reports.js';

/**
 * Fiches de paie ÉTABLIES (circuit Établie → Approuvée).
 *  - Un admin (le trésorier) établit la fiche d'une période pour une ou plusieurs équipes : le serveur en garde une
 *    photo figée (snapshot) avec un numéro FP-AAAA-NNN. Elle n'est plus jamais recalculée, même si les saisies changent.
 *  - Le président l'approuve, et ce ne peut pas être la personne qui l'a établie.
 *  - Une fiche ne se supprime ni ne se modifie : seule l'annulation motivée est possible (une fiche approuvée ne peut
 *    être annulée que par le président). Tout est tracé dans le journal d'audit.
 *  - Deux fiches non annulées ne peuvent pas couvrir le même jour pour la même équipe (pas de double paiement).
 */
const LIST_SQL = `
  select id, number, status, period_from, period_to, established_by_name, established_at,
         approved_by_name, approved_at, cancelled_by_name, cancelled_at, cancel_reason,
         snapshot->'totalAmount' as total_amount, (snapshot->>'totalBricks')::int as total_bricks,
         (select coalesce(jsonb_agg(t->>'name'), '[]'::jsonb) from jsonb_array_elements(snapshot->'teams') t) as team_names
    from payroll_sheets`;

const dto = (r, sheet) => ({
  id: r.id,
  number: r.number,
  status: r.status,
  from: r.period_from,
  to: r.period_to,
  label: `${frDate(r.period_from)} au ${frDate(r.period_to)}`,
  teamNames: r.team_names ?? (sheet ? sheet.teams.map((t) => t.name) : []),
  totalBricks: r.total_bricks ?? sheet?.totalBricks ?? 0,
  totalAmount: r.total_amount ?? sheet?.totalAmount ?? null,
  establishedBy: { name: r.established_by_name, at: r.established_at },
  approvedBy: r.approved_at ? { name: r.approved_by_name, at: r.approved_at } : null,
  cancelled: r.cancelled_at ? { by: r.cancelled_by_name, at: r.cancelled_at, reason: r.cancel_reason } : null,
  ...(sheet ? { sheet } : {}),
});

export function payrollSheetsRouter({ db, auth, admin, president }) {
  const r = Router();
  r.use(auth, admin);

  r.get('/', ah(async (req, res) => {
    const { status } = z.object({ status: z.enum(['established', 'approved', 'cancelled']).optional() }).parse(req.query);
    const { rows } = await db.query(`${LIST_SQL} ${status ? 'where status = $1' : ''} order by established_at desc limit 200`, status ? [status] : []);
    res.json(rows.map((x) => dto(x)));
  }));

  r.get('/:id', ah(async (req, res) => {
    const row = (await db.query(
      'select *, snapshot as sheet, snapshot->\'totalAmount\' as total_amount, (snapshot->>\'totalBricks\')::int as total_bricks from payroll_sheets where id = $1',
      [req.params.id],
    )).rows[0];
    if (!row) throw notFound('Fiche de paie introuvable.');
    res.json(dto(row, row.sheet));
  }));

  // Établir : calcule la fiche maintenant et la fige. Refus si une journée saisie est incomplète (la fiche
  // donnerait de faux montants) ou si une autre fiche non annulée couvre déjà ces équipes sur ces jours.
  r.post('/', ah(async (req, res) => {
    const b = z.object({
      from: z.string(), to: z.string(), teamIds: z.array(z.string().uuid()).min(1).nullable().optional(),
    }).parse(req.body);
    const sheet = await buildPayrollSheet(db, { from: b.from, to: b.to, teamIds: b.teamIds ?? null });
    if (sheet.teams.length === 0) throw badRequest('Aucune équipe enregistrée.');
    if (!sheet.teams.some((t) => t.days.some((d) => d.entered))) throw badRequest('Aucune saisie sur cette période : rien à établir.');
    const bad = sheet.teams
      .map((t) => ({ name: t.name, dates: t.days.filter((d) => d.incomplete).map((d) => frDate(d.date).slice(0, 5)) }))
      .filter((t) => t.dates.length);
    if (bad.length) {
      throw conflict(
        `Journées incomplètes à régulariser avant d'établir la fiche : ${bad.map((t) => `${t.name} (${t.dates.join(', ')})`).join(' ; ')}.`,
        'incomplete_days',
      );
    }
    const teamIds = sheet.teams.map((t) => t.teamId);
    const year = todayStr().slice(0, 4);

    for (let attempt = 1; ; attempt++) {
      try {
        const out = await db.tx(async (q) => {
          const clash = (await q.query(
            `select number from payroll_sheets
              where status <> 'cancelled' and period_from <= $2 and period_to >= $1 and team_ids && $3::uuid[] limit 1`,
            [b.from, b.to, teamIds],
          )).rows[0];
          if (clash) {
            throw conflict(
              `La fiche ${clash.number} couvre déjà une partie de cette période pour ces équipes. Annulez-la d'abord ou choisissez une autre période.`,
              'overlap',
            );
          }
          const prefix = `FP-${year}-`;
          const last = (await q.query(
            "select coalesce(max(substring(number from '[0-9]+$')::int), 0) as n from payroll_sheets where number like $1",
            [`${prefix}%`],
          )).rows[0].n;
          const number = `${prefix}${String(last + 1).padStart(3, '0')}`;
          const row = (await q.query(
            `insert into payroll_sheets (number, period_from, period_to, team_ids, snapshot, established_by, established_by_name)
             values ($1, $2, $3, $4::uuid[], $5::jsonb, $6, $7) returning id`,
            [number, b.from, b.to, teamIds, JSON.stringify(sheet), req.user.id, req.user.name],
          )).rows[0];
          await logAudit(q, req.user, {
            action: 'Fiche de paie établie',
            object: number,
            newValue: `${sheet.label} · ${sheet.teams.map((t) => t.name).join(', ')} · ${sheet.totalAmount.value} FCFA`,
          });
          return { id: row.id, number };
        });
        return res.status(201).json(out);
      } catch (e) {
        if (/payroll_sheets_number_key|unique/i.test(e?.message ?? '') && attempt < 3) continue;
        throw e;
      }
    }
  }));

  // Approuver : réservé au président, jamais la personne qui a établi la fiche.
  r.post('/:id/approve', president, ah(async (req, res) => {
    // Le refus est tracé HORS transaction : sinon la trace serait annulée avec elle.
    const pre = (await db.query('select number, established_by from payroll_sheets where id = $1', [req.params.id])).rows[0];
    if (pre && pre.established_by === req.user.id) {
      await logAudit(db, req.user, {
        action: 'Approbation refusée', object: pre.number, reason: 'Fiche établie par la même personne', security: true,
      });
      throw forbidden('Vous avez établi cette fiche : elle doit être approuvée par une autre personne.');
    }
    await db.tx(async (q) => {
      const s = (await q.query('select number, status, established_by_name from payroll_sheets where id = $1 for update', [req.params.id])).rows[0];
      if (!s) throw notFound('Fiche de paie introuvable.');
      if (s.status !== 'established') throw conflict(s.status === 'approved' ? 'Cette fiche est déjà approuvée.' : 'Cette fiche est annulée.', 'bad_status');
      await q.query(
        "update payroll_sheets set status = 'approved', approved_by = $2, approved_by_name = $3, approved_at = now() where id = $1",
        [req.params.id, req.user.id, req.user.name],
      );
      await logAudit(q, req.user, { action: 'Fiche de paie approuvée', object: s.number, oldValue: `établie par ${s.established_by_name}` });
    });
    res.json({ ok: true });
  }));

  // Annuler avec motif : toute fiche établie par un admin ; une fiche approuvée seulement par le président.
  r.post('/:id/cancel', ah(async (req, res) => {
    const { reason } = z.object({ reason: z.string().trim().min(3, 'Indiquez le motif.').max(200) }).parse(req.body);
    const pre = (await db.query('select number, status from payroll_sheets where id = $1', [req.params.id])).rows[0];
    if (pre?.status === 'approved' && !req.user.isPresident) {
      await logAudit(db, req.user, {
        action: 'Annulation refusée', object: pre.number, reason: 'Fiche approuvée : réservé au président', security: true,
      });
      throw forbidden('Seul le président peut annuler une fiche approuvée.');
    }
    await db.tx(async (q) => {
      const s = (await q.query('select number, status from payroll_sheets where id = $1 for update', [req.params.id])).rows[0];
      if (!s) throw notFound('Fiche de paie introuvable.');
      if (s.status === 'cancelled') throw conflict('Cette fiche est déjà annulée.', 'already_cancelled');
      if (s.status === 'approved' && !req.user.isPresident) throw forbidden('Seul le président peut annuler une fiche approuvée.');
      await q.query(
        "update payroll_sheets set status = 'cancelled', cancelled_by_name = $2, cancelled_at = now(), cancel_reason = $3 where id = $1",
        [req.params.id, req.user.name, reason],
      );
      await logAudit(q, req.user, { action: 'Fiche de paie annulée', object: s.number, oldValue: s.status === 'approved' ? 'approuvée' : 'établie', newValue: reason });
    });
    res.json({ ok: true });
  }));

  return r;
}
