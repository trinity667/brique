import { readFile, mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

/**
 * Base PostgreSQL LOCALE de développement (PGlite, fichiers dans backend/.localdb).
 * Même schéma SQL que Supabase. Sert uniquement à essayer l'application sans
 * projet Supabase ; la production utilise toujours DATABASE_URL (Supabase).
 */
export async function openLocalDb(dir = fileURLToPath(new URL('../.localdb', import.meta.url))) {
  // Chargé à la demande : PGlite est une dépendance de développement.
  const { PGlite, types } = await import('@electric-sql/pglite');
  // Sous-dossier dédié : PGlite refuse d'initialiser une base dans un dossier non vide
  // (or `dir` contient déjà secrets.json).
  const dataDir = path.join(dir, 'pgdata');
  await mkdir(dataDir, { recursive: true });
  const pg = new PGlite(dataDir, { parsers: { [types.DATE]: (v) => v } });
  await pg.waitReady;
  const sql = await readFile(fileURLToPath(new URL('../db/schema.sql', import.meta.url)), 'utf8');
  await pg.exec(sql);

  const wrap = async (p) => {
    const r = await p;
    return { ...r, rowCount: r.rows.length };
  };
  return {
    query: (t, p) => wrap(pg.query(t, p)),
    tx: (fn) => pg.transaction((tx) => fn({ query: (t, p) => wrap(tx.query(t, p)) })),
    close: () => pg.close(),
  };
}
