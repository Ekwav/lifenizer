import 'dart:async';

import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/pages/search/search_results_list.dart';
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

Future<void> _open(WidgetTester tester, _LoadingState state) async {
  await tester.pumpWidget(
    MaterialApp(
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
