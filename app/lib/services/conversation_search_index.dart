import 'dart:math' as math;

import '../models.dart';
import 'string_distance_service.dart';

class IndexedConversation {
  IndexedConversation({
    required this.conversation,
    required this.haystack,
    required this.titleTokens,
    required this.personTokens,
    required this.tagSet,
    required this.termFrequency,
    required this.vectorNorm,
    required this.length,
  });

  final Conversation conversation;
  final String haystack;
  final Set<String> titleTokens;
  final Set<String> personTokens;
  final Set<String> tagSet;
  final Map<String, int> termFrequency;
  final double vectorNorm;
  final int length;
}

/// A local index over decrypted conversations. Query expansion runs once per
/// term, and candidate intersection enforces coverage across all query terms.
class ConversationSearchIndex {
  ConversationSearchIndex._(
    this.documents,
    this.invertedIndex,
    this.idf,
    this.averageLength,
  );

  final Map<String, IndexedConversation> documents;
  final Map<String, Set<String>> invertedIndex;
  final Map<String, double> idf;
  final double averageLength;
  static final _word = RegExp(r'[\p{L}\p{N}\p{M}]+', unicode: true);

  static ConversationSearchIndex build({
    required List<Conversation> conversations,
    required Map<String, String> participantById,
    required Map<String, String> relationTextByConversation,
  }) {
    final docs = <String, IndexedConversation>{};
    final inverted = <String, Set<String>>{};
    for (final conversation in conversations) {
      final participantText = conversation.participantIds
          .map((id) => participantById[id] ?? id)
          .join(' ');
      final tokens = tokenize(
        '${conversation.searchableText} $participantText '
        '${relationTextByConversation[conversation.id] ?? ''}',
      );
      final frequency = <String, int>{};
      for (final token in tokens) {
        frequency.update(token, (count) => count + 1, ifAbsent: () => 1);
      }
      for (final token in frequency.keys) {
        inverted.putIfAbsent(token, () => <String>{}).add(conversation.id);
      }
      docs[conversation.id] = IndexedConversation(
        conversation: conversation,
        haystack: tokens.join(' '),
        titleTokens: tokenize(conversation.title).toSet(),
        personTokens: tokenize(participantText).toSet(),
        tagSet: conversation.tags.map((tag) => tag.toLowerCase()).toSet(),
        termFrequency: frequency,
        vectorNorm: 0,
        length: tokens.length,
      );
    }
    final idf = <String, double>{
      for (final entry in inverted.entries)
        entry.key: math.log(
          1 +
              (docs.length - entry.value.length + 0.5) /
                  (entry.value.length + 0.5),
        ),
    };
    final withNorm = <String, IndexedConversation>{};
    var totalLength = 0;
    for (final entry in docs.entries) {
      final doc = entry.value;
      totalLength += doc.length;
      final norm = doc.termFrequency.entries.fold(0.0, (sum, term) {
        final weight = (1 + math.log(term.value)) * idf[term.key]!;
        return sum + weight * weight;
      });
      withNorm[entry.key] = IndexedConversation(
        conversation: doc.conversation,
        haystack: doc.haystack,
        titleTokens: doc.titleTokens,
        personTokens: doc.personTokens,
        tagSet: doc.tagSet,
        termFrequency: doc.termFrequency,
        vectorNorm: math.sqrt(norm),
        length: doc.length,
      );
    }
    return ConversationSearchIndex._(
      withNorm,
      inverted,
      idf,
      docs.isEmpty ? 1 : math.max(1.0, totalLength / docs.length),
    );
  }

  Map<String, Map<String, double>> expandTokens(List<String> tokens) {
    final expansions = <String, Map<String, double>>{};
    for (final token in tokens.toSet()) {
      final matches = <String, double>{};
      for (final indexed in invertedIndex.keys) {
        final quality = _matchQuality(token, indexed);
        if (quality > 0) matches[indexed] = quality;
      }
      expansions[token] = matches;
    }
    return expansions;
  }

  Set<String> lookupCandidates(
    List<String> queryTokens, {
    Map<String, Map<String, double>>? expansions,
  }) {
    if (queryTokens.isEmpty) return documents.keys.toSet();
    final expanded = expansions ?? expandTokens(queryTokens);
    Set<String>? candidates;
    for (final matches in expanded.values) {
      final tokenCandidates = <String>{
        for (final token in matches.keys) ...invertedIndex[token]!,
      };
      candidates = candidates == null
          ? tokenCandidates
          : candidates.intersection(tokenCandidates);
      if (candidates.isEmpty) break;
    }
    return candidates ?? <String>{};
  }

  double lexicalScore(
    IndexedConversation document,
    String query,
    List<String> queryTokens, {
    Map<String, Map<String, double>>? expansions,
  }) {
    final expanded = expansions ?? expandTokens(queryTokens);
    var score = 0.0;
    for (final matches in expanded.values) {
      var best = 0.0;
      for (final entry in matches.entries) {
        final tf = document.termFrequency[entry.key] ?? 0;
        if (tf == 0) continue;
        // BM25 saturation keeps repeated words in long exports from drowning
        // out a concise title or an actual participant match.
        final bm25 =
            idf[entry.key]! *
            tf *
            2.2 /
            (tf + 1.2 * (0.25 + 0.75 * document.length / averageLength));
        final fieldBoost =
            (document.titleTokens.contains(entry.key) ? 4.0 : 0.0) +
            (document.personTokens.contains(entry.key) ? 5.0 : 0.0) +
            (document.tagSet.contains(entry.key) ? 2.0 : 0.0);
        best = math.max(best, entry.value * (4 + bm25 + fieldBoost));
      }
      score += best;
    }
    if (query.isNotEmpty && document.haystack.contains(query)) score += 4;
    return score;
  }

  double vectorScore(IndexedConversation document, List<String> queryTokens) {
    if (queryTokens.isEmpty || document.vectorNorm <= 0) return 0;
    var norm = 0.0;
    var dot = 0.0;
    for (final token in queryTokens.toSet()) {
      final weight = idf[token] ?? 0;
      norm += weight * weight;
      final frequency = document.termFrequency[token] ?? 0;
      if (frequency > 0) dot += weight * weight * (1 + math.log(frequency));
    }
    return norm > 0 ? dot / (math.sqrt(norm) * document.vectorNorm) : 0;
  }

  static double _matchQuality(String query, String token) {
    if (query == token) return 1;
    if (token.startsWith(query)) return 0.8;
    if (query.length >= 2 && token.contains(query)) return 0.6;
    if (query.length < 4) return 0;
    final limit = query.length >= 6 ? 2 : 1;
    final distance = StringDistance.levenshtein(query, token, limit);
    return distance <= limit ? (distance == 1 ? 0.5 : 0.3) : 0;
  }

  /// Preserve non-Latin words and fold common Latin accents for name lookup.
  static List<String> tokenize(String text) {
    final normalized = text
        .toLowerCase()
        .replaceAll('ß', 'ss')
        .replaceAll('ä', 'ae')
        .replaceAll('ö', 'oe')
        .replaceAll('ü', 'ue')
        .replaceAll(RegExp('[àáâãäå]'), 'a')
        .replaceAll(RegExp('[èéêë]'), 'e')
        .replaceAll(RegExp('[ìíîï]'), 'i')
        .replaceAll(RegExp('[òóôõö]'), 'o')
        .replaceAll(RegExp('[ùúûü]'), 'u')
        .replaceAll('ç', 'c')
        .replaceAll('ñ', 'n')
        .replaceAll(RegExp(r'\p{M}', unicode: true), '');
    return _word
        .allMatches(normalized)
        .map((match) => match.group(0)!)
        .toList(growable: false);
  }
}
