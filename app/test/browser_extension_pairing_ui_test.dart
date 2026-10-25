import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/services/browser_extension_receiver_service.dart';
import 'package:app/services/document_credentials.dart';
import 'package:app/services/quick_action_service.dart';
import 'package:app/widgets/vault_shell.dart';
import 'package:app/widgets/browser_extension_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

class _Vault extends LifenizerAppState {
  _Vault({super.documentStore});
  @override
  bool get isAuthenticated => true;
}

class _Store extends DocumentCredentialStore {
  @override
  Future<Map<String, dynamic>?> read(String identity, String source) async =>
      null;

  @override
  Future<void> write(
    String identity,
    String source,
    Map<String, dynamic> value,
  ) async {}
}

void main() {
  testWidgets('an external pairing link requires app confirmation', (
    tester,
  ) async {
    final state = _Vault(documentStore: _Store())
      ..session = AuthSession(
        authToken: 't',
        userId: 'u',
        vaultId: 'v',
        vaultSalt: 's',
      );
    addTearDown(state.dispose);
    addTearDown(() => QuickActionService.instance.consume());
    final action = QuickAction.fromUri(
      Uri.parse(
        'lifenizer://connect-extension?code=${List.filled(43, 'a').join()}&port=5076',
      ),
    )!;
    QuickActionService.instance.request(action);
    await tester.pumpWidget(MaterialApp(home: VaultShell(state: state)));
    await tester.pumpAndSettle();
    expect(find.text('Connect browser to this vault?'), findsOneWidget);
    expect(state.browserExtension.enabled, isFalse);
    expect(state.browserExtension.listening, isFalse);
    expect(state.browserExtension.pairingLink, isNull);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Connect browser to this vault?'), findsNothing);
    expect(state.browserExtension.enabled, isFalse);
    expect(state.browserExtension.listening, isFalse);
    expect(state.browserExtension.pairingLink, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('QR pairing hides manual credentials and clears after exchange', (
    tester,
  ) async {
    HttpOverrides.global = null;
    final state = _Vault()
      ..session = AuthSession(
        authToken: 't',
        userId: 'u',
        vaultId: 'v',
        vaultSalt: 's',
      );
    late BrowserExtensionReceiverService service;
    await tester.runAsync(() async {
      service = BrowserExtensionReceiverService(
        state,
        store: _Store(),
        supportedOverride: true,
        defaultPort: 0,
      );
      await service.setEnabled(false);
    });
    addTearDown(state.dispose);
    addTearDown(service.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: BrowserExtensionSection(service: service, signedIn: true),
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('browser-extension-pairing-qr')), findsNothing);
    await tester.runAsync(() async {
      final ready = Completer<void>();
      void changed() {
        if (service.pairingLink != null && !ready.isCompleted) ready.complete();
      }

      service.addListener(changed);
      try {
        await tester.tap(find.byKey(const Key('browser-extension-qr')));
        await ready.future.timeout(const Duration(seconds: 5));
      } finally {
        service.removeListener(changed);
      }
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('browser-extension-port')), findsNothing);
    expect(find.byKey(const Key('browser-extension-token')), findsNothing);
    final qr = tester.widget<QrImageView>(
      find.byKey(const Key('browser-extension-pairing-qr')),
    );
    expect(qr.backgroundColor, Colors.white);
    final link = service.pairingLink!;
    expect(link, isNot(contains(service.token!)));
    await tester.ensureVisible(find.text('Advanced connection settings'));
    await tester.tap(find.text('Advanced connection settings'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('browser-extension-port')), findsOneWidget);
    expect(find.byKey(const Key('browser-extension-token')), findsOneWidget);
    await tester.runAsync(() async {
      final client = HttpClient();
      try {
        final uri = Uri.parse(link);
        final request = await client.postUrl(uri.replace(fragment: ''));
        request.headers
          ..contentType = ContentType.json
          ..set('origin', 'chrome-extension://test');
        request.write(jsonEncode(Uri.splitQueryString(uri.fragment)));
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, 200);
      } finally {
        client.close(force: true);
      }
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('browser-extension-pairing-qr')), findsNothing);
    expect(find.text('Copy connection link'), findsNothing);
  });
}
