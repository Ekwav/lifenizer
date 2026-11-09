import 'package:app/models.dart';
import 'package:app/services/recording_suggestions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const service = RecordingSuggestionService();
  // Monday 2026-10-05 09:00 local time, so the offsets below stay in local time.
  final now = DateTime(2026, 10, 5, 9, 0);
  final people = {
    'alice': Participant(id: 'alice', displayName: 'Alice Müller'),
    'bob': Participant(id: 'bob', displayName: 'Bob', aliases: ['Robert']),
    'carol': Participant(id: 'carol', displayName: 'Carol'),
    'old': Participant(id: 'old', displayName: 'Old Dave', mergedInto: 'cycle'),
  };

  Conversation convo(
    String id,
    DateTime local,
    List<String> who, {
    String title = 'Chat',
    String source = 'audio',
  }) => Conversation(
    id: id,
    title: title,
    source: source,
    participantIds: who,
    segments: [],
    startedAt: local.toUtc(),
    endedAt: local.toUtc(),
  );

  List<PersonSuggestion> suggest(List<Conversation> history, {int limit = 6}) =>
      service.suggestPeople(
        conversations: history,
        participantById: (id) => people[id],
        recordedAt: now.toUtc(),
        limit: limit,
      );

  test('same weekday and time last week outranks a random recent contact', () {
    final result = suggest([
      convo('1', now.subtract(const Duration(days: 7)), ['alice']),
      convo('2', now.subtract(const Duration(hours: 20)), ['bob']),
    ]);
    expect(result.map((s) => s.participant.id), ['alice', 'bob']);
    expect(result.first.reason, 'Same time last Monday');
    expect(result.first.score, greaterThan(result.last.score));
  });

  test('repeated weekly pattern is summarised', () {
    final result = suggest([
      for (var week = 1; week <= 3; week++)
        convo('w$week', now.subtract(Duration(days: 7 * week)), ['alice']),
    ]);
    expect(result.single.reason, '3 of the last 4 Mondays');
  });

  test('older matches decay and anything older than 8 weeks is ignored', () {
    final result = suggest([
      convo('1', now.subtract(const Duration(days: 49)), ['bob']),
      convo('2', now.subtract(const Duration(days: 7)), ['carol']),
      convo('3', now.subtract(const Duration(days: 70)), ['alice']),
    ]);
    expect(result.map((s) => s.participant.id), ['carol', 'bob']);
  });

  test('yesterday and audio sources are explained and favoured', () {
    final result = suggest([
      convo('1', now.subtract(const Duration(hours: 20)), [
        'bob',
      ], source: 'whatsapp'),
      convo('2', now.subtract(const Duration(hours: 20)), ['carol']),
    ]);
    expect(result.first.participant.id, 'carol');
    expect(result.first.reason, 'Yesterday');
  });

  test('merged participants are excluded and redirects are followed', () {
    final result = service.suggestPeople(
      conversations: [
        convo('1', now.subtract(const Duration(days: 7)), ['old']),
        convo('2', now.subtract(const Duration(days: 7)), ['dup']),
      ],
      participantById: (id) => id == 'dup' ? people['alice'] : people[id],
      recordedAt: now.toUtc(),
    );
    expect(result.map((s) => s.participant.id), ['alice']);
  });

  test('titles prefer similar slots, skip generic defaults, max six', () {
    final history = [
      convo('1', now.subtract(const Duration(days: 7)), [], title: 'Team sync'),
      convo(
        '2',
        now.subtract(const Duration(days: 2)),
        [],
        title: 'Recorded conversation',
      ),
      convo(
        '3',
        now.subtract(const Duration(days: 3, hours: 5)),
        [],
        title: 'Groceries',
        source: 'manual',
      ),
      convo(
        '4',
        now.subtract(const Duration(days: 4, hours: 5)),
        [],
        title: 'Groceries',
        source: 'manual',
      ),
      for (var i = 0; i < 8; i++)
        convo(
          'x$i',
          now.subtract(Duration(days: 1, hours: i + 3)),
          [],
          title: 'Topic $i',
        ),
    ];
    final titles = service.suggestTitles(
      conversations: history,
      recordedAt: now.toUtc(),
    );
    expect(titles.first, 'Team sync');
    expect(titles, isNot(contains('Recorded conversation')));
    expect(titles, contains('Groceries'));
    expect(titles.length, 6);
  });

  test('people completion ignores case and diacritics and matches aliases', () {
    List<String> names(String q, {Set<String> exclude = const {}}) => service
        .completePeople(q, people.values, exclude: exclude)
        .map((p) => p.displayName)
        .toList();
    expect(names('mul'), ['Alice Müller']);
    expect(names('MÜL'), ['Alice Müller']);
    expect(names('al'), ['Alice Müller']);
    expect(names('rob'), ['Bob']);
    expect(names('b', exclude: {'bob'}), isEmpty);
    expect(names(''), isEmpty);
    expect(names('dave'), isEmpty);
  });

  test('title completion is prefix and word-start based', () {
    final history = [
      convo('1', now, [], title: 'Café planning'),
      convo('2', now, [], title: 'Café planning'),
      convo('3', now, [], title: 'Weekly café run'),
      convo('4', now, [], title: 'Recorded conversation'),
    ];
    expect(service.completeTitles('cafe', history), [
      'Café planning',
      'Weekly café run',
    ]);
    expect(service.completeTitles('rec', history), isEmpty);
  });
}
