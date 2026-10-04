import 'dart:convert';

import 'package:app/app_state.dart';
import 'package:app/pages/sync_page.dart';
import 'package:app/services/pairing_crypto.dart';
import 'package:app/services/pairing_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

const _server = 'https://example.test/lifenizer';
const _email = 'paired@example.test';
final _secret = List<int>.generate(32, (index) => index + 1);

class _Keyring extends PairingCredentialStore {
  _Keyring(this.until);
  final DateTime until;

  @override
  Future<Map<String, dynamic>?> read() async => {
    'server': _server,
    'email': _email,
    'secret': base64UrlEncode(_secret),
    'until': until.millisecondsSinceEpoch ~/ 1000,
  };
}

class _State extends LifenizerAppState {
  _State(PairingCredentialStore store) : super(pairingStore: store);
  bool unlocked = true;

  @override
  bool get isAuthenticated => unlocked;

  void changed() => notifyListeners();
}

Future<_State> _state({bool automatic = false}) async {
  final state =
      _State(
          _Keyring(
            DateTime.now().toUtc().add(Duration(hours: automatic ? 1 : -1)),
          ),
        )
        ..apiBaseUrl = _server
        ..rememberedEmail = _email;
  await state.pairing.restore(autoUnlock: false);
  return state;
}

void main() {
  test(
    'connection link preserves the vault secret and original approval deadline',
    () async {
      final state = await _state();
      addTearDown(state.dispose);
      final link = PairingLink.parse(state.pairing.connectionLink!);
      expect(link.server, _server);
      expect(link.secret, _secret);
      expect(link.until, state.pairing.automaticApprovalUntil);
      expect(state.pairing.automaticApprovalActive, isFalse);

      state.unlocked = false;
      expect(state.pairing.connectionLink, isNull);
      state.unlocked = true;
      state.rememberedEmail = 'other@example.test';
      expect(state.pairing.connectionLink, isNull);
      state.rememberedEmail = _email;
      state.apiBaseUrl = 'https://another.example.test';
      expect(state.pairing.connectionLink, isNull);
      state.apiBaseUrl = _server;
      state.pairing.onLocked();
      expect(state.pairing.connectionLink, isNull);
    },
  );

  testWidgets('Sync reveals a scannable link and copies the same link', (
    tester,
  ) async {
    final state = await _state();
    try {
      await tester.binding.setSurfaceSize(const Size(360, 600));
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SyncPage(state: state)),
        ),
      );
      expect(find.byType(QrImageView), findsNothing);
      await tester.tap(find.text('Add device'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final qr = tester.widget<QrImageView>(find.byType(QrImageView));
      expect(
        find.byWidgetPredicate(
          (widget) => widget is CustomPaint && widget.painter is QrPainter,
        ),
        findsOneWidget,
      );
      expect(qr.semanticsLabel, 'Secure vault connection QR code');
      expect(
        find.textContaining('Compare the verification code'),
        findsOneWidget,
      );
      await tester.tap(find.text('Copy connection link'));
      await tester.pump();
      expect(copied, state.pairing.connectionLink);

      state.unlocked = false;
      state.changed();
      await tester.pump();
      expect(find.byType(QrImageView), findsNothing);
      expect(find.text('Copy connection link'), findsNothing);
      expect(
        find.text('Unlock this vault to show its connection code.'),
        findsOneWidget,
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets('revealed QR disappears after switching accounts', (
    tester,
  ) async {
    final state = await _state(automatic: true);
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SyncPage(state: state)),
        ),
      );
      await tester.tap(find.text('Add device'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Automatic approval is available until'),
        findsOneWidget,
      );
      state.rememberedEmail = 'another@example.test';
      state.changed();
      await tester.pump();
      expect(find.byType(QrImageView), findsNothing);
      expect(find.text('Copy connection link'), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    }
  });
}
