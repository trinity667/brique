import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

/**
 * Serveur de DÉMONSTRATION : base fictive .demodb (voir seed-demo.js), port 3001 par défaut,
 * donc utilisable en même temps que le vrai serveur local sans le toucher.
 */
const dir = fileURLToPath(new URL('../.demodb', import.meta.url));
const server = fileURLToPath(new URL('./local-server.js', import.meta.url));
const child = spawn(process.execPath, [server], {
  stdio: 'inherit',
  env: { ...process.env, LOCAL_DB_DIR: dir, PORT: process.env.PORT ?? '3001' },
});
child.on('exit', (code) => process.exit(code ?? 0));
for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => child.kill(sig));
