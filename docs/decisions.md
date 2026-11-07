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
