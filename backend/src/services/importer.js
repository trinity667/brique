import { z } from 'zod';
import { contactFields } from '../lib/contact.js';

/** Découpe une ligne CSV/TSV : séparateur tabulation (collage depuis Excel), point-virgule ou virgule ; guillemets gérés. */
export function splitLine(line, sep) {
  const out = [];
  let cur = '';
  let quoted = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (quoted) {
      if (c === '"' && line[i + 1] === '"') { cur += '"'; i++; } else if (c === '"') quoted = false; else cur += c;
    } else if (c === '"') quoted = true;
    else if (c === sep) { out.push(cur.trim()); cur = ''; } else cur += c;
  }
  out.push(cur.trim());
  return out;
}

const detectSeparator = (line) => {
  for (const s of ['\t', ';']) if (line.includes(s)) return s;
  return ',';
};

const norm = (s) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]/g, '');

const OPERATORS = { orange: 'orange', moov: 'moov', telecel: 'telecel', autre: 'other', other: 'other' };

const rowSchema = z.object({
  fullName: z.string().trim().min(1, 'Nom manquant.').max(120, 'Nom trop long.'),
  ...contactFields,
});

/** Ordre des colonnes sans ligne d'en-tête (le N° CNIB est en dernier : les anciens tableaux restent valides). */
const DEFAULT_COLUMNS = { fullName: 0, phone: 1, village: 2, operator: 3, mobile: 4, team: 5, cnib: 6 };

/** Intitulés d'en-tête reconnus (normalisés : sans accents, majuscules ni ponctuation). */
const HEADER_ALIASES = {
  fullName: ['nom', 'nomprenoms', 'nomprenom', 'nometprenoms', 'nometprenom', 'nomcomplet', 'name', 'ouvrier', 'agent'],
  phone: ['telephone', 'tel', 'phone', 'contact'],
  village: ['village', 'quartier', 'villagequartier', 'localite'],
  cnib: ['cnib', 'ncnib', 'numerocnib', 'numcnib', 'cni', 'ncni', 'numerocni'],
  operator: ['operateur', 'operateurmobilemoney', 'operateurmobile'],
  mobile: ['numeromobile', 'numeromobilemoney', 'mobilemoney', 'numerodereception', 'numeroreception'],
  team: ['equipe', 'team', 'groupe'],
};

/** Position de chaque colonne reconnue dans une ligne d'en-tête ; les autres colonnes (N°, signature…) sont ignorées. */
function headerColumns(cells) {
  const cols = {};
  cells.forEach((c, i) => {
    const k = norm(c);
    for (const [field, aliases] of Object.entries(HEADER_ALIASES)) {
      if (aliases.includes(k) && !(field in cols)) cols[field] = i;
    }
  });
  return cols;
}

/**
 * Lit un tableau collé depuis Excel ou lu dans un fichier CSV.
 * Avec une ligne d'en-tête reconnue (Nom, Téléphone, Village, N° CNIB, Opérateur, Numéro mobile, Équipe…),
 * les colonnes sont repérées par leur titre, dans n'importe quel ordre. Sans en-tête, ordre par défaut :
 * Nom ; Téléphone ; Village ; Opérateur mobile money ; Numéro mobile money ; Équipe ; N° CNIB.
 * `teams` : Map(nom normalisé → id), `existing` : Set(nom normalisé) des ouvriers déjà enregistrés.
 */
export function parseWorkers(text, { teams, existing }) {
  const lines = String(text).replace(/^﻿/, '').split(/\r?\n/).filter((l) => l.trim() !== '');
  const rows = [];
  if (!lines.length) return rows;
  const sep = detectSeparator(lines[0]);
  const seen = new Set();
  let cols = DEFAULT_COLUMNS;
  lines.forEach((line, idx) => {
    const cells = splitLine(line, sep);
    if (idx === 0) {
      const found = headerColumns(cells);
      if ('fullName' in found) { cols = found; return; } // en-tête reconnu : colonnes repérées par leur titre
      if (/^(nom|name|ouvrier)/.test(norm(cells[0] ?? ''))) return; // en-tête simple : ordre par défaut
    }
    const at = (field) => (field in cols ? (cells[cols[field]] ?? '') : '');
    const name = at('fullName');
    const phone = at('phone');
    const village = at('village');
    const cnib = at('cnib');
    const operator = at('operator');
    const mobile = at('mobile');
    const team = at('team');
    const row = { line: idx + 1, name, status: 'ok', message: '' };
    const fail = (message) => { row.status = 'error'; row.message = message; return row; };
    rows.push(row);

    const op = operator ? OPERATORS[norm(operator)] : null;
    if (operator && !op) return fail(`Opérateur inconnu « ${operator} » (orange, moov, telecel, autre).`);
    const parsed = rowSchema.safeParse({ fullName: name, phone, village, cnib, mobileOperator: op ?? '', mobileNumber: mobile });
    if (!parsed.success) return fail(parsed.error.issues[0].message);
    if (Boolean(op) !== Boolean(mobile)) return fail("Indiquez à la fois l'opérateur et le numéro mobile money.");

    let teamId = null;
    if (team) {
      teamId = teams.get(norm(team));
      if (!teamId) return fail(`Équipe inconnue « ${team} ».`);
    }
    const key = norm(parsed.data.fullName);
    if (existing.has(key)) { row.status = 'duplicate'; row.message = 'Déjà enregistré.'; return row; }
    if (seen.has(key)) { row.status = 'duplicate'; row.message = 'Doublon dans la liste collée.'; return row; }
    seen.add(key);
    row.data = { ...parsed.data, teamId };
    return row;
  });
  return rows;
}
