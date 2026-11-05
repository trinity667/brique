import { randomInt } from 'node:crypto';
import bcrypt from 'bcryptjs';
import { z } from 'zod';

export const PIN_COST = 10;

/** PIN : 4 à 6 chiffres. Jamais stocké en clair (bcrypt). */
export const pinSchema = z.string().regex(/^\d{4,6}$/, 'Le code PIN doit contenir 4 à 6 chiffres.');

/** Code trop facile à deviner : chiffres identiques (0000), suite (1234, 4321), motif répété (1212, 123123). */
export function isWeakPin(pin) {
  if (/^(\d)\1+$/.test(pin)) return true;
  if (/^(\d\d)\1+$/.test(pin)) return true;
  const d = [...pin].map(Number);
  const steps = d.slice(1).map((x, i) => x - d[i]);
  if (steps.every((s) => s === 1) || steps.every((s) => s === -1)) return true;
  const half = pin.length / 2;
  return Number.isInteger(half) && pin.slice(0, half) === pin.slice(half);
}

/** PIN choisi par l'utilisateur : 4 à 6 chiffres ET pas trop simple. */
export const strongPinSchema = pinSchema.refine(
  (p) => !isWeakPin(p),
  'Code trop simple (0000, 1234, 1212…). Choisissez-en un plus difficile à deviner.',
);

/** Code provisoire de 6 chiffres, aléatoire (CSPRNG), jamais « simple ». Affiché une seule fois à l'admin. */
export function generateTempPin() {
  for (;;) {
    const pin = String(randomInt(100_000, 1_000_000));
    if (!isWeakPin(pin)) return pin;
  }
}

export const hashPin = (pin, cost = PIN_COST) => bcrypt.hash(pin, cost);
export const verifyPin = (pin, hash) => bcrypt.compare(pin, hash);
