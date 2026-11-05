import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { startTestApp } from './helpers.js';

let ctx;
let admin;     // Admin 1 : admin simple
let president; // Admin 2 : désigné président
let sup1;
let T1; let T2;

const Q = '?from=2025-06-09&to=2025-06-10';

const save = (token, team, date, bricks, cementBags, present = 10) => ctx.api('PUT', '/api/days', {
  token,
  body: {
    teamId: team.id, date, bricks, cementBags,
    presences: team.workerIds.map((id, i) => ({ workerId: id, status: i < present ? 'present' : 'absent' })),
  },
});

before(async () => {
  ctx = await startTestApp();
  [T1, T2] = ctx.seed.teams;
  await ctx.db.query("update users set is_president = true where name = 'Admin 2'");
  admin = await ctx.login('Admin 1', '1234');
  president = await ctx.login('Admin 2', '2345');
  sup1 = await ctx.login('Ouédraogo Issa', '1111');
  // Équipe 2 = poste de nuit.
  assert.equal((await ctx.api('PUT', `/api/teams/${T2.id}/shift`, { token: admin, body: { shift: 'nuit' } })).status, 200);
  assert.equal((await save(admin, T1, '2025-06-09', 855, 9)).status, 200);
  assert.equal((await save(admin, T2, '2025-06-09', 190, 2, 8)).status, 200);
  assert.equal((await save(admin, T1, '2025-06-10', 734, 8)).status, 200);
});
after(() => ctx.close());

test('rapports : réservés au président (admin simple et superviseur refusés, refus tracé)', async () => {
  for (const path of ['/api/reports/production', '/api/reports/team-payroll', '/api/reports/attendance']) {
    assert.equal((await ctx.api('GET', path + Q, { token: admin })).status, 403);
    assert.equal((await ctx.api('GET', path + Q, { token: sup1 })).status, 403);
    assert.equal((await ctx.api('GET', path + Q, { token: president })).status, 200);
  }
  const { rows } = await ctx.db.query("select count(*)::int as n from audit_log where reason = 'Réservé au président'");
  assert.equal(rows[0].n, 3);
  // Le président est signalé à la connexion ; seul un admin peut l'être.
  const me = await ctx.api('GET', '/api/auth/me', { token: president });
  assert.equal(me.body.user.isPresident, true);
  await assert.rejects(ctx.db.query("update users set is_president = true where role = 'chief'"), /president_is_admin/);
});

test('rapport de production : lignes jour / nuit, ciment, montant au prix de vente', async () => {
  const r = (await ctx.api('GET', '/api/reports/production' + Q, { token: president })).body;
  assert.deepEqual(r.rows, [
    { date: '2025-06-09', shift: 'jour', bricks: 855, cementBags: 9 },
    { date: '2025-06-09', shift: 'nuit', bricks: 190, cementBags: 2 },
    { date: '2025-06-10', shift: 'jour', bricks: 734, cementBags: 8 },
    { date: '2025-06-10', shift: 'nuit', bricks: 0, cementBags: 0 },
  ]);
  assert.equal(r.totalBricks, 1779);
  assert.equal(r.totalCement, 19);
  assert.equal(r.unitPrice, 250);
  assert.equal(r.amount.exact, '444750/1');
  assert.equal(r.letterhead.name, 'ASSOCIATION BAYIIR MÊTBA');
  assert.equal(r.label, '09/06/2025 au 10/06/2025');
});

test('ciment : une saisie sans le champ garde la valeur enregistrée', async () => {
  const r = await ctx.api('PUT', '/api/days', {
    token: sup1,
    body: { teamId: T1.id, date: '2025-06-10', bricks: 734, presences: T1.workerIds.map((id) => ({ workerId: id, status: 'present' })) },
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.cementBags, 8);
  assert.equal((await save(admin, T1, '2025-06-10', 734, null)).body.cementBags, null);
  assert.equal((await save(admin, T1, '2025-06-10', 734, 8)).body.cementBags, 8);
});

test('fiche de paie globale : équipe, briques, somme au prix de confection, date', async () => {
  const r = (await ctx.api('GET', '/api/reports/team-payroll' + Q, { token: president })).body;
  // Une ligne par date, une colonne par équipe enregistrée (0 si l'équipe n'a rien produit ce jour-là).
  assert.deepEqual(r.days.map((d) => [d.date, ...d.cells.map((x) => [x.bricks, x.amount.exact]), d.bricks, d.amount.exact]), [
    ['2025-06-09', [855, '149625/1'], [190, '33250/1'], 1045, '182875/1'],
    ['2025-06-10', [734, '128450/1'], [0, '0/1'], 734, '128450/1'],
  ]);
  assert.deepEqual(r.teams.map((t) => [t.name, t.bricks, t.days, t.amount.exact]), [
    ['Équipe 1', 1589, 2, '278075/1'],
    ['Équipe 2', 190, 1, '33250/1'],
  ]);
  assert.equal(r.totalBricks, 1779);
  assert.equal(r.totalAmount.exact, '311325/1');
  assert.equal(r.unitPrice, 175);
  // Filtre par équipe.
  const one = (await ctx.api('GET', `/api/reports/team-payroll${Q}&teamId=${T2.id}`, { token: president })).body;
  assert.equal(one.team, 'Équipe 2');
  assert.equal(one.teams.length, 1);
  assert.equal(one.days.length, 1);
});

test('fiche de paie : ouverte à tous les admins, une colonne par jour, montants exacts par ouvrier', async () => {
  const path = '/api/reports/payroll-sheet' + Q;
  assert.equal((await ctx.api('GET', path, { token: sup1 })).status, 403);
  const res = await ctx.api('GET', path, { token: admin }); // admin simple, pas le président
  assert.equal(res.status, 200);
  const r = res.body;
  assert.deepEqual(r.dates, ['2025-06-09', '2025-06-10']);
  assert.equal(r.unitPrice, 175);
  assert.equal(r.totalBricks, 1779);
  assert.equal(r.totalAmount.exact, '311325/1');

  const [t1, t2] = r.teams;
  assert.equal(t1.name, 'Équipe 1');
  assert.deepEqual([t1.totalBricks, t1.totalPresent, t1.totalAmount.exact], [1589, 20, '278075/1']);
  assert.deepEqual(t1.days.map((d) => [d.bricks, d.present, d.share.exact]), [[855, 10, '29925/2'], [734, 10, '12845/1']]);
  // Un ouvrier présent les deux jours : 14 962,5 + 12 845 = 27 807,5 FCFA (exact, sans arrondi journalier).
  const first = t1.workers.find((w) => w.workerId === T1.workerIds[0]);
  assert.deepEqual([first.marks, first.days, first.total.exact], [['p', 'p'], 2, '55615/2']);
  // La somme des montants individuels est égale au total de l'équipe.
  assert.equal(t1.workers.reduce((s, w) => s + Number(w.total.exact.split('/')[0]) / Number(w.total.exact.split('/')[1] ?? 1), 0), 278075);

  // Équipe 2 : absente le 10 (aucune saisie), un absent le 9.
  const absent = t2.workers.find((w) => w.workerId === T2.workerIds[9]);
  assert.deepEqual([absent.marks, absent.days, absent.total.exact], [['a', 'n'], 0, '0/1']);
  assert.equal(t2.days[1].entered, false);

  // Filtre par équipe.
  const one = (await ctx.api('GET', `${path}&teamId=${T2.id}`, { token: admin })).body;
  assert.equal(one.teams.length, 1);

  // Choix d'une ou plusieurs équipes : le total général suit les équipes choisies.
  const only2 = (await ctx.api('GET', `${path}&teamIds=${T2.id}`, { token: admin })).body;
  assert.deepEqual([only2.teams.map((t) => t.name), only2.team, only2.totalBricks, only2.totalAmount.exact], [['Équipe 2'], 'Équipe 2', 190, '33250/1']);
  const both = (await ctx.api('GET', `${path}&teamIds=${T1.id},${T2.id}`, { token: admin })).body;
  assert.deepEqual([both.teams.length, both.team, both.totalBricks], [2, null, 1779]);
  assert.equal((await ctx.api('GET', `${path}&teamIds=`, { token: admin })).status, 400);
  assert.equal((await ctx.api('GET', `${path}&teamIds=${T1.id},00000000-0000-4000-8000-000000000000`, { token: admin })).status, 400);
});

test('réglages des rapports : signataires et libellés modifiables par le président seul', async () => {
  const def = (await ctx.api('GET', '/api/reports/settings', { token: president })).body;
  assert.deepEqual(def.signatories, []);
  const body = {
    tagline: '', productLabel: 'Nombre de BTC confectionnés (14x10x29 cm)', cementLabel: 'Nombre de sacs de ciment CPA 45',
    signatories: [
      { title: 'Responsable équipe production BTC', company: '', names: [] },
      { title: 'Contremaître génie civil', company: 'Client SA', names: ['Personne A', 'Personne B'] },
    ],
  };
  assert.equal((await ctx.api('PUT', '/api/reports/settings', { token: admin, body })).status, 403);
  assert.equal((await ctx.api('PUT', '/api/reports/settings', { token: president, body })).status, 200);
  const r = (await ctx.api('GET', '/api/reports/production' + Q, { token: president })).body;
  assert.equal(r.settings.signatories[1].names.length, 2);
  assert.equal(r.settings.cementLabel, 'Nombre de sacs de ciment CPA 45');
  assert.equal(r.client, null);
  // Références du client (bloc « DOIT » de l'en-tête) choisies parmi les clients enregistrés.
  const c = await ctx.api('POST', '/api/invoices/clients', { token: admin, body: { code: 'CLI', name: 'Client SA', rccm: 'RC-1', ifu: 'IFU-1' } });
  assert.equal(c.status, 201);
  const withClient = (await ctx.api('GET', `/api/reports/production${Q}&clientId=${c.body.id}`, { token: president })).body;
  assert.equal(withClient.client.rccm, 'RC-1');
});

test('superviseur : ajoute un ouvrier à son équipe, enregistre son visage une fois, remplace un membre', async () => {
  const add = await ctx.api('POST', '/api/workers', { token: sup1, body: { fullName: 'Nouveau Membre', teamId: T1.id } });
  assert.equal(add.status, 201);
  // Pas dans l'équipe d'un autre.
  assert.equal((await ctx.api('POST', '/api/workers', { token: sup1, body: { fullName: 'Intrus', teamId: T2.id } })).status, 403);
  const { fakePhoto } = await import('./fixtures.js');
  const face = (id, token) => ctx.api('PUT', `/api/workers/${id}/face`, { token, body: { images: [fakePhoto('nm', '1'), fakePhoto('nm', '2')] } });
  assert.equal((await face(add.body.id, sup1)).status, 200);
  assert.equal((await face(add.body.id, sup1)).status, 403); // refaire : admin seulement
  // Remplacement : l'ancien est retiré (historique gardé), le nouveau rejoint l'équipe.
  const old = T1.workerIds[9];
  const rep = await ctx.api('POST', `/api/workers/${old}/replace`, { token: sup1, body: { fullName: 'Remplaçant Durable' } });
  assert.equal(rep.status, 201);
  const mine = (await ctx.api('GET', '/api/workers', { token: sup1 })).body;
  assert.ok(!mine.some((w) => w.id === old));
  assert.ok(mine.some((w) => w.fullName === 'Remplaçant Durable' && w.teamId === T1.id));
  // Un superviseur (compte) ne se remplace pas ici ; pas d'accès à l'équipe d'un autre.
  assert.equal((await ctx.api('POST', `/api/workers/${T1.workerIds[0]}/replace`, { token: sup1, body: { fullName: 'X' } })).status, 409);
  assert.equal((await ctx.api('POST', `/api/workers/${T2.workerIds[3]}/replace`, { token: sup1, body: { fullName: 'X' } })).status, 403);
});

test('rapport de présence : nombre de jours présent par membre et par équipe', async () => {
  const r = (await ctx.api('GET', '/api/reports/attendance' + Q, { token: president })).body;
  const [t1, t2] = r.teams;
  assert.equal(t1.days, 2);
  // 10 membres d'origine présents 2 fois (dont celui remplacé entre-temps) ; les nouveaux venus à 0.
  assert.equal(t1.members.filter((m) => m.present === 2 && m.absent === 0).length, 10);
  assert.ok(t1.members.some((m) => m.fullName === 'Nouveau Membre' && m.present === 0));
  assert.equal(t2.shift, 'nuit');
  assert.equal(t2.days, 1);
  assert.equal(t2.members.filter((m) => m.present === 1).length, 8);
  assert.equal(t2.members.filter((m) => m.absent === 1).length, 2);
});
