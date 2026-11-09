import 'dart:math' as math;

/// Relative dates use the caller's local calendar, including DST boundaries.
class TemporalIntent {
  const TemporalIntent({
    required this.targetStart,
    required this.targetEnd,
    this.hourStart,
    this.hourEnd,
    this.weight = 1.0,
  });

  final DateTime targetStart;
  final DateTime targetEnd;
  final int? hourStart;
  final int? hourEnd;
  final double weight;

  static final _datePhrase = RegExp(
    r'\b(same time last year|this time last year|on this day last year|same date last year|'
    r'last year|yesterday|today|tonight|last week|last month|'
    r'letztes jahr|gestern|heute|letzte woche|letzten monat)\b',
  );
  static final _carryPhrase = RegExp(
    r'\b(last search|previous search|same as before|search again|nochmal|wie zuvor)\b',
  );
  static final _hourPhrase = RegExp(
    r'\b(morning|afternoon|evening|night|morgens|nachmittags|abends|nachts)\b',
  );

  static String lexicalQuery(String query) {
    final hasDate = _datePhrase.hasMatch(query);
    var text = query.replaceAll(_datePhrase, ' ').replaceAll(_carryPhrase, ' ');
    if (hasDate) text = text.replaceAll(_hourPhrase, ' ');
    return text.trim();
  }

  static bool referencesPrevious(String query) => _carryPhrase.hasMatch(query);

  static TemporalIntent? tryParse(String query, DateTime now) {
    final phrase = _datePhrase.firstMatch(query)?.group(0);
    if (phrase == null) return null;
    final local = now.toLocal();
    final today = DateTime(local.year, local.month, local.day);
    late DateTime start;
    late DateTime next;
    var weight = 1.6;
    if (phrase.contains('same') ||
        phrase.startsWith('this time') ||
        phrase.startsWith('on this')) {
      final year = local.year - 1;
      final day = math.min(local.day, DateTime(year, local.month + 1, 0).day);
      start = DateTime(year, local.month, day - 1);
      next = DateTime(year, local.month, day + 2);
      weight = 2.6;
    } else if (phrase == 'last year' || phrase == 'letztes jahr') {
      start = DateTime(local.year - 1, 1, 1);
      next = DateTime(local.year, 1, 1);
    } else if (phrase == 'yesterday' || phrase == 'gestern') {
      start = DateTime(local.year, local.month, local.day - 1);
      next = today;
      weight = 1.9;
    } else if (phrase == 'last week' || phrase == 'letzte woche') {
      next = DateTime(local.year, local.month, local.day - local.weekday + 1);
      start = DateTime(next.year, next.month, next.day - 7);
    } else if (phrase == 'last month' || phrase == 'letzten monat') {
      start = DateTime(local.year, local.month - 1, 1);
      next = DateTime(local.year, local.month, 1);
    } else {
      start = today;
      next = DateTime(local.year, local.month, local.day + 1);
    }
    final hours = _hours(query);
    return TemporalIntent(
      targetStart: start.toUtc(),
      targetEnd: next.toUtc().subtract(const Duration(microseconds: 1)),
      hourStart: hours?.$1,
      hourEnd: hours?.$2,
      weight: weight,
    );
  }

  double alignmentScore(DateTime documentTime) {
    final doc = documentTime.toUtc();
    final start = targetStart.toUtc();
    final end = targetEnd.toUtc();
    if (doc.isBefore(start) || doc.isAfter(end)) {
      final distance = doc.isBefore(start)
          ? start.difference(doc)
          : doc.difference(end);
      return math.exp(-distance.inHours / (24 * 21)) * 0.8;
    }
    var score = 2 * weight;
    if (hourStart != null && hourEnd != null) {
      final hour = doc.toLocal().hour;
      final matches = hourStart! <= hourEnd!
          ? hour >= hourStart! && hour <= hourEnd!
          : hour >= hourStart! || hour <= hourEnd!;
      score += matches ? 1.4 : -0.6;
    }
    return score;
  }

  static (int, int)? _hours(String query) {
    if (RegExp(r'\b(morning|morgens)\b').hasMatch(query)) return (5, 11);
    if (RegExp(r'\b(afternoon|nachmittags)\b').hasMatch(query)) return (12, 17);
    if (RegExp(r'\b(evening|abends)\b').hasMatch(query)) return (18, 22);
    if (RegExp(r'\b(night|tonight|nachts)\b').hasMatch(query)) return (22, 4);
    return null;
  }
}
