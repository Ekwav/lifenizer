import 'package:app/models.dart';
import 'package:app/services/search_criteria.dart';
import 'package:app/services/search_source_groups.dart';

/// Authored destinations, independent of search scores or a reference engine.
/// IDs may be remapped to existing benchmark slots; preserve lexical ID order
/// so the tie-order judgment still describes the same deterministic ordering.
class SearchRelevanceJudgment {
  const SearchRelevanceJudgment(
    this.label,
    this.criteria,
    this.expectedTopIds, {
    this.unordered = false,
    this.requireExactResults = false,
    this.heldOut = false,
    this.excludedIds = const [],
  });

  final String label;
  final SearchCriteria criteria;
  final List<String> expectedTopIds;
  final bool unordered;
  final bool requireExactResults;
  final bool heldOut;
  final List<String> excludedIds;
}

/// Small editorial corpus shared by unit tests and the full-size benchmark.
/// The separate held-out topic can be added after the initial indexing phase.
class SearchRelevanceFixture {
  SearchRelevanceFixture(this.now);
  final DateTime now;
  final Map<String, String> participantById = const {
    'relevance-person-alice': 'Alice Robertson',
    'relevance-person-bob': 'Bob Carter',
    'relevance-person-joerg': 'Jörg Müller',
    'relevance-person-lea': 'Léa Dubois',
  };

  Conversation _document(
    String id,
    String title,
    String body, {
    String source = 'signal',
    List<String> people = const [],
    List<String> tags = const [],
    bool favorite = false,
    int daysAgo = 1,
    RecordingLocation? location,
  }) => Conversation(
    id: id,
    title: title,
    source: source,
    participantIds: people,
    tags: tags,
    isFavorite: favorite,
    location: location,
    startedAt: now.subtract(Duration(days: daysAgo)),
    endedAt: now.subtract(Duration(days: daysAgo)),
    segments: [ConversationSegment(id: '$id-message', text: body)],
  );

  late final List<Conversation> conversations = [
    _document(
      'budget-decision',
      'Project budget',
      'Project budget approved. Venue costs are capped at 4200 euros.',
      people: ['relevance-person-alice'],
      tags: ['approved'],
      favorite: true,
    ),
    _document(
      'budget-draft',
      'Finance correspondence',
      'Project budget draft. Please review the venue estimate before approval.',
      source: 'email',
      people: ['relevance-person-alice'],
      daysAgo: 30,
    ),
    _document(
      'budget-scan',
      'Project budget',
      'Signed venue estimate and receipt for the project budget.',
      source: 'scanned-pdf',
    ),
    _document(
      'budget-video',
      'Project budget',
      'A tutorial about project budget planning and common accounting mistakes.',
      source: 'youtube-transcript',
    ),
    _document(
      'budget-bob',
      'Project cost planning',
      'Project budget discussion. We still need quotes from the venue.',
      people: ['relevance-person-bob'],
    ),
    _document(
      'insurance-renewal',
      'Versicherung erneuern',
      'Der Vertrag läuft aus. Bitte die neue Police prüfen.',
      source: 'email',
      people: ['relevance-person-joerg'],
    ),
    _document(
      'insurance-guide',
      'Versicherung erneuern',
      'Ein Ratgeber zur jährlichen Prüfung der Police.',
      source: 'browser-capture',
    ),
    _document(
      'joerg-holiday',
      'Wandern im Herbst',
      'Wir buchen eine Hütte in den Bergen.',
      people: ['relevance-person-joerg'],
    ),
    _document(
      'train-connection',
      'Train connection',
      'Reserved seats for our journey.',
    ),
    _document(
      'train-reversed',
      'Connection train',
      'Reserved seats for our journey.',
    ),
    _document(
      'dresden-meeting',
      'Workshop arrangements',
      'Bring the printed agenda and a projector.',
      source: 'recording',
      people: ['relevance-person-lea'],
      location: RecordingLocation(
        town: 'Dresden',
        venue: 'Café Nord',
        address: 'Hauptstraße 17',
      ),
    ),
    _document(
      'berlin-meeting',
      'Workshop arrangements',
      'Bring the printed agenda and a projector.',
      source: 'recording',
      people: ['relevance-person-lea'],
      location: RecordingLocation(town: 'Berlin', venue: 'Café Süd'),
    ),
    _document(
      'dresden-article',
      'Dresden travel guide',
      'Workshop venues and cafes around Dresden.',
      source: 'browser-history',
    ),
    for (final id in ['tie-c', 'tie-b', 'tie-a'])
      _document(id, 'Observatory reservation', 'Tickets for the evening tour.'),
    _document(
      'tie-older',
      'Observatory reservation',
      'Tickets for the evening tour.',
      daysAgo: 40,
    ),
  ];

  late final List<Conversation> heldOutConversations = [
    _document(
      'battery-claim',
      'Battery warranty',
      'The replacement was approved. Bring the purchase receipt on Friday.',
      source: 'email',
      people: ['relevance-person-bob'],
    ),
    _document(
      'battery-receipt',
      'Battery warranty',
      'Purchase receipt and warranty terms for the replacement battery.',
      source: 'paperless',
    ),
    _document(
      'battery-review',
      'Battery warranty',
      List.filled(
        50,
        'Battery warranty explained in this product review.',
      ).join(' '),
      source: 'youtube-transcript',
    ),
  ];

  late final List<SearchRelevanceJudgment> judgments = [
    for (final (criteria, expected) in <(SearchCriteria, String)>[
      (SearchCriteria(query: 'project budget'), 'budget-decision'),
      (SearchCriteria(query: 'proj budg'), 'budget-decision'),
      (SearchCriteria(query: 'alice budget'), 'budget-decision'),
      (SearchCriteria(query: 'Versicherung Jörg Müller'), 'insurance-renewal'),
      (SearchCriteria(query: 'versich Joerg Muell'), 'insurance-renewal'),
      (SearchCriteria(query: 'versicherung Jorg Muller'), 'insurance-renewal'),
      (SearchCriteria(query: 'versicherugn mueller'), 'insurance-renewal'),
      (SearchCriteria(query: 'sicherung muell'), 'insurance-renewal'),
      (SearchCriteria(query: 'train connection'), 'train-connection'),
      (SearchCriteria(query: 'connection train'), 'train-reversed'),
      (SearchCriteria(query: 'workshop dresden'), 'dresden-meeting'),
      (SearchCriteria(query: 'workshop town:"Dresden"'), 'dresden-meeting'),
      (
        SearchCriteria(query: 'workshop location:"Café Nord"'),
        'dresden-meeting',
      ),
      (
        SearchCriteria(query: 'project budget', source: 'email'),
        'budget-draft',
      ),
      (
        SearchCriteria(
          query: 'project budget',
          source: sourceGroupFilter(SearchSourceGroup.documents),
        ),
        'budget-scan',
      ),
      (
        SearchCriteria(
          query: 'project budget',
          source: sourceGroupFilter(SearchSourceGroup.consumed),
        ),
        'budget-video',
      ),
      (
        SearchCriteria(
          query: 'project budget',
          participantId: 'relevance-person-bob',
        ),
        'budget-bob',
      ),
      (
        SearchCriteria(query: 'project budget', tag: 'approved'),
        'budget-decision',
      ),
      (
        SearchCriteria(query: 'project budget', favoritesOnly: true),
        'budget-decision',
      ),
      (
        SearchCriteria(
          query: 'project budget',
          from: now.subtract(const Duration(days: 30)),
          to: now.subtract(const Duration(days: 30)),
          participantId: 'relevance-person-alice',
        ),
        'budget-draft',
      ),
    ])
      SearchRelevanceJudgment(
        '$criteria -> $expected ${criteria.locationLabels}',
        criteria,
        [expected],
      ),
    for (final vector in [true, false])
      SearchRelevanceJudgment(
        'common exact titles ahead of incidental prefix (vector=$vector)',
        SearchCriteria(query: 'project', useVector: vector),
        const ['budget-decision', 'budget-bob'],
        unordered: true,
      ),
    SearchRelevanceJudgment(
      'accented participant and topic',
      SearchCriteria(query: 'lea workshop'),
      const ['dresden-meeting', 'berlin-meeting'],
      unordered: true,
    ),
    SearchRelevanceJudgment(
      'equal-score dates and IDs order stably',
      SearchCriteria(query: 'observatory reservation'),
      const ['tie-a', 'tie-b', 'tie-c', 'tie-older'],
      requireExactResults: true,
    ),
    for (final query in [
      'joerg budget',
      'project xylophonist',
      'workshop town:"Hamburg"',
    ])
      SearchRelevanceJudgment(
        'strict coverage: $query',
        SearchCriteria(query: query),
        const [],
        requireExactResults: true,
      ),
    SearchRelevanceJudgment(
      'hide consumed media',
      SearchCriteria(query: 'project budget', includeConsumed: false),
      const ['budget-decision'],
      excludedIds: const ['budget-video'],
    ),
    for (final query in ['battery warranty', 'batt warr', 'batery waranty'])
      SearchRelevanceJudgment(
        'held-out topic: $query',
        SearchCriteria(query: query),
        const ['battery-claim'],
        heldOut: true,
      ),
    SearchRelevanceJudgment(
      'held-out scan destination',
      SearchCriteria(query: 'battery warranty', source: 'paperless'),
      const ['battery-receipt'],
      heldOut: true,
    ),
  ];
}
