import { Router } from 'express';
import { z } from 'zod';
import { ah, badRequest } from '../lib/errors.js';
import { assertDate, frDate } from '../lib/dates.js';
import { Rational } from '../lib/rational.js';
import { computeDay, DayStatus, loadEntries, loadTariffs, productionValue, rateFor } from '../services/payroll.js';
import { nextDay } from '../services/days.js';
import { dateRange, loadCalendar, resolveDay } from '../services/calendar.js';
import { logAudit } from '../lib/audit.js';
import { clientDto, loadLetterhead } from './invoices.js';

const MAX_DAYS = 93;

/**
 * Réglages des rapports officiels, enregistrés dans app_settings (clé « report_settings ») :
 *  - libellés des colonnes du rapport de production (ex. « Nombre de BTC confectionnés (14x10x29 cm) ») ;
 *  - signataires en bas du rapport : intitulé du poste, structure, noms (case à cocher si plusieurs).
 * Valeurs par défaut neutres : aucun nom de personne n'est écrit dans le code.
 */
const text = (max) => z.string().trim().max(max);
export const reportSettingsSchema = z.object({
  tagline: text(120).default(''),
  productLabel: text(120).min(1).default('Nombre de BTC confectionnés'),
  cementLabel: text(120).min(1).default('Nombre de sacs de ciment'),
  signatories: z.array(z.object({
    title: text(120).min(1),
    company: text(160).default(''),
    names: z.array(text(120).min(1)).max(6).default([]),
  })).max(4).default([]),
});

export async function loadReportSettings(q) {
  const v = (await q.query("select value from app_settings where key = 'report_settings'")).rows[0]?.value;
  const o = typeof v === 'string' ? JSON.parse(v) : v;
  const parsed = reportSettingsSchema.safeParse(o ?? {});
  return parsed.success ? parsed.data : reportSettingsSchema.parse({});
}

const spanDays = (from, to) => Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000) + 1;

/** Prix unique sur la période, ou null s'il a changé (ou manque) en cours de route. */
const uniformRate = (tariffs, kind, from, to) => {
  const rates = new Set();
  for (let d = from; d <= to; d = nextDay(d)) rates.add(rateFor(tariffs, kind, d));
  return rates.size === 1 ? [...rates][0] : null;
};

/**
 * Données communes aux rapports : période, équipes (toutes si `teamIds` est null), saisies, tarifs, en-tête.
 * Exportée pour que la fiche de paie figée (payroll-sheets) utilise exactement le même calcul.
 */
export async function loadContext(db, { from, to, teamIds: wanted = null, clientId }) {
  const teamId = wanted?.length === 1 ? wanted[0] : null;
  assertDate(from, 'début');
  assertDate(to, 'fin');
  if (to < from) throw badRequest('La date de fin précède le début.');
  if (spanDays(from, to) > MAX_DAYS) throw badRequest(`Période trop longue (${MAX_DAYS} jours au maximum).`);
  const teams = (await db.query('select id, name, shift from teams order by name')).rows
    .filter((t) => !wanted || wanted.includes(t.id));
  if (wanted && teams.length !== new Set(wanted).size) throw badRequest('Équipe introuvable.');
  let client = null;
  if (clientId) {
    client = (await db.query('select * from clients where id = $1', [clientId])).rows[0];
    if (!client) throw badRequest('Client introuvable.');
  }
  const ids = new Set(teams.map((t) => t.id));
  const [tariffs, entries, letterhead, settings] = await Promise.all([
    loadTariffs(db),
    loadEntries(db, from, nextDay(to)).then((es) => es.filter((e) => ids.has(e.teamId))),
    loadLetterhead(db),
    loadReportSettings(db),
  ]);
  entries.sort((a, b) => a.date.localeCompare(b.date));
  return {
    from, to, teams, tariffs, entries,
    head: {
      from, to, label: `${frDate(from)} au ${frDate(to)}`, team: teamId ? teams[0].name : null,
      letterhead, settings, client: client ? clientDto(client) : null,
    },
  };
}

/**
 * Fiche de paie : par équipe, une colonne par jour (présent / absent / repos), montant par ouvrier,
 * total de l'équipe et total général. Même calcul exact que la paie mensuelle.
 */
export async function sheetFromContext(db, c) {
  const dates = dateRange(c.from, c.to);
  const cal = await loadCalendar(db, c.from, nextDay(c.to));
  const members = (await db.query(
    `select id, full_name, team_id, cnib, village, phone from workers
      where active and team_id = any($1::uuid[]) order by created_at, full_name`,
    [c.teams.map((t) => t.id)],
  )).rows;
  const known = new Map(members.map((w) => [w.id, w]));
  const extraIds = [...new Set(c.entries.flatMap((e) => Object.keys(e.presence)))].filter((id) => !known.has(id));
  if (extraIds.length) {
    for (const w of (await db.query(
      'select id, full_name, team_id, cnib, village, phone from workers where id = any($1::uuid[]) order by created_at, full_name', [extraIds],
    )).rows) known.set(w.id, w);
  }

  const teams = c.teams.map((t) => {
    const entries = new Map(c.entries.filter((e) => e.teamId === t.id).map((e) => [e.date, e]));
    const days = dates.map((date) => {
      const info = resolveDay(cal, date, t.id);
      const e = entries.get(date);
      const d = e ? computeDay(e, c.tariffs) : null;
      return {
        date,
        working: info.working,
        kind: info.kind,
        entered: Boolean(e),
        bricks: e?.bricks ?? 0,
        present: e ? d.presentCount : 0,
        share: d?.status === DayStatus.OK ? d.share : Rational.ZERO,
        amount: d?.status === DayStatus.OK ? d.total : Rational.ZERO,
        incomplete: Boolean(d) && (d.status === DayStatus.INCOMPLETE || d.status === DayStatus.NO_PRESENT || d.status === DayStatus.NO_TARIFF),
      };
    });

    const rows = new Map();
    const row = (w) => {
      let x = rows.get(w.id);
      if (!x) {
        x = {
          workerId: w.id, fullName: w.full_name, cnib: w.cnib ?? '', village: w.village ?? '', phone: w.phone ?? '',
          substitute: w.team_id !== t.id, marks: dates.map(() => 'n'), days: 0, total: Rational.ZERO,
        };
        rows.set(w.id, x);
      }
      return x;
    };
    for (const w of members.filter((m) => m.team_id === t.id)) row(w);
    dates.forEach((date, i) => {
      const e = entries.get(date);
      if (!e) return;
      const d = computeDay(e, c.tariffs);
      for (const [id, st] of Object.entries(e.presence)) {
        const w = known.get(id);
        if (!w || (st !== 'present' && !rows.has(id))) continue;
        const x = row(w);
        x.marks[i] = st === 'present' ? 'p' : st === 'absent' ? 'a' : 'u';
        if (st === 'present') {
          x.days++;
          if (d.status === DayStatus.OK) x.total = x.total.add(d.share);
        }
      }
    });

    const workers = [...rows.values()];
    return {
      teamId: t.id, name: t.name, shift: t.shift, days, workers,
      totalBricks: days.reduce((n, d) => n + d.bricks, 0),
      totalPresent: days.reduce((n, d) => n + d.present, 0),
      totalAmount: days.reduce((s, d) => s.add(d.amount), Rational.ZERO),
    };
  });

  return {
    ...c.head,
    dates,
    unitPrice: uniformRate(c.tariffs, 'cost', c.from, c.to),
    teams,
    totalBricks: teams.reduce((n, t) => n + t.totalBricks, 0),
    totalAmount: teams.reduce((s, t) => s.add(t.totalAmount), Rational.ZERO),
  };
}

/** Fiche de paie d'une période pour les équipes choisies (null = toutes). */
export async function buildPayrollSheet(db, { from, to, teamIds = null }) {
  return sheetFromContext(db, await loadContext(db, { from, to, teamIds }));
}

/**
 * Paie sur une période libre (semaine, quinzaine…), à titre d'information : mêmes règles que la paie
 * mensuelle (briques × prix de confection ÷ présents), sans validation ni verrouillage.
 * Le règlement officiel reste la paie mensuelle validée.
 */
export function reportsRouter({ db, auth, admin, president }) {
  const r = Router();
  r.use(auth, admin);

  r.get('/period', ah(async (req, res) => {
    const { from, to } = z.object({ from: z.string(), to: z.string() }).parse(req.query);
    assertDate(from, 'début');
    assertDate(to, 'fin');
    if (to < from) throw badRequest('La date de fin précède le début.');
    const days = spanDays(from, to);
    if (days > MAX_DAYS) throw badRequest(`Période trop longue (${MAX_DAYS} jours au maximum).`);

    const [tariffs, entries, teams, names] = await Promise.all([
      loadTariffs(db),
      loadEntries(db, from, nextDay(to)),
      db.query('select id, name from teams').then((x) => new Map(x.rows.map((t) => [t.id, t.name]))),
      db.query('select id, full_name from workers').then((x) => new Map(x.rows.map((w) => [w.id, w.full_name]))),
    ]);

    const workers = new Map();
    const perTeam = new Map();
    let bricks = 0;
    let cost = Rational.ZERO;
    let sale = Rational.ZERO;
    let incomplete = 0;
    for (const e of entries) {
      const d = computeDay(e, tariffs);
      if (d.status === DayStatus.INCOMPLETE || d.status === DayStatus.NO_PRESENT || d.status === DayStatus.NO_TARIFF) incomplete++;
      if (e.bricks != null) {
        bricks += e.bricks;
        const s = productionValue(tariffs, 'sale', e.date, e.bricks);
        if (s) sale = sale.add(s);
      }
      if (d.status !== DayStatus.OK) continue;
      cost = cost.add(d.total);
      perTeam.set(e.teamId, (perTeam.get(e.teamId) ?? Rational.ZERO).add(d.total));
      for (const [id, st] of Object.entries(e.presence)) {
        if (st !== 'present') continue;
        const w = workers.get(id) ?? { total: Rational.ZERO, days: 0 };
        w.total = w.total.add(d.share);
        w.days++;
        workers.set(id, w);
      }
    }

    res.json({
      from, to, label: `${frDate(from)} au ${frDate(to)}`, days,
      bricks, cost, sale, margin: sale.sub(cost), incompleteDays: incomplete,
      teams: [...perTeam.entries()].map(([id, total]) => ({ teamId: id, name: teams.get(id) ?? '—', total }))
        .sort((a, b) => a.name.localeCompare(b.name, 'fr')),
      workers: [...workers.entries()].map(([id, w]) => ({ workerId: id, fullName: names.get(id) ?? '—', days: w.days, total: w.total }))
        .sort((a, b) => a.fullName.localeCompare(b.fullName, 'fr')),
    });
  }));

  // ───────────── Rapports officiels : réservés au président ─────────────

  // Réglages des rapports (libellés, signataires) : rien n'est écrit en dur, tout se modifie dans l'application.
  r.get('/settings', president, ah(async (_req, res) => res.json(await loadReportSettings(db))));

  r.put('/settings', president, ah(async (req, res) => {
    const b = reportSettingsSchema.parse(req.body);
    await db.tx(async (q) => {
      const old = await loadReportSettings(q);
      await q.query(
        `insert into app_settings (key, value, updated_by) values ('report_settings', $1::jsonb, $2)
         on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = now()`,
        [JSON.stringify(b), req.user.id],
      );
      await logAudit(q, req.user, {
        action: 'Réglages des rapports',
        object: 'Rapports',
        oldValue: `${old.signatories.length} signataire(s)`,
        newValue: `${b.signatories.length} signataire(s)`,
      });
    });
    res.json(b);
  }));

  /** Période, équipe et client facultatifs, communs aux trois rapports. */
  async function context(req) {
    const q = z.object({
      from: z.string(), to: z.string(), teamId: z.string().uuid().optional(), clientId: z.string().uuid().optional(),
      // Plusieurs équipes à la fois : identifiants séparés par des virgules (la fiche de paie en choisit 1 ou plusieurs).
      teamIds: z.string().optional(),
    }).parse(req.query);
    const wanted = q.teamIds === undefined
      ? (q.teamId ? [q.teamId] : null)
      : z.array(z.string().uuid()).min(1, 'Choisissez au moins une équipe.').parse(q.teamIds.split(',').map((x) => x.trim()));
    return loadContext(db, { from: q.from, to: q.to, teamIds: wanted, clientId: q.clientId });
  }

  // Rapport de production : une ligne par jour et par poste (jour / nuit), BTC et sacs de ciment,
  // puis montant à payer = briques × prix de vente.
  r.get('/production', president, ah(async (req, res) => {
    const c = await context(req);
    const shifts = ['jour', 'nuit'].filter((s) => c.teams.some((t) => t.shift === s));
    const shiftOf = new Map(c.teams.map((t) => [t.id, t.shift]));
    const rows = new Map();
    for (let d = c.from; d <= c.to; d = nextDay(d)) {
      for (const s of shifts) rows.set(`${d}|${s}`, { date: d, shift: s, bricks: 0, cementBags: 0 });
    }
    let amount = Rational.ZERO;
    let missingPrice = false;
    for (const e of c.entries) {
      const row = rows.get(`${e.date}|${shiftOf.get(e.teamId)}`);
      row.bricks += e.bricks ?? 0;
      row.cementBags += e.cementBags ?? 0;
      if (!e.bricks) continue;
      const v = productionValue(c.tariffs, 'sale', e.date, e.bricks);
      if (v) amount = amount.add(v);
      else missingPrice = true;
    }
    const list = [...rows.values()];
    res.json({
      ...c.head,
      rows: list,
      totalBricks: list.reduce((n, x) => n + x.bricks, 0),
      totalCement: list.reduce((n, x) => n + x.cementBags, 0),
      unitPrice: uniformRate(c.tariffs, 'sale', c.from, c.to),
      amount,
      missingPrice,
    });
  }));

  // Fiche de paie globale : une ligne par date, une colonne (briques, somme) pour CHAQUE équipe enregistrée,
  // même sans production ; somme = briques × prix de confection.
  r.get('/team-payroll', president, ah(async (req, res) => {
    const c = await context(req);
    const byDate = new Map();
    const totals = new Map(c.teams.map((t) => [t.id, { bricks: 0, amount: Rational.ZERO, days: 0 }]));
    for (const e of c.entries) {
      if (e.bricks == null) continue;
      const amount = productionValue(c.tariffs, 'cost', e.date, e.bricks) ?? Rational.ZERO;
      const d = computeDay(e, c.tariffs);
      const day = byDate.get(e.date) ?? new Map();
      day.set(e.teamId, {
        bricks: e.bricks,
        amount,
        // journée à régulariser avant la paie officielle (présences non saisies, aucun présent, tarif manquant)
        incomplete: d.status === DayStatus.INCOMPLETE || d.status === DayStatus.NO_PRESENT || d.status === DayStatus.NO_TARIFF,
      });
      byDate.set(e.date, day);
      const t = totals.get(e.teamId);
      t.bricks += e.bricks;
      t.amount = t.amount.add(amount);
      t.days++;
    }
    const empty = { bricks: 0, amount: Rational.ZERO, incomplete: false };
    const days = [...byDate.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([date, m]) => {
      const cells = c.teams.map((t) => m.get(t.id) ?? empty);
      return {
        date,
        cells,
        bricks: cells.reduce((n, x) => n + x.bricks, 0),
        amount: cells.reduce((s, x) => s.add(x.amount), Rational.ZERO),
      };
    });
    const teams = c.teams.map((t) => ({ teamId: t.id, name: t.name, shift: t.shift, ...totals.get(t.id) }));
    res.json({
      ...c.head,
      teams,
      days,
      totalBricks: teams.reduce((n, t) => n + t.bricks, 0),
      totalAmount: teams.reduce((s, t) => s.add(t.amount), Rational.ZERO),
      unitPrice: uniformRate(c.tariffs, 'cost', c.from, c.to),
    });
  }));

  // Rapport de présence : par équipe, chaque membre (et remplaçant) avec son nombre de jours présent.
  r.get('/attendance', president, ah(async (req, res) => {
    const c = await context(req);
    const members = (await db.query(
      'select id, full_name, team_id from workers where active and team_id = any($1::uuid[])',
      [c.teams.map((t) => t.id)],
    )).rows;
    const names = new Map(members.map((w) => [w.id, w.full_name]));
    const missing = [...new Set(c.entries.flatMap((e) => Object.keys(e.presence)))].filter((id) => !names.has(id));
    if (missing.length) {
      for (const w of (await db.query('select id, full_name from workers where id = any($1::uuid[])', [missing])).rows) names.set(w.id, w.full_name);
    }

    const teams = c.teams.map((t) => {
      const stats = new Map(members.filter((w) => w.team_id === t.id)
        .map((w) => [w.id, { workerId: w.id, fullName: w.full_name, present: 0, absent: 0, substitute: false }]));
      const entries = c.entries.filter((e) => e.teamId === t.id);
      for (const e of entries) {
        for (const [id, st] of Object.entries(e.presence)) {
          let w = stats.get(id);
          if (!w) {
            if (st !== 'present') continue;
            w = { workerId: id, fullName: names.get(id) ?? '—', present: 0, absent: 0, substitute: true };
            stats.set(id, w);
          }
          if (st === 'present') w.present++;
          else if (st === 'absent') w.absent++;
        }
      }
      return {
        teamId: t.id, name: t.name, shift: t.shift, days: entries.length,
        members: [...stats.values()].sort((a, b) => Number(a.substitute) - Number(b.substitute) || a.fullName.localeCompare(b.fullName, 'fr')),
      };
    });
    res.json({ ...c.head, teams });
  }));

  // Fiche de paie : par équipe, une colonne par jour (présent / absent / repos), montant par ouvrier,
  // total de l'équipe et total général. Ouverte à tous les admins (le trésorier l'établit) ; chaque
  // ouvrier la signe en face de son montant. Même calcul exact que la paie mensuelle.
  r.get('/payroll-sheet', ah(async (req, res) => res.json(await sheetFromContext(db, await context(req)))));

  return r;
}
