import 'dart:async';

import 'package:app/app_state.dart';
import 'package:app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _ModalVault extends LifenizerAppState {
  bool unlocked = true;
  @override
  bool get isAuthenticated => unlocked;
  void closeVault() {
    unlocked = false;
    notifyListeners();
  }
}

void main() {
  testWidgets(
    'locking discards modal routes containing private vault content',
    (tester) async {
      final state = _ModalVault();
      await tester.pumpWidget(LifenizerApp(state: state));
      await tester.pumpAndSettle();
      final context = tester.element(find.text('Lifenizer'));
      unawaited(
        showDialog<void>(
          context: context,
          builder: (_) => const AlertDialog(
            content: Text('Private transcript in a modal route'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Private transcript in a modal route'), findsOneWidget);
      state.closeVault();
      await tester.pumpAndSettle();
      expect(find.text('Private transcript in a modal route'), findsNothing);
      expect(find.text('Enter vault'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );
}
