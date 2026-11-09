import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:app/app_state.dart';
import 'package:app/main.dart';

void main() {
  testWidgets('shows the vault login screen', (WidgetTester tester) async {
    await tester.pumpWidget(LifenizerApp(state: LifenizerAppState()));

    expect(find.text('Lifenizer'), findsOneWidget);
    expect(find.text('Connect this device'), findsOneWidget);
    expect(find.text('Enter vault'), findsNothing);
  });
  testWidgets(
    'invitation field is obscured and visible only when creating an account',
    (tester) async {
      await tester.pumpWidget(LifenizerApp(state: LifenizerAppState()));
      await tester.tap(find.text('Use email and passwords'));
      await tester.pumpAndSettle();
      Finder invitation() => find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'Invitation code (if required)',
      );
      expect(invitation(), findsNothing);
      await tester.ensureVisible(find.text('Create an account'));
      await tester.tap(find.text('Create an account'));
      await tester.pumpAndSettle();
      expect(invitation(), findsOneWidget);
      expect(tester.widget<TextField>(invitation()).obscureText, isTrue);
      await tester.ensureVisible(find.text('Use an existing account'));
      await tester.tap(find.text('Use an existing account'));
      await tester.pumpAndSettle();
      expect(invitation(), findsNothing);
    },
  );
}
