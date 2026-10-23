import 'package:app/app_state.dart';
import 'package:app/pages/login_page.dart';
import 'package:app/services/pairing_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Store extends PairingCredentialStore {
  _Store(this.mode);
  final String mode;
  int prompts = 0;
  int writes = 0;
  @override
  Future<Map<String, dynamic>?> read() async => {
    'server': 'https://example.test',
    'email': 'linked@example.test',
    'deviceId': 'device',
    'until': 1,
    if (mode != 'system') 'protection': mode,
  };
  @override
  Future<Map<String, dynamic>?> readForUnlock({
    String? password,
    bool authenticate = false,
  }) async {
    expect(authenticate, true);
    prompts++;
    throw PlatformException(code: 'cancelled');
  }

  @override
  Future<void> write(Map<String, dynamic> credentials) async => writes++;
}

void main() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  Future<void> show(WidgetTester tester, LifenizerAppState state) =>
      tester.pumpWidget(
        MaterialApp(
          home: AnimatedBuilder(
            animation: state,
            builder: (context, _) => LoginPage(state: state),
          ),
        ),
      );

  for (final mode in ['system', 'password']) {
    testWidgets('linked $mode device shows unlock without setup fields', (
      tester,
    ) async {
      final state = LifenizerAppState(pairingStore: _Store(mode))
        ..startupUnlockPending = true;
      await state.pairing.restore(autoUnlock: false);
      try {
        await show(tester, state);
        await tester.pumpAndSettle();
        expect(find.text('Unlock this device'), findsOneWidget);
        expect(find.text('Link elsewhere'), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        expect(find.text('Scan connection QR'), findsNothing);
        expect(find.text('Use email and passwords'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox());
        state.dispose();
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets(
    'startup hides connection forms and waits for restored pairing before one OS unlock',
    (tester) async {
      final store = _Store('biometric');
      final state = LifenizerAppState(pairingStore: store)
        ..startupLoading = true
        ..startupUnlockPending = true;
      try {
        await show(tester, state);
        expect(find.text('Search conversations'), findsOneWidget);
        expect(find.text('Connection link'), findsNothing);
        expect(find.text('Connect this device'), findsNothing);
        await state.pairing.restore(autoUnlock: false);
        await tester.pump();
        expect(store.prompts, 0);
        state.startupLoading = false;
        state.reportError('');
        await tester.pumpAndSettle();
        expect(store.prompts, 1);
        expect(find.text('Unlock this device'), findsOneWidget);
        expect(find.text('Connection link'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox());
        state.dispose();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'restored biometric link attempts once, cancellation stays canceled until manual retry',
    (tester) async {
      final store = _Store('biometric');
      final state = LifenizerAppState(pairingStore: store)
        ..startupLoading = true
        ..startupUnlockPending = true;
      try {
        await show(tester, state);
        await state.pairing.restore(autoUnlock: false);
        state.startupLoading = false;
        state.reportError('');
        await tester.pumpAndSettle();
        expect(store.prompts, 1);
        expect(find.text('Unlock this device'), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        state.reportError('A background update');
        await state.pairing.restore(autoUnlock: false);
        await tester.pumpAndSettle();
        expect(store.prompts, 1);
        await tester.tap(find.text('Unlock this device'));
        await tester.pumpAndSettle();
        expect(store.prompts, 2);
        expect(store.writes, 0);
      } finally {
        await tester.pumpWidget(const SizedBox());
        state.dispose();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'link elsewhere reveals setup and cancel preserves the saved link without another prompt',
    (tester) async {
      final store = _Store('biometric');
      final state = LifenizerAppState(pairingStore: store)
        ..startupUnlockPending = true;
      await state.pairing.restore(autoUnlock: false);
      try {
        await show(tester, state);
        await tester.pumpAndSettle();
        expect(store.prompts, 1);
        await tester.tap(find.text('Link elsewhere'));
        await tester.pumpAndSettle();
        expect(find.text('Connection link'), findsOneWidget);
        expect(find.text('Scan connection QR'), findsOneWidget);
        expect(
          find.textContaining('Unlock this device before changing'),
          findsOneWidget,
        );
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.text('Unlock this device'), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        expect(state.pairing.isPaired, true);
        expect(store.prompts, 1);
        expect(store.writes, 0);
      } finally {
        await tester.pumpWidget(const SizedBox());
        state.dispose();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
  testWidgets(
    'manual lock and a recreated login page never reopen OS verification automatically',
    (tester) async {
      final store = _Store('biometric');
      final state = LifenizerAppState(pairingStore: store)
        ..startupUnlockPending = true;
      await state.pairing.restore(autoUnlock: false);
      try {
        await show(tester, state);
        await tester.pumpAndSettle();
        expect(store.prompts, 1);
        expect(state.startupUnlockPending, false);
        await state.lock();
        await tester.pumpWidget(const SizedBox());
        await show(tester, state);
        await tester.pumpAndSettle();
        expect(store.prompts, 1);
        expect(find.text('Unlock this device'), findsOneWidget);
        await tester.tap(find.text('Unlock this device'));
        await tester.pumpAndSettle();
        expect(store.prompts, 2);
      } finally {
        await tester.pumpWidget(const SizedBox());
        state.dispose();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'unpaired startup consumes automatic unlock before a later connection',
    (tester) async {
      final store = _Store('biometric');
      final state = LifenizerAppState(pairingStore: store)
        ..startupUnlockPending = true;
      try {
        await show(tester, state);
        expect(state.startupUnlockPending, false);
        await state.pairing.restore(autoUnlock: false);
        await tester.pumpAndSettle();
        expect(store.prompts, 0);
        expect(find.text('Unlock this device'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox());
        state.dispose();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
