# Exploitation : sauvegardes, restauration, déploiement, supervision

Tout se lance sur le VPS, en tant que `deploy`, depuis `/srv/platform` (clone de ce dépôt).
Aucun de ces scripts n'affiche de secret. La configuration d'exploitation (non versionnée) est dans
`infra/.env.ops` (modèle : `infra/.env.ops.example`).

## Vue d'ensemble

| Quoi | Script | Quand |
|---|---|---|
| Sauvegarde complète | `scripts/backup.sh` | chaque nuit à 03h30 (Paris), timer `platform-backup` |
| Test de restauration (base jetable) | `scripts/restore.sh --test` | chaque dimanche à 05h00, timer `platform-restoretest` |
| Restauration réelle | `scripts/restore.sh <projet> <dump> --apply` | à la main, en cas de besoin |
| Déploiement | `scripts/deploy.sh <projet> [--migrate]` | à la main |
| Retour arrière | `scripts/rollback.sh <projet>` | à la main (ou automatique si le déploiement échoue) |
| Supervision + alerte e-mail | `scripts/healthwatch.sh` | toutes les 2 minutes, timer `platform-healthwatch` |

Installation : `scripts/setup-alerts.sh` (une fois), puis `scripts/install-timers.sh`.

## Sauvegardes

Contenu d'une sauvegarde quotidienne (`/srv/backups`, dossiers 700, fichiers 600) :

- `daily/<base>/<base>_<UTC>.dump` : `pg_dump -Fc` de chaque base de projet (compressé), + `.sha256`.
- `daily/_globals/` : rôles Postgres (`pg_dumpall --globals-only`, contient des hachages de mots de passe).
- `daily/_config/` : `docker-compose.yml`, `.env` et `secrets/` de chaque projet, `infra/.env`, `infra/.env.ops`,
  blocs Caddy, règles `pg_hba`. **Contient des secrets** : à ne jamais copier hors du VPS en clair.
  Le secret du superutilisateur Postgres n'est pas inclus (il est recréé par `init-infra.sh` sur un nouveau serveur).
- `daily/_caddy/` : volume des certificats Caddy (évite de redemander des certificats Let's Encrypt, qui ont des quotas).

Rotation : 7 quotidiennes, 4 hebdomadaires (un lien dur du plus récent fichier si aucun hebdomadaire n'a moins de
6 jours : pas de place supplémentaire). Chaque dump est relu (`pg_restore --list`) avant d'être conservé.
Avant chaque déploiement ou restauration, une sauvegarde de sécurité de la base concernée est faite dans
`predeploy/<base>/` (5 conservées).

Une sauvegarde ratée envoie un e-mail. La supervision alerte aussi si la dernière sauvegarde réussie a plus de 26 h
(couvre le cas où le timer ne tourne plus).

### Copie hors VPS (non activée pour l'instant)

Les sauvegardes sont aujourd'hui **sur le même disque que les données** : elles protègent d'une erreur de
manipulation, pas de la perte du VPS. À activer dès que possible :

1. Installer rclone : `sudo apt-get install -y rclone`.
2. `rclone config` : créer d'abord le remote du stockage (ex : Backblaze B2, type `b2`), puis un second remote de
   type **`crypt`** qui l'enveloppe (ex : `b2crypt`, pointant sur `b2:<bucket>`). Les clés sont saisies sur le VPS.
3. Dans `infra/.env.ops` : `RCLONE_REMOTE=b2crypt:`.
4. `scripts/backup.sh` envoie alors tout `/srv/backups` après chaque sauvegarde. Il **refuse** un remote non chiffré.
5. **Sauvegarde les mots de passe rclone crypt dans ton gestionnaire de mots de passe** : sans eux, les copies
   sont illisibles.

## Restauration

### Tester (sans risque)

```bash
scripts/restore.sh --test            # toutes les bases ; ou --db tenue
```

Pour chaque base : vérifie la somme de contrôle, crée `restore_test_<base>` (même propriétaire et mêmes droits
que la vraie), restaure la dernière sauvegarde quotidienne avec les mêmes options que la restauration réelle,
affiche le nombre de lignes de chaque table (restauré / production), puis supprime la base jetable.
Les bases réelles ne sont jamais modifiées. Le timer hebdomadaire fait la même chose et envoie un e-mail en cas d'échec.

### Restaurer pour de vrai (un projet)

```bash
ls -1 /srv/backups/daily/tenue/                       # choisir un fichier
scripts/restore.sh tenue /srv/backups/daily/tenue/tenue_20261107T023000Z.dump --apply
```

Le script : demande de retaper le nom de la base, fait une sauvegarde de sécurité (`predeploy`), arrête `tenue-api`,
supprime et recrée la base `tenue` (même création que `create-project.sh`), restaure, redémarre l'API et attend
qu'elle soit saine. En cas d'échec, il indique le fichier `predeploy` pour revenir à l'état d'avant.

### Perte totale du VPS

1. Nouveau VPS : `server/harden.sh`, puis Docker, puis `scripts/init-infra.sh` et `docker compose up -d` dans `infra/`.
2. Récupérer l'archive `_config` la plus récente (copie hors VPS) : elle contient les `.env`, `secrets/`, blocs Caddy.
   La restaurer avec `tar -C / -xzf config_<date>.tar.gz`.
3. Recréer chaque projet : `scripts/create-project.sh <nom>` puis remplacer son `.env` par celui sauvegardé
   (ou mettre à jour le mot de passe du rôle), puis `restore.sh <nom> <dump> --apply`.
4. Mettre à jour les enregistrements DNS vers la nouvelle IP.
5. (Optionnel) restaurer `_caddy` pour réutiliser les certificats ; sinon Caddy en redemande.

## Déploiement

```bash
scripts/deploy.sh tenue --migrate     # git pull + sauvegarde + build + migrations + bascule
scripts/deploy.sh tenue --no-pull     # code déjà copié dans app/ (rsync)
scripts/rollback.sh tenue             # revenir à la version précédente
scripts/rollback.sh tenue --list      # versions disponibles
```

- L'image est étiquetée par le commit git (`tenue-api:<sha>`), ou `manual-<horodatage>` hors git.
  Les 4 dernières sont gardées.
- Les migrations tournent **avant** la bascule, avec la nouvelle image : si elles échouent, l'ancienne version
  reste en ligne. Elles ne s'exécutent jamais au démarrage de l'API.
- Si la nouvelle version n'est pas « healthy » après 90 s, retour automatique à la précédente et e-mail.
- **Un retour arrière ne défait pas les migrations.** Règle : migrations rétro-compatibles (ajouter une colonne
  ou une table avant de supprimer l'ancienne, supprimer seulement dans un déploiement ultérieur). Pour un
  retour de données : `restore.sh --apply` avec le fichier `predeploy` juste avant le déploiement.

### Passer au déploiement par `git pull` (plus tard)

Aujourd'hui `app/` est copié par `rsync`. Pour utiliser `git pull` : créer un dépôt privé pour `tenue-api`,
générer **sur le VPS** une clé de déploiement en lecture seule (`ssh-keygen -t ed25519 -f ~/.ssh/tenue_deploy`),
ajouter la clé **publique** dans les « Deploy keys » du dépôt, puis cloner dans `/srv/projects/tenue/app`.
`deploy.sh` détecte alors `.git` et fait `git pull --ff-only` (il refuse un arbre modifié).

## Supervision et alertes

`healthwatch.sh` contrôle toutes les 2 minutes : démon Docker, conteneurs `caddy`, `postgres`, `<projet>-api`
(en marche et « healthy »), réponse HTTPS de `/health` de chaque API via Caddy, certificat valide plus de 14 jours,
disque sous 85 %, sauvegarde de moins de 26 h.

- Alerte après 2 échecs consécutifs (~4 min), un seul e-mail par incident, rappel toutes les 12 h, e-mail « rétabli ».
- `scripts/healthwatch.sh --check` affiche l'état de chaque contrôle à la demande.
- **Limite** : un VPS éteint ne peut pas envoyer d'e-mail. Ajoute un moniteur **externe** gratuit
  (UptimeRobot ou Healthchecks.io) sur `https://api.tenue.ahua.fr/health`, qui t'écrit s'il ne répond plus.
  Il n'a besoin d'aucun secret.
- L'envoi d'e-mails passe par `msmtp` et un relais SMTP que tu choisis (`scripts/setup-alerts.sh`). Le mot de
  passe SMTP n'est que dans `~/.msmtprc` (600) sur le VPS.

## Dépannage rapide

```bash
systemctl list-timers 'platform-*' --no-pager       # prochaines exécutions
journalctl -u platform-backup --since yesterday     # journal de la sauvegarde
journalctl -u platform-healthwatch -n 50            # journal de la supervision
scripts/healthwatch.sh --check                      # état immédiat
tail -20 ~/.msmtp.log                               # erreurs d'envoi d'e-mail
```
