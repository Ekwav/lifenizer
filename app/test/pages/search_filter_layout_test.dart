import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/pages/search/search_filters.dart';
import 'package:app/pages/search/search_input_field.dart';
import 'package:app/pages/search/search_results_list.dart';
import 'package:app/pages/search_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final width in [320.0, 390.0, 800.0]) {
    testWidgets('filter pairs stay on one row at $width pixels', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final model = SearchViewModel(
        queryController: TextEditingController(),
        sourceFilter: 'a-source-with-a-long-name',
        participantFilter: 'person',
        tagFilter: 'a tag with a long name',
        fromFilter: DateTime(2025),
        toFilter: DateTime(2026),
      );
      addTearDown(model.queryController.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(20),
              child: SearchFilters(
                viewModel: model,
                availableSources: [model.sourceFilter],
                availableParticipants: const ['person'],
                availableTags: [model.tagFilter],
                participantName: (_) => 'A participant with a very long name',
                onFilterChanged: () {},
                onClearFilters: model.clearFilters,
                onSaveSearch: () {},
                isBusy: false,
              ),
            ),
          ),
        ),
      );
      final source = tester.getRect(
        find.byType(DropdownButtonFormField<String>),
      );
      final when = tester.getRect(find.byKey(const Key('search-when-filter')));
      final participant = tester.getRect(
        find.byKey(const Key('search-participant-filter')),
      );
      final tag = tester.getRect(find.byKey(const Key('search-tag-filter')));
      expect(source.center.dy, closeTo(when.center.dy, 1));
      expect(participant.top, tag.top);
      expect(source.right, lessThan(when.left));
      expect(participant.right, lessThan(tag.left));
      expect(participant.top, greaterThan(source.bottom));
      expect(find.byKey(const Key('search-when-clear')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'participant and tag search select real filters and support cancel and clear',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = LifenizerAppState();
      addTearDown(state.dispose);
      state.participants.addAll([
        Participant(id: 'alice-1', displayName: 'Alice Smith'),
        Participant(id: 'alice-2', displayName: 'Alice Smith'),
        Participant(id: 'bob', displayName: 'Bob Jones'),
      ]);
      state.conversations.addAll([
        for (final (id, person, tag) in [
          ('First Alice', 'alice-1', 'Work'),
          ('Second Alice', 'alice-2', 'Family'),
          ('Bob chat', 'bob', 'Work'),
        ])
          Conversation(
            id: id,
            title: id,
            source: 'manual',
            participantIds: [person],
            tags: [tag],
            segments: [],
          ),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SearchPage(state: state)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('3 results'), findsOneWidget);
      for (final label in ['Conversations', 'Participants', 'Relations', 'Saved']) {
        expect(find.text(label), findsNothing);
      }
      expect(
        tester.getRect(find.byType(ConversationCard).first).bottom,
        lessThanOrEqualTo(844),
      );

      await tester.tap(find.byKey(const Key('search-participant-filter')));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.enterText(
        find.byKey(const Key('search-filter-query')),
        '  ALIce  ',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filter-option-bob')), findsNothing);
      expect(find.byKey(const Key('filter-option-alice-1')), findsOneWidget);
      await tester.tap(find.byKey(const Key('filter-option-alice-2')));
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(find.text('1 result'), findsOneWidget);
      expect(find.text('Second Alice'), findsOneWidget);
      expect(find.text('First Alice'), findsNothing);

      await tester.tap(find.byKey(const Key('search-tag-filter')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('search-filter-query')),
        'fAM',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filter-option-Work')), findsNothing);
      await tester.tap(find.byKey(const Key('filter-option-Family')));
      await tester.pumpAndSettle();
      expect(find.text('1 result'), findsOneWidget);

      await tester.tap(find.byKey(const Key('search-tag-filter')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('search-filter-query')),
        'missing tag',
      );
      await tester.pumpAndSettle();
      expect(find.text('No matches'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('search-tag-filter')),
          matching: find.text('Family'),
        ),
        findsOneWidget,
      );
      expect(find.text('1 result'), findsOneWidget);

      await tester.tap(find.byKey(const Key('search-tag-filter')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: find.byKey(const Key('search-filter-query')),
                matching: find.byType(EditableText),
              ),
            )
            .controller
            .text,
        isEmpty,
      );
      await tester.tap(find.byKey(const Key('filter-option-Work')));
      await tester.pumpAndSettle();
      expect(find.text('Second Alice'), findsNothing);
      expect(
        find.text('No matches. Try a different query or clear the filters.'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('search-participant-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter-option-')));
      await tester.pumpAndSettle();
      expect(find.text('2 results'), findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Clear'));
      await tester.pumpAndSettle();
      expect(find.text('3 results'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
