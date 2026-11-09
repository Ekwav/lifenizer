import 'dart:async';

import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/pages/page_frame.dart';
import 'package:app/pages/search/search_results_list.dart';
import 'package:app/pages/search_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _State extends LifenizerAppState {
  final requests = <Completer<Conversation>>[];
  bool unlocked = false;
  @override
  bool get isAuthenticated => unlocked;
  void lockForTest() {
    unlocked = false;
    notifyListeners();
  }

  @override
  Future<Conversation> loadConversation(String id) {
    final request = Completer<Conversation>();
    requests.add(request);
    return request.future;
  }
}

Conversation _conversation(int index, {bool loaded = true}) => Conversation(
  id: 'thread-$index',
  title: 'Thread $index',
  source: 'signal',
  participantIds: [],
  isLoaded: loaded,
  previewText: 'Cached summary $index',
  segments: loaded
      ? [ConversationSegment(id: 'message', text: 'Message $index')]
      : [],
);

Future<void> _openDetail(
  WidgetTester tester,
  _State state, {
  Conversation? conversation,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => openConversationDetail(
              context,
              state,
              conversation ?? _conversation(1, loaded: false),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  testWidgets(
    'hundreds of results build only viewport cards and remain scrollable',
    (tester) async {
      final state = _State();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PageFrame.slivers(
              title: 'Search',
              slivers: [
                SearchResultsList(
                  results: List.generate(250, _conversation),
                  state: state,
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.byType(ConversationCard).evaluate().length, lessThan(12));
      expect(find.text('Thread 80'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('Thread 80'),
        600,
        maxScrolls: 50,
      );
      expect(find.text('Thread 80'), findsOneWidget);
      expect(find.byType(ConversationCard).evaluate().length, lessThan(12));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'search page preserves pagination and filters with lazy results',
    (tester) async {
      final state = _State();
      addTearDown(state.dispose);
      state.conversations.addAll(List.generate(250, _conversation));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SearchPage(state: state)),
        ),
      );
      await tester.pump();
      expect(find.text('Showing first 50 results'), findsOneWidget);
      expect(find.byType(ConversationCard).evaluate().length, lessThan(12));
      final scrollable = find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('Show more conversations'),
        600,
        maxScrolls: 50,
        scrollable: scrollable,
      );
      await tester.tap(find.text('Show more conversations'));
      await tester.pump();
      expect(
        tester
            .widget<SearchResultsList>(find.byType(SearchResultsList))
            .results,
        hasLength(100),
      );
      expect(find.byType(ConversationCard).evaluate().length, lessThan(12));
      await tester.scrollUntilVisible(
        find.byType(TextField),
        -600,
        maxScrolls: 50,
        scrollable: scrollable,
      );
      await tester.enterText(find.byType(TextField).first, 'Thread 249');
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(ConversationCard),
          matching: find.text('Thread 249'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('detail paints cached summary before hydrating after entrance', (
    tester,
  ) async {
    final state = _State();
    addTearDown(state.dispose);
    await _openDetail(tester, state);
    expect(find.text('Thread 1'), findsOneWidget);
    expect(find.text('Cached summary 1'), findsOneWidget);
    expect(state.requests, isEmpty);
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.requests, hasLength(1));
    state.requests.single.complete(_conversation(1));
    await tester.pumpAndSettle();
    expect(find.text('Message 1'), findsOneWidget);
    expect(find.text('Cached summary 1'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('closing during entrance avoids loading the unopened body', (
    tester,
  ) async {
    final state = _State();
    addTearDown(state.dispose);
    await _openDetail(tester, state);
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(state.requests, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cached audio actions are ready on the entrance frame', (
    tester,
  ) async {
    final state = _State();
    addTearDown(state.dispose);
    final recording = Conversation(
      id: 'audio',
      title: 'Recording',
      source: 'audio',
      participantIds: [],
      segments: [],
      isLoaded: false,
    );
    await _openDetail(tester, state, conversation: recording);
    expect(find.byTooltip('Play recording'), findsOneWidget);
    expect(find.text('Edit people and location'), findsOneWidget);
    expect(state.requests, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('locking during entrance cancels deferred hydration', (
    tester,
  ) async {
    final state = _State()..unlocked = true;
    addTearDown(state.dispose);
    await _openDetail(tester, state);
    state.lockForTest();
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.requests, isEmpty);
    expect(find.text('Thread 1'), findsNothing);
    expect(find.text('Cached summary 1'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
