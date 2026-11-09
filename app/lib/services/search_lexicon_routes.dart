/// Vocabulary-page routes use Unicode code points, like edit-distance scoring.
/// The original matcher verifies routed words; routes may have false positives.
Iterable<String> searchLexiconGrams(String word) sync* {
  final runes = word.runes.toList(growable: false);
  for (var width = 1; width <= 3; width++) {
    for (var start = 0; start + width <= runes.length; start++) {
      yield String.fromCharCodes(runes.sublist(start, start + width));
    }
  }
}

Set<String> searchLexiconQueryGrams(String query) {
  final runes = query.runes.toList(growable: false);
  if (runes.isEmpty) return {};
  // Match the existing quality() edit limit, including its UTF-16 thresholds.
  final edits = query.length < 4 ? 0 : (query.length < 6 ? 1 : 2);
  final pieces = edits + 1;
  // At most k edits leave one of k+1 disjoint pieces unchanged. Every exact,
  // prefix and substring match also contains these grams. OR their page routes.
  return {
    for (var piece = 0; piece < pieces; piece++)
      String.fromCharCodes(
        runes.sublist(
          runes.length * piece ~/ pieces,
          _end(runes.length, piece, pieces),
        ),
      ),
  };
}

int _end(int length, int piece, int pieces) {
  final start = length * piece ~/ pieces;
  final end = length * (piece + 1) ~/ pieces;
  return end - start > 3 ? start + 3 : end;
}
