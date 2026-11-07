# API Tenue : contrat pour l'application Flutter

À donner tel quel à la conversation qui construit l'app. Ce document décrit **uniquement ce qui existe aujourd'hui**
en production. Toute route absente d'ici n'existe pas : elle doit être demandée (voir « Ce qui manque »).

- **URL de base (production)** : `https://api.tenue.ahua.fr`
- **Format** : JSON (`Content-Type: application/json`), UTF-8. Pas de CORS (app mobile uniquement).
- **Authentification** : Firebase Authentication, projet `dressing-assistance`. Toutes les routes `/v1/*` exigent
  `Authorization: Bearer <ID token Firebase>`. `/health` est public.
- **Identité** : l'utilisateur est identifié **uniquement par le token** (uid Firebase). Le client n'envoie jamais
  d'identifiant utilisateur : tout champ inconnu dans un corps de requête est refusé (400). Chaque utilisateur ne voit
  que ses propres données.

## Obtenir le token côté Flutter

Package `firebase_auth` (l'utilisateur doit être connecté). Le token expire au bout d'1 h : redemande-le avant
**chaque** requête, le SDK le met en cache et le renouvelle seul.

```dart
import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

const baseUrl = 'https://api.tenue.ahua.fr';

Future<Map<String, String>> _headers() async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) throw StateError('Utilisateur non connecté');
  final token = await user.getIdToken(); // renouvelé automatiquement si expiré
  return {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'};
}

Future<List<dynamic>> listItems({int limit = 50, int offset = 0}) async {
  final r = await http.get(
    Uri.parse('$baseUrl/v1/items?limit=$limit&offset=$offset'),
    headers: await _headers(),
  );
  if (r.statusCode != 200) throw ApiException.from(r);
  return (jsonDecode(r.body) as Map<String, dynamic>)['items'] as List<dynamic>;
}
```

Conseils : ne jamais journaliser le token ; ne jamais le stocker toi-même (laisse `firebase_auth` le gérer) ;
si une réponse `401` arrive, demande un token neuf avec `getIdToken(true)` et réessaie **une seule fois**, puis
reconnecte l'utilisateur.

## Routes

### `GET /health` (public)
`200 {"status":"ok","db":"ok"}` ou `503 {"status":"degraded","db":"error"}`. Pour diagnostic, pas pour l'UI.

### `GET /v1/me`
Renvoie l'identité vue par le serveur.
`200 {"uid":"<uid firebase>"}`

### `GET /v1/items`
Liste les vêtements de l'utilisateur, du plus récent au plus ancien.

| Paramètre (query) | Type | Défaut | Contraintes |
|---|---|---|---|
| `limit` | entier | 50 | 1 à 100 |
| `offset` | entier | 0 | 0 à 10 000 |

Tout autre paramètre → `400`.

`200` :
```json
{
  "items": [
    {
      "id": "3f1b2c4e-5a6d-4e7f-8a9b-0c1d2e3f4a5b",
      "name": "Chemise bleue",
      "category": "top",
      "color": "bleu",
      "createdAt": "2026-11-07T13:31:20.123Z"
    }
  ],
  "limit": 50,
  "offset": 0
}
```
Pagination : s'il y a `limit` éléments dans `items`, il peut y en avoir d'autres : redemande avec
`offset += limit` jusqu'à recevoir moins de `limit` éléments.

### `POST /v1/items`
Crée un vêtement. Corps :

| Champ | Type | Obligatoire | Contraintes |
|---|---|---|---|
| `name` | string | oui | 1 à 100 caractères (espaces autour retirés) |
| `category` | string | oui | `top`, `bottom`, `outerwear`, `dress`, `shoes`, `accessory`, `other` |
| `color` | string | non | 1 à 30 caractères (espaces autour retirés) |

```json
{ "name": "Chemise bleue", "category": "top", "color": "bleu" }
```
`201` : l'objet créé (même forme qu'un élément de la liste). `color` vaut `null` s'il n'a pas été fourni.
Tout champ inconnu (ex. `userId`, `id`, `createdAt`) → `400`. Corps limité à 100 Ko.

### `GET /v1/items/{id}`
`{id}` : UUID. `200` : un vêtement. `404` si l'id n'existe pas **ou appartient à un autre utilisateur**
(même réponse, volontairement). `400` si l'id n'est pas un UUID.

### `DELETE /v1/items/{id}`
`204` (sans corps) si supprimé. `404` si introuvable ou à un autre utilisateur. Non idempotent côté statut :
une 2e suppression renvoie `404`, à traiter comme un succès côté UI.

## Erreurs

Corps JSON, toujours un champ `error` (code stable, à tester dans le code) :

| HTTP | `error` | Quand | Que faire dans l'app |
|---|---|---|---|
| 400 | `validation_error` | données invalides ; `details: [{path, message}]` | corriger/afficher le champ `path` |
| 400 | `bad_request` | requête mal formée | bug client |
| 401 | `unauthorized` | token absent, invalide ou expiré | `getIdToken(true)`, réessayer une fois, sinon reconnecter |
| 404 | `not_found` | ressource ou route inconnue | traiter comme absent |
| 413 | `payload_too_large` | corps > 100 Ko | bug client |
| 415 | `unsupported_media_type` | `Content-Type` incorrect | envoyer `application/json` |
| 429 | `rate_limited` | trop de requêtes ; `retryAfterSeconds` (et en-tête `Retry-After`) | attendre ce délai, ne pas réessayer en boucle |
| 500 | `internal_error` | erreur serveur ; `requestId` | message générique, réessai avec délai croissant |
| 503 | (sur `/health`) | base indisponible | — |

Exemple `400` :
```json
{ "error": "validation_error", "details": [{ "path": "category", "message": "Invalid option: expected one of \"top\"|\"bottom\"|..." }] }
```
Les messages de `details` sont techniques (anglais) : ne les affiche pas tels quels à l'utilisateur ; sers-toi de `path`.

## Limites de débit

- Par IP : 100 requêtes / 60 s. Par utilisateur : 300 requêtes / 60 s. Au-delà : `429`.
- Évite d'appeler la liste à chaque rebuild d'écran : mets en cache côté app et rafraîchis sur action utilisateur.

## Classe Dart minimale pour les erreurs

```dart
class ApiException implements Exception {
  final int status;
  final String code;       // valeur du champ `error`
  final int? retryAfter;   // secondes, pour 429
  ApiException(this.status, this.code, [this.retryAfter]);

  factory ApiException.from(http.Response r) {
    try {
      final b = jsonDecode(r.body) as Map<String, dynamic>;
      return ApiException(r.statusCode, b['error'] as String? ?? 'unknown', b['retryAfterSeconds'] as int?);
    } catch (_) {
      return ApiException(r.statusCode, 'unknown');
    }
  }
}
```

## Ce qui manque aujourd'hui (à demander avant de coder l'écran correspondant)

L'API est un squelette validé (authentification, isolation par utilisateur, CRUD minimal). **N'existe pas encore** :
- modifier un vêtement (`PATCH`/`PUT`) : aujourd'hui, supprimer puis recréer ;
- photos / images des vêtements (aucun stockage de fichiers) ;
- tenues (associations de vêtements), favoris, tags, recherche, filtre par catégorie ;
- champs supplémentaires sur un vêtement (marque, saison, matière, etc.) ;
- suppression du compte / export des données (utile pour les exigences App Store et Google Play).

Pour chacun, décris le besoin dans cette conversation ; la route et la migration de base sont ajoutées côté API
(dépôt `tenue-api`), déployées avec `scripts/deploy.sh tenue --migrate`, puis ce document est mis à jour.
