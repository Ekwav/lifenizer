import 'package:app/app_state.dart';
import 'package:app/services/pairing_store.dart';
import 'package:app/widgets/device_security_dialog.dart';
import 'package:app/widgets/vault_shell.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Keyring extends PairingCredentialStore {
  _Keyring(this.mode);
  final String mode;

  @override
  Future<Map<String, dynamic>?> read() async => {
    'server': 'https://example.test',
    'email': 'paired@example.test',
    'until': 1,
    if (mode != 'system') 'protection': mode,
  };
}

void main() {
  for (final mode in ['system', 'password']) {
    testWidgets('$mode lock explains only the current unprotected pairing', (
      tester,
    ) async {
      final state = LifenizerAppState(pairingStore: _Keyring(mode))
        ..apiBaseUrl = 'https://example.test'
        ..rememberedEmail = 'paired@example.test';
      await state.pairing.restore(autoUnlock: false);
      try {
        await tester.pumpWidget(MaterialApp(home: VaultShell(state: state)));
        await tester.tap(find.byTooltip('Lock vault'));
        await tester.pumpAndSettle();
        if (mode == 'system') {
          expect(
            find.textContaining('without an app password'),
            findsOneWidget,
          );
          expect(state.status, isNull);
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
          expect(state.status, isNull);
          await tester.tap(find.byTooltip('Lock vault'));
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(FilledButton, 'Lock vault'));
          await tester.pumpAndSettle();
          expect(state.status, 'Vault locked');
          expect(find.byType(AlertDialog), findsNothing);
          state.rememberedEmail = 'other@example.test';
          state.status = null;
          await tester.tap(find.byTooltip('Lock vault'));
          await tester.pumpAndSettle();
          expect(state.status, 'Vault locked');
          expect(find.byType(AlertDialog), findsNothing);
        } else {
          expect(state.status, 'Vault locked');
          expect(find.byType(AlertDialog), findsNothing);
        }
      } finally {
        await tester.pumpWidget(const SizedBox());
        state.dispose();
      }
    });
  }

  testWidgets(
    'desktop security requires a matching twelve-character password',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        final state = LifenizerAppState();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          state.dispose();
        });
        await tester.pumpWidget(
          MaterialApp(home: DeviceSecurityDialog(state: state)),
        );
        expect(
          tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isFalse,
        );
        await tester.tap(find.byType(SwitchListTile));
        await tester.pump();
        final fields = find.byType(TextField);
        await tester.enterText(fields.at(0), 'too-short');
        await tester.enterText(fields.at(1), 'too-short');
        await tester.tap(find.text('Save'));
        await tester.pump();
        expect(find.textContaining('at least 12 characters'), findsOneWidget);
        await tester.enterText(fields.at(0), 'long-device-password');
        await tester.enterText(fields.at(1), 'different-password');
        await tester.tap(find.text('Save'));
        await tester.pump();
        expect(find.text('The device passwords do not match.'), findsOneWidget);
        expect(state.pairing.higherSecurity, isFalse);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('Android extra authentication stays off until explicitly saved', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final state = LifenizerAppState();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        state.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDeviceSecurityDialog(context, state),
              child: const Text('Security'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Security'));
      await tester.pumpAndSettle();
      expect(find.text('Fingerprint or phone PIN'), findsOneWidget);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );
      await tester.tap(find.byType(SwitchListTile));
      await tester.pump();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(state.pairing.higherSecurity, isFalse);
      expect(find.byType(DeviceSecurityDialog), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    'device password prompt can cancel or submit without retaining input',
    (tester) async {
      final results = <String?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  results.add(await requestDevicePassword(context)),
              child: const Text('Open unlock'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open unlock'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'never-submit-this');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(results, [null]);
      await tester.tap(find.text('Open unlock'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      await tester.enterText(find.byType(TextField), 'device-unlock-password');
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(results, [null, 'device-unlock-password']);
      expect(find.byType(TextField), findsNothing);
    },
  );
}
