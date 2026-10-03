import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/pages/search/search_results_list.dart';
import 'package:app/pages/search_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'large search renders fifty results and resets after a new query',
    (tester) async {
      final state = LifenizerAppState();
      state.conversations.addAll(
        List.generate(
          150,
          (index) => Conversation(
            id: '$index',
            title: 'Archive $index',
            source: 'signal',
            startedAt: DateTime(2026, 10, 3),
            participantIds: [],
            segments: [
              ConversationSegment(id: 'segment-$index', text: 'Train plans'),
            ],
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SearchPage(state: state)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ConversationCard), findsNWidgets(50));
      expect(find.text('Showing first 50 results'), findsOneWidget);
      await tester.ensureVisible(find.text('Show more conversations'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show more conversations'));
      await tester.pumpAndSettle();
      expect(find.byType(ConversationCard), findsNWidgets(100));
      await tester.ensureVisible(find.byType(TextField).first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'archive');
      await tester.pumpAndSettle();
      expect(find.byType(ConversationCard), findsNWidgets(50));
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );
}
