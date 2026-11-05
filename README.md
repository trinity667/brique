# Briques & Paie

Application de gestion de production de briques et de paie : **Flutter** (Android, web) + **API Node.js / Express** + **PostgreSQL (Supabase)**.

- **Superviseur** : se connecte avec son nom et son code PIN, voit les autres membres de son équipe, les marque présents/absents
  (identification par le **visage** possible) et saisit le **nombre de briques confectionnées**. Il ne voit aucun prix ni montant.
- **Admin** : tableau de bord (web et mobile) avec présents/absents, briques, coût de confection (175 FCFA), valeur de vente (250 FCFA)
  et marge ; gestion des équipes, superviseurs, remplaçants et visages ; paie mensuelle (validation, verrouillage), paiements, prix, audit.

Aucune donnée n'est codée en dur : tout vient de l'API. Voir [backend/README.md](backend/README.md) pour l'installation complète.

## Lancer en local

```bash
cd backend && npm install
npm run create-admin -- --local "Votre Nom" 1234     # premier admin (base locale de développement)
npm run local                                        # API sur http://localhost:3000

# dans un autre terminal, à la racine :
flutter pub get
flutter run -d chrome --dart-define=API_URL=http://localhost:3000
```

Tests : `flutter test` (application) et `cd backend && npm test` (API, base SQL, reconnaissance faciale).

## Calendrier de travail, fiche ouvrier, mode hors ligne

- **Calendrier** (admin : onglet « Calendrier » ; superviseur : onglet « Calendrier ») : jours travaillés, repos
  hebdomadaire (dimanche par défaut, configurable), fériés, intempéries, pannes, par équipe ou pour toutes.
  Un jour non travaillé n'est plus compté « sans saisie » dans la paie et la saisie y est refusée.
- **Fiche ouvrier** (admin : Équipes → clic sur un membre) : présences jour par jour, taux de présence,
  motifs d'absence, gains exacts, paiements, solde.
- **Motifs d'absence** : Maladie, Permission, Non justifiée, Autre (choisis par le superviseur sur un absent).
- **Hors ligne (superviseur)** : après une première connexion, l'appareil garde ses équipes, la journée du jour et le
  calendrier. Sans réseau on peut se reconnecter avec son code, saisir présences et briques ; les saisies attendent
  dans une file et partent dès que le serveur répond (sans doublon : `requestId`). Si la journée a changé entre-temps
  (autre appareil, correction de l'admin), le superviseur choisit « garder ma saisie » ou « garder celle du serveur ».
  L'identification faciale demande le réseau. L'admin travaille en ligne uniquement (aucun montant n'est stocké sur l'appareil).
- Mettre à jour la base : `npm run db:schema` (idempotent) dans `backend/`.

## Statistiques, avances, paie sur période, PDF, alertes (admin)

- **Statistiques** : tendance sur 6 mois, production par jour, classement des équipes, assiduité des ouvriers.
- **Avances** : ajoutées depuis la fiche d'un ouvrier (avant validation du mois), déduites du solde, annulables tant que le mois n'est pas verrouillé.
- **Paie sur période** : semaine, quinzaine… à titre d'information (le règlement officiel reste mensuel).
- **PDF** : fiche de paie (fiche ouvrier), état de paie du mois, paie sur période. Générés sur l'appareil ; les accents sont retirés (polices PDF de base).
- **Alertes** : jours sans saisie, journées incomplètes, baisse de production, absences répétées, paie à valider, avances excessives, prix manquants, visages manquants. Elles sont calculées à la demande : on ne les supprime pas, on les **ignore** (✕ sur l'alerte ou « Tout ignorer », commun à tous les admins, tracé dans l'audit). Une alerte ignorée revient d'elle-même si la situation change ; « Alertes ignorées » permet de la rétablir. La liste s'actualise seule (90 s), avec le bouton ↻ ou en tirant vers le bas.

## Rapports officiels (président uniquement)

- **Président** : un compte admin désigné par `npm run set-president -- "Nom Prénom"` (dans `backend/`, ajouter `--local`
  pour la base locale ; `--none` pour retirer). Un seul président à la fois. Les autres admins ne voient pas la page
  « Rapports » et le serveur leur refuse ces routes (refus tracé dans le journal d'audit).
- **Rapport de production** : une ligne par jour et par poste (Jour / Nuit), nombre de BTC confectionnés (14x10x29 cm),
  sacs de ciment CPA 45, total, puis Nombre BTC × prix unitaire (prix de vente) = montant à payer.
- **Fiche de paie globale des équipes** : date, équipe, briques confectionnées, somme (briques × prix de confection), totaux par équipe.
- **Rapport de présence** : par équipe, nom et prénoms, nombre de fois présent, absences et une case à cocher
  (cochée à l'écran = cochée sur le PDF, sinon vide pour cocher à la main).
- Chaque rapport : **Imprimer**, **Télécharger PDF**, **Excel (CSV)**. En-tête au format des factures : logo, nom de
  l'association, filet, titre, lieu et date, puis les **références du client** choisi (statut, RCCM, IFU, capital, siège,
  pris dans Factures → Clients). Pied de page : références de l'association (en-tête de facture).
- **Signataires et libellés** (bouton sur la page Rapports) : poste, structure et nom(s) de chaque signataire, imprimés en
  bas du rapport de production (plusieurs noms = une case à cocher devant chacun) ; libellés des colonnes BTC et ciment.
  Tout est enregistré sur le serveur (`app_settings`, clé `report_settings`) : aucun nom n'est écrit dans le code.
- **Paie globale** : une ligne par date et, pour **chaque équipe enregistrée**, ses briques et sa somme ; total par jour et par équipe.
- **Poste de l'équipe** (Jour / Nuit) : Équipes → carte de l'équipe. **Sacs de ciment** : saisis par le superviseur avec les briques (facultatif).

## Fiche de paie sur période : établir, approuver, exporter (admin)

- **Aperçu** (« Paie sur période ») : choisissez les dates et les équipes (cases à cocher, « Toutes » par défaut), puis
  PDF, Imprimer, **Excel (CSV)** ou « Une fiche par équipe ». Une page par équipe, N° CNIB, colonne Signature, jours de repos
  grisés ; au-delà de 15 jours, blocs de 15 jours puis récapitulatif signé. Aucun numéro : c'est un aperçu.
- **Établir** : « Établir la fiche » fige la fiche (photo non modifiable, même si les saisies sont corrigées ensuite) et lui
  donne un numéro `FP-AAAA-NNN`. Refusé si une journée saisie est incomplète ou si une fiche non annulée couvre déjà les
  mêmes jours pour la même équipe (pas de double paiement).
- **Approuver** : le **président** seul, et jamais la personne qui a établi la fiche (refus tracé dans l'audit).
- **Annuler** : avec motif. Une fiche établie, par tout admin ; une fiche approuvée, par le président seul. Une fiche ne se
  supprime ni ne se modifie (garde en base). Les états figurent sur le PDF (en attente, approuvée, annulée).
- Page « Fiches de paie » : liste filtrable, détail, PDF, impression, Excel (CSV), approbation, annulation.
- Mettre à jour la base : `npm run db:schema` dans `backend/` (tables `payroll_sheets`, `dismissed_alerts`).

## Règles d'alerte réglables (admin)

Bouton ⚙ sur la page Alertes : **briques attendues par sac de ciment** (± tolérance en %) et **objectif de production par
jour et par équipe**. Champ vide = règle désactivée. Alerte « briques par sac anormal » (14 derniers jours) et alerte
« sous l'objectif » (au moins 3 jours travaillés sur 7).

## Comptes et codes PIN

- **Mon compte** (icône en haut, pour tous : admin, président, superviseur) : changer son code (code actuel, nouveau, confirmation).
  Le nouveau code doit être différent et pas trop simple (0000, 1234, 1212…). Les autres connexions ouvertes avec
  l'ancien code sont **fermées** immédiatement. Un code actuel faux compte comme un échec de connexion (verrouillage).
- **Code provisoire** : à la création d'un superviseur et à chaque réinitialisation, le code est provisoire. À la connexion,
  un écran obligatoire impose de choisir son propre code avant d'utiliser l'application.
- **Réinitialiser** (Équipes → menu ⋮ du compte) : le serveur génère un code provisoire aléatoire, affiché **une seule fois**
  à l'admin, qui le transmet. L'admin ne connaît donc jamais le code définitif. Tracé dans l'audit (sans le code).
  - Un superviseur : n'importe quel admin.
  - Un admin (trésorier…) : le **président** seul (section « Administrateurs » de la page Équipes).
  - Le président : pas depuis l'application (un autre admin pourrait sinon en prendre le contrôle) ; récupération sur le
    serveur par un accès à la base (`create-admin` / `set-president`).
- **Modifier un compte** : renommer (nom de connexion ; pour un superviseur, la fiche de l'ouvrier suit) et
  désactiver / réactiver (accès coupé tout de suite). Superviseurs : tout admin ; admins : le président.
- Mettre à jour la base : `npm run db:schema` (colonnes `must_change_pin`, `token_version`).
- Limite : un superviseur qui s'est déjà connecté sur un appareil peut s'y reconnecter **hors ligne** avec son ancien code
  tant que cet appareil n'a pas retrouvé le réseau ; son jeton serait alors refusé dès la première synchronisation.

## Mon équipe (superviseur)

- Onglet **Mon équipe** : liste des membres déjà enregistrés de son équipe et état de leur visage.
- **Ajouter** : nom (+ contact facultatif), puis enregistrement du visage dans la foulée (consentement + 3 photos).
- **Remplacer** un membre : il quitte l'équipe (ses journées passées restent) et le nouvel ouvrier prend sa place.
- Le superviseur enregistre un visage **une première fois** ; refaire un visage déjà enregistré reste réservé à l'admin.
  Il n'agit que sur son équipe (ou celle qu'il remplace), contrôlé par le serveur.

## Import et sauvegarde (admin)

- **Import d'ouvriers** (page « Import & sauvegarde ») : choisissez un **fichier CSV** (Excel : Fichier > Enregistrer sous > CSV ; encodages UTF-8, Windows-1252 et UTF-16 reconnus) ou collez un tableau Excel. Avec une ligne d'en-tête (Nom, Téléphone, Village, N° CNIB, Opérateur, Numéro mobile, Équipe), les colonnes sont repérées par leur titre, dans n'importe quel ordre, les autres (N°, Signature…) sont ignorées ; sans en-tête l'ordre est Nom, Téléphone, Village, Opérateur, Numéro mobile money, Équipe, N° CNIB. Le fichier est vérifié tout de suite. « Vérifier » affiche le résultat ligne par ligne sans rien écrire ; « Importer » n'enregistre que les lignes valides. Les doublons (déjà enregistrés ou répétés dans la liste) sont ignorés, donc relancer le même import ne crée rien en double.
- **Sauvegarde** : bouton « Exporter la sauvegarde » (fichier JSON partagé depuis l'appareil) ou `npm run backup` dans `backend/` (écrit `backups/sauvegarde-AAAA-MM-JJ.json`). Sans PIN ni signatures de visage. Il n'y a pas de restauration automatique : le fichier sert d'archive et de contrôle ; les sauvegardes complètes de la base sont celles de Supabase.
