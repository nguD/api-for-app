# Décisions et choix par défaut

Ce fichier liste les décisions prises quand la demande initiale ne les couvrait pas.
Il est repris dans le README final (étape 7).

## Contexte

- Usage : **production uniquement**.
- VPS IONOS, Ubuntu 26.04.1 LTS, 1 vCPU, 2 Go RAM, 60 Go de disque.
- Domaine `ahua.fr` (DNS chez Gandi). Une API = un sous-domaine `api.<projet>.ahua.fr`
  (enregistrement A vers l'IP du VPS). Premier projet : `api.tenue.ahua.fr`.
- Utilisateur d'administration : `deploy` (sudo avec mot de passe, SSH par clé uniquement).
- Clé SSH dédiée à ce VPS : `~/.ssh/ahua_vps_ed25519` (ne pas réutiliser celle d'autres serveurs).

## Étape 2 — durcissement

- **Deux phases** (`install` puis `lockdown`) : root et mot de passe SSH ne sont coupés
  qu'après un test réussi de la connexion par clé.
- Fichier SSH nommé `00-hardening.conf` : sshd garde la première valeur rencontrée, il doit
  passer avant `50-cloud-init.conf`. Les valeurs effectives sont vérifiées avec `sshd -T`
  avant rechargement, avec retour arrière automatique.
- `deploy` a un **mot de passe sudo** (pas de `NOPASSWD`) : un vol de clé SSH ne donne pas root.
- Le mot de passe root du VPS est conservé (utile pour la console web IONOS), mais la
  connexion SSH de root est refusée.
- `AllowTcpForwarding local` : autorise `ssh -L` pour administrer Postgres via tunnel.
- ufw : 22 (limité en débit), 80, 443 en TCP. Pas de 443/UDP (HTTP/3) : choix de rester
  strictement sur 22/80/443 comme demandé. Caddy fonctionne très bien en HTTP/2.
- fail2ban : jail `sshd`, ban 1 h, croissant jusqu'à 1 semaine, `banaction = ufw`.
- Mises à jour de sécurité automatiques, **sans redémarrage automatique** : vérifier
  `/var/run/reboot-required` (le script de vérification l'indique).
- Swap de 2 Go, `vm.swappiness=10`.
- Docker : rotation des logs (10 Mo x 3), `live-restore`.
- Docker contourne ufw pour les ports qu'il publie : seul Caddy publiera 80/443, Postgres
  ne publiera aucun port. Le groupe `docker` donne un accès équivalent à root : seul `deploy`
  en fait partie.
- Les mises à jour automatiques ne couvrent que les dépôts de sécurité Ubuntu. Si Docker vient
  d'un dépôt tiers, ses mises à jour sont manuelles (à vérifier : `apt-cache policy docker-ce docker.io`).

## Étape 3 — Docker, Caddy, Postgres

- Dépôt cloné sur le VPS dans **`/srv/platform`** (la stack tourne depuis `/srv/platform/infra`).
  Projets dans `/srv/projects/<nom>`, dumps locaux dans `/srv/backups` (700).
- **PostgreSQL 17** (et non 16) : plus récent, supporté jusqu'en 2029. Évite aussi le changement
  de répertoire de données de la 18. `--data-checksums` activé.
- Images épinglées sur la **version majeure** (`postgres:17-bookworm`, `caddy:2-alpine`) :
  les mises à jour mineures sont volontaires (`docker compose pull`). À durcir avec des digests si besoin.
- Superutilisateur Postgres `dbadmin`. Son mot de passe est un **fichier secret** (400, propriétaire uid 999),
  généré sur le serveur, jamais affiché. Il n'est pas utilisé au quotidien : l'administration passe par
  `docker exec postgres psql` (socket Unix interne, `local trust`). Aucune connexion superutilisateur par le réseau.
- `pg_hba.conf` : `reject` par défaut + `include_dir hba.d/` : un fichier par projet, limité à son
  utilisateur, sa base **et au sous-réseau Docker fixe de son projet** (défini à l'étape 4).
- Postgres est sur `db_internal` (réseau `internal: true`, sans accès Internet) et n'a aucun port publié.
  `listen_addresses=*` s'applique donc seulement aux interfaces Docker internes.
- Pas de TLS entre l'API et Postgres : le trafic reste sur un réseau Docker local à l'hôte.
- Caddy : HTTP/3 désactivé (443/UDP fermé), conteneur en lecture seule, `cap_drop: ALL` + `NET_BIND_SERVICE`.
- `ACME_CA` optionnel dans `.env` pour tester avec le CA de test Let's Encrypt avant la production.
- `compose.networks.yml` (réseaux de projets) et `caddy/sites/*.caddy`, `postgres/hba.d/*.conf` sont des
  fichiers générés, non versionnés : l'état des projets vit sur le serveur, pas dans git.

## Étape 4 — create-project.sh

- Un projet = une base `<nom>`, un rôle `<nom>_app` (LOGIN, NOSUPERUSER, NOCREATEDB, NOCREATEROLE,
  NOREPLICATION, 15 connexions max), un réseau Docker `net_<nom>` à **sous-réseau fixe** `10.77.N.0/24`.
- `hba.d/<nom>.conf` autorise ce rôle, sur cette base, **depuis ce sous-réseau uniquement**. Même avec le bon
  mot de passe, un autre projet ne peut pas se connecter. `CONNECT` est aussi révoqué pour PUBLIC sur
  `postgres`, `template1` et la base du projet ; `public` n'est plus utilisable par PUBLIC.
- Postgres et Caddy sont rattachés au réseau du projet **à chaud** (`docker network connect`, sans redémarrage).
  `compose.networks.yml` est régénéré à partir de `hba.d/*.conf` pour que cela survive à un redémarrage.
  Conséquence : le prochain `docker compose up -d` dans `infra/` recréera caddy/postgres (quelques secondes
  de coupure) : à faire en maintenance planifiée.
- Le mot de passe est généré (192 bits), passé à psql par stdin (jamais en argument), écrit dans le `.env` du
  projet (600). Il n'est **affiché que si `--show-password`** est passé, car les sorties de terminal peuvent
  être collées dans un chat ou enregistrées. Écart volontaire par rapport à « affiché une seule fois ».
- Si une étape échoue (ou Ctrl+C), le script annule ce qu'il a créé (base, rôle, réseau, fichiers).
- Dossier projet : `/srv/projects/<nom>/{docker-compose.yml,.env,secrets/,app/}`. `app/` = clone du dépôt de l'API.
  Le compose et le `.env` ne sont pas dans le dépôt de l'API : ils suffisent, avec un `pg_dump` et le DNS, à migrer.
- Le conteneur API tourne avec l'uid/gid de `deploy` (pour lire `secrets/` en 600), en lecture seule,
  `cap_drop: ALL`. Sur un autre VPS, `create-project.sh` (ou un `sed`) réadapte l'uid.
- `check-project.sh <nom>` : teste l'isolation depuis un conteneur jetable sur le réseau du projet
  (accès légitime OK, autres bases refusées, superuser refusé par le réseau, mauvais mot de passe refusé).

## Étape 5 — API Tenue (projects/tenue-api, dépôt git séparé)

- Code dans `projects/tenue-api/`, **ignoré par ce dépôt** (`projects/*/`) et doté de son propre dépôt git.
  Première mise en ligne par `rsync` (aucune clé de déploiement nécessaire) ; la clé de déploiement GitHub
  en lecture seule sera mise en place avec `deploy.sh` (git pull).
- Node.js **24 LTS** dans l'image Docker (testé en local avec Node 22). Fastify 5, Zod 4, Drizzle ORM (migrations SQL
  versionnées dans `drizzle/`, générées par `drizzle-kit generate`), firebase-admin (imports modulaires).
- Authentification : `Authorization: Bearer <ID token Firebase>` vérifié par le SDK Admin. `request.user.uid` est
  la SEULE identité utilisée ; `user_id` n'est jamais lu depuis le client (`z.strictObject` refuse tout champ inconnu).
  Chaque requête SQL filtre sur `user_id` (vérifié par des tests sur le SQL réellement envoyé).
  Élément d'un autre utilisateur : **404** (et non 403) pour ne pas révéler son existence.
- Révocation des tokens non vérifiée par défaut (`FIREBASE_CHECK_REVOKED=false`) : évite un appel réseau à Google par
  requête. Un token volé reste donc valable jusqu'à son expiration (1 h). À activer si le besoin le justifie.
- Au démarrage, l'API compare `project_id` du compte de service à `FIREBASE_PROJECT_ID` et refuse de démarrer en cas
  d'écart. Les messages d'erreur de configuration ne contiennent jamais de valeur de variable.
- Limites de débit : par IP (100 requêtes / 60 s, avant authentification, y compris sur les 404) via `@fastify/rate-limit`,
  puis par uid (300 / 60 s) via `rate-limiter-flexible`. Compteurs **en mémoire** : suffisant pour un conteneur unique,
  réinitialisés à chaque redémarrage.
- `trustProxy` limité aux adresses privées (`loopback,uniquelocal`) : seul Caddy atteint l'API. Caddy remplace
  `X-Forwarded-For` par défaut, le client ne peut donc pas falsifier son IP.
- CORS fermé par défaut (application mobile). Origines autorisées via `CORS_ORIGINS`.
- `/health` interroge la base (`select 1`, timeout 2 s) : 200 si tout va bien, 503 sinon. La supervision détecte donc aussi
  une base indisponible. Public mais soumis à la limite par IP.
- Logs JSON (pino) avec `redact` (Authorization, cookies, mots de passe, tokens, clés). L'uid est journalisé (identifiant
  pseudonyme, utile au diagnostic). Le token n'est jamais écrit : un test le vérifie.
- Les migrations ne s'exécutent JAMAIS au démarrage : `docker compose run --rm api node dist/db/migrate.js`, à lancer
  volontairement après un dump (voir étape 6).
- Dépendances : 6 alertes `npm audit` « moderate » en production, toutes **indirectes via firebase-admin**
  (`glob`/`minimatch`/`rimraf` dans le chemin Firestore, non utilisé ici, sans entrée utilisateur) ; non corrigeables sans
  changement majeur. À revérifier régulièrement (`npm audit --omit=dev`). `drizzle-kit` (esbuild) est un outil de
  développement absent de l'image.
- Outils de test : `tools/mint-test-id-token.mjs` (crée un vrai ID token pour un uid de test à partir du compte de service)
  et `tools/smoke-test.sh` (scénario de bout en bout avec deux utilisateurs). Ils créent les utilisateurs de test
  `smoke-alice` et `smoke-bob` dans Firebase Auth (supprimables ensuite dans la console).
- Le compte de service est monté depuis `/srv/projects/tenue/secrets/` (600) en lecture seule dans `/run/secrets/`.
  Il n'est ni dans git, ni dans l'image (`.dockerignore`), ni lu par le code autrement que par `cert(chemin)`.

## Étape 6 — Sauvegardes, déploiement, supervision

Détail d'usage dans `docs/operations.md`. Décisions :

- **Copie hors VPS reportée** (choix de l'utilisateur). Le script la gère déjà (`RCLONE_REMOTE`) et refuse tout
  remote non chiffré (`crypt`), car les archives contiennent des secrets. En attendant, les sauvegardes sont sur le
  même disque que les données : protection contre l'erreur humaine, pas contre la perte du VPS. À corriger vite.
- Format des dumps : `pg_dump -Fc` (compressé, restauration sélective possible), un fichier par base, relu par
  `pg_restore --list` avant d'être gardé. Somme `.sha256` à côté. Écriture dans `*.part` puis `mv` (jamais de
  fichier à moitié écrit pris pour une sauvegarde).
- Rotation : 7 quotidiennes + 4 hebdomadaires (liens durs, aucune place supplémentaire) ; 5 « predeploy » par base.
- Sont aussi sauvegardés : rôles Postgres, configuration des projets (`.env`, `secrets/`), blocs Caddy, `pg_hba`, volume
  des certificats Caddy. **Pas** `infra/secrets/postgres_password` (illisible pour `deploy`, recréé sur un nouveau serveur).
- Restauration : `--test` restaure dans une base jetable créée comme une vraie base de projet, avec exactement
  les mêmes options que `--apply` (`--single-transaction --exit-on-error --no-owner --no-acl --role=<projet>_app`) :
  un test réussi garantit que la vraie restauration ne trouvera pas d'erreur d'ordre ou de droits. Exécuté
  chaque semaine par un timer, avec alerte en cas d'échec.
- Déploiement : images étiquetées par le sha git (`manual-<horodatage>` hors git), 4 conservées ; migrations avant la
  bascule avec la nouvelle image ; retour automatique si le healthcheck échoue. Les retours arrière ne défont pas les
  migrations (règle : migrations rétro-compatibles, documentée).
- Alertes : e-mail via `msmtp` et un relais SMTP choisi par l'utilisateur (mot de passe saisi sur le VPS, jamais
  dans git ni dans le chat). Simple et sans service tiers. Limite assumée : un VPS éteint ne peut pas écrire,
  d'où la recommandation d'un moniteur externe gratuit (UptimeRobot / Healthchecks.io, sans secret).
- Anti-bruit : 2 échecs consécutifs avant alerte, un e-mail par incident, rappel à 12 h, e-mail de rétablissement.
- Planification par timers systemd (pas cron) : `Persistent=true` rattrape une sauvegarde manquée si le VPS était
  éteint, journalisation dans journald, fuseau explicite `Europe/Paris`.
