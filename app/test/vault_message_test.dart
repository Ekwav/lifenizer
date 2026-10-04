import 'package:app/app_state.dart';
import 'package:app/widgets/vault_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _State extends LifenizerAppState {
  void changed() => notifyListeners();
}

void main() {
  testWidgets('status expires after eight seconds while errors stay visible', (
    tester,
  ) async {
    final state = _State()..status = 'Search saved and encrypted';
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: state,
          builder: (_, _) => VaultShell(state: state),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 4));
    state.changed();
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(find.text(state.status!), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text(state.status!), findsNothing);

    state.syncError = 'Saved locally; sync will retry';
    state.changed();
    await tester.pump();
    await tester.pump(const Duration(seconds: 20));
    expect(find.text(state.syncError!), findsOneWidget);
    await tester.tap(find.byTooltip('Dismiss message'));
    await tester.pumpAndSettle();
    expect(find.text(state.syncError!), findsNothing);

    state.syncError = null;
    state.status = 'Conversation encrypted and synced';
    state.changed();
    await tester.pump();
    expect(find.text(state.status!), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 9));
    expect(tester.takeException(), isNull);
  });

  for (final error in [false, true]) {
    testWidgets(
      '${error ? 'Error' : 'Status'} banner stays dismissed during updates',
      (tester) async {
        final state = _State();
        if (error) {
          state.syncError = 'Saved locally; sync will retry';
        } else {
          state.status = 'Conversation encrypted and synced';
        }
        final initial = (state.syncError ?? state.status)!;
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          state.dispose();
        });
        await tester.pumpWidget(
          MaterialApp(
            home: AnimatedBuilder(
              animation: state,
              builder: (_, _) => VaultShell(state: state),
            ),
          ),
        );
        expect(find.text(initial), findsOneWidget);
        await tester.tap(find.byTooltip('Dismiss message'));
        await tester.pumpAndSettle();
        expect(find.text(initial), findsNothing);
        expect(state.syncError ?? state.status, initial);

        state.busy = true;
        state.changed();
        await tester.pump();
        expect(find.byTooltip('Dismiss message'), findsNothing);

        state.busy = false;
        if (error) {
          state.syncError = 'Connection failed; sync will retry';
        } else {
          state.status = 'Search saved and encrypted';
        }
        state.changed();
        await tester.pump();
        expect(find.byTooltip('Dismiss message'), findsOneWidget);
        expect(find.text(state.syncError ?? state.status!), findsOneWidget);
      },
    );
  }
}
