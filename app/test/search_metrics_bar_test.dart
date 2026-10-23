import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/pages/search/search_metrics_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final (width, columns) in [(479.0, 1), (480.0, 2), (1000.0, 4)]) {
    testWidgets('search metrics adapt to $width available pixels', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = LifenizerAppState();
      addTearDown(state.dispose);
      state.conversations.addAll(
        List.filled(
          12345,
          Conversation(
            id: 'conversation',
            title: 'Example',
            source: 'email',
            participantIds: [],
            segments: [],
          ),
        ),
      );
      state.participants.addAll(
        List.filled(6789, Participant(id: 'person', displayName: 'Example')),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: SearchMetricsBar(state: state),
              ),
            ),
          ),
        ),
      );

      final cards = [
        for (final label in [
          'Conversations',
          'Participants',
          'Relations',
          'Saved',
        ])
          tester.getRect(
            find.ancestor(
              of: find.text(label),
              matching: find.byType(Container),
            ),
          ),
      ];
      expect(cards[columns - 1].right, closeTo(width, 0.01));
      for (var i = 0; i < cards.length; i++) {
        expect(cards[i].width, cards.first.width);
        expect(cards[i].right, lessThanOrEqualTo(width));
        if (i > 0) {
          if (i % columns == 0) {
            expect(cards[i].top, greaterThan(cards[i - 1].bottom));
          } else {
            expect(cards[i].top, cards[i - 1].top);
            expect(cards[i].left - cards[i - 1].right, 12);
          }
        }
      }
      expect(find.text('12345'), findsOneWidget);
      expect(find.text('6789'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
