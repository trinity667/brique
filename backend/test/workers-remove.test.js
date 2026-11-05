import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { startTestApp } from './helpers.js';

let ctx;
let admin;
let sup1;
let T1;

before(async () => {
  ctx = await startTestApp();
  [T1] = ctx.seed.teams;
  admin = await ctx.login('Admin 1', '1234');
  sup1 = await ctx.login('Ouédraogo Issa', '1111');
});
after(() => ctx.close());

const add = async (name) => (await ctx.api('POST', '/api/workers', { token: admin, body: { fullName: name, teamId: T1.id } })).body.id;
const find = async (id) => (await ctx.api('GET', '/api/workers', { token: admin })).body.find((w) => w.id === id);

test('ouvrier sans historique : supprimé définitivement (admin seul, tracé)', async () => {
  const id = await add('Ouvrier Erreur');
  assert.equal((await find(id)).hasHistory, false);

  assert.equal((await ctx.api('DELETE', `/api/workers/${id}`, { token: sup1 })).status, 403);
  assert.ok(await find(id), 'le superviseur ne supprime rien');

  assert.equal((await ctx.api('DELETE', `/api/workers/${id}`, { token: admin })).status, 200);
  assert.equal(await find(id), undefined);
  assert.equal((await ctx.api('DELETE', `/api/workers/${id}`, { token: admin })).status, 404);
  const { rows } = await ctx.db.query('select count(*)::int as n from audit_log where action = $1', ["Suppression d'ouvrier"]);
  assert.equal(rows[0].n, 1);
});

test('ouvrier avec historique : suppression refusée, retrait possible puis réactivation', async () => {
  const id = T1.workerIds[1];
  // Une journée saisie : l'ouvrier a des présences.
  const day = await ctx.api('PUT', '/api/days', {
    token: admin,
    body: { teamId: T1.id, date: '2025-06-09', bricks: 100, presences: T1.workerIds.map((w) => ({ workerId: w, status: 'present' })) },
  });
  assert.equal(day.status, 200);
  assert.equal((await find(id)).hasHistory, true);

  const del = await ctx.api('DELETE', `/api/workers/${id}`, { token: admin });
  assert.equal(del.status, 409);
  assert.equal(del.body.code, 'has_history');
  assert.ok(await find(id));

  // Retrait : il sort de la saisie, son historique reste.
  assert.equal((await ctx.api('PATCH', `/api/workers/${id}`, { token: admin, body: { active: false } })).status, 200);
  assert.equal((await find(id)).active, false);
  const { rows } = await ctx.db.query('select count(*)::int as n from day_presences where worker_id = $1', [id]);
  assert.equal(rows[0].n, 1);

  // Réactivation.
  assert.equal((await ctx.api('PATCH', `/api/workers/${id}`, { token: admin, body: { active: true } })).status, 200);
  assert.equal((await find(id)).active, true);
});

test("superviseur : retire un membre de SON équipe seulement, sans pouvoir supprimer ni réactiver", async () => {
  const id = await add('Membre à retirer');
  const other = ctx.seed.teams[1].workerIds[1];
  assert.equal((await ctx.api('POST', `/api/workers/${other}/remove`, { token: sup1 })).status, 403); // autre équipe
  assert.equal((await find(other)).active, true);
  assert.equal((await ctx.api('POST', `/api/workers/${T1.workerIds[0]}/remove`, { token: sup1 })).status, 409); // lui-même

  assert.equal((await ctx.api('POST', `/api/workers/${id}/remove`, { token: sup1 })).status, 200);
  const w = await find(id);
  assert.equal(w.active, false); // retiré, pas supprimé : l'historique reste possible
  assert.equal((await ctx.api('POST', `/api/workers/${id}/remove`, { token: sup1 })).status, 404); // déjà retiré
  const mine = (await ctx.api('GET', '/api/workers', { token: sup1 })).body;
  assert.equal(mine.some((x) => x.id === id), false);

  assert.equal((await ctx.api('DELETE', `/api/workers/${id}`, { token: sup1 })).status, 403);
  assert.equal((await ctx.api('PATCH', `/api/workers/${id}`, { token: sup1, body: { active: true } })).status, 403);
  const { rows } = await ctx.db.query('select count(*)::int as n from audit_log where action = $1', ["Retrait d'ouvrier"]);
  assert.equal(rows[0].n, 1);
});

test('superviseur : ni supprimé ni retiré', async () => {
  const id = T1.workerIds[0]; // ouvrier du superviseur
  const del = await ctx.api('DELETE', `/api/workers/${id}`, { token: admin });
  assert.equal(del.status, 409);
  assert.equal(del.body.code, 'is_supervisor');
  const off = await ctx.api('PATCH', `/api/workers/${id}`, { token: admin, body: { active: false } });
  assert.equal(off.status, 409);
  assert.equal(off.body.code, 'is_supervisor');
  assert.equal((await find(id)).active, true);
});
