-- =============================================================================
--  Briques & Paie : schéma PostgreSQL (Supabase)
--  À exécuter dans Supabase > SQL Editor (ou via `npm run db:schema`).
--  Idempotent : peut être relancé sans erreur sur une base vide ou déjà migrée.
--
--  Principes
--   * Les règles métier critiques sont aussi appliquées PAR LA BASE (pas
--     seulement par l'API) : mois verrouillé, audit immuable, présence unique.
--   * Les montants exacts (parts = total / présents) ne sont jamais stockés en
--     flottant : la paie est recalculée à la demande en rationnels (API) ; seuls
--     les entiers FCFA (tarifs, quantités, paiements) vivent en base.
--   * RLS activée sur toutes les tables, sans politique : la clé anonyme de
--     Supabase ne peut rien lire. Seul le backend (connexion serveur) accède.
-- =============================================================================

-- ───────────────────────────── Types ─────────────────────────────

do $$ begin
  create type role_t as enum ('admin', 'chief');
exception when duplicate_object then null; end $$;

do $$ begin
  create type presence_t as enum ('present', 'absent', 'unset');
exception when duplicate_object then null; end $$;

do $$ begin
  create type pay_mode_t as enum ('cash', 'mobile_money');
exception when duplicate_object then null; end $$;

-- Statut d'un jour du calendrier de travail ('work' = jour travaillé à titre exceptionnel, ex. un dimanche).
do $$ begin
  create type day_kind_t as enum ('work', 'rest', 'holiday', 'weather', 'breakdown', 'other');
exception when duplicate_object then null; end $$;

-- Motif d'une absence.
do $$ begin
  create type absence_reason_t as enum ('sick', 'permission', 'unjustified', 'other');
exception when duplicate_object then null; end $$;

-- Deux prix par brique :
--   cost = prix de confection (175 FCFA) : base de la rémunération des ouvriers ;
--   sale = prix de vente (250 FCFA)      : chiffre d'affaires, réservé à l'admin.
do $$ begin
  create type price_kind_t as enum ('cost', 'sale');
exception when duplicate_object then null; end $$;

-- ───────────────────────────── Équipes / ouvriers / utilisateurs ─────────────────────────────

create table if not exists teams (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(btrim(name)) > 0),
  chief_id    uuid,                       -- superviseur titulaire (FK ajoutée plus bas)
  interim_id  uuid,                       -- superviseur remplaçant désigné par l'admin
  created_at  timestamptz not null default now()
);
create unique index if not exists teams_name_uq on teams (lower(name));

create table if not exists workers (
  id             uuid primary key default gen_random_uuid(),
  full_name      text not null check (length(btrim(full_name)) > 0),
  phone          text,
  team_id        uuid references teams (id) on delete set null,
  active         boolean not null default true,
  face_enrolled  boolean not null default false,
  face_template  bytea,                   -- signature du visage CHIFFRÉE (jamais la photo)
  created_at     timestamptz not null default now(),
  constraint face_consistency check (face_enrolled = (face_template is not null))
);
create index if not exists workers_team_idx on workers (team_id) where active;

-- Coordonnées (saisies à l'enregistrement, visibles de l'admin uniquement).
alter table workers add column if not exists village text;
alter table workers add column if not exists mobile_operator text;   -- orange | moov | telecel | other
alter table workers add column if not exists mobile_number text;     -- numéro de réception mobile money
alter table workers add column if not exists cnib text;              -- n° CNIB (fiche de paie), admin uniquement
do $$ begin
  alter table workers add constraint workers_mobile_operator_chk
    check (mobile_operator is null or mobile_operator in ('orange', 'moov', 'telecel', 'other'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table workers add constraint workers_mobile_pair_chk
    check ((mobile_operator is null) = (mobile_number is null));
exception when duplicate_object then null; end $$;

create table if not exists users (
  id              uuid primary key default gen_random_uuid(),
  name            text not null check (length(btrim(name)) > 0),
  role            role_t not null,
  worker_id       uuid unique references workers (id) on delete restrict, -- un superviseur EST un ouvrier
  pin_hash        text not null,        -- bcrypt, jamais le PIN
  active          boolean not null default true,
  failed_attempts int not null default 0,
  locked_until    timestamptz,
  created_at      timestamptz not null default now(),
  constraint chief_is_worker check (role <> 'chief' or worker_id is not null)
);
create unique index if not exists users_name_uq on users (lower(name));

-- Dernière activité : sert à savoir qui est connecté en ce moment (NULL = déconnecté).
alter table users add column if not exists last_seen_at timestamptz;

-- Président : un admin qui, seul, voit et imprime les rapports (production, paie globale, présences).
alter table users add column if not exists is_president boolean not null default false;
do $$ begin
  alter table users add constraint president_is_admin check (not is_president or role = 'admin');
exception when duplicate_object then null; end $$;

-- Poste de travail de l'équipe (rapport de production : lignes « Jour » / « Nuit »).
alter table teams add column if not exists shift text not null default 'jour';
do $$ begin
  alter table teams add constraint teams_shift_chk check (shift in ('jour', 'nuit'));
exception when duplicate_object then null; end $$;

do $$ begin
  alter table teams add constraint teams_chief_fk
    foreign key (chief_id) references users (id) on delete set null;
exception when duplicate_object then null; end $$;
do $$ begin
  alter table teams add constraint teams_interim_fk
    foreign key (interim_id) references users (id) on delete set null;
exception when duplicate_object then null; end $$;
do $$ begin
  alter table teams add constraint teams_chief_ne_interim check (chief_id is distinct from interim_id or chief_id is null);
exception when duplicate_object then null; end $$;

-- ───────────────────────────── Tarifs ─────────────────────────────

create table if not exists tariffs (
  id              uuid primary key default gen_random_uuid(),
  kind            price_kind_t not null,
  value           int  not null check (value > 0),          -- FCFA par brique
  effective_date  date not null,
  reason          text not null check (length(btrim(reason)) > 0),
  created_by      uuid not null references users (id),
  created_at      timestamptz not null default now()
);
-- Tarif applicable = effective_date la plus récente <= date de production.
create index if not exists tariffs_lookup_idx on tariffs (kind, effective_date desc, created_at desc);

-- ───────────────────────────── Saisie journalière ─────────────────────────────

create table if not exists day_entries (
  id          uuid primary key default gen_random_uuid(),
  team_id     uuid not null references teams (id),
  work_date   date not null,
  entered_by  uuid not null references users (id),
  bricks      int check (bricks >= 0),       -- briques confectionnées ; NULL = non saisi (≠ 0)
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (team_id, work_date)
);
create index if not exists day_entries_date_idx on day_entries (work_date);

-- Dernière requête appliquée : une saisie renvoyée après une coupure réseau n'est jamais appliquée deux fois.
alter table day_entries add column if not exists last_request_id uuid;

-- Sacs de ciment (CPA 45) utilisés dans la journée ; NULL = non saisi. Aucun montant.
alter table day_entries add column if not exists cement_bags int;
do $$ begin
  alter table day_entries add constraint day_entries_cement_chk check (cement_bags is null or cement_bags >= 0);
exception when duplicate_object then null; end $$;

-- Présence : 'unset' (non saisi) n'est JAMAIS interprété comme une absence.
create table if not exists day_presences (
  entry_id       uuid not null references day_entries (id) on delete cascade,
  worker_id      uuid not null references workers (id),
  work_date      date not null,                 -- dénormalisé pour l'unicité inter-équipes
  status         presence_t not null default 'unset',
  is_substitute  boolean not null default false,
  face_verified  boolean not null default false,
  primary key (entry_id, worker_id),
  constraint face_only_if_present check (not face_verified or status = 'present')
);
alter table day_presences add column if not exists absence_reason absence_reason_t;
do $$ begin
  alter table day_presences add constraint absence_reason_only_if_absent
    check (absence_reason is null or status = 'absent');
exception when duplicate_object then null; end $$;

-- Une même personne ne peut pas être « présente » dans deux équipes le même jour.
create unique index if not exists one_presence_per_day_uq
  on day_presences (worker_id, work_date) where status = 'present';

-- ───────────────────────────── Calendrier de travail ─────────────────────────────

-- Réglages de l'application (ex. 'rest_weekdays' = jours de repos hebdomadaires, 0 = dimanche).
create table if not exists app_settings (
  key         text primary key,
  value       jsonb not null,
  updated_at  timestamptz not null default now(),
  updated_by  uuid references users (id)
);

-- Exceptions au calendrier habituel : jour non travaillé (férié, intempérie, panne…) ou travaillé
-- exceptionnellement. team_id NULL = toutes les équipes ; une ligne d'équipe l'emporte sur une ligne globale.
create table if not exists calendar_days (
  id          uuid primary key default gen_random_uuid(),
  work_date   date not null,
  team_id     uuid references teams (id) on delete cascade,
  kind        day_kind_t not null,
  reason      text,
  created_by  uuid not null references users (id),
  created_at  timestamptz not null default now()
);
create unique index if not exists calendar_days_uq
  on calendar_days (work_date, coalesce(team_id, '00000000-0000-0000-0000-000000000000'::uuid));
create index if not exists calendar_days_date_idx on calendar_days (work_date);

-- ───────────────────────────── Paie, paiements ─────────────────────────────

create table if not exists payroll_versions (
  id            uuid primary key default gen_random_uuid(),
  month         text not null check (month ~ '^\d{4}-(0[1-9]|1[0-2])$'),
  version       int  not null check (version > 0),
  total_exact   text not null,                  -- rationnel « num/den »
  validated_by  uuid not null references users (id),
  validated_at  timestamptz not null default now(),
  unlocked_by   uuid references users (id),
  unlocked_at   timestamptz,
  unlock_reason text,
  unique (month, version),
  constraint unlock_complete check (
    (unlocked_at is null and unlocked_by is null and unlock_reason is null)
    or (unlocked_at is not null and unlocked_by is not null and length(btrim(coalesce(unlock_reason, ''))) > 0)
  )
);
-- Au plus une version verrouillée à la fois par mois.
create unique index if not exists one_locked_version_per_month_uq
  on payroll_versions (month) where unlocked_at is null;

create table if not exists payments (
  id               uuid primary key default gen_random_uuid(),
  worker_id        uuid not null references workers (id),
  month            text not null check (month ~ '^\d{4}-(0[1-9]|1[0-2])$'),
  paid_at          timestamptz not null default now(),
  theoretical_exact text not null,              -- solde exact dû au moment du paiement « num/den »
  proposed         int  not null,               -- arrondi proposé à l'unité
  paid             int  not null check (paid > 0),  -- réellement versé
  mode             pay_mode_t not null,
  created_by       uuid not null references users (id)
);
create index if not exists payments_worker_month_idx on payments (worker_id, month);

-- ───────────────────────────── Journal d'audit (immuable) ─────────────────────────────

create table if not exists audit_log (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  user_id     uuid,
  user_name   text not null,
  role        text not null,
  action      text not null,
  object      text not null,
  old_value   text,
  new_value   text,
  reason      text,
  security    boolean not null default false
);
create index if not exists audit_at_idx on audit_log (at desc);

-- ───────────────────────────── Fonctions & triggers de protection ─────────────────────────────

create or replace function month_is_locked(d date) returns boolean
language sql stable as $$
  select exists (
    select 1 from payroll_versions
    where month = to_char(d, 'YYYY-MM') and unlocked_at is null
  );
$$;

-- Aucune écriture dans un mois dont la paie est verrouillée.
create or replace function guard_locked_month() returns trigger
language plpgsql as $$
declare
  d date;
begin
  d := coalesce(new.work_date, old.work_date);
  if d is not null and month_is_locked(d) then
    raise exception 'La paie de % est verrouillée : modification refusée.', to_char(d, 'YYYY-MM')
      using errcode = 'P0001';
  end if;
  return coalesce(new, old);
end $$;

drop trigger if exists trg_lock_entries on day_entries;
create trigger trg_lock_entries before insert or update or delete on day_entries
  for each row execute function guard_locked_month();
drop trigger if exists trg_lock_calendar on calendar_days;
create trigger trg_lock_calendar before insert or update or delete on calendar_days
  for each row execute function guard_locked_month();
drop trigger if exists trg_lock_presences on day_presences;
create trigger trg_lock_presences before insert or update or delete on day_presences
  for each row execute function guard_locked_month();

-- Pas de tarif rétroactif dans un mois verrouillé (ni dans un mois antérieur verrouillé).
create or replace function guard_tariff_insert() returns trigger
language plpgsql as $$
begin
  if exists (
    select 1 from payroll_versions
    where unlocked_at is null and month >= to_char(new.effective_date, 'YYYY-MM')
  ) then
    raise exception 'Un mois verrouillé serait impacté par ce tarif : déverrouillez-le d''abord.'
      using errcode = 'P0001';
  end if;
  return new;
end $$;
drop trigger if exists trg_tariff_guard on tariffs;
create trigger trg_tariff_guard before insert on tariffs
  for each row execute function guard_tariff_insert();

-- Les tarifs et paiements ne se modifient pas : on ajoute une ligne (historique).
create or replace function forbid_change() returns trigger
language plpgsql as $$
begin
  raise exception 'Table % en ajout seul : % interdit.', tg_table_name, lower(tg_op)
    using errcode = 'P0001';
end $$;

drop trigger if exists trg_tariffs_append_only on tariffs;
create trigger trg_tariffs_append_only before update or delete on tariffs
  for each row execute function forbid_change();
drop trigger if exists trg_audit_append_only on audit_log;
create trigger trg_audit_append_only before update or delete on audit_log
  for each row execute function forbid_change();
drop trigger if exists trg_payments_append_only on payments;
create trigger trg_payments_append_only before update or delete on payments
  for each row execute function forbid_change();

-- Une version de paie validée n'est jamais supprimée ; seul le déverrouillage la modifie.
create or replace function guard_payroll_versions() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Une version de paie ne se supprime pas.' using errcode = 'P0001';
  end if;
  if old.unlocked_at is not null then
    raise exception 'Cette version est déjà déverrouillée : elle est figée.' using errcode = 'P0001';
  end if;
  if new.month <> old.month or new.version <> old.version or new.total_exact <> old.total_exact
     or new.validated_by <> old.validated_by or new.validated_at <> old.validated_at then
    raise exception 'Seul le déverrouillage peut modifier une version de paie.' using errcode = 'P0001';
  end if;
  return new;
end $$;
drop trigger if exists trg_payroll_versions_guard on payroll_versions;
create trigger trg_payroll_versions_guard before update or delete on payroll_versions
  for each row execute function guard_payroll_versions();

create or replace function touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists trg_entries_touch on day_entries;
create trigger trg_entries_touch before update on day_entries
  for each row execute function touch_updated_at();

-- ───────────────────────────── Sécurité (RLS) ─────────────────────────────
-- RLS sans politique = refus total pour les rôles anon/authenticated de Supabase.
-- Le backend se connecte avec le rôle postgres / service (qui contourne RLS).

alter table teams             enable row level security;
alter table workers           enable row level security;
alter table users             enable row level security;
alter table tariffs           enable row level security;
alter table day_entries       enable row level security;
alter table day_presences     enable row level security;
alter table payroll_versions  enable row level security;
alter table payments          enable row level security;
alter table audit_log         enable row level security;
alter table app_settings      enable row level security;
alter table calendar_days     enable row level security;

-- ───────────────────────────── Avances sur salaire ─────────────────────────────
-- Une avance est versée avant la validation de la paie et se déduit du solde du mois indiqué.
-- Elle ne se crée ni ne s'annule dans un mois dont la paie est verrouillée (contrôlé par l'API).
create table if not exists advances (
  id          uuid primary key default gen_random_uuid(),
  worker_id   uuid not null references workers (id),
  month       text not null check (month ~ '^\d{4}-(0[1-9]|1[0-2])$'),
  amount      int  not null check (amount > 0),
  given_at    date not null default current_date,
  mode        pay_mode_t not null,
  note        text check (note is null or char_length(note) <= 200),
  created_by  uuid not null references users (id),
  created_at  timestamptz not null default now()
);
create index if not exists advances_worker_month_idx on advances (worker_id, month);
alter table advances enable row level security;

-- ───────────────────────────── Clients et factures ─────────────────────────────
-- L'en-tête (nom, pied de page, lieu, signataire) est dans app_settings, clé « letterhead ».
create table if not exists clients (
  id          uuid primary key default gen_random_uuid(),
  code        text not null check (code ~ '^[A-Z0-9]{2,12}$'),   -- sert au numéro de facture : ABM/SOPAMIB/2026-07-001
  name        text not null check (length(btrim(name)) > 0),
  status      text,                                               -- ex. Société d'État avec conseil d'administration
  rccm        text,
  ifu         text,
  capital     text,
  address     text,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);
create unique index if not exists clients_code_uq on clients (code);

create table if not exists invoices (
  id                  uuid primary key default gen_random_uuid(),
  number              text not null unique,
  client_id           uuid not null references clients (id),
  issued_on           date not null,
  place               text not null,
  subject             text not null,
  period_from         date,
  period_to           date,
  unit_price          int  not null check (unit_price > 0),
  lines               jsonb not null,                -- [{date|null, label, qty}]
  total_qty           int  not null check (total_qty >= 0),
  total_amount        bigint not null check (total_amount >= 0),
  amount_words        text not null,
  signer              text not null,
  client_snapshot     jsonb not null,                -- informations du client au moment de l'émission
  letterhead_snapshot jsonb not null,                -- en-tête au moment de l'émission
  status              text not null default 'issued' check (status in ('issued', 'cancelled')),
  cancel_reason       text,
  created_by          uuid not null references users (id),
  created_at          timestamptz not null default now()
);
create index if not exists invoices_client_idx on invoices (client_id, issued_on);

-- Une facture émise ne se modifie ni ne se supprime : seule l'annulation motivée est possible.
create or replace function guard_invoice_change() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Une facture ne se supprime pas : annulez-la.' using errcode = 'P0001';
  end if;
  if old.status = 'issued' and new.status = 'cancelled'
     and new.number = old.number and new.total_amount = old.total_amount and new.lines = old.lines
     and new.client_snapshot = old.client_snapshot and new.issued_on = old.issued_on then
    return new;
  end if;
  raise exception 'Une facture émise ne se modifie pas : annulez-la et émettez-en une nouvelle.' using errcode = 'P0001';
end $$;
drop trigger if exists trg_invoice_guard on invoices;
create trigger trg_invoice_guard before update or delete on invoices
  for each row execute function guard_invoice_change();

alter table clients  enable row level security;
alter table invoices enable row level security;

-- ───────────────────────────── Alertes ignorées ─────────────────────────────
-- Les alertes sont calculées à la demande (rien n'est stocké) ; on ne mémorise que celles qu'un admin a
-- « ignorées ». La clé (alert_id) est stable : l'alerte revient d'elle-même si la situation change
-- (nouveaux jours sans saisie, autre mois, autre ouvrier…).
create table if not exists dismissed_alerts (
  alert_id      text primary key,
  title         text not null,
  dismissed_by  uuid references users (id) on delete set null,
  dismissed_at  timestamptz not null default now()
);
alter table dismissed_alerts enable row level security;

-- ───────────────────────────── Fiches de paie établies (circuit Établie → Approuvée) ─────────────────────────────
-- Une fiche établie est une PHOTO figée de la fiche de paie d'une période (snapshot) : elle n'est jamais recalculée.
-- Un admin l'établit, le président l'approuve (une autre personne que celle qui l'a établie).
-- Elle ne se supprime ni ne se modifie : seule l'annulation motivée est possible.
create table if not exists payroll_sheets (
  id                  uuid primary key default gen_random_uuid(),
  number              text not null unique,                 -- FP-AAAA-NNN
  period_from         date not null,
  period_to           date not null,
  team_ids            uuid[] not null,                      -- équipes couvertes (contrôle des chevauchements)
  status              text not null default 'established'
                        check (status in ('established', 'approved', 'cancelled')),
  snapshot            jsonb not null,
  established_by      uuid references users (id) on delete set null,
  established_by_name text not null,
  established_at      timestamptz not null default now(),
  approved_by         uuid references users (id) on delete set null,
  approved_by_name    text,
  approved_at         timestamptz,
  cancelled_by_name   text,
  cancelled_at        timestamptz,
  cancel_reason       text,
  constraint payroll_sheets_period_chk check (period_to >= period_from)
);
create index if not exists payroll_sheets_period_idx on payroll_sheets (period_from, period_to);

create or replace function guard_payroll_sheet_change() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Une fiche de paie ne se supprime pas : annulez-la.' using errcode = 'P0001';
  end if;
  if new.number <> old.number or new.period_from <> old.period_from or new.period_to <> old.period_to
     or new.team_ids <> old.team_ids or new.snapshot <> old.snapshot
     or new.established_at <> old.established_at or new.established_by_name <> old.established_by_name then
    raise exception 'Le contenu d''une fiche de paie établie ne se modifie pas.' using errcode = 'P0001';
  end if;
  -- Seules transitions permises : établie → approuvée, établie → annulée, approuvée → annulée.
  if old.status = 'established' and new.status in ('approved', 'cancelled') then return new; end if;
  if old.status = 'approved' and new.status = 'cancelled' then return new; end if;
  raise exception 'Cette fiche de paie ne peut plus changer d''état.' using errcode = 'P0001';
end $$;
drop trigger if exists trg_payroll_sheet_guard on payroll_sheets;
create trigger trg_payroll_sheet_guard before update or delete on payroll_sheets
  for each row execute function guard_payroll_sheet_change();
alter table payroll_sheets enable row level security;

-- ───────────────────────────── Codes PIN : changement obligatoire, fermeture des sessions ─────────────────────────────
-- must_change_pin : code provisoire (création ou réinitialisation) : le titulaire doit choisir le sien à la connexion.
-- token_version   : incrémenté à chaque changement / réinitialisation du PIN ; un jeton d'une version plus ancienne est refusé
--                   (les connexions ouvertes avec l'ancien code se ferment tout de suite).
alter table users add column if not exists must_change_pin boolean not null default false;
alter table users add column if not exists token_version   int     not null default 0;
alter table users add column if not exists pin_changed_at  timestamptz;
