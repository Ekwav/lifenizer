import 'package:app/app_state.dart';
import 'package:app/main.dart';
import 'package:app/models.dart';
import 'package:app/services/quick_action_service.dart';
import 'package:dbus/dbus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

class _UnlockedTestVault extends LifenizerAppState {
  @override
  bool get isAuthenticated => true;
  @override
  Future<void> refreshImages({String? conversationId}) async {}
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native KRunner opens an unlocked conversation and shortcuts focus search',
    (tester) async {
      final state = _UnlockedTestVault();
      state.conversations.add(
        Conversation(
          id: 'native-quick-action',
          title: 'Synthetic train plans',
          source: 'manual-text',
          startedAt: DateTime(2026, 10, 3),
          participantIds: [],
          segments: [
            ConversationSegment(
              id: 'segment',
              text: 'Meet Alice at the station',
            ),
          ],
        ),
      );
      await tester.runAsync(() => QuickActionService.instance.start(state));
      await tester.pumpWidget(LifenizerApp(state: state));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final bus = DBusClient.session();
        try {
          final runner = DBusRemoteObject(
            bus,
            name: 'com.lifenizer.Search',
            path: DBusObjectPath('/runner'),
          );
          final result = await runner.callMethod(
            'org.kde.krunner1',
            'Match',
            [const DBusString('life Alice')],
            replySignature: DBusSignature('a(sssida{sv})'),
          );
          final first = result.returnValues.single.asArray().first.asStruct();
          expect(first[1].asString(), 'Synthetic train plans');
          await runner.callMethod('org.kde.krunner1', 'Run', [
            first[0],
            const DBusString(''),
          ]);
        } finally {
          await bus.close();
        }
      });
      await tester.pumpAndSettle();
      expect(find.text('Transcript'), findsOneWidget);
      expect(find.text('Meet Alice at the station'), findsWidgets);
      Navigator.of(tester.element(find.text('Transcript'))).pop();
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      final searchField = tester.widget<TextField>(
        find.byType(TextField).first,
      );
      expect(searchField.focusNode!.hasFocus, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );
}
