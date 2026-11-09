import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/pages/search_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'the "When" control narrows results to a preset range and can be cleared',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day, 10);
      final state = LifenizerAppState();
      state.conversations.addAll([
        Conversation(
          id: 'today-conv',
          title: 'Today chat',
          source: 'manual-text',
          participantIds: const [],
          segments: [ConversationSegment(id: 's1', text: 'todays notes')],
          startedAt: today,
          endedAt: today,
        ),
        Conversation(
          id: 'old-conv',
          title: 'Old chat',
          source: 'manual-text',
          participantIds: const [],
          segments: [ConversationSegment(id: 's2', text: 'old notes')],
          startedAt: DateTime.utc(2020, 1, 1),
          endedAt: DateTime.utc(2020, 1, 1),
        ),
      ]);

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SearchPage(state: state))),
      );
      await tester.pumpAndSettle();

      // No range active yet: both conversations show, control reads "Any time".
      expect(find.text('2 results'), findsOneWidget);
      expect(find.text('Any time'), findsOneWidget);
      expect(find.byKey(const Key('search-when-clear')), findsNothing);

      // Open the When control and pick the "Today" preset.
      await tester.tap(find.byKey(const Key('search-when-filter')));
      await tester.pumpAndSettle();
      expect(find.text('Last 7 days'), findsOneWidget);
      expect(find.text('Custom range…'), findsOneWidget);
      await tester.tap(find.text('Today'));
      await tester.pumpAndSettle();

      // Only the conversation dated today matches; the control shows the
      // active range and a clear button appears.
      expect(find.text('1 result'), findsOneWidget);
      expect(find.text('Today chat'), findsOneWidget);
      expect(find.text('Old chat'), findsNothing);
      expect(find.byKey(const Key('search-when-clear')), findsOneWidget);

      // Clearing the range restores both conversations.
      await tester.tap(find.byKey(const Key('search-when-clear')));
      await tester.pumpAndSettle();

      expect(find.text('2 results'), findsOneWidget);
      expect(find.text('Any time'), findsOneWidget);
    },
  );
}
