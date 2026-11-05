import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { startTestApp } from './helpers.js';
import { todayStr } from '../src/lib/dates.js';

let ctx;
let admin;
let sup1;
let T1; let T2;

const addDays = (date, n) => new Date(Date.parse(`${date}T00:00:00Z`) + n * 86_400_000).toISOString().slice(0, 10);
// Les 4 derniers jours travaillés (hors dimanche) avant aujourd'hui.
const days = [];
for (let d = addDays(todayStr(), -1); days.length < 4; d = addDays(d, -1)) {
  if (new Date(`${d}T00:00:00Z`).getUTCDay() !== 0) days.push(d);
}

const save = (team, date, bricks, cementBags) => ctx.api('PUT', '/api/days', {
  token: admin,
  body: { teamId: team.id, date, bricks, cementBags, presences: team.workerIds.map((id) => ({ workerId: id, status: 'present' })) },
});
const alerts = async () => (await ctx.api('GET', '/api/alerts', { token: admin })).body.alerts;
const rules = (body, token = admin) => ctx.api('PUT', '/api/alerts/settings', { token, body });

before(async () => {
  ctx = await startTestApp();
  [T1, T2] = ctx.seed.teams;
  admin = await ctx.login('Admin 1', '1234');
  sup1 = await ctx.login('Ouédraogo Issa', '1111');
  for (const d of days) {
    assert.equal((await save(T1, d, 600, 3)).status, 200); // 200 briques par sac, sous l'objectif
    assert.equal((await save(T2, d, 950, 10)).status, 200); // 95 briques par sac, objectif atteint
  }
});
after(() => ctx.close());

test('sans règle renseignée : aucune alerte ciment ni objectif', async () => {
  const def = (await ctx.api('GET', '/api/alerts/settings', { token: admin })).body;
  assert.deepEqual(def, { bricksPerBag: null, tolerancePct: 20, dailyTarget: null });
  const kinds = (await alerts()).map((a) => a.kind);
  assert.ok(!kinds.includes('cement_ratio') && !kinds.includes('below_target'));
});

test('règles : admin seulement, valeurs contrôlées, tracées', async () => {
  assert.equal((await rules({ bricksPerBag: 95 }, sup1)).status, 403);
  assert.equal((await rules({ bricksPerBag: 0 })).status, 400);
  assert.equal((await rules({ tolerancePct: 99 })).status, 400);
  const ok = await rules({ bricksPerBag: 95, tolerancePct: 20, dailyTarget: 800 });
  assert.equal(ok.status, 200);
  assert.deepEqual((await ctx.api('GET', '/api/alerts/settings', { token: admin })).body, { bricksPerBag: 95, tolerancePct: 20, dailyTarget: 800 });
  const { rows } = await ctx.db.query("select count(*)::int as n from audit_log where action = $1", ["Règles d'alerte"]);
  assert.equal(rows[0].n, 1);
});

test('alerte ciment : seule l\'équipe au ratio anormal est signalée', async () => {
  const list = await alerts();
  const cement = list.filter((a) => a.kind === 'cement_ratio');
  assert.equal(cement.length, 1);
  assert.match(cement[0].title, /Équipe 1 : briques par sac de ciment anormal \(4 jours\)/);
  assert.match(cement[0].detail, /200/);
  assert.match(cement[0].detail, /attendu ≈ 95/);
  assert.ok(cement[0].id.startsWith('cement_ratio:'));
});

test('alerte objectif : sous l\'objectif au moins 3 jours sur 7, seule l\'équipe concernée', async () => {
  const low = (await alerts()).filter((a) => a.kind === 'below_target');
  assert.equal(low.length, 1);
  assert.match(low[0].title, /Équipe 1 : sous l'objectif 4 jours sur 7/);
  assert.match(low[0].detail, /Objectif 800 briques par jour/);
});

test('règle assouplie ou retirée : les alertes disparaissent', async () => {
  // 200 briques/sac devient normal pour 190 ± 20 % (l'équipe 1 n'est plus signalée) et l'objectif passe à 500 ;
  // c'est maintenant l'équipe 2 (95 par sac) qui s'écarte de la règle.
  assert.equal((await rules({ bricksPerBag: 190, tolerancePct: 20, dailyTarget: 500 })).status, 200);
  const list = await alerts();
  assert.ok(!list.some((a) => a.kind === 'below_target'));
  const cement = list.filter((a) => a.kind === 'cement_ratio');
  assert.equal(cement.length, 1);
  assert.match(cement[0].title, /Équipe 2/);
  assert.equal((await rules({ bricksPerBag: null, tolerancePct: 20, dailyTarget: null })).status, 200);
  assert.ok(!(await alerts()).some((a) => a.kind === 'cement_ratio'));
});
