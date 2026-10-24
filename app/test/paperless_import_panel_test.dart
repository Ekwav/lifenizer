import 'dart:async';
import 'dart:convert';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/services/document_credentials.dart';
import 'package:app/services/local_vault_store.dart';
import 'package:app/widgets/paperless_import_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sembast/sembast.dart';

class _Database extends Fake implements Database {}

class _VaultStore extends LocalVaultStore {
  _VaultStore() : super(_Database());
  final records = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>?> read(String key) async => records[key];
  @override
  Future<void> write(String key, Map<String, dynamic> value) async {
    records[key] = Map.from(value);
  }
}

class _Credentials extends DocumentCredentialStore {
  @override
  Future<Map<String, dynamic>?> read(String identity, String source) async =>
      null;
  @override
  Future<void> write(
    String identity,
    String source,
    Map<String, dynamic> value,
  ) async {}
  @override
  Future<void> remove(String identity, String source) async {}
}

class _Fixture {
  late final LifenizerAppState state;
  bool closed = false;
  void close() {
    if (!closed) {
      state.dispose();
      closed = true;
    }
  }

  String address = 'https://paperless.example.test/paperless/';
  bool configured = true;
  bool settingsFail = false;
  bool importFail = false;
  Completer<void>? settingsGate;
  int settingsRequests = 0;
  final tokens = <String>[];

  Future<void> open() async {
    final client = MockClient((request) async {
      if (request.url.path.startsWith('/api/auth/')) {
        return http.Response(
          jsonEncode({
            'authToken': 'auth',
            'userId': 'owner',
            'vaultId': 'vault',
            'vaultSalt': 'salt',
          }),
          200,
        );
      }
      if (request.url.path == '/api/imports/capabilities') {
        return http.Response('[]', 200);
      }
      if (request.url.path == '/api/imports/paperless/settings') {
        settingsRequests++;
        await settingsGate?.future;
        return http.Response(
          settingsFail
              ? '{}'
              : jsonEncode({'configured': configured, 'baseUrl': address}),
          settingsFail ? 503 : 200,
        );
      }
      if (request.url.path == '/api/imports/paperless') {
        tokens.add(
          (jsonDecode(request.body) as Map)['metadata']['token'] as String,
        );
        return http.Response(
          importFail
              ? '{"error":"Invalid API token"}'
              : jsonEncode({
                  'source': 'paperless',
                  'conversations': [],
                  'participants': [],
                  'diagnostics': {'hasMore': 'false', 'nextPage': ''},
                }),
          importFail ? 400 : 200,
        );
      }
      return http.Response('{"cursor":0,"envelopes":[]}', 200);
    });
    state = LifenizerAppState(
      localStore: _VaultStore(),
      documentStore: _Credentials(),
      apiFactory: (base) => LifenizerApiClient(baseUrl: base, client: client),
    );
    await state.login(
      baseUrl: 'https://vault.example.test',
      email: 'owner@example.test',
      passphrase: 'a long vault passphrase',
    );
    expect(state.error, isNull);
  }

  Widget get widget => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(child: PaperlessImportPanel(state: state)),
    ),
  );
}

void main() {
  testWidgets(
    'explains tokens and opens the configured installation in an external browser',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(f.close);
      final launches = <MethodCall>[];
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        launches.add(call);
        return true;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(f.widget);
      await tester.pumpAndSettle();
      expect(find.textContaining('access key'), findsOneWidget);
      expect(find.textContaining('My Profile → API token'), findsOneWidget);
      expect(find.textContaining('circular-arrow'), findsOneWidget);
      await tester.tap(find.text('Open Paperless'));
      await tester.pumpAndSettle();
      expect(launches.single.arguments['url'], f.address);
      expect(launches.single.arguments['useWebView'], isFalse);
      expect(launches.single.arguments['useSafariVC'], isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      f.close();
    },
  );

  testWidgets(
    'loading, missing configuration and errors hide token setup and allow retry',
    (tester) async {
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(f.close);
      f.settingsGate = Completer<void>();
      await tester.pumpWidget(f.widget);
      await tester.pump();
      expect(find.text('Loading Paperless setup…'), findsOneWidget);
      expect(find.byKey(const Key('paperless-token')), findsNothing);
      expect(find.text('Open Paperless'), findsNothing);
      f.settingsFail = true;
      f.settingsGate!.complete();
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Check your Lifenizer connection'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('paperless-token')), findsNothing);
      f.settingsFail = false;
      f.configured = false;
      await tester.ensureVisible(find.text('Retry Paperless setup'));
      await tester.tap(find.text('Retry Paperless setup'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Your Lifenizer server has no Paperless address'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Imports__Paperless__BaseUrl'),
        findsOneWidget,
      );
      expect(
        find.textContaining('restart the server, then retry'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('paperless-token')), findsNothing);
      expect(find.text('Connect & import'), findsNothing);
      f.configured = true;
      await tester.tap(find.text('Retry Paperless setup'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('paperless-token')))
            .enabled,
        isTrue,
      );
      expect(f.settingsRequests, 3);
      await tester.pumpWidget(const SizedBox.shrink());
      f.close();
    },
  );

  testWidgets('unsafe configured browser links are not enabled', (
    tester,
  ) async {
    final f = _Fixture();
    await tester.runAsync(f.open);
    addTearDown(f.close);
    for (final address in [
      'https://user:secret@example.test/',
      'https://example.test/?token=secret',
      'javascript:alert(1)',
    ]) {
      f.address = address;
      await tester.pumpWidget(f.widget);
      await tester.pumpAndSettle();
      expect(find.text('Open Paperless'), findsNothing);
      expect(find.byKey(const Key('paperless-token')), findsNothing);
      expect(find.textContaining('secret'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    }
    f.close();
  });

  testWidgets(
    'failed imports retain the token and successful retry shows compact controls',
    (tester) async {
      final f = _Fixture()..importFail = true;
      await tester.runAsync(f.open);
      addTearDown(f.close);
      await tester.pumpWidget(f.widget);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('paperless-token')),
        'private-api-token',
      );
      Future<void> connect() async {
        await tester.ensureVisible(find.text('Connect & import'));
        final action = tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Connect & import'),
            )
            .onPressed!;
        await tester.runAsync(() async {
          await (action as Future<void> Function())();
        });
        await tester.pumpAndSettle();
      }

      await connect();
      expect(f.state.documentImport.connected, isTrue);
      expect(f.state.documentImport.error, isNotNull);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('paperless-token')))
            .controller!
            .text,
        'private-api-token',
      );
      expect(find.text('Check now'), findsNothing);
      f.importFail = false;
      await connect();
      expect(f.tokens, ['private-api-token', 'private-api-token']);
      expect(find.byKey(const Key('paperless-token')), findsNothing);
      expect(find.text('Check now'), findsOneWidget);
      await tester.tap(find.text('Change API token'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('paperless-token')))
            .controller!
            .text,
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      f.close();
    },
  );
}
