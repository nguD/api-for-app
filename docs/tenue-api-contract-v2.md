# CONTRAT API v2 : API Tenue pour l'application Flutter

À donner tel quel à la conversation qui construit l'app. Ce document **remplace** `tenue-api-contract.md` (v1) et décrit
les routes de la v2. **Statut : EN PRODUCTION depuis le 7 novembre 2026** (validée par 80 vérifications de bout en bout,
dont les photos Bunny et la suppression de compte).

La v2 est **rétrocompatible** : les routes de la v1 (`GET /v1/me`, `GET|POST /v1/items`, `GET|DELETE /v1/items/{id}`)
se comportent comme avant, les objets « vêtement » reçoivent seulement des champs supplémentaires (une app v1 qui
ignore les champs inconnus continue de fonctionner).

- **URL de base (production)** : `https://api.tenue.ahua.fr`
- **Format** : JSON (`Content-Type: application/json`), UTF-8, sauf l'envoi de photo (multipart). Pas de CORS.
- **Authentification** : Firebase Authentication, projet `dressing-assistance`. Toutes les routes `/v1/*` exigent
  `Authorization: Bearer <ID token Firebase>`. `/health` est public.
- **Identité** : uniquement le token. Le client n'envoie **jamais** d'identifiant utilisateur ; tout champ inconnu dans
  un corps ou un paramètre de requête est refusé (`400 validation_error`).
- **Isolation** : la ressource d'un autre utilisateur donne **`404`** (jamais `403`), comme une ressource inexistante.
- **Dates** : ISO 8601 UTC avec millisecondes (`2026-11-07T13:31:20.123Z`). **Identifiants** : UUID (sauf `uid`).
- **Corps JSON vide** : `Content-Type: application/json` avec un corps vide est accepté (utile pour `DELETE` et
  `POST …/wear`). Sur une route qui exige un corps, cela donne `400 validation_error`.

Obtention du token, conseils et classe `ApiException` : inchangés (voir v1). Rappel : `getIdToken()` avant chaque
requête ; sur `401 unauthorized`, `getIdToken(true)` puis **un seul** réessai.

---

## 1. Objet « vêtement » (item)

Renvoyé par `GET/POST/PATCH /v1/items…`, `POST …/image`.

```json
{
  "id": "3f1b2c4e-5a6d-4e7f-8a9b-0c1d2e3f4a5b",
  "number": 12,
  "name": "Chemise bleue",
  "category": "shirt",
  "color": "#1A2B3C",
  "style": "casual",
  "warmth": 2,
  "waterproof": false,
  "status": "active",
  "estimatedPrice": 39.9,
  "imageUrl": "https://<cdn>/users/<uid>/items/<id>.jpg?token=…&expires=1794150000",
  "thumbUrl": "https://<cdn>/users/<uid>/items/<id>_thumb.jpg?token=…&expires=1794150000",
  "wearCount": 3,
  "lastWornAt": "2026-11-01T08:15:00.000Z",
  "createdAt": "2026-10-02T13:31:20.123Z"
}
```

| Champ | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `number` | entier ≥ 1 | **attribué par le serveur**, propre à chaque utilisateur (1, 2, 3…), **jamais réutilisé** (même après suppression), **immuable** |
| `name` | string | 1 à 100 car. (espaces autour retirés) |
| `category` | enum | `top` `bottom` `outerwear` `dress` `shoes` `accessory` `other` (v1) + `tee` `shirt` `sweater` `turtleneck` `jacket` `jeans` `chino` `jogger` `cargo` `hoodie` `sweatshirt` |
| `color` | string \| null | texte libre de 1 à 30 car. (`"bleu"`, `"#1A2B3C"`…) ; le serveur ne valide pas le format |
| `style` | enum | `casual` (défaut) `chic` `fashion` |
| `warmth` | entier 1..4 | défaut `2` |
| `waterproof` | bool | défaut `false` |
| `status` | enum | `active` (défaut) `listed` `sold` |
| `estimatedPrice` | nombre \| null | 0 à 100 000, **2 décimales au plus** ; défaut `null` |
| `imageUrl`, `thumbUrl` | string \| null | URLs **signées** (voir §6), `null` si pas de photo |
| `wearCount` | entier | nombre de fois porté (≥ 0) |
| `lastWornAt` | date \| null | dernier port, `null` si jamais porté |
| `createdAt` | date | |

Les vêtements existants avant la v2 reçoivent : `number` par ordre de création, et les valeurs par défaut pour le reste.

---

## 2. Routes : vêtements

### `GET /v1/items`
Du plus récent au plus ancien (tri **inchangé**). Réponse : `200 {"items":[…],"limit":50,"offset":0}`.

| Paramètre (query) | Type | Défaut | Contraintes |
|---|---|---|---|
| `limit` | entier | 50 | 1 à 100 |
| `offset` | entier | 0 | 0 à 10 000 |
| `category` | liste | — | une ou plusieurs valeurs de l'enum séparées par des virgules : `?category=tee,jeans` |
| `status` | liste | — | idem : `?status=listed,sold` |
| `style` | liste | — | idem : `?style=chic,fashion` |
| `neverWornSince` | date | — | date (`2026-06-01`, minuit UTC) ou date-heure ISO. Garde les pièces dont **le dernier port, ou à défaut la date de création,** est **antérieur** à cette date |

Les filtres se combinent par **ET** ; plusieurs valeurs d'un même filtre par **OU**. Tout autre paramètre, ou une valeur
hors enum (ex. `?category=hat`, `?category=`), → `400 validation_error`.

### `POST /v1/items`
Corps (strict : tout autre champ → `400`) :

| Champ | Obligatoire | Défaut |
|---|---|---|
| `name`, `category` | oui | |
| `color` | non | `null` |
| `style` | non | `casual` |
| `warmth` | non | `2` |
| `waterproof` | non | `false` |
| `status` | non | `active` |
| `estimatedPrice` | non | `null` (accepte `null`) |

`201` : l'objet vêtement. `id`, `number`, `createdAt`, `imageUrl`… ne se fournissent **pas** (`400`).

### `GET /v1/items/{id}`
`200` objet vêtement ; `404` inexistant ou à un autre ; `400` si l'id n'est pas un UUID.

### `PATCH /v1/items/{id}`  (nouveau)
Corps **partiel** : mêmes champs et mêmes règles que `POST`, **au moins un** champ. `id`, `number`, `createdAt`, les
URLs et les compteurs ne sont pas modifiables (champ inconnu → `400`).
`color` et `estimatedPrice` acceptent `null` pour être effacés. Les champs absents ne changent pas.
`200` : l'objet complet à jour. `400` corps vide ou invalide. `404` inexistant ou à un autre utilisateur.
`status` se change ici (ex. `{"status":"sold"}`).

### `DELETE /v1/items/{id}`
`204`. Supprime aussi les photos chez Bunny, l'historique de ports, et traite les tenues (voir §5).
`404` si introuvable (à traiter comme un succès côté UI). `502 storage_unavailable` si Bunny est indisponible :
**la pièce n'est alors pas supprimée**, réessaie plus tard.

---

## 3. Routes : photos

Images **privées** : on ne les récupère que via `imageUrl` / `thumbUrl` (URLs signées renvoyées dans l'objet vêtement).

### `POST /v1/items/{id}/image`  (nouveau)
`multipart/form-data` avec **exactement deux fichiers** : `image` (JPEG, ≤ 1200 px de côté) et `thumb` (JPEG, ≤ 400 px).
Aucun autre champ (texte ou fichier) n'est accepté.

- Contrôle du **contenu réel** (octets) : JPEG ou WebP, quel que soit le `Content-Type` déclaré → sinon `415`.
- **5 Mo maximum par fichier** → sinon `413`.
- Les dimensions ne sont **pas** vérifiées par le serveur : redimensionne côté app.
- **30 envois par heure et par utilisateur** → sinon `429` (avec `Retry-After`). Un envoi compte même s'il échoue ensuite.
- Un nouvel envoi **remplace** les photos de la pièce.
- `200` : l'objet vêtement complet (avec `imageUrl` / `thumbUrl` signées).
- `404` pièce inexistante ou à un autre ; `400` fichier manquant/en double/inattendu ; `502 storage_unavailable` si
  Bunny est indisponible (**rien n'est modifié**, réessaie).

```dart
Future<Map<String, dynamic>> uploadImage(String itemId, Uint8List image, Uint8List thumb) async {
  final token = await FirebaseAuth.instance.currentUser!.getIdToken();
  final req = http.MultipartRequest('POST', Uri.parse('$baseUrl/v1/items/$itemId/image'))
    ..headers['Authorization'] = 'Bearer $token' // PAS de Content-Type à la main : il est fixé par MultipartRequest
    ..files.add(http.MultipartFile.fromBytes('image', image, filename: 'image.jpg', contentType: MediaType('image', 'jpeg')))
    ..files.add(http.MultipartFile.fromBytes('thumb', thumb, filename: 'thumb.jpg', contentType: MediaType('image', 'jpeg')));
  final r = await http.Response.fromStream(await req.send());
  if (r.statusCode != 200) throw ApiException.from(r);
  return jsonDecode(r.body) as Map<String, dynamic>;
}
```

### `DELETE /v1/items/{id}/image`  (nouveau)
`204`, **idempotent** (204 aussi s'il n'y avait pas de photo). `404` si la pièce n'existe pas / est à un autre.
`502 storage_unavailable` si Bunny est indisponible (la photo reste ; réessaie).

---

## 4. Routes : portés

### `POST /v1/items/{id}/wear`  (nouveau)
Corps optionnel : `{ "wornAt": "2026-11-07T08:00:00.000Z" }` (ISO UTC avec `Z` ou décalage ; **pas dans le futur**,
tolérance de 5 minutes pour l'horloge du téléphone ; pas avant 2000). Sans `wornAt` : maintenant. Corps absent, vide ou `{}` accepté.
`201 {"id":"<uuid>","itemId":"<uuid>","wornAt":"2026-11-07T08:00:00.000Z"}`.
`400` date invalide ou future ; `404` pièce inexistante ou à un autre.
Chaque appel ajoute une entrée : `wearCount` augmente de 1, `lastWornAt` est le port le plus récent.

---

## 5. Routes : tenues (outfits)

### `POST /v1/outfits`  (nouveau)
```json
{
  "topId": "<uuid>",
  "layerId": "<uuid> ou null ou absent",
  "bottomId": "<uuid>",
  "weatherSnapshot": { "temperature": 18.5, "feelsLike": 16, "rainProbability": 40, "unit": "C" },
  "wornAt": "2026-11-07T08:00:00.000Z"
}
```
- `weatherSnapshot` strict : `temperature` et `feelsLike` nombres (-100 à 150), `rainProbability` nombre 0 à 100, `unit` `"C"` ou `"F"` ; aucun autre champ.
- `wornAt` optionnel (mêmes règles que pour `/wear`). **S'il est fourni**, une entrée de port est créée pour chaque pièce
  (haut, couche, bas), **dans la même transaction** : tout ou rien.
- Une pièce inexistante **ou à un autre utilisateur** → `404 not_found` (rien n'est créé). Corps invalide → `400`.
- `201` :
```json
{ "id": "<uuid>", "topId": "<uuid>", "layerId": null, "bottomId": "<uuid>", "wornAt": null,
  "weatherSnapshot": { "temperature": 18.5, "feelsLike": 16, "rainProbability": 40, "unit": "C" },
  "createdAt": "2026-11-07T13:31:20.123Z" }
```

### `GET /v1/outfits?limit&offset`  (nouveau)
Mêmes bornes que les vêtements (limit 1..100 défaut 50, offset 0..10 000), **du plus récent au plus ancien**.
`200 {"outfits":[…],"limit":50,"offset":0}`.

**Suppression d'une pièce utilisée par des tenues** (choix le plus simple, voir « Choix de conception ») :
- si c'est le **haut** ou le **bas** → la tenue est **supprimée** ;
- si c'est la **couche** (`layerId`) → la tenue est **conservée**, avec `layerId: null`.

---

## 6. Routes : compte et profil

### `GET /v1/me/profile`  (nouveau)
`200 {"displayName":null,"city":null,"preferredStyle":"casual","tempUnit":"C"}`. Le profil par défaut est créé à la demande.

### `PATCH /v1/me/profile`  (nouveau)
Corps partiel, au moins un champ, champs inconnus refusés :

| Champ | Contraintes |
|---|---|
| `displayName` | string 1 à 50 car. (espaces autour retirés) ou `null` pour effacer |
| `city` | string 1 à 100 car. ou `null` |
| `preferredStyle` | `casual` (défaut) `chic` `fashion` |
| `tempUnit` | `"C"` (défaut) ou `"F"` |

`200` : le profil complet à jour.

### `GET /v1/me/export`  (nouveau)
`200` :
```json
{
  "exportedAt": "2026-11-07T13:31:20.123Z",
  "uid": "<uid>",
  "profile": { "displayName": null, "city": null, "preferredStyle": "casual", "tempUnit": "C" },
  "items": [ { "id": "…", "number": 1, "name": "…", "category": "…", "color": null, "style": "casual", "warmth": 2,
               "waterproof": false, "status": "active", "estimatedPrice": null, "wearCount": 0, "lastWornAt": null,
               "createdAt": "…" } ],
  "wearLogs": [ { "id": "…", "itemId": "…", "wornAt": "…" } ],
  "outfits": [ { "id": "…", "topId": "…", "layerId": null, "bottomId": "…", "wornAt": null, "weatherSnapshot": {…}, "createdAt": "…" } ]
}
```
**Aucune URL** (ni signée ni autre) et aucun chemin interne : les photos elles-mêmes ne sont pas incluses.
Si l'utilisateur n'a jamais rempli son profil, `profile` contient les valeurs par défaut (sans créer de profil).
**5 appels par heure et par utilisateur** → sinon `429` (`Retry-After`).

### `DELETE /v1/me`  (nouveau) : suppression définitive du compte
Exigence App Store / Google Play. Supprime **toutes** les données : vêtements, portés, tenues, profil, photos Bunny
(dossier `users/{uid}/`), puis le **compte Firebase Authentication** (en dernier).

- **Connexion récente exigée** : si la dernière authentification date de plus de 5 minutes →
  `401 {"error":"recent_login_required"}` et **rien n'est supprimé**. L'app doit demander à l'utilisateur de se
  reconnecter (`reauthenticateWithCredential`), puis `getIdToken(true)` et **rejouer** la requête.
- `204` (sans corps) en cas de succès. **Idempotent et reprenable** : l'ordre est photos → base → compte Firebase ;
  en cas de `502` (`storage_unavailable` ou `auth_unavailable`), **rejoue simplement la même requête** : chaque étape
  reprend où elle s'était arrêtée. Un `DELETE` rejoué après succès répond `204`.
- Après `204`, le token (encore valable jusqu'à 1 h) ne fonctionne plus pour rien d'autre : `401 unauthorized`.
  Déconnecte l'utilisateur localement (`FirebaseAuth.instance.signOut()`) et efface le cache local.
- Un compte sans aucune donnée peut aussi être supprimé.

```dart
Future<void> deleteAccount() async {
  final user = FirebaseAuth.instance.currentUser!;
  Future<http.Response> call() async => http.delete(Uri.parse('$baseUrl/v1/me'),
      headers: {'Authorization': 'Bearer ${await user.getIdToken(true)}'});
  var r = await call();
  if (r.statusCode == 401 && ApiException.from(r).code == 'recent_login_required') {
    await user.reauthenticateWithCredential(/* identifiants fraîchement saisis (Apple, Google, mot de passe…) */);
    r = await call();
  }
  if (r.statusCode != 204) throw ApiException.from(r); // 502 : proposer « Réessayer »
  await FirebaseAuth.instance.signOut();
}
```

---

## 7. Photos privées : URLs signées

- `imageUrl` / `thumbUrl` pointent vers un CDN (Bunny) **protégé par jeton** : sans le jeton, l'image est inaccessible.
- Validité : **au moins 24 h** (arrondie à l'heure supérieure : jusqu'à 25 h). L'URL d'une même image **reste
  identique pendant une heure**, donc le cache d'images (`cached_network_image`) fonctionne. Comme l'URL change
  d'une heure à l'autre, passe une clé de cache stable (par exemple l'`id` de la pièce + `thumb`/`image`) pour ne pas
  retélécharger la même photo.
- Ne **stocke pas** les URLs durablement : redemande l'objet vêtement (`GET /v1/items`) pour obtenir des URLs fraîches.
- Si le chargement d'une image échoue en `403`, l'URL a expiré : rafraîchis la liste.
- `null` : la pièce n'a pas de photo (ou le stockage n'est pas configuré côté serveur).

---

## 8. Erreurs

Corps JSON, toujours un champ `error` (code stable) :

| HTTP | `error` | Quand | Que faire dans l'app |
|---|---|---|---|
| 400 | `validation_error` | données invalides ; `details: [{path, message}]` | corriger/afficher le champ `path` |
| 400 | `bad_request` | requête mal formée (JSON illisible…) | bug client |
| 401 | `unauthorized` | token absent, invalide, expiré ; **compte supprimé** | `getIdToken(true)`, réessayer une fois, sinon reconnecter |
| 401 | **`recent_login_required`** *(nouveau)* | `DELETE /v1/me` avec une connexion de plus de 5 min | demander une reconnexion, rejouer |
| 404 | `not_found` | ressource inconnue **ou d'un autre utilisateur**, route inconnue | traiter comme absent |
| 413 | `payload_too_large` | corps JSON > 100 Ko ; fichier photo > 5 Mo | réduire l'image |
| 415 | `unsupported_media_type` | `Content-Type` non géré ; photo qui n'est ni JPEG ni WebP | envoyer du JPEG |
| 429 | `rate_limited` | trop de requêtes ; `retryAfterSeconds` + en-tête `Retry-After` | attendre ce délai |
| 500 | `internal_error` | erreur serveur ; `requestId` | message générique, réessai avec délai croissant |
| 502 | **`storage_unavailable`** *(nouveau)* | Bunny (photos) indisponible : envoi/suppression de photo, suppression d'une pièce avec photo, `DELETE /v1/me` | rien n'a été modifié : proposer « Réessayer » |
| 502 | **`auth_unavailable`** *(nouveau)* | `DELETE /v1/me` : suppression du compte Firebase impossible (les données sont déjà effacées) | rejouer la même requête |
| 503 | (sur `/health`) | base indisponible | — |

Aucune réponse 4xx ne contient de détail interne (pas de SQL, chemin, clé, trace).

## 9. Limites de débit

| Limite | Valeur | Réponse |
|---|---|---|
| Par IP (toutes les routes) | 100 requêtes / 60 s | `429` |
| Par utilisateur (toutes les routes `/v1/*`) | 300 requêtes / 60 s | `429` |
| Envois de photo | **30 / heure / utilisateur** | `429` |
| Export des données | **5 / heure / utilisateur** | `429` |

Les compteurs sont en mémoire : ils repartent de zéro quand le serveur redémarre.

## 10. Choix de conception (à connaître)

1. **Catégories** : les 7 valeurs v1 sont conservées et 11 s'ajoutent (`tee`, `shirt`, `sweater`, `turtleneck`, `jacket`,
   `jeans`, `chino`, `jogger`, `cargo`, `hoodie`, `sweatshirt`). Les anciennes pièces ne sont pas reclassées ; il n'y a pas de défaut (champ obligatoire à la création, comme en v1).
2. **`number`** : compteur par utilisateur, verrouillé dans la transaction d'insertion (pas de `MAX()+1`), donc sûr en concurrence.
3. **`color`** : reste une chaîne libre 1 à 30 caractères ; `#RRGGBB` y tient, mais le serveur ne vérifie pas que c'est une couleur.
4. **PATCH** : `color` et `estimatedPrice` peuvent être remis à `null` ; `name`, `category`, `style`, `warmth`, `waterproof`, `status` non.
5. **Date de port** : « pas dans le futur » avec 5 minutes de tolérance (horloge du téléphone) ; antérieure à 2000 refusée.
6. **Tenues** : suppression du haut/bas → tenue supprimée ; suppression de la couche → `layerId: null`.
7. **Photos** : le serveur ne vérifie pas les dimensions en pixels ni que le fichier est décodable (seulement l'en-tête JPEG/WebP et 5 Mo) ;
   le chemin `users/{uid}/items/{itemId}.jpg` ne sort jamais de l'API ; si Bunny n'est pas configuré côté serveur, les routes d'envoi répondent `502`.
8. **Suppression de compte** : après `204`, le serveur garde en mémoire (2 h) que le compte est supprimé pour refuser son token. Si le
   serveur redémarre dans l'heure, le token (valable 1 h) pourrait être accepté de nouveau, mais le compte Firebase n'existe plus, donc
   aucun nouveau token ne peut être obtenu. Pour fermer complètement cette fenêtre : `FIREBASE_CHECK_REVOKED=true` (un appel réseau par requête).
9. **Export** : ne contient pas les photos elles-mêmes (uniquement les métadonnées) ; pas d'URL.

## 11. Ce que la v2 ne fait pas (à demander si besoin)

Favoris, tags, recherche texte, marque/saison/matière, redimensionnement serveur des photos, modification/suppression
d'une tenue, suppression d'une entrée de port (annuler un « porté aujourd'hui »), notifications.

## Historique

| Version | Statut |
|---|---|
| v1 | en production |
| v2 | en production (7 novembre 2026) |
| v2.1 | ajout des catégories `hoodie` et `sweatshirt` (aucun autre changement) : **développée, pas encore déployée** |
