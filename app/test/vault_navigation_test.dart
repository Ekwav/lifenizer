import 'package:app/app_state.dart';
import 'package:app/widgets/vault_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'phone navigation offers four primary pages and a complete More drawer',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = LifenizerAppState()
        ..busy = true
        ..syncError = 'Saved locally; sync will retry';
      await tester.pumpWidget(MaterialApp(home: VaultShell(state: state)));
      await tester.pump();
      final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(nav.destinations, hasLength(5));
      expect(find.text('Saved locally; sync will retry'), findsOneWidget);
      final lock = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == 'Lock vault',
        ),
      );
      expect(lock.onPressed, isNull);
      state.busy = false;
      await tester.pumpWidget(MaterialApp(home: VaultShell(state: state)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      expect(find.byType(ListTile), findsNWidgets(8));
      await tester.tap(find.widgetWithText(ListTile, 'People'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        4,
      );
      expect(find.byType(Drawer), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );
}
