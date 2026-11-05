import { randomBytes } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync, mkdirSync, readdirSync, unlinkSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { createApp } from '../src/app.js';
import { openLocalDb } from '../src/localDb.js';
import { buildBackup } from '../src/services/backup.js';

/**
 * Serveur de DÉVELOPPEMENT : même API, même schéma SQL, mais base PostgreSQL locale
 * (fichiers dans backend/.localdb) au lieu de Supabase. Aucune donnée n'est créée :
 * créez le premier admin avec `npm run create-admin -- --local "Nom" 1234`
 * (serveur arrêté : la base locale n'accepte qu'un processus à la fois).
 * La production utilise `npm start` + DATABASE_URL (Supabase).
 */
// LOCAL_DB_DIR : autre base (ex. la démonstration .demodb), sans toucher à la vraie base.
const dir = process.env.LOCAL_DB_DIR ?? fileURLToPath(new URL('../.localdb', import.meta.url));
mkdirSync(dir, { recursive: true });

// Secrets générés une fois et conservés (sinon les visages enregistrés deviendraient illisibles).
const secretsFile = path.join(dir, 'secrets.json');
if (!existsSync(secretsFile)) {
  writeFileSync(secretsFile, JSON.stringify({
    jwtSecret: randomBytes(48).toString('base64url'),
    faceKey: randomBytes(32).toString('hex'),
  }));
}
const secrets = JSON.parse(readFileSync(secretsFile, 'utf8'));

const config = {
  port: Number(process.env.PORT ?? 3000),
  jwtSecret: secrets.jwtSecret,
  jwtTtl: '12h',
  faceKey: Buffer.from(secrets.faceKey, 'hex'),
  faceThreshold: Number(process.env.FACE_THRESHOLD ?? 0.5),
  corsOrigins: [/^http:\/\/(localhost|127\.0\.0\.1):\d+$/],
  isProd: false,
  // Application web construite (build-web.cmd), servie à la même adresse que l'API.
  publicDir: fileURLToPath(new URL('../public', import.meta.url)),
};

const db = await openLocalDb(dir);
const { rows } = await db.query("select count(*)::int as n from users where role = 'admin'");
if (rows[0].n === 0) {
  console.warn('⚠ Aucun compte admin. Arrêtez ce serveur puis lancez :\n  npm run create-admin -- --local "Nom Prénom" 1234');
}

// Sauvegarde automatique : un fichier JSON par jour dans backend/backups (30 derniers conservés).
// Archive sans PIN ni signatures de visage ; la copie complète reste le dossier .localdb.
const backupDir = process.env.LOCAL_DB_DIR
  ? path.join(dir, 'backups')
  : fileURLToPath(new URL('../backups/', import.meta.url));
async function dailyBackup() {
  try {
    mkdirSync(backupDir, { recursive: true });
    const file = path.join(backupDir, `sauvegarde-${new Date().toISOString().slice(0, 10)}.json`);
    if (existsSync(file)) return;
    writeFileSync(file, JSON.stringify(await buildBackup(db), null, 1), 'utf8');
    const old = readdirSync(backupDir).filter((f) => /^sauvegarde-.*\.json$/.test(f)).sort().slice(0, -30);
    for (const f of old) unlinkSync(path.join(backupDir, f));
    console.log(`Sauvegarde écrite : ${file}`);
  } catch (e) {
    console.error('Sauvegarde automatique échouée :', e.message);
  }
}
await dailyBackup();
const backupTimer = setInterval(dailyBackup, 60 * 60 * 1000);
backupTimer.unref();

const app = createApp({ db, config });
const server = app.listen(config.port, () => {
  console.log(`API (base locale de développement) sur http://localhost:${config.port}`);
});
for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => server.close(async () => { await db.close(); process.exit(0); }));
}
