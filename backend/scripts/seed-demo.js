import { rmSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { openLocalDb } from '../src/localDb.js';
import { hashPin } from '../src/lib/pin.js';

/**
 * Données FICTIVES de démonstration, dans une base séparée (backend/.demodb) :
 *   npm run demo:seed     (efface et recrée .demodb ; la vraie base .localdb n'est jamais touchée)
 *   npm run demo          (lance le serveur de démonstration sur http://localhost:3000)
 * Comptes : Directeur Démo / 4827 (admin et président), Chef Alpha / 5931, Chef Bravo / 7264, Chef Nuit / 6158.
 * Les noms sont inventés. Aujourd'hui est laissé vide pour pouvoir saisir en direct pendant la présentation.
 */
const dir = fileURLToPath(new URL('../.demodb', import.meta.url));
rmSync(dir, { recursive: true, force: true });
mkdirSync(dir, { recursive: true });

// Générateur pseudo-aléatoire à graine fixe : la démo est identique à chaque fois.
let seed = 20260101;
const rnd = () => ((seed = (seed * 1664525 + 1013904223) % 4294967296) / 4294967296);
const between = (a, b) => Math.round(a + rnd() * (b - a));

const iso = (d) => d.toISOString().slice(0, 10);
const today = new Date();
today.setUTCHours(0, 0, 0, 0);
const start = new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth() - 1, 1)); // 1er jour du mois précédent

const TEAMS = [
  { name: 'Équipe Alpha', shift: 'jour', chief: ['Chef Alpha', '5931'], chiefName: 'Souleymane Yaméogo', members: ['Issouf Ouédraogo', 'Salif Traoré', 'Adama Sawadogo', 'Boureima Kaboré', 'Ousmane Zongo', 'Daouda Compaoré'] },
  { name: 'Équipe Bravo', shift: 'jour', chief: ['Chef Bravo', '7264'], chiefName: 'Rasmané Ouoba', members: ['Hamidou Sankara', 'Seydou Ilboudo', 'Karim Bambara', 'Yacouba Nikiéma', 'Abdoul Tapsoba', 'Moumouni Barry'] },
  { name: 'Équipe Nuit', shift: 'nuit', chief: ['Chef Nuit', '6158'], chiefName: 'Boukary Zoungrana', members: ['Lassané Ouattara', 'Drissa Kéré', 'Rasmané Belem', 'Idrissa Konaté', 'Mahamadi Savadogo'] },
];
const OPERATORS = ['orange', 'moov', 'telecel'];
const REASONS = ['sick', 'permission', 'unjustified', 'other'];

const db = await openLocalDb(dir);
try {
  const admin = (await db.query(
    "insert into users (name, role, pin_hash, is_president) values ('Directeur Démo', 'admin', $1, true) returning id",
    [await hashPin('4827')],
  )).rows[0].id;

  for (const [kind, value] of [['cost', 175], ['sale', 250]]) {
    await db.query(
      "insert into tariffs (kind, value, effective_date, reason, created_by) values ($1, $2, $3, 'Tarif de démonstration', $4)",
      [kind, value, iso(start), admin],
    );
  }

  let phone = 70000000;
  const teams = [];
  for (const t of TEAMS) {
    const teamId = (await db.query('insert into teams (name, shift) values ($1, $2) returning id', [t.name, t.shift])).rows[0].id;
    const workers = [];
    for (const [i, full] of [t.chiefName, ...t.members].entries()) {
      const mobile = i % 2 === 0;
      const op = OPERATORS[i % OPERATORS.length];
      const id = (await db.query(
        `insert into workers (full_name, phone, team_id, village, mobile_operator, mobile_number)
         values ($1, $2, $3, 'Village de démonstration', $4, $5) returning id`,
        [full, String(phone++), teamId, mobile ? op : null, mobile ? String(phone++) : null],
      )).rows[0].id;
      workers.push(id);
    }
    const chiefId = (await db.query(
      "insert into users (name, role, worker_id, pin_hash) values ($1, 'chief', $2, $3) returning id",
      [t.chief[0], workers[0], await hashPin(t.chief[1])],
    )).rows[0].id;
    await db.query('update teams set chief_id = $1 where id = $2', [chiefId, teamId]);
    teams.push({ teamId, chiefId, workers });
  }

  let jours = 0;
  for (const d = new Date(start); d < today; d.setUTCDate(d.getUTCDate() + 1)) {
    if (d.getUTCDay() === 0) continue; // dimanche = repos par défaut
    const date = iso(d);
    for (const t of teams) {
      const bricks = between(800, 1400);
      const entry = (await db.query(
        'insert into day_entries (team_id, work_date, entered_by, bricks, cement_bags) values ($1, $2, $3, $4, $5) returning id',
        [t.teamId, date, t.chiefId, bricks, Math.round(bricks / 55)],
      )).rows[0].id;
      for (const w of t.workers) {
        const present = rnd() < 0.9;
        await db.query(
          'insert into day_presences (entry_id, worker_id, work_date, status, absence_reason) values ($1, $2, $3, $4, $5)',
          [entry, w, date, present ? 'present' : 'absent', present ? null : REASONS[between(0, 3)]],
        );
      }
    }
    jours++;
  }

  await db.query(
    "insert into audit_log (user_name, role, action, object) values ('Système', '-', 'Données de démonstration créées', 'démo')",
  );
  console.log(`Démo prête dans ${dir}\n  ${teams.length} équipes, ${teams.reduce((n, t) => n + t.workers.length, 0)} ouvriers, ${jours} jours de saisie (du ${iso(start)} à hier).`);
  console.log('  Admin : Directeur Démo / 4827   Superviseurs : Chef Alpha / 5931, Chef Bravo / 7264, Chef Nuit / 6158');
} finally {
  await db.close();
}
