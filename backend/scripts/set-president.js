import { loadConfig } from '../src/config.js';
import { createPgDb } from '../src/db.js';
import { openLocalDb } from '../src/localDb.js';

/**
 * Désigne le président : un compte admin existant, le seul à voir et imprimer les rapports
 * (production, paie globale des équipes, présences). Un seul président à la fois.
 *   npm run set-president -- "Nom Prénom"            (base Supabase, via .env)
 *   npm run set-president -- --local "Nom Prénom"    (base locale de développement)
 *   npm run set-president -- --none                  (plus aucun président)
 */
const args = process.argv.slice(2);
const local = args[0] === '--local';
const [name] = local ? args.slice(1) : args;

if (!name) {
  console.error('Usage : npm run set-president -- [--local] "Nom Prénom" | --none');
  process.exit(1);
}

const db = local ? await openLocalDb() : (() => {
  const config = loadConfig();
  return createPgDb({ databaseUrl: config.databaseUrl, ssl: config.dbSsl });
})();

try {
  await db.tx(async (q) => {
    let target = null;
    if (name !== '--none') {
      target = (await q.query("select id, name from users where lower(name) = lower($1) and role = 'admin' and active", [name.trim()])).rows[0];
      if (!target) throw new Error(`Aucun compte admin actif nommé « ${name} ».`);
    }
    await q.query('update users set is_president = false where is_president');
    if (target) await q.query('update users set is_president = true where id = $1', [target.id]);
    await q.query(
      "insert into audit_log (user_name, role, action, object) values ('Système', '-', 'Désignation du président', $1)",
      [target?.name ?? 'aucun'],
    );
    console.log(target ? `Président : ${target.name}` : 'Plus aucun président désigné.');
  });
} catch (e) {
  console.error(e.message);
  process.exitCode = 1;
} finally {
  await db.close();
}
