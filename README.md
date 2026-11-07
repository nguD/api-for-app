# Plateforme d'APIs mobiles (VPS unique, production)

Infrastructure pour héberger plusieurs APIs de projets mobiles sur un seul VPS, avec une isolation stricte entre
projets, et la possibilité de déplacer n'importe quel projet vers son propre VPS.

- **Serveur** : IONOS, Ubuntu 26.04 LTS, 1 vCPU, 2 Go de RAM, 60 Go. IP `31.70.169.172`.
- **Domaine** : `ahua.fr` (DNS chez Gandi). Une API = un sous-domaine `api.<projet>.ahua.fr`.
- **Projet en ligne** : `tenue` (`https://api.tenue.ahua.fr`), application Flutter de dressing, authentification Firebase
  (projet `dressing-assistance`). Le code de l'API est dans son propre dépôt (`projects/tenue-api/`, ignoré ici).
- **Usage** : production uniquement.

Pour les décisions détaillées et les écarts par rapport à la demande initiale : [`docs/decisions.md`](docs/decisions.md).
Pour l'exploitation au quotidien (sauvegardes, restauration, déploiement, alertes) : [`docs/operations.md`](docs/operations.md).

## 1. Architecture

```
                         Internet
                            │  80 / 443 (seuls ports ouverts, avec 22 pour SSH)
                     ┌──────┴──────┐
                     │    Caddy    │  HTTPS automatique (Let's Encrypt), en-têtes de sécurité, limite de taille
                     └──┬───────┬──┘
        réseau net_tenue │       │ réseau net_<autre projet>
                  ┌──────┴──┐ ┌──┴───────────┐
                  │tenue-api│ │<autre>-api   │   un conteneur par projet : lecture seule, sans capacités,
                  └──────┬──┘ └──┬───────────┘   mémoire limitée, secrets montés en fichiers
                         │       │
                      ┌──┴───────┴──┐
                      │  Postgres   │   UNE instance, UNE base et UN utilisateur par projet.
                      └─────────────┘   Aucun port publié. Réseau interne sans accès Internet.
```

Règles d'isolation :

| Élément | Isolation |
|---|---|
| Réseau | Chaque projet a son réseau Docker `net_<projet>` (sous-réseau fixe `10.77.N.0/24`). Seuls Caddy et Postgres y sont rattachés : un projet ne voit jamais un autre projet. |
| Base de données | Une base `<projet>` et un rôle `<projet>_app` (ni superuser, ni createdb, ni createrole). `REVOKE` sur `PUBLIC`. Le rôle est refusé sur toutes les autres bases. |
| Accès Postgres | `pg_hba.conf` : `reject` par défaut, une règle par projet limitée à son rôle, sa base et son sous-réseau. Le superutilisateur `dbadmin` n'est joignable que par la socket Unix du conteneur (`docker exec`), jamais par le réseau. |
| Secrets | Fichiers (`/srv/projects/<projet>/secrets/`, 700) montés en lecture seule dans le conteneur. `.env` en 600. Aucun secret dans git ni dans les images. |
| Exposition | Seul Caddy publie des ports (80/443). Postgres et les APIs n'en publient aucun. |

## 2. Organisation des fichiers

**Dépôt** (`/srv/platform` sur le VPS, https://github.com/nguD/api-for-app) :

```
server/            harden.sh, verify-hardening.sh, systemd/ (timers)    → système
infra/             docker-compose.yml (Caddy + Postgres), caddy/, postgres/, templates/
scripts/           create-project, check-project, backup, restore, deploy, rollback, healthwatch...
docs/              decisions.md, operations.md
```

**Sur le VPS** (hors git, jamais commité) :

```
/srv/platform/infra/.env, .env.ops, secrets/      configuration de l'infra
/srv/projects/<projet>/                           docker-compose.yml, .env (600), secrets/ (700), app/ (code)
/srv/backups/                                     sauvegardes (700) : voir docs/operations.md
```

## 3. Référence des scripts

| Script | Rôle | Lancé |
|---|---|---|
| `server/harden.sh install\|lockdown` | Durcissement du VPS en 2 phases | une fois, en root |
| `server/verify-hardening.sh` | Contrôles du durcissement, lecture seule | à la demande, en root |
| `scripts/init-infra.sh` | Prépare dossiers, `.env`, secret Postgres | une fois |
| `scripts/create-project.sh <nom>` | Crée réseau, base, rôle, règle pg_hba, dossier, bloc Caddy, puis teste l'isolation | à chaque nouveau projet |
| `scripts/check-project.sh <nom>` | Teste l'isolation Postgres du projet | à la demande |
| `scripts/deploy.sh <nom> [--migrate]` | Déploie avec sauvegarde préalable et retour automatique | à chaque mise à jour |
| `scripts/rollback.sh <nom> [tag]` | Revient à une version précédente | si besoin |
| `scripts/backup.sh` | Sauvegarde complète | chaque nuit (timer) |
| `scripts/restore.sh --test` / `<nom> <dump> --apply` | Test de restauration / restauration réelle | chaque dimanche (timer) / si besoin |
| `scripts/healthwatch.sh [--check]` | Supervision et alerte e-mail | toutes les 2 minutes (timer) |
| `scripts/setup-alerts.sh`, `install-timers.sh` | Alertes e-mail, timers systemd | une fois |

Tous s'exécutent en tant que `deploy` (pas en root), sauf `server/*.sh`. Aucun n'affiche de secret.

## 4. Ajouter un projet

Exemple pour un projet `monapp` (nom : minuscules et chiffres, 2 à 20 caractères, commence par une lettre).

1. **DNS (Gandi)** : ajouter un enregistrement `A` : `api.monapp` → `31.70.169.172`. Vérifier :
   `dig +short api.monapp.ahua.fr`. Le certificat ne peut être obtenu qu'une fois le DNS en place.
2. **Créer le projet** sur le VPS :
   ```bash
   cd /srv/platform && git pull
   scripts/create-project.sh monapp          # option : --domain, --port (3000 par défaut)
   ```
   Il crée le réseau, la base, le rôle, la règle `pg_hba`, `/srv/projects/monapp/` et le bloc Caddy, puis lance
   le test d'isolation. En cas d'échec en cours de route, il annule ce qu'il vient de créer.
3. **Contrat de l'API** : le code doit avoir un `Dockerfile` à la racine, écouter sur le port configuré (`PORT`,
   `HOST=0.0.0.0`), répondre `200` sur `GET /health` (idéalement en testant la base), lire `DATABASE_URL` et ses
   autres réglages dans l'environnement, et lire ses fichiers secrets sous `/run/secrets/`. Le modèle de référence
   est `projects/tenue-api/` (Fastify, Zod, Drizzle, migrations versionnées).
4. **Configurer** : compléter `/srv/projects/monapp/.env` (le script y a déjà mis `DATABASE_URL`) ; déposer les
   fichiers secrets dans `/srv/projects/monapp/secrets/`.
5. **Mettre le code** dans `/srv/projects/monapp/app/` (`git clone`, voir `docs/operations.md` pour la clé de
   déploiement, ou `rsync`).
6. **Déployer** : `scripts/deploy.sh monapp --migrate` (ajouter `--no-pull` sans git).
7. **Vérifier** : `scripts/check-project.sh monapp`, `curl -i https://api.monapp.ahua.fr/health`,
   `scripts/healthwatch.sh --check`.
8. **Sauvegardes et supervision** : prises en compte automatiquement (le projet est découvert dans
   `/srv/projects`). Lance `scripts/backup.sh` et `scripts/restore.sh --test` une première fois.

## 5. Migrer un projet vers un VPS dédié

Un projet se déplace avec : son `docker-compose.yml`, son `.env`, ses `secrets/`, un `pg_dump`, et un enregistrement DNS.
Exemple pour `monapp`, de l'ancien serveur (**A**) vers le nouveau (**B**).

**Préparation (jours avant)**

1. Baisser le TTL de l'enregistrement `api.monapp` chez Gandi (par ex. 300 s) pour que le basculement soit rapide.
2. Sur **B** : `server/harden.sh install` puis `lockdown`, installer Docker, cloner ce dépôt dans `/srv/platform`,
   `scripts/init-infra.sh`, `docker compose up -d` dans `infra/`. Vérifier avec `server/verify-hardening.sh`.
3. Sur **B** : `scripts/create-project.sh monapp`. Cela crée une base vide, un rôle et un **nouveau** mot de passe
   dans le `.env` de B (ne reprends pas le `DATABASE_URL` de A).
4. Copier de A vers B (en passant par ton Mac, avec `scp`) : le contenu de `secrets/` et les variables propres au projet
   du `.env` de A (tout **sauf** `DATABASE_URL`). Placer le code dans `app/`.
5. Sur **B** : construire l'image pour vérifier qu'elle se construit : `docker compose build` dans le dossier du projet.

**Jour J (coupure de quelques minutes)**

6. Sur **A** : arrêter l'API pour figer les données : `cd /srv/projects/monapp && docker compose stop api`, puis
   `scripts/backup.sh --db monapp --kind predeploy`. Le dump est dans `/srv/backups/predeploy/monapp/`.
7. Copier ce `.dump` vers **B** (via ton Mac).
8. Sur **B** : `scripts/restore.sh monapp <fichier.dump> --apply` (restaure dans la base, relance l'API et attend qu'elle
   soit saine). PostgreSQL de B doit être de version majeure **égale ou supérieure** à celle de A.
9. Chez Gandi : faire pointer l'enregistrement `A` de `api.monapp` vers l'IP de **B**. Caddy obtient son certificat
   automatiquement dès que le DNS répond (compter 1 à 2 minutes). Option : restaurer l'archive `_caddy` de A dans
   le volume de B pour réutiliser le certificat existant.
10. Vérifier : `curl -i https://api.monapp.ahua.fr/health`, `scripts/healthwatch.sh --check` sur B, et utiliser l'app.
11. Sur **B** : activer les sauvegardes et alertes (`scripts/setup-alerts.sh`, `scripts/install-timers.sh`) et
    lancer `scripts/backup.sh` puis `scripts/restore.sh --test`.

**Après** : garder le projet sur **A** à l'arrêt quelques jours (retour possible en remettant l'ancien DNS), puis le
supprimer. **Il n'existe pas de script de suppression d'un projet** (opération destructive, volontairement non
automatisée) : fais d'abord une dernière sauvegarde et conserve-la.

## 6. Checklist de sécurité

À relire après toute modification importante et au moins une fois par mois.

| Contrôle | Commande | Attendu |
|---|---|---|
| Durcissement du serveur | `sudo server/verify-hardening.sh` | aucun `[FAIL]` |
| SSH : clé uniquement, root refusé | `sudo sshd -T \| grep -E 'passwordauthentication\|permitrootlogin\|pubkeyauthentication'` | `no`, `no`, `yes` |
| Pare-feu | `sudo ufw status` | 22 (limit), 80, 443 seulement |
| Ports en écoute | `sudo ss -tlnp` | SSH, 80/443 (docker-proxy) ; rien d'autre ; pas de 5432 |
| Postgres non publié | `docker port postgres` | vide |
| Isolation de chaque projet | `scripts/check-project.sh <nom>` | tout `[OK]` |
| Fichiers secrets | `ls -la /srv/projects/*/.env /srv/projects/*/secrets` | `.env` en `-rw-------`, `secrets` en `drwx------` |
| Aucun secret dans git | `git ls-files \| grep -Ei '\.env$\|secret\|service-account\|\.pem'` | rien (sauf `.env*.example`) |
| fail2ban | `sudo fail2ban-client status sshd` | jail active |
| Mises à jour de sécurité | `ls /var/run/reboot-required` | absent (sinon : planifier un redémarrage) |
| Supervision | `scripts/healthwatch.sh --check` | `Tout est OK.` |
| Sauvegardes | `systemctl list-timers 'platform-*'` puis `scripts/restore.sh --test` | 3 timers, test `TOUT EST OK` |
| Dépendances de l'API | dans le dépôt de l'API : `npm audit --omit=dev` | voir les risques acceptés dans `docs/decisions.md` |

Entretien mensuel conseillé :
- `sudo apt update && sudo apt upgrade`, puis redémarrer si `/var/run/reboot-required` existe.
- `cd /srv/platform/infra && docker compose pull && docker compose up -d` : mise à jour **mineure** de Caddy et
  Postgres (versions majeures épinglées). Ce redémarrage coupe les APIs quelques secondes : à faire en heure creuse.
- Relire un test de restauration et l'espace disque (`df -h /`).

## 7. Limites connues et points à traiter

- **Pas de copie hors VPS des sauvegardes** (choix reporté). Tant qu'elle n'est pas en place, la perte du VPS fait
  perdre aussi les sauvegardes. Procédure prête dans `docs/operations.md` (rclone chiffré, Backblaze B2 conseillé).
- **Pas de moniteur externe** : un VPS éteint ne peut pas envoyer d'e-mail d'alerte. Ajouter un moniteur gratuit
  (UptimeRobot, Healthchecks.io) sur `https://api.tenue.ahua.fr/health`.
- **Un seul serveur** : une panne du VPS interrompt toutes les APIs. C'est le compromis de départ ; la migration
  par projet (section 5) est la réponse quand un projet le justifie.
- **Ressources** : 2 Go de RAM partagés (Postgres plafonné à 768 Mo, Caddy 128 Mo, chaque API 256 Mo). Surveiller
  `docker stats` et ajouter des projets avec prudence.
- **Révocation des tokens Firebase** non vérifiée par défaut (`FIREBASE_CHECK_REVOKED=false`) : un token volé reste
  valable jusqu'à son expiration (1 h). À activer si le besoin le justifie.
- **Alertes `npm audit`** indirectes via `firebase-admin` : acceptées et documentées dans `docs/decisions.md`.
- **Déploiement par git** pas encore en place pour `tenue` (le code est copié par `rsync`) : voir `docs/operations.md`.
- **Pas de script de suppression de projet** (voir section 5).
