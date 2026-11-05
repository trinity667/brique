import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { startTestApp } from './helpers.js';

let ctx;
let admin1; // trésorier : établit
let admin3; // autre admin
let president; // Admin 2
let sup1;
let T1; let T2;

const save = (token, team, date, bricks, cementBags, present = 10, unset = false) => ctx.api('PUT', '/api/days', {
  token,
  body: {
    teamId: team.id, date, bricks, cementBags,
    presences: team.workerIds.map((id, i) => ({ workerId: id, status: unset && i === 0 ? 'unset' : i < present ? 'present' : 'absent' })),
  },
});
const post = (path, body, token = admin1) => ctx.api('POST', `/api/payroll-sheets${path}`, { token, body });
const get = (path = '', token = admin1) => ctx.api('GET', `/api/payroll-sheets${path}`, { token });

before(async () => {
  ctx = await startTestApp();
  [T1, T2] = ctx.seed.teams;
  await ctx.db.query("update users set is_president = true where name = 'Admin 2'");
  admin1 = await ctx.login('Admin 1', '1234');
  president = await ctx.login('Admin 2', '2345');
  admin3 = await ctx.login('Admin 3', '3456');
  sup1 = await ctx.login('Ouédraogo Issa', '1111');
  assert.equal((await save(admin1, T1, '2025-06-09', 855, 9)).status, 200);
  assert.equal((await save(admin1, T2, '2025-06-09', 190, 2, 8)).status, 200);
  assert.equal((await save(admin1, T1, '2025-06-10', 734, 8)).status, 200);
});
after(() => ctx.close());

test('établir : numéro, photo figée qui ne bouge plus quand les saisies changent', async () => {
  const body = { from: '2025-06-09', to: '2025-06-10', teamIds: [T1.id] };
  assert.equal((await post('', body, sup1)).status, 403);

  const created = await post('', body);
  assert.equal(created.status, 201, JSON.stringify(created.body));
  assert.match(created.body.number, /^FP-\d{4}-001$/);

  const one = (await get(`/${created.body.id}`)).body;
  assert.equal(one.status, 'established');
  assert.deepEqual([one.from, one.to, one.teamNames, one.totalBricks], ['2025-06-09', '2025-06-10', ['Équipe 1'], 1589]);
  assert.equal(one.sheet.totalAmount.exact, '278075/1');
  assert.equal(one.establishedBy.name, 'Admin 1');
  assert.equal(one.approvedBy, null);

  // La saisie change après coup : la fiche établie reste identique, la fiche « en direct » suit.
  assert.equal((await save(admin1, T1, '2025-06-10', 1000, 8)).status, 200);
  const frozen = (await get(`/${created.body.id}`)).body;
  assert.equal(frozen.sheet.totalAmount.exact, '278075/1');
  const live = (await ctx.api('GET', `/api/reports/payroll-sheet?from=2025-06-09&to=2025-06-10&teamIds=${T1.id}`, { token: admin1 })).body;
  assert.notEqual(live.totalAmount.exact, '278075/1');
  assert.equal((await save(admin1, T1, '2025-06-10', 734, 8)).status, 200); // remise comme avant
});

test('chevauchement : pas de double fiche pour la même équipe, autre équipe possible', async () => {
  const dup = await post('', { from: '2025-06-10', to: '2025-06-12', teamIds: [T1.id] });
  assert.equal(dup.status, 409);
  assert.equal(dup.body.code, 'overlap');
  assert.match(dup.body.error, /FP-\d{4}-001/);
  const other = await post('', { from: '2025-06-09', to: '2025-06-10', teamIds: [T2.id] });
  assert.equal(other.status, 201);
  assert.match(other.body.number, /-002$/);
  assert.equal((await get()).body.length, 2);
});

test('refus : aucune saisie, ou journée incomplète à régulariser', async () => {
  const empty = await post('', { from: '2025-07-01', to: '2025-07-05' });
  assert.equal(empty.status, 400);
  assert.equal((await save(admin1, T2, '2025-06-12', 100, 1, 10, true)).status, 200); // un « non saisi »
  const bad = await post('', { from: '2025-06-12', to: '2025-06-12', teamIds: [T2.id] });
  assert.equal(bad.status, 409);
  assert.equal(bad.body.code, 'incomplete_days');
  assert.match(bad.body.error, /Équipe 2 \(12\/06\)/);
});

test('approbation : président seulement, jamais celui qui a établi la fiche', async () => {
  const list = (await get('?status=established')).body;
  const sheet = list.find((s) => s.teamNames[0] === 'Équipe 1');
  assert.equal((await post(`/${sheet.id}/approve`, {}, admin3)).status, 403); // pas le président
  assert.equal((await post(`/${sheet.id}/approve`, {}, sup1)).status, 403);

  assert.equal((await post(`/${sheet.id}/approve`, {}, president)).status, 200);
  const ok = (await get(`/${sheet.id}`)).body;
  assert.deepEqual([ok.status, ok.approvedBy.name], ['approved', 'Admin 2']);
  assert.equal((await post(`/${sheet.id}/approve`, {}, president)).status, 409); // déjà approuvée

  // Fiche établie par le président lui-même : il ne peut pas l'approuver.
  assert.equal((await save(admin1, T1, '2025-06-11', 500, 5)).status, 200);
  const mine = await post('', { from: '2025-06-11', to: '2025-06-11', teamIds: [T1.id] }, president);
  assert.equal(mine.status, 201);
  const self = await post(`/${mine.body.id}/approve`, {}, president);
  assert.equal(self.status, 403);
  assert.match(self.body.error, /autre personne/);
  assert.equal((await post(`/${mine.body.id}/approve`, {}, admin3)).status, 403); // admin3 n'est pas président
  const { rows } = await ctx.db.query("select count(*)::int as n from audit_log where action = 'Approbation refusée'");
  assert.equal(rows[0].n, 1);
});

test('annulation motivée : établie par tout admin, approuvée par le président seul ; ré-établir ensuite', async () => {
  const all = (await get()).body;
  const approved = all.find((s) => s.status === 'approved');
  const pending = all.find((s) => s.teamNames[0] === 'Équipe 2' && s.status === 'established');

  assert.equal((await post(`/${pending.id}/cancel`, { reason: 'x' }, admin3)).status, 400); // motif trop court
  assert.equal((await post(`/${pending.id}/cancel`, { reason: 'Erreur de période' }, admin3)).status, 200);
  assert.equal((await post(`/${pending.id}/cancel`, { reason: 'Encore' }, admin3)).status, 409);
  assert.equal((await post(`/${pending.id}/approve`, {}, president)).status, 409); // annulée

  assert.equal((await post(`/${approved.id}/cancel`, { reason: 'Montants contestés' }, admin3)).status, 403);
  assert.equal((await post(`/${approved.id}/cancel`, { reason: 'Montants contestés' }, president)).status, 200);
  const c = (await get(`/${approved.id}`)).body;
  assert.deepEqual([c.status, c.cancelled.by, c.cancelled.reason], ['cancelled', 'Admin 2', 'Montants contestés']);

  // La période est libre à nouveau : on peut établir une nouvelle fiche, avec le numéro suivant.
  const again = await post('', { from: '2025-06-09', to: '2025-06-10', teamIds: [T1.id] });
  assert.equal(again.status, 201);
  assert.match(again.body.number, /-004$/);
});

test('garde en base : ni suppression, ni modification du contenu, ni retour en arrière', async () => {
  const { rows } = await ctx.db.query("select id, status from payroll_sheets where status = 'cancelled' limit 1");
  await assert.rejects(ctx.db.query('delete from payroll_sheets'), /ne se supprime pas/);
  await assert.rejects(ctx.db.query("update payroll_sheets set snapshot = '{}'::jsonb"), /ne se modifie pas/);
  await assert.rejects(ctx.db.query("update payroll_sheets set period_to = '2030-01-01'"), /ne se modifie pas/);
  await assert.rejects(ctx.db.query("update payroll_sheets set status = 'established' where id = $1", [rows[0].id]), /ne peut plus changer/);
});
