Tu es un développeur Flutter senior. L'API de production de l'app « Tenue » (gestion de dressing) est en ligne :
https://api.tenue.ahua.fr. Ta mission : brancher l'app dessus, proprement, en suivant STRICTEMENT le « CONTRAT API v2 »
qui se trouve à la fin de ce message. Ce contrat est la seule source de vérité : n'invente aucune route, aucun champ, aucun code
d'erreur. S'il te manque quelque chose, dis-le-moi au lieu de le deviner.

Commence par lire le code existant de l'app (architecture, gestion d'état, navigation, modèles, tests) et respecte ses conventions.

## Fondations
1. Un client HTTP unique (ex. `ApiClient`) avec la base URL dans une configuration (jamais en dur dans les écrans).
2. Avant CHAQUE requête : `await FirebaseAuth.instance.currentUser!.getIdToken()` (le SDK met en cache et renouvelle).
   Sur 401 `unauthorized` : `getIdToken(true)` puis UN SEUL réessai ; si 401 de nouveau, déconnecter proprement l'utilisateur.
3. Ne JAMAIS journaliser ni stocker le token ; ne mettre aucun secret dans l'app (ni clé Bunny, ni compte de service : l'app n'en
   a pas besoin, les photos passent par l'API).
4. Erreurs typées : une `ApiException(status, code, retryAfter?)` construite depuis le champ `error` du JSON, et un mapping
   code -> message utilisateur en français (ne jamais afficher `details[].message`, ils sont techniques ; utiliser `details[].path`
   pour surligner le champ fautif).
   - 429 `rate_limited` : attendre `retryAfterSeconds`, pas de boucle de réessai.
   - 500 `internal_error` : message générique, réessai avec délai croissant (max 2 fois).
   - 502 `storage_unavailable` / `auth_unavailable` : proposer « Réessayer » (rien n'a été modifié, ou la requête est rejouable).
   - 404 `not_found` : traiter comme « absent » (aussi pour la ressource d'un autre utilisateur).
5. Le client n'envoie JAMAIS d'identifiant utilisateur ni d'`id`/`number`/`createdAt` dans un corps : l'identité vient du token.
6. Dates : ISO 8601 UTC avec millisecondes ; envoyer `DateTime.toUtc().toIso8601String()`, afficher en heure locale.

## Fonctionnalités à brancher (toutes décrites dans le contrat)
- Vêtements : liste paginée (limit/offset) avec filtres `category`, `status`, `style` (listes séparées par des virgules) et
  `neverWornSince` ; création ; lecture ; modification partielle (`PATCH`, uniquement les champs changés) ; suppression.
  Modèle `Item` complet : `number`, `style`, `warmth` (1..4), `waterproof`, `status`, `estimatedPrice` (null possible), `imageUrl`,
  `thumbUrl`, `wearCount`, `lastWornAt`. Les 18 catégories du contrat dans un enum Dart ; une valeur inconnue reçue du serveur ne doit
  pas faire planter l'app (valeur de repli).
- Photos : avant l'envoi, redimensionner côté app en JPEG (image ≤ 1200 px, miniature ≤ 400 px, chacune < 5 Mo), puis
  `POST /v1/items/{id}/image` en multipart (champs `image` et `thumb` uniquement ; ne PAS fixer le Content-Type à la main).
  Afficher `thumbUrl` en liste, `imageUrl` en détail, avec `cached_network_image` et une clé de cache stable (id de la pièce + type),
  car les URLs signées changent toutes les heures. Ne pas stocker les URLs durablement : les redemander via l'API. Sur échec de
  chargement (403) : rafraîchir l'item. Suppression de photo : `DELETE /v1/items/{id}/image`.
- Portés : `POST /v1/items/{id}/wear` (wornAt optionnel, jamais dans le futur) ; mettre à jour `wearCount`/`lastWornAt` localement
  à partir de la réponse ou recharger l'item.
- Tenues : `POST /v1/outfits` (haut + bas obligatoires, couche optionnelle, `weatherSnapshot` strict, `wornAt` optionnel) et
  `GET /v1/outfits` paginé. Attention : supprimer un vêtement supprime les tenues dont il est le haut/bas (la couche passe à null) :
  prévenir l'utilisateur avant la suppression et rafraîchir la liste des tenues après.
- Profil : `GET`/`PATCH /v1/me/profile` (displayName, city, preferredStyle, tempUnit ; `null` pour effacer le nom ou la ville).
- Compte (exigence App Store / Google Play) : un écran « Supprimer mon compte » avec confirmation explicite, qui appelle
  `DELETE /v1/me` en suivant l'exemple du contrat : sur `recent_login_required`, demander une reconnexion
  (`reauthenticateWithCredential` selon le fournisseur : Apple, Google, e-mail/mot de passe), puis rejouer. Sur 204 :
  `FirebaseAuth.instance.signOut()` et effacement complet du cache local. Sur 502 : « Réessayer » (la requête est reprenable).
- Export : `GET /v1/me/export` (limité à 5 par heure) : enregistrer/partager le JSON via la feuille de partage du système.

## Exigences de qualité
- Couche d'accès séparée de l'interface (repositories + modèles typés avec sérialisation JSON), états de chargement / vide /
  erreur pour chaque écran, aucune logique réseau dans les widgets.
- Tests : client API testé avec un faux transport HTTP (succès, 401 puis réessai, 404, 413, 415, 429 avec retryAfter, 502, 500),
  désérialisation de chaque modèle, et au moins un test de widget par écran branché.
- Ne casse rien d'existant ; fais des changements par étapes, en indiquant à la fin de chacune ce qui est branché et ce qui reste.

## Première étape (avant tout le reste)
Branche uniquement `GET /v1/me` avec le vrai token Firebase et affiche l'uid reçu dans un écran de debug (retiré ensuite) : ça
prouve que l'authentification fonctionne de bout en bout. Montre-moi le résultat, puis continue dans l'ordre : vêtements, photos,
portés, tenues, profil, export, suppression de compte.

==================== CONTRAT API v2 (source de vérité) ====================

