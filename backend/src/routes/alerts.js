import { Router } from 'express';
import { z } from 'zod';
import { ah } from '../lib/errors.js';
import { todayStr } from '../lib/dates.js';
import { logAudit } from '../lib/audit.js';
import { alertRulesSchema, buildAlerts, loadAlertRules } from '../services/alerts.js';

const keys = z.object({
  ids: z.array(z.string().min(1).max(300)).min(1).max(500).optional(),
  all: z.boolean().optional(),
}).refine((b) => b.ids || b.all, 'Indiquez les alertes ou « all ».');

/**
 * Alertes de l'admin. Elles sont calculées à la demande ; « ignorer » mémorise seulement l'identifiant
 * (stable) de l'alerte, commun à tous les admins. Une alerte ignorée revient d'elle-même si la situation change.
 */
export function alertsRouter({ db, auth, admin }) {
  const r = Router();
  r.use(auth, admin);

  const dismissedIds = async (q) => new Map((await q.query('select alert_id, title from dismissed_alerts')).rows.map((x) => [x.alert_id, x.title]));

  // Alertes à traiter ; `?dismissed=1` liste celles qui ont été ignorées (pour les rétablir).
  r.get('/', ah(async (req, res) => {
    const [alerts, dismissed] = await Promise.all([buildAlerts(db, todayStr()), dismissedIds(db)]);
    const active = alerts.filter((a) => !dismissed.has(a.id));
    const ignored = alerts.filter((a) => dismissed.has(a.id));
    if (req.query.dismissed) return res.json({ count: ignored.length, alerts: ignored });
    res.json({
      count: active.length,
      high: active.filter((a) => a.level === 'high').length,
      dismissedCount: ignored.length,
      alerts: active,
    });
  }));

  // Règles d'alerte réglables (briques par sac de ciment, objectif de production) : toutes facultatives.
  r.get('/settings', ah(async (_req, res) => res.json(await loadAlertRules(db))));

  r.put('/settings', ah(async (req, res) => {
    const b = alertRulesSchema.parse(req.body);
    await db.tx(async (q) => {
      const old = await loadAlertRules(q);
      await q.query(
        `insert into app_settings (key, value, updated_by) values ('alert_rules', $1::jsonb, $2)
         on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = now()`,
        [JSON.stringify(b), req.user.id],
      );
      const show = (x) => `${x.bricksPerBag ? `${x.bricksPerBag} briques/sac ±${x.tolerancePct} %` : 'sans règle ciment'} · ${x.dailyTarget ? `objectif ${x.dailyTarget}/jour` : 'sans objectif'}`;
      await logAudit(q, req.user, { action: "Règles d'alerte", object: 'Alertes', oldValue: show(old), newValue: show(b) });
    });
    res.json(b);
  }));

  // Ignorer une, plusieurs ou toutes les alertes affichées. Les identifiants inconnus sont ignorés ;
  // les anciennes mémorisations devenues sans objet (situation réglée) sont nettoyées au passage.
  r.post('/dismiss', ah(async (req, res) => {
    const b = keys.parse(req.body);
    const alerts = await buildAlerts(db, todayStr());
    const live = new Set(alerts.map((a) => a.id));
    const wanted = b.all ? alerts : alerts.filter((a) => b.ids.includes(a.id));
    let n = 0;
    await db.tx(async (q) => {
      for (const a of wanted) {
        const { rows } = await q.query(
          `insert into dismissed_alerts (alert_id, title, dismissed_by) values ($1, $2, $3)
           on conflict (alert_id) do nothing returning alert_id`,
          [a.id, a.title, req.user.id],
        );
        n += rows.length;
      }
      await q.query('delete from dismissed_alerts where not (alert_id = any($1::text[]))', [[...live]]);
      if (n) await logAudit(q, req.user, { action: 'Alertes ignorées', object: 'Alertes', newValue: `${n} alerte(s)` });
    });
    res.json({ dismissed: n });
  }));

  // Rétablir une, plusieurs ou toutes les alertes ignorées.
  r.post('/restore', ah(async (req, res) => {
    const b = keys.parse(req.body);
    let n = 0;
    await db.tx(async (q) => {
      const { rows } = b.all
        ? await q.query('delete from dismissed_alerts returning alert_id')
        : await q.query('delete from dismissed_alerts where alert_id = any($1::text[]) returning alert_id', [b.ids]);
      n = rows.length;
      if (n) await logAudit(q, req.user, { action: 'Alertes rétablies', object: 'Alertes', newValue: `${n} alerte(s)` });
    });
    res.json({ restored: n });
  }));

  return r;
}
