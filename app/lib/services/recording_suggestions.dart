import '../models.dart';

/// A ranked person suggestion with a short human explanation.
class PersonSuggestion {
  PersonSuggestion({
    required this.participant,
    required this.score,
    required this.reason,
  });

  final Participant participant;
  final double score;
  final String reason;
}

/// Suggests people and titles for a new recording from historic habits and
/// provides diacritic-insensitive autocomplete. Pure Dart so it is cheap to test.
class RecordingSuggestionService {
  const RecordingSuggestionService();

  static const _weekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  static const _audioSources = {'audio', 'live-recording'};
  static const _genericTitles = {
    'recorded conversation',
    'live session',
    'untitled',
    'untitled conversation',
    'audio',
    'recording',
  };
  static const _lookback = Duration(days: 56);

  /// Ranks people the user usually records with around [recordedAt].
  List<PersonSuggestion> suggestPeople({
    required List<Conversation> conversations,
    required Participant? Function(String id) participantById,
    required DateTime recordedAt,
    int limit = 6,
  }) {
    final now = recordedAt.toLocal();
    final stats = <String, _PersonStats>{};
    for (final conversation in conversations) {
      final age = recordedAt.difference(conversation.startedAt);
      if (age > _lookback || age < const Duration(minutes: -5)) continue;
      final started = conversation.startedAt.toLocal();
      final sameWeekday = started.weekday == now.weekday;
      final minutes = _minuteGap(started, now);
      final weeksAgo = age.isNegative ? 0.0 : age.inHours / (24 * 7);
      var weight = 0.0;
      final slot = sameWeekday && minutes <= 90;
      if (slot) {
        weight += 3.0;
      } else if (sameWeekday) {
        weight += 1.0;
      }
      final nearTime = minutes <= 60;
      if (nearTime) weight += 1.5;
      final recent = age <= const Duration(hours: 24);
      if (recent) weight += 1.0;
      if (weight == 0) continue;
      weight /= 1 + weeksAgo / 4;
      if (_audioSources.contains(conversation.source)) weight *= 1.3;
      final resolved = <String>{};
      for (final id in conversation.participantIds) {
        final person = participantById(id);
        if (person == null || person.mergedInto != null) continue;
        if (!resolved.add(person.id)) continue;
        final entry = stats.putIfAbsent(person.id, () => _PersonStats(person));
        entry.score += weight;
        if (slot) {
          entry.slotWeeks.add((age.inHours / (24 * 7)).floor());
          entry.slotAges.add(age);
        } else if (nearTime) {
          entry.nearTime++;
        } else if (sameWeekday) {
          entry.weekday++;
        }
        if (recent &&
            (entry.recentStart == null ||
                conversation.startedAt.isAfter(entry.recentStart!))) {
          entry.recentStart = conversation.startedAt;
        }
      }
    }
    final ranked = stats.values.toList()
      ..sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        return byScore != 0
            ? byScore
            : a.person.displayName.toLowerCase().compareTo(
                b.person.displayName.toLowerCase(),
              );
      });
    return [
      for (final entry in ranked.take(limit))
        PersonSuggestion(
          participant: entry.person,
          score: entry.score,
          reason: _reason(entry, now, recordedAt),
        ),
    ];
  }

  String _reason(_PersonStats entry, DateTime now, DateTime recordedAt) {
    final weekday = _weekdays[now.weekday - 1];
    if (entry.slotWeeks.isNotEmpty) {
      final weeks = entry.slotWeeks.length;
      if (weeks == 1) {
        final days = entry.slotAges.first.inHours / 24;
        if (days >= 6 && days <= 8) return 'Same time last $weekday';
        return 'Around this time on a $weekday';
      }
      final window = entry.slotWeeks.any((week) => week >= 4) ? 8 : 4;
      return '$weeks of the last $window ${weekday}s';
    }
    final recent = entry.recentStart;
    if (recent != null) {
      return recent.toLocal().day == now.day ? 'Earlier today' : 'Yesterday';
    }
    if (entry.nearTime > 0) return 'Often around this time';
    return 'Often on ${weekday}s';
  }

  /// Distinct, non-generic titles of similar recordings, then frequent ones.
  List<String> suggestTitles({
    required List<Conversation> conversations,
    required DateTime recordedAt,
    int limit = 6,
  }) {
    final now = recordedAt.toLocal();
    final similar = <String, _TitleStats>{};
    final frequent = <String, _TitleStats>{};
    for (final conversation in conversations) {
      final age = recordedAt.difference(conversation.startedAt);
      if (age > _lookback || age < const Duration(minutes: -5)) continue;
      final title = conversation.title.trim();
      if (title.isEmpty || _genericTitles.contains(title.toLowerCase())) {
        continue;
      }
      final key = title.toLowerCase();
      final stats = frequent.putIfAbsent(key, () => _TitleStats(title));
      stats.count++;
      if (conversation.startedAt.isAfter(stats.latest)) {
        stats.latest = conversation.startedAt;
      }
      final started = conversation.startedAt.toLocal();
      if (_audioSources.contains(conversation.source) &&
          started.weekday == now.weekday &&
          _minuteGap(started, now) <= 90) {
        final slot = similar.putIfAbsent(key, () => _TitleStats(title));
        slot.count++;
        if (conversation.startedAt.isAfter(slot.latest)) {
          slot.latest = conversation.startedAt;
        }
      }
    }
    int order(_TitleStats a, _TitleStats b) {
      final byCount = b.count.compareTo(a.count);
      return byCount != 0 ? byCount : b.latest.compareTo(a.latest);
    }

    final result = <String>[];
    final seen = <String>{};
    for (final group in [
      similar.values.toList()..sort(order),
      frequent.values.toList()..sort(order),
    ]) {
      for (final entry in group) {
        if (result.length >= limit) return result;
        if (seen.add(entry.title.toLowerCase())) result.add(entry.title);
      }
    }
    return result;
  }

  /// Matches name/alias prefixes and parts of contact identifiers.
  List<Participant> completePeople(
    String prefix,
    Iterable<Participant> people, {
    Set<String> exclude = const {},
    Set<String> excludeIds = const {},
  }) {
    final query = fold(prefix);
    if (query.isEmpty) return const [];
    final excluded = exclude.map(fold).toSet();
    final scored = <(int, Participant)>[];
    for (final person in people) {
      if (person.mergedInto != null || excludeIds.contains(person.id)) continue;
      if (excluded.contains(fold(person.displayName))) continue;
      var best = 99;
      for (final name in [person.displayName, ...person.aliases]) {
        final rank = _matchRank(fold(name), query);
        if (rank < best) best = rank;
      }
      if (best == 99 &&
          person.identifiers.any((id) => fold(id).contains(query))) {
        best = 2;
      }
      if (best < 99) scored.add((best, person));
    }
    scored.sort((a, b) {
      final byRank = a.$1.compareTo(b.$1);
      return byRank != 0
          ? byRank
          : a.$2.displayName.toLowerCase().compareTo(
              b.$2.displayName.toLowerCase(),
            );
    });
    return [for (final entry in scored.take(8)) entry.$2];
  }

  /// Distinct existing titles that start with (or have a word starting with) [prefix].
  List<String> completeTitles(String prefix, Iterable<Conversation> history) {
    final query = fold(prefix);
    if (query.isEmpty) return const [];
    final counts = <String, _TitleStats>{};
    for (final conversation in history) {
      final title = conversation.title.trim();
      if (title.isEmpty || _genericTitles.contains(title.toLowerCase())) {
        continue;
      }
      if (_matchRank(fold(title), query) >= 99) continue;
      final stats = counts.putIfAbsent(
        title.toLowerCase(),
        () => _TitleStats(title),
      );
      stats.count++;
      if (conversation.startedAt.isAfter(stats.latest)) {
        stats.latest = conversation.startedAt;
      }
    }
    final entries = counts.values.toList()
      ..sort((a, b) {
        final rankA = _matchRank(fold(a.title), query);
        final rankB = _matchRank(fold(b.title), query);
        if (rankA != rankB) return rankA.compareTo(rankB);
        final byCount = b.count.compareTo(a.count);
        return byCount != 0 ? byCount : b.latest.compareTo(a.latest);
      });
    return [for (final entry in entries.take(8)) entry.title];
  }

  /// 0 = full prefix, 1 = word-start, 99 = no match.
  static int _matchRank(String name, String query) {
    if (name.startsWith(query)) return 0;
    if (name.contains(' $query') ||
        name.contains('-$query') ||
        name.contains('.$query')) {
      return 1;
    }
    return 99;
  }

  static int _minuteGap(DateTime a, DateTime b) {
    final first = a.hour * 60 + a.minute;
    final second = b.hour * 60 + b.minute;
    final gap = (first - second).abs();
    return gap > 720 ? 1440 - gap : gap;
  }

  /// Lower-cases and strips common Latin diacritics.
  static String fold(String value) {
    final buffer = StringBuffer();
    for (final rune in value.trim().toLowerCase().runes) {
      final char = String.fromCharCode(rune);
      buffer.write(_folds[char] ?? char);
    }
    return buffer.toString();
  }

  static final Map<String, String> _folds = () {
    const groups = {
      'a': 'àáâãäåāăą',
      'c': 'çćčĉċ',
      'd': 'ďđ',
      'e': 'èéêëēĕėęě',
      'g': 'ĝğġģ',
      'i': 'ìíîïĩīĭįı',
      'l': 'łľĺļ',
      'n': 'ñńňņ',
      'o': 'òóôõöøōŏő',
      'r': 'ŕřŗ',
      's': 'śšşŝș',
      't': 'ťţț',
      'u': 'ùúûüũūŭůűų',
      'y': 'ýÿ',
      'z': 'źžż',
    };
    final map = <String, String>{'ß': 'ss', 'æ': 'ae', 'œ': 'oe'};
    groups.forEach((base, chars) {
      for (final rune in chars.runes) {
        map[String.fromCharCode(rune)] = base;
      }
    });
    return map;
  }();
}

class _PersonStats {
  _PersonStats(this.person);
  final Participant person;
  double score = 0;
  final Set<int> slotWeeks = {};
  final List<Duration> slotAges = [];
  int nearTime = 0;
  int weekday = 0;
  DateTime? recentStart;
}

class _TitleStats {
  _TitleStats(this.title) : latest = DateTime.fromMillisecondsSinceEpoch(0);
  final String title;
  int count = 0;
  DateTime latest;
}
