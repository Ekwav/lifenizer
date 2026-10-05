import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/pages/imports_page.dart';
import 'package:app/pages/search/search_filters.dart';
import 'package:app/pages/search/search_input_field.dart';
import 'package:app/pages/search/search_results_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Conversation _watched(String source, {Map<String, String>? metadata}) =>
    Conversation(
      id: source,
      title: 'Cat video',
      source: source,
      participantIds: const [],
      metadata: metadata ?? const {},
      segments: [ConversationSegment(id: 's', text: 'Cat video')],
    );

void main() {
  testWidgets('imports page shows camera photos and viewing history panels', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = LifenizerAppState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ImportsPage(state: state)),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('camera-photos-panel')), findsOneWidget);
    expect(find.text('Camera photos'), findsOneWidget);
    expect(find.textContaining('only while Lifenizer is open'), findsOneWidget);
    expect(find.byKey(const Key('camera-auto-import')), findsOneWidget);
    expect(find.byKey(const Key('camera-keep-in-vault')), findsOneWidget);
    expect(find.byKey(const Key('camera-last-week')), findsOneWidget);

    expect(find.byKey(const Key('viewing-history-panel')), findsOneWidget);
    expect(find.text('Viewing history'), findsOneWidget);
    expect(find.textContaining('Google Takeout'), findsOneWidget);
    expect(find.textContaining('Download your data'), findsOneWidget);
    expect(find.byKey(const Key('viewing-history-pick')), findsOneWidget);
    expect(
      find.text('Fetch transcripts for the 25 most recent videos'),
      findsOneWidget,
    );
  });

  testWidgets(
    'watched YouTube cards show badge, channel line and fetch action',
    (tester) async {
      final state = LifenizerAppState();
      addTearDown(state.dispose);
      final video = _watched(
        'youtube-watch-history',
        metadata: {
          'channel': 'Cat Channel',
          'watchCount': '3',
          'transcript': 'none',
        },
      );
      state.conversations.add(video);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ConversationCard(state: state, conversation: video),
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('consumed-badge')), findsOneWidget);
      expect(find.text('YouTube • Cat Channel • watched 3×'), findsOneWidget);
      expect(find.byKey(const Key('fetch-transcript')), findsOneWidget);
    },
  );

  testWidgets(
    'TikTok cards explain the missing transcript; chats get no badge',
    (tester) async {
      final state = LifenizerAppState();
      addTearDown(state.dispose);
      final tiktok = _watched(
        'tiktok-watch-history',
        metadata: {'watchCount': '1'},
      );
      final chat = _watched('whatsapp');
      state.conversations.addAll([tiktok, chat]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  ConversationCard(state: state, conversation: tiktok),
                  ConversationCard(state: state, conversation: chat),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.text('No transcript available for TikTok'), findsOneWidget);
      expect(find.text('TikTok • watched 1×'), findsOneWidget);
      expect(find.byKey(const Key('consumed-badge')), findsOneWidget);
      expect(find.byKey(const Key('fetch-transcript')), findsNothing);
    },
  );

  testWidgets('"Hide consumed media" chip toggles the view model', (
    tester,
  ) async {
    final viewModel = SearchViewModel(
      queryController: TextEditingController(),
      sourceFilter: '',
      participantFilter: '',
      tagFilter: '',
    );
    var changes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SearchFilters(
              viewModel: viewModel,
              availableSources: const [],
              availableParticipants: const [],
              availableTags: const [],
              participantName: (id) => id,
              onFilterChanged: () => changes++,
              onClearFilters: viewModel.clearFilters,
              onSaveSearch: () {},
              isBusy: false,
            ),
          ),
        ),
      ),
    );
    expect(viewModel.hideConsumed, isFalse);
    await tester.tap(find.byKey(const Key('search-hide-consumed')));
    await tester.pump();
    expect(viewModel.hideConsumed, isTrue);
    expect(changes, 1);
    viewModel.clearFilters();
    expect(viewModel.hideConsumed, isFalse);
  });
}
