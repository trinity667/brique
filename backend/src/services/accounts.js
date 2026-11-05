import { conflict } from '../lib/errors.js';
import { generateTempPin, hashPin } from '../lib/pin.js';
import { logAudit } from '../lib/audit.js';

/**
 * Réinitialise le code d'un compte : un code PROVISOIRE aléatoire que l'admin ne voit qu'une fois et transmet à la
 * personne, qui devra choisir le sien à sa prochaine connexion. L'admin ne connaît donc jamais le code définitif.
 * Les connexions ouvertes sont fermées (token_version) et le verrouillage éventuel est levé. Tracé dans l'audit.
 * `user` : ligne { id, name } déjà vérifiée par l'appelant (rôle, droits).
 */
export async function resetPin(q, actor, user, { pinCost }) {
  const pin = generateTempPin();
  await q.query(
    `update users set pin_hash = $2, must_change_pin = true, token_version = token_version + 1,
                      failed_attempts = 0, locked_until = null, last_seen_at = null
      where id = $1`,
    [user.id, await hashPin(pin, pinCost)],
  );
  await logAudit(q, actor, { action: 'Réinitialisation du PIN', object: user.name, newValue: 'code provisoire' });
  return pin;
}

/**
 * Renomme un compte (le nom sert à la connexion). Deux comptes ne peuvent pas porter le même nom ; pour un
 * superviseur, la fiche de l'ouvrier qui est ce superviseur est renommée aussi (même personne, même nom).
 * `user` : ligne { id, name, worker_id } verrouillée par l'appelant. Sans effet si le nom ne change pas.
 */
export async function renameAccount(q, actor, user, newName) {
  if (newName === user.name) return;
  const clash = (await q.query('select 1 from users where lower(name) = lower($1) and id <> $2', [newName, user.id])).rows[0];
  if (clash) throw conflict('Un compte porte déjà ce nom.', 'name_taken');
  await q.query('update users set name = $2 where id = $1', [user.id, newName]);
  if (user.worker_id) await q.query('update workers set full_name = $2 where id = $1', [user.worker_id, newName]);
  await logAudit(q, actor, { action: 'Renommage de compte', object: newName, oldValue: user.name, newValue: newName });
}
