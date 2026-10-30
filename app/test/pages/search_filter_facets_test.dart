import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/pages/search_page.dart';
import 'package:app/services/sync_progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Reads {
  int sources = 0, tags = 0, locations = 0;
}

class _Summary extends Conversation {
  _Summary(int n, this.reads)
    : super(
        id: 'summary-$n',
        title: 'Summary $n',
        source: 'email',
        participantIds: const [],
        segments: const [],
        isLoaded: false,
        segmentCount: 20,
        tags: const ['Work'],
        location: RecordingLocation(town: 'Berlin', venue: 'Studio'),
      );
  final _Reads reads;
  @override
  String get source {
    reads.sources++;
    return super.source;
  }

  @override
  List<String> get tags {
    reads.tags++;
    return super.tags;
  }

  @override
  RecordingLocation? get location {
    reads.locations++;
    return super.location;
  }
}

// Isolate filter rendering from search-engine work, whose scans have separate
// native integration coverage. Every catalog facet access remains observable.
class _State extends LifenizerAppState {
  final _observedConversations = <Conversation>[];
  // Keep the instrumented getters; catalog compaction has separate coverage.
  @override
  List<Conversation> get conversations => _observedConversations;

  @override
  List<Conversation> search(
    String query, {
    String? source,
    String? participantId,
    String? tag,
    bool favoritesOnly = false,
    bool useVector = true,
    DateTime? from,
    DateTime? to,
    bool includeConsumed = true,
    int? maxResults,
  }) => const [];
}

void main() {
  test(
    'facets scan once and defer refresh during busy or active sync',
    () async {
      final state = _State();
      addTearDown(state.dispose);
      final reads = _Reads();
      state.conversations.addAll(
        List.generate(1000, (n) => _Summary(n, reads)),
      );
      state.busy = true;
      expect(state.availableSources, isEmpty);
      expect(reads.sources, 0);
      state.busy = false;
      final sources = state.availableSources;
      final tags = state.allTags;
      final locations = state.availableLocations;
      final options = state.locationFilterOptions;
      expect(sources, ['email']);
      expect(tags, ['Work']);
      expect(locations, hasLength(1));
      expect(options.towns, ['Berlin']);
      expect(options.places, ['Berlin Studio']);
      for (var build = 0; build < 25; build++) {
        expect(identical(state.availableSources, sources), isTrue);
        expect(identical(state.allTags, tags), isTrue);
        expect(identical(state.availableLocations, locations), isTrue);
        expect(state.locationFilterOptions, options);
      }
      expect((reads.sources, reads.tags, reads.locations), (1000, 1000, 1000));
      state.syncProgress = const SyncProgress(stage: SyncStage.applying);
      state.conversations.add(
        Conversation(
          id: 'new',
          title: 'New',
          source: 'discord',
          participantIds: const [],
          segments: const [],
          tags: const ['Family'],
        ),
      );
      expect(state.availableSources, ['email']);
      expect(reads.sources, 1000);
      state.syncProgress = const SyncProgress(stage: SyncStage.complete);
      expect(state.availableSources, ['discord', 'email']);
      expect(state.allTags, ['Family', 'Work']);
      expect(reads.sources, 2000);
      await state.lock();
      expect(state.availableSources, isEmpty);
      expect(state.allTags, isEmpty);
      expect(state.availableLocations, isEmpty);
      expect(state.locationFilterOptions.towns, isEmpty);
      expect(state.locationFilterOptions.places, isEmpty);
      state.conversations.add(
        Conversation(
          id: 'next-vault',
          title: 'Next',
          source: 'manual-text',
          participantIds: const [],
          segments: const [],
        ),
      );
      expect(state.availableSources, ['manual-text']);
      expect(state.allTags, isEmpty);
      expect(state.availableLocations, isEmpty);
    },
  );

  testWidgets('typing and repeated search-page builds reuse catalog facets', (
    tester,
  ) async {
    final state = _State();
    addTearDown(state.dispose);
    final reads = _Reads();
    state.conversations.addAll(List.generate(10000, (n) => _Summary(n, reads)));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: state,
            builder: (context, child) => SearchPage(state: state),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect((reads.sources, reads.tags, reads.locations), (10000, 10000, 10000));
    for (final query in ['a', 'ar', 'archive']) {
      await tester.enterText(find.byType(TextField).first, query);
      await tester.pumpAndSettle();
      state.notifyListeners();
      await tester.pumpAndSettle();
    }
    expect((reads.sources, reads.tags, reads.locations), (10000, 10000, 10000));
    expect(find.text('archive'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
