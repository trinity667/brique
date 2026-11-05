import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { startTestApp } from './helpers.js';

let ctx;
let admin1; let president;

const api = (method, path, token, body) => ctx.api(method, path, { token, body });
const login = (name, pin) => ctx.api('POST', '/api/auth/login', { body: { name, pin } });
const userId = async (name) => (await ctx.db.query('select id from users where name = $1', [name])).rows[0].id;

before(async () => {
  ctx = await startTestApp();
  await ctx.db.query("update users set is_president = true where name = 'Admin 2'");
  admin1 = await ctx.login('Admin 1', '1234');
  president = await ctx.login('Admin 2', '2345');
});
after(() => ctx.close());

test('superviseur : renommer (nom de connexion et fiche ouvrier), doublon refusé, désactiver / réactiver', async () => {
  const supId = await userId('Ouédraogo Issa');
  const w = (await ctx.db.query('select worker_id from users where id = $1', [supId])).rows[0].worker_id;

  assert.equal((await api('PATCH', `/api/supervisors/${supId}`, admin1, { name: 'Tapsoba Idrissa' })).status, 409);
  assert.equal((await api('PATCH', `/api/supervisors/${supId}`, admin1, {})).status, 400);
  assert.equal((await api('PATCH', `/api/supervisors/${supId}`, admin1, { name: 'Issa Ouédraogo' })).status, 200);
  assert.equal((await ctx.db.query('select full_name from workers where id = $1', [w])).rows[0].full_name, 'Issa Ouédraogo');
  assert.equal((await login('Ouédraogo Issa', '1111')).status, 401); // l'ancien nom ne connecte plus
  assert.equal((await login('Issa Ouédraogo', '1111')).status, 200);

  assert.equal((await api('PATCH', `/api/supervisors/${supId}`, admin1, { active: false })).status, 200);
  assert.equal((await login('Issa Ouédraogo', '1111')).status, 401);
  assert.equal((await api('PATCH', `/api/supervisors/${supId}`, admin1, { active: true })).status, 200);
  assert.equal((await login('Issa Ouédraogo', '1111')).status, 200);
});

test('admins : renommer et désactiver réservés au président ; ni soi-même ni le président ; accès coupé aussitôt', async () => {
  const id3 = await userId('Admin 3');
  const id2 = await userId('Admin 2');
  assert.equal((await api('PATCH', `/api/admins/${id3}`, admin1, { name: 'Trésorier' })).status, 403); // admin simple
  assert.equal((await api('PATCH', `/api/admins/${id2}`, president, { name: 'Autre' })).status, 400); // soi-même
  assert.equal((await api('PATCH', `/api/admins/${id3}`, president, { name: 'Admin 1' })).status, 409); // doublon
  assert.equal((await api('PATCH', `/api/admins/${id3}`, president, {})).status, 400);
  assert.equal((await api('PATCH', `/api/admins/${id3}`, president, { name: 'Trésorier' })).status, 200);

  const treasurer = (await login('Trésorier', '3456')).body.token;
  assert.equal((await api('GET', '/api/auth/me', treasurer)).status, 200);
  assert.equal((await api('PATCH', `/api/admins/${id3}`, president, { active: false })).status, 200);
  assert.equal((await api('GET', '/api/auth/me', treasurer)).status, 401); // accès coupé aussitôt
  assert.equal((await login('Trésorier', '3456')).status, 401);
  assert.equal((await api('PATCH', `/api/admins/${id3}`, president, { active: true })).status, 200);
  assert.equal((await login('Trésorier', '3456')).status, 200);

  const { rows } = await ctx.db.query(
    "select count(*)::int as n from audit_log where action in ('Renommage de compte', 'Désactivation de compte', 'Réactivation de compte')",
  );
  assert.equal(rows[0].n, 6); // 3 pour le superviseur + 3 pour l'admin
});
