import 'dart:convert';

import 'package:app/data/api_client.dart';
import 'package:app/data/app_store.dart';
import 'package:app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// Faux serveur (TEST uniquement) : un superviseur dont le code est PROVISOIRE (réinitialisé par un admin).

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

class _Server {
  final List<String> calls = [];
  bool provisional = true;
  Map<String, dynamic>? changeBody;

  Map<String, dynamic> user() =>
      {'id': 'u1', 'name': 'Chef Test', 'role': 'chief', 'workerId': 'w0', 'mustChangePin': provisional};

  Future<http.Response> handle(http.Request r) async {
    calls.add('${r.method} ${r.url.path}');
    final path = r.url.path;
    if (path == '/api/auth/login') {
      final b = jsonDecode(r.body) as Map<String, dynamic>;
      if (b['pin'] == '483920') return _json({'token': 'jeton-provisoire', 'user': user()});
      return _json({'error': 'Nom ou code incorrect.', 'code': 'unauthorized'}, 401);
    }
    if (path == '/api/auth/pin' && r.method == 'PUT') {
      changeBody = jsonDecode(r.body) as Map<String, dynamic>;
      if (changeBody!['currentPin'] != '483920') return _json({'error': 'Code actuel incorrect.', 'code': 'wrong_pin'}, 422);
      if (changeBody!['newPin'] == '1234') {
        return _json({'error': 'Données invalides.', 'code': 'validation'}, 400);
      }
      provisional = false;
      return _json({'ok': true, 'token': 'jeton-definitif', 'user': user()});
    }
    if (path == '/api/auth/me') return _json({'user': user(), 'teams': []});
    if (path == '/api/auth/logout') return _json({'ok': true});
    // Tant que le code est provisoire, le serveur refuse tout le reste.
    if (provisional) return _json({'error': "Choisissez d'abord votre propre code PIN.", 'code': 'must_change_pin'}, 403);
    return _json({'teamId': 't', 'date': '2026-10-28', 'saved': false, 'locked': false, 'complete': false, 'bricks': null, 'members': [], 'counts': {'present': 0, 'absent': 0, 'unset': 0}});
  }
}

Future<void> _tapKeys(WidgetTester tester, String digits) async {
  for (final d in digits.split('')) {
    await tester.tap(find.text(d).first);
    await tester.pump();
  }
}

void main() {
  testWidgets('code provisoire : écran de changement obligatoire, puis accès avec le nouveau jeton', (tester) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final server = _Server();
    final store = AppStore(ApiClient(baseUrl: 'http://test.local', client: MockClient(server.handle)));
    await tester.pumpWidget(BriquesApp(store: store));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(find.byType(TextField), 'Chef Test');
    await _tapKeys(tester, '483920');
    await tester.tap(find.text('Se connecter'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // L'écran obligatoire remplace toute l'application : aucune autre requête n'est partie (le serveur les refuserait).
    expect(find.text('Choisissez votre code'), findsOneWidget);
    expect(find.textContaining('Votre code est provisoire'), findsOneWidget);
    expect(find.text('Code provisoire reçu'), findsOneWidget);
    expect(server.calls, ['POST /api/auth/login']);
    expect(store.user!.mustChangePin, isTrue);

    // Contrôles locaux : codes différents, 4 à 6 chiffres.
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), '483920');
    await tester.enterText(fields.at(1), '12');
    await tester.enterText(fields.at(2), '13');
    await tester.tap(find.text('Enregistrer et continuer'));
    await tester.pump();
    expect(find.text('Le code doit contenir 4 à 6 chiffres.'), findsOneWidget);
    expect(find.text('Les deux codes ne correspondent pas.'), findsOneWidget);
    expect(server.changeBody, isNull); // rien n'est envoyé tant que le formulaire est faux

    await tester.enterText(fields.at(1), '483920');
    await tester.enterText(fields.at(2), '483920');
    await tester.tap(find.text('Enregistrer et continuer'));
    await tester.pump();
    expect(find.text('Le nouveau code doit être différent.'), findsOneWidget);

    // Code refusé par le serveur (trop simple) : message affiché, on reste sur l'écran.
    await tester.enterText(fields.at(1), '1234');
    await tester.enterText(fields.at(2), '1234');
    await tester.tap(find.text('Enregistrer et continuer'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Choisissez votre code'), findsOneWidget);
    expect(store.user!.mustChangePin, isTrue);

    // Bon nouveau code : l'application prend le nouveau jeton et affiche l'écran du superviseur.
    await tester.enterText(fields.at(1), '580246');
    await tester.enterText(fields.at(2), '580246');
    await tester.tap(find.text('Enregistrer et continuer'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(server.changeBody, {'currentPin': '483920', 'newPin': '580246'});
    expect(store.user!.mustChangePin, isFalse);
    expect(store.api.token, 'jeton-definitif');
    expect(find.text('Choisissez votre code'), findsNothing);
    expect(find.byTooltip('Mon compte'), findsOneWidget);
  });
}
