# Guide de démonstration (sans internet, sans Wi-Fi du chantier)

Le « Wi-Fi » utilisé ici n'est pas internet : c'est un petit réseau que le **PC crée lui-même**, uniquement pour que les téléphones parlent au PC.

## 1. Avant de partir (la veille)

1. Dans le dossier `backend` : `npm run demo:seed` (recrée les données fictives, la vraie base n'est jamais touchée).
2. `npm run demo` : le serveur de démonstration démarre (compter environ une minute).
3. Ouvrir http://localhost:3001 sur le PC et se connecter une fois pour vérifier.
4. Brancher le portable sur secteur, désactiver la veille.

## 2. Sur place : créer le réseau (2 minutes)

1. Windows 11 : **Paramètres → Réseau et Internet → Point d'accès sans fil mobile**.
2. Noter le nom du réseau et le mot de passe (modifiables), puis activer l'interrupteur.
   S'il demande une connexion internet à partager, choisir « Wi-Fi » ou « Ethernet » même sans internet : le point d'accès fonctionne quand même.
3. Lancer `npm run demo` dans `backend`.
4. Sur chaque téléphone : se connecter à ce réseau (le téléphone dira « pas d'internet », c'est normal : rester connecté).
5. Ouvrir dans le navigateur du téléphone : **http://192.168.137.1:3001**
   (si cette adresse ne répond pas, lancer `ipconfig` sur le PC et utiliser l'adresse de la carte « Wi-Fi Direct / Connexion au réseau local* »).

Si le pare-feu Windows demande une autorisation pour Node.js, accepter pour les réseaux **privés**.

## 3. Comptes de démonstration

| Rôle | Nom | PIN |
|---|---|---|
| Admin et président | Directeur Démo | 4827 |
| Superviseur | Chef Alpha | 5931 |
| Superviseur | Chef Bravo | 7264 |
| Superviseur | Chef Nuit | 6158 |

Les noms et les données sont fictifs. Aujourd'hui est laissé vide pour saisir en direct.

## 4. Déroulé conseillé (environ 10 minutes)

1. **Superviseur (téléphone)** : connexion de Chef Alpha, marquer les présences, saisir les briques d'aujourd'hui.
2. **Hors ligne** : sur le téléphone, désactiver le Wi-Fi, saisir une autre équipe (Chef Bravo), puis réactiver le Wi-Fi : la saisie part toute seule.
   *(Le mode hors ligne est celui de l'application Android ; dans un navigateur il est limité.)*
3. **Admin (PC)** : tableau de bord (briques, coût, valeur de vente, marge), statistiques, alertes.
4. **Paie** : fiche d'un ouvrier, état de paie du mois, PDF.
5. **Rapports (président)** : production, paie globale, présence, impression ou export.

## 5. À ne pas faire

- Ne pas montrer `backend/.env` ni `backend/.localdb/secrets.json`.
- Ne pas utiliser la vraie base devant les clients (le serveur de démonstration est sur le port **3001**, le vrai sur **3000**).
- Ne pas mettre l'application sur internet pour la démonstration.

## 6. Dépannage rapide

| Problème | Solution |
|---|---|
| Le téléphone n'ouvre pas la page | Vérifier qu'il est sur le réseau du PC, puis `ipconfig` pour l'adresse exacte |
| « Connexion refusée » | Le serveur n'est pas encore prêt (attendre une minute) ou le pare-feu bloque : autoriser Node.js (réseau privé) |
| Le point d'accès ne s'active pas | Redémarrer le PC, ou utiliser le partage de connexion d'un téléphone à la place |
| Remettre la démo à zéro | Arrêter le serveur, `npm run demo:seed`, `npm run demo` |
