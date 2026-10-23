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
  testWidgets(
    'Paperless has its own searchable setup separate from documents',
    (tester) async {
      final state = LifenizerAppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ImportsPage(state: state)),
        ),
      );
      final search = find.byKey(const Key('imports-search'));
      await tester.enterText(search, 'paperless');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('import-adapter-paperless')), findsOneWidget);
      expect(find.byKey(const Key('import-adapter-documents')), findsNothing);
      await tester.tap(find.byKey(const Key('import-adapter-paperless')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('paperless-import-panel')), findsOneWidget);
      expect(find.textContaining('My Profile → API token'), findsOneWidget);
      expect(find.text('Watch scan/PDF folder'), findsNothing);
      await tester.tap(find.byTooltip('Close setup'));
      await tester.pumpAndSettle();
      await tester.enterText(search, 'documents');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('import-adapter-documents')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Import a PDF with the file picker'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('paperless-import-panel')), findsNothing);
      expect(find.text('Paperless API token'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('import catalogue opens only the selected setup panel', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = LifenizerAppState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ImportsPage(state: state)),
      ),
    );
    expect(find.byKey(const Key('imports-auto-file')), findsOneWidget);
    expect(
      find.byKey(const Key('import-adapter-discord-export')),
      findsOneWidget,
    );
    expect(
      find.textContaining('detects the source automatically'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('camera-photos-panel')), findsNothing);
    expect(find.byKey(const Key('viewing-history-panel')), findsNothing);
    expect(find.text('Text or export payload'), findsNothing);

    await tester.tap(find.byKey(const Key('import-adapter-photos')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('camera-photos-panel')), findsOneWidget);
    expect(find.byKey(const Key('camera-auto-import')), findsOneWidget);
    expect(find.byKey(const Key('camera-keep-in-vault')), findsOneWidget);
    expect(find.byKey(const Key('viewing-history-panel')), findsNothing);
    await tester.tap(find.byTooltip('Close setup'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('import-adapter-history')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('viewing-history-panel')), findsOneWidget);
    expect(find.byKey(const Key('viewing-history-pick')), findsOneWidget);
    expect(
      find.text('Fetch transcripts for the 25 most recent videos'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('camera-photos-panel')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('search finds export adapters and separate extension setups', (
    tester,
  ) async {
    final state = LifenizerAppState();
    state.importCapabilities.add(
      ImportCapability(
        source: 'whatsapp',
        displayName: 'WhatsApp chat export',
        availableNow: true,
        requiresCredentials: false,
        status: 'Reads exported chats',
        acceptedFormats: ['text/plain', 'application/zip'],
      ),
    );
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ImportsPage(state: state)),
      ),
    );
    final search = find.byKey(const Key('imports-search'));
    await tester.enterText(search, 'whatsapp');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('import-adapter-source-whatsapp')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('import-adapter-extension-whatsapp')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('import-adapter-extension-discord')),
      findsNothing,
    );
    expect(find.byKey(const Key('import-adapter-photos')), findsNothing);
    await tester.ensureVisible(
      find.byKey(const Key('import-adapter-extension-whatsapp')),
    );
    await tester.tap(
      find.byKey(const Key('import-adapter-extension-whatsapp')),
    );
    await tester.pumpAndSettle();
    expect(find.text('WhatsApp Web extension setup'), findsOneWidget);
    expect(find.textContaining('Load unpacked'), findsOneWidget);
    expect(find.textContaining('only newly rendered messages'), findsOneWidget);
    expect(
      find.text('Get the extension and installation guide'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Close setup'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(search);
    await tester.enterText(search, 'unknown adapter 123');
    await tester.pumpAndSettle();
    expect(find.textContaining('No importers match'), findsOneWidget);
    expect(find.byKey(const Key('imports-auto-file')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
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
