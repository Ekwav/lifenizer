import 'dart:async';

import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/pages/search/search_results_list.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _LoadingState extends LifenizerAppState {
  bool unlocked = true;
  final requests = <Completer<Conversation>>[];

  @override
  bool get isAuthenticated => unlocked;

  @override
  Future<Conversation> loadConversation(String id) {
    final request = Completer<Conversation>();
    requests.add(request);
    return request.future;
  }

  void lockForTest() {
    unlocked = false;
    notifyListeners();
  }
}

Conversation _conversation({bool loaded = false}) => Conversation(
  id: 'thread',
  title: 'Archive thread',
  source: 'signal',
  participantIds: [],
  isLoaded: loaded,
  segmentCount: 1,
  previewText: 'Saved preview',
  segments: loaded
      ? [ConversationSegment(id: 'message', text: 'Decrypted message')]
      : [],
);

Future<void> _open(
  WidgetTester tester,
  _LoadingState state, {
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness, platform: TargetPlatform.linux),
      home: Scaffold(
        body: ConversationCard(state: state, conversation: _conversation()),
      ),
    ),
  );
  expect(find.text('Saved preview'), findsOneWidget);
  expect(state.requests, isEmpty);
  await tester.tap(find.text('Archive thread'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  expect(find.byType(CircularProgressIndicator), findsOneWidget);
  expect(find.text('No transcript.'), findsNothing);
}

void main() {
  testWidgets('conversation body loads on open and failed loads can retry', (
    tester,
  ) async {
    final state = _LoadingState();
    addTearDown(state.dispose);
    await _open(tester, state);
    state.requests.single.completeError(StateError('Failed to read body'));
    await tester.pumpAndSettle();
    expect(find.text('Could not load this conversation.'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(state.requests, hasLength(2));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    state.requests.last.complete(_conversation(loaded: true));
    await tester.pumpAndSettle();
    expect(find.text('Decrypted message'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final brightness in Brightness.values) {
    testWidgets('detail scrollbar stays in its gutter on hover ($brightness)', (
      tester,
    ) async {
      final state = _LoadingState();
      addTearDown(state.dispose);
      await _open(tester, state, brightness: brightness);
      state.requests.single.complete(
        Conversation(
          id: 'thread',
          title: 'Archive thread',
          source: 'signal',
          participantIds: [],
          segments: List.generate(
            50,
            (index) =>
                ConversationSegment(id: '$index', text: 'Message $index'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final viewport = find.byType(CustomScrollView);
      final scrollbar = find.ancestor(
        of: find
            .descendant(of: viewport, matching: find.byType(Scrollable))
            .first,
        matching: find.byType(Scrollbar),
      );
      expect(scrollbar, findsOneWidget);
      expect(
        tester.getRect(scrollbar).right - tester.getRect(viewport).right,
        greaterThanOrEqualTo(16),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer();
      await mouse.moveTo(
        tester.getRect(scrollbar).topRight + const Offset(-3, 40),
      );
      await tester.pumpAndSettle();
      final painter = tester
          .state<RawScrollbarState>(
            find
                .descendant(
                  of: scrollbar,
                  matching: find.byWidgetPredicate(
                    (widget) => widget is RawScrollbar,
                  ),
                )
                .first,
          )
          .scrollbarPainter;
      expect(painter.thickness, 6);
      expect(tester.widget<Scrollbar>(scrollbar).trackVisibility, isFalse);
      expect(tester.takeException(), isNull);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('locking while a body loads hides its late result', (
    tester,
  ) async {
    final state = _LoadingState();
    addTearDown(state.dispose);
    await _open(tester, state);
    state.lockForTest();
    await tester.pump();
    state.requests.single.complete(_conversation(loaded: true));
    await tester.pumpAndSettle();
    expect(find.text('Decrypted message'), findsNothing);
    expect(find.text('Transcript'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
