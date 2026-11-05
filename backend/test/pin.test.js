import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { startTestApp } from './helpers.js';
import { generateTempPin, isWeakPin } from '../src/lib/pin.js';

let ctx;
let admin1; let president; let sup1;
let T1;

const api = (method, path, token, body) => ctx.api(method, path, { token, body });
const login = (name, pin) => ctx.api('POST', '/api/auth/login', { body: { name, pin } });
const userId = async (name) => (await ctx.db.query('select id from users where name = $1', [name])).rows[0].id;

before(async () => {
  ctx = await startTestApp();
  [T1] = ctx.seed.teams;
  await ctx.db.query("update users set is_president = true where name = 'Admin 2'");
  admin1 = await ctx.login('Admin 1', '1234');
  president = await ctx.login('Admin 2', '2345');
  sup1 = await ctx.login('Ouédraogo Issa', '1111');
});
after(() => ctx.close());

test('codes trop simples reconnus, codes provisoires toujours solides', () => {
  for (const weak of ['0000', '1111', '1234', '4321', '123456', '654321', '1212', '121212', '123123', '9999']) {
    assert.equal(isWeakPin(weak), true, weak);
  }
  for (const ok of ['4827', '739214', '1357', '2468', '908172']) assert.equal(isWeakPin(ok), false, ok);
  for (let i = 0; i < 300; i++) {
    const pin = generateTempPin();
    assert.match(pin, /^[1-9]\d{5}$/);
    assert.equal(isWeakPin(pin), false, pin);
  }
});

test('changer son propre code : contrôles, anciennes connexions fermées, nouveau jeton', async () => {
  const t = await ctx.login('Admin 3', '3456');
  const change = (currentPin, newPin, token = t) => api('PUT', '/api/auth/pin', token, { currentPin, newPin });

  const weak = await change('3456', '1234');
  assert.equal(weak.status, 400);
  assert.match(JSON.stringify(weak.body), /trop simple/);
  assert.equal((await change('3456', '12')).status, 400);
  assert.equal((await change('0000', '739214')).status, 422); // code actuel faux : 422, la session reste ouverte
  assert.equal((await api('GET', '/api/auth/me', t)).status, 200);

  const ok = await change('3456', '739214');
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  assert.equal(ok.body.user.mustChangePin, false);
  assert.ok(ok.body.token && ok.body.token !== t);

  // L'ancienne connexion est fermée, la nouvelle fonctionne ; l'ancien code ne marche plus.
  assert.equal((await api('GET', '/api/auth/me', t)).status, 401);
  assert.equal((await api('GET', '/api/auth/me', ok.body.token)).status, 200);
  assert.equal((await login('Admin 3', '3456')).status, 401);
  assert.equal((await login('Admin 3', '739214')).status, 200);

  // Le nouveau code doit différer de l'actuel.
  const same = await change('739214', '739214', ok.body.token);
  assert.equal(same.status, 400);
  assert.match(same.body.error, /différent/);

  const { rows } = await ctx.db.query("select count(*)::int as n from audit_log where action = 'Changement de PIN'");
  assert.equal(rows[0].n, 1);
});

test('code actuel faux : compte comme un échec de connexion et verrouille au bout de 5 essais', async () => {
  const t = await ctx.login('Tapsoba Idrissa', '2222');
  const statuses = [];
  for (let i = 0; i < 5; i++) statuses.push((await api('PUT', '/api/auth/pin', t, { currentPin: '0000', newPin: '739214' })).status);
  assert.deepEqual(statuses, [422, 422, 422, 422, 423]);
  assert.equal((await api('PUT', '/api/auth/pin', t, { currentPin: '2222', newPin: '739214' })).status, 423);
  assert.equal((await login('Tapsoba Idrissa', '2222')).status, 423);
});

test('réinitialisation d\'un superviseur : code provisoire aléatoire, changement obligatoire, sessions fermées', async () => {
  const id = await userId('Ouédraogo Issa');
  assert.equal((await api('POST', `/api/supervisors/${id}/reset-pin`, sup1)).status, 403); // pas un admin
  assert.equal((await api('POST', `/api/supervisors/${await userId('Admin 3')}/reset-pin`, admin1)).status, 404); // pas un superviseur

  const reset = await api('POST', `/api/supervisors/${id}/reset-pin`, admin1);
  assert.equal(reset.status, 200);
  const temp = reset.body.pin;
  assert.match(temp, /^\d{6}$/);
  assert.equal(isWeakPin(temp), false);

  // Ancienne connexion fermée, ancien code refusé, code provisoire accepté.
  assert.equal((await api('GET', '/api/auth/me', sup1)).status, 401);
  assert.equal((await login('Ouédraogo Issa', '1111')).status, 401);
  const first = await login('Ouédraogo Issa', temp);
  assert.equal(first.status, 200);
  assert.equal(first.body.user.mustChangePin, true);

  // Tant que le code n'est pas changé : rien d'autre que « me », « logout » et le changement de code.
  const blocked = await api('GET', '/api/workers', first.body.token);
  assert.equal(blocked.status, 403);
  assert.equal(blocked.body.code, 'must_change_pin');
  assert.equal((await api('GET', '/api/auth/me', first.body.token)).status, 200);

  const done = await api('PUT', '/api/auth/pin', first.body.token, { currentPin: temp, newPin: '580246' });
  assert.equal(done.status, 200);
  assert.equal(done.body.user.mustChangePin, false);
  assert.equal((await api('GET', '/api/workers', done.body.token)).status, 200);
  assert.equal((await login('Ouédraogo Issa', temp)).status, 401);

  // Le code provisoire n'est écrit nulle part dans le journal.
  const leak = await ctx.db.query(
    "select count(*)::int as n from audit_log where coalesce(object,'') || coalesce(old_value,'') || coalesce(new_value,'') || coalesce(reason,'') like $1",
    [`%${temp}%`],
  );
  assert.equal(leak.rows[0].n, 0);
  const trace = await ctx.db.query("select count(*)::int as n from audit_log where action = 'Réinitialisation du PIN' and user_name = 'Admin 1'");
  assert.equal(trace.rows[0].n, 1);
});

test('administrateurs : le président voit les admins et réinitialise leur code, pas le sien ni celui du président', async () => {
  assert.equal((await api('GET', '/api/admins', admin1)).status, 403); // admin simple
  const supTok = (await login('Ouédraogo Issa', '580246')).body.token; // son ancienne connexion a été fermée par la réinitialisation
  assert.equal((await api('GET', '/api/admins', supTok)).status, 403);
  const list = (await api('GET', '/api/admins', president)).body;
  assert.deepEqual(list.map((a) => [a.name, a.isPresident]), [['Admin 2', true], ['Admin 1', false], ['Admin 3', false]]);

  const id1 = await userId('Admin 1');
  assert.equal((await api('POST', `/api/admins/${id1}/reset-pin`, admin1)).status, 403); // pas le président
  assert.equal((await api('POST', `/api/admins/${await userId('Admin 2')}/reset-pin`, president)).status, 400); // soi-même

  const reset = await api('POST', `/api/admins/${id1}/reset-pin`, president);
  assert.equal(reset.status, 200);
  assert.equal((await api('GET', '/api/auth/me', admin1)).status, 401); // sa connexion est fermée
  const again = await login('Admin 1', reset.body.pin);
  assert.equal(again.body.user.mustChangePin, true);
  assert.equal((await api('GET', '/api/admins', president)).body.find((a) => a.name === 'Admin 1').mustChangePin, true);
  assert.equal((await api('GET', '/api/tariffs', again.body.token)).status, 403); // bloqué jusqu'au changement
});

test('nouveau superviseur : son code initial est provisoire, à changer à la première connexion', async () => {
  const adminTok = (await login('Admin 3', '739214')).body.token;
  const w = await api('POST', '/api/workers', adminTok, { fullName: 'Nouveau Chef', teamId: T1.id });
  assert.equal(w.status, 201, JSON.stringify(w.body));
  assert.equal((await api('POST', '/api/supervisors', adminTok, { workerId: w.body.id, pin: '5678' })).status, 201);
  const first = await login('Nouveau Chef', '5678');
  assert.equal(first.body.user.mustChangePin, true);
  assert.equal((await api('GET', '/api/workers', first.body.token)).status, 403);
});
