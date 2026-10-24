import 'dart:collection';
import 'dart:math' as math;

import '../models.dart';
import 'string_distance_service.dart';

typedef SearchIndexInputs = (
  List<Conversation>,
  Map<String, String>,
  Map<String, String>,
);

class SearchIndexProgress {
  const SearchIndexProgress(
    this.completed,
    this.total, {
    this.finalizing = false,
  });
  final int completed;
  final int total;
  final bool finalizing;
}

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
    this.detailsLoaded = true,
  });

  Conversation conversation;
  String haystack;
  Set<String> titleTokens;
  Set<String> personTokens;
  final Set<String> tagSet;
  Map<String, int> termFrequency;
  bool detailsLoaded;
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
  final Set<String> _unloadedPostingTerms = {};
  Set<String> get unloadedPostingTerms =>
      UnmodifiableSetView(_unloadedPostingTerms);
  bool get postingsLoaded => _unloadedPostingTerms.isEmpty;
  Map<String, double> idf;
  double averageLength;
  static final _digits = RegExp(r'^\d+$');
  static final _word = RegExp(r'[\p{L}\p{N}\p{M}]+', unicode: true);

  /// Stores prepared search data and lightweight conversation summaries. Terms
  /// and posting document IDs are represented by positions to avoid repeating
  /// strings throughout the snapshot.
  Map<String, dynamic> toJson({
    bool includeDetails = true,
    bool includePostings = true,
  }) {
    if (includePostings && !postingsLoaded) {
      throw StateError('Load search postings before saving the full index');
    }
    if (_pendingNorms.isNotEmpty) {
      throw StateError('Refresh search statistics before saving the index');
    }
    final terms = invertedIndex.keys.toList();
    final termIds = {
      if (includeDetails)
        for (var i = 0; i < terms.length; i++) terms[i]: i,
    };
    final ids = documents.keys.toList();
    final documentIds = {
      if (includePostings)
        for (var i = 0; i < ids.length; i++) ids[i]: i,
    };
    return {
      'version': 1,
      if (!includeDetails) 'detailsLoaded': false,
      'terms': terms,
      'idf': [for (final term in terms) idf[term]],
      if (includePostings)
        'postings': [
          for (final term in terms)
            [for (final id in invertedIndex[term]!) documentIds[id]!],
        ],
      'averageLength': averageLength,
      'documents': [
        for (final doc in documents.values)
          [
            doc.conversation.toSummaryJson(
              previewLength: includeDetails ? 500 : 180,
            ),
            includeDetails ? doc.haystack : '',
            includeDetails ? doc.titleTokens.toList() : const <String>[],
            includeDetails ? doc.personTokens.toList() : const <String>[],
            doc.tagSet.toList(),
            [
              if (includeDetails)
                for (final entry in doc.termFrequency.entries) ...[
                  termIds[entry.key]!,
                  entry.value,
                ],
            ],
            doc.vectorNorm,
            doc.length,
          ],
      ],
    };
  }

  /// Contiguous ranges preserve document and vocabulary ordering after merging.
  List<Map<String, dynamic>> toCatalogShards(int count) {
    if (count < 1) throw ArgumentError.value(count, 'count');
    final catalog = toJson(includeDetails: false, includePostings: false);
    final terms = catalog['terms'] as List;
    final weights = catalog['idf'] as List;
    final rows = catalog['documents'] as List;
    List<dynamic> slice(List<dynamic> values, int n) => values.sublist(
      values.length * n ~/ count,
      values.length * (n + 1) ~/ count,
    );
    return [
      for (var n = 0; n < count; n++)
        {
          ...catalog,
          'terms': slice(terms, n),
          'idf': slice(weights, n),
          'documents': slice(rows, n),
        },
    ];
  }

  static ConversationSearchIndex mergeCatalogs(
    List<ConversationSearchIndex> shards,
  ) {
    if (shards.isEmpty) throw const FormatException('Missing catalog shards');
    final merged = ConversationSearchIndex._(
      {},
      {},
      {},
      shards.first.averageLength,
    );
    for (final shard in shards) {
      if (shard.averageLength != merged.averageLength ||
          shard.documents.values.any((doc) => doc.detailsLoaded) ||
          shard.invertedIndex.values.any((ids) => ids.isNotEmpty)) {
        throw const FormatException('Invalid catalog shard');
      }
      final docs = merged.documents.length + shard.documents.length;
      final terms = merged.idf.length + shard.idf.length;
      merged.documents.addAll(shard.documents);
      merged.invertedIndex.addAll(shard.invertedIndex);
      merged.idf.addAll(shard.idf);
      merged._unloadedPostingTerms.addAll(shard._unloadedPostingTerms);
      if (merged.documents.length != docs || merged.idf.length != terms) {
        throw const FormatException('Duplicate catalog shard entries');
      }
    }
    return merged;
  }

  /// Restores the prepared index without tokenizing text or recomputing scores.
  static ConversationSearchIndex fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unsupported search index version');
    }
    final terms = (json['terms'] as List).cast<String>();
    final docs = <String, IndexedConversation>{};
    for (final value in json['documents'] as List) {
      final row = value as List;
      final conversation = Conversation.fromSummaryJson(
        row[0] as Map<String, dynamic>,
      );
      final frequency = row[5] as List;
      docs[conversation.id] = IndexedConversation(
        conversation: conversation,
        haystack: row[1] as String,
        titleTokens: (row[2] as List).cast<String>().toSet(),
        personTokens: (row[3] as List).cast<String>().toSet(),
        tagSet: (row[4] as List).cast<String>().toSet(),
        termFrequency: {
          for (var i = 0; i < frequency.length; i += 2)
            terms[frequency[i] as int]: frequency[i + 1] as int,
        },
        vectorNorm: (row[6] as num).toDouble(),
        length: row[7] as int,
        detailsLoaded: json['detailsLoaded'] as bool? ?? true,
      );
    }
    final ids = docs.keys.toList();
    final postings = json['postings'] as List?;
    final weights = json['idf'] as List;
    final index = ConversationSearchIndex._(
      docs,
      {
        for (var i = 0; i < terms.length; i++)
          terms[i]: postings == null
              ? const <String>{}
              : {for (final id in postings[i] as List) ids[id as int]},
      },
      {
        for (var i = 0; i < terms.length; i++)
          terms[i]: (weights[i] as num).toDouble(),
      },
      (json['averageLength'] as num).toDouble(),
    );
    if (postings == null) index._unloadedPostingTerms.addAll(terms);
    return index;
  }

  /// Load a term bucket once; later bucket reads cannot replace current postings.
  /// All postings must be loaded before editing documents or refreshing scores.
  void loadPostings(Map<String, dynamic> postings) {
    for (final entry in postings.entries) {
      if (!_unloadedPostingTerms.contains(entry.key)) continue;
      final ids = (entry.value as List)
          .cast<String>()
          .where(documents.containsKey)
          .toSet();
      invertedIndex[entry.key] = ids;
      _unloadedPostingTerms.remove(entry.key);
    }
  }

  /// Attach a decoded detail bucket without replacing live conversations or
  /// overwriting a newer upsert that completed while the bucket was loading.
  void loadDetails(Map<String, dynamic> details) {
    for (final entry in details.entries) {
      final document = documents[entry.key];
      if (document == null || document.detailsLoaded) continue;
      final data = entry.value as Map;
      final haystack = data['haystack'] as String;
      final frequency = Map<String, int>.from(data['termFrequency'] as Map);
      document.haystack = haystack;
      document.termFrequency = frequency;
      if (data['titleTokens'] case final List tokens) {
        document.titleTokens = tokens.cast<String>().toSet();
      }
      if (data['personTokens'] case final List tokens) {
        document.personTokens = tokens.cast<String>().toSet();
      }
      document.detailsLoaded = true;
    }
  }

  static ConversationSearchIndex build({
    required List<Conversation> conversations,
    required Map<String, String> participantById,
    required Map<String, String> relationTextByConversation,
    void Function(SearchIndexProgress)? onProgress,
  }) {
    final progressClock = Stopwatch()..start();
    void report(int completed, {bool finalizing = false, bool force = false}) {
      if (onProgress == null ||
          (!force && progressClock.elapsedMilliseconds < 150)) {
        return;
      }
      progressClock.reset();
      onProgress(
        SearchIndexProgress(
          completed,
          conversations.length,
          finalizing: finalizing,
        ),
      );
    }

    report(0, force: true);
    final docs = <String, IndexedConversation>{};
    final inverted = <String, Set<String>>{};
    for (final conversation in conversations) {
      docs[conversation.id] = _analyze(
        conversation,
        participantById,
        relationTextByConversation,
        inverted,
      );
      report(docs.length);
    }
    report(docs.length, force: true);
    report(0, finalizing: true, force: true);
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
      report(withNorm.length, finalizing: true);
    }
    report(withNorm.length, finalizing: true, force: true);
    return ConversationSearchIndex._(
      withNorm,
      inverted,
      idf,
      docs.isEmpty ? 1 : math.max(1.0, totalLength / docs.length),
    );
  }

  static IndexedConversation _analyze(
    Conversation conversation,
    Map<String, String> participantById,
    Map<String, String> relationTextByConversation,
    Map<String, Set<String>> inverted,
  ) {
    final participantText = {
      ...conversation.participantIds,
      ...conversation.segments
          .map((segment) => segment.participantId)
          .whereType<String>(),
    }.map((id) => participantById[id] ?? id).join(' ');
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
    return IndexedConversation(
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

  static double _norm(IndexedConversation doc, Map<String, double> idf) {
    final sum = doc.termFrequency.entries.fold(0.0, (sum, term) {
      final weight = (1 + math.log(term.value)) * (idf[term.key] ?? 0);
      return sum + weight * weight;
    });
    return math.sqrt(sum);
  }

  static Map<String, double> _idf(
    Map<String, Set<String>> inverted,
    int documentCount,
  ) => {
    for (final entry in inverted.entries)
      entry.key: math.log(
        1 +
            (documentCount - entry.value.length + 0.5) /
                (entry.value.length + 0.5),
      ),
  };

  /// Insert or replace one conversation without rebuilding the corpus. IDF and
  /// the average length are recomputed (O(vocabulary)) and only this document's
  /// vector norm is refreshed; other norms stay slightly stale until the next
  /// full build, which affects only the vector-similarity tie-breaking.
  /// Pass `refresh: false` when applying a batch and call [refreshStatistics].
  void upsert(
    Conversation conversation, {
    required Map<String, String> participantById,
    required Map<String, String> relationTextByConversation,
    bool refresh = true,
  }) {
    _detach(conversation.id);
    final document = _analyze(
      conversation,
      participantById,
      relationTextByConversation,
      invertedIndex,
    );
    documents[conversation.id] = document;
    _pendingNorms.add(conversation.id);
    if (refresh) refreshStatistics();
  }

  void remove(String id, {bool refresh = true}) {
    _detach(id);
    documents.remove(id);
    _pendingNorms.remove(id);
    if (refresh) refreshStatistics();
  }

  final Set<String> _pendingNorms = <String>{};

  void _detach(String id) {
    if (!postingsLoaded) {
      throw StateError('Load search postings before editing the index');
    }
    final previous = documents[id];
    if (previous == null) return;
    for (final token
        in previous.detailsLoaded
            ? previous.termFrequency.keys
            : invertedIndex.keys.toList()) {
      final ids = invertedIndex[token];
      if (ids == null) continue;
      ids.remove(id);
      if (ids.isEmpty) invertedIndex.remove(token);
    }
  }

  void refreshStatistics() {
    if (!postingsLoaded) {
      throw StateError('Load search postings before refreshing statistics');
    }
    idf = _idf(invertedIndex, documents.length);
    var totalLength = 0;
    for (final doc in documents.values) {
      totalLength += doc.length;
    }
    averageLength = documents.isEmpty
        ? 1
        : math.max(1.0, totalLength / documents.length);
    for (final id in _pendingNorms) {
      final doc = documents[id];
      if (doc == null) continue;
      documents[id] = IndexedConversation(
        conversation: doc.conversation,
        haystack: doc.haystack,
        titleTokens: doc.titleTokens,
        personTokens: doc.personTokens,
        tagSet: doc.tagSet,
        termFrequency: doc.termFrequency,
        vectorNorm: _norm(doc, idf),
        length: doc.length,
      );
    }
    _pendingNorms.clear();
  }

  /// Point every indexed document at the live conversation instance (a full
  /// build in an isolate returns copies).
  void rebind(Map<String, Conversation> current) {
    for (final entry in documents.entries) {
      final live = current[entry.key];
      if (live != null) entry.value.conversation = live;
    }
  }

  Map<String, Map<String, double>> expandTokens(List<String> tokens) {
    final expansions = <String, Map<String, double>>{};
    for (final token in tokens.toSet()) {
      if (_digits.hasMatch(token)) {
        expansions[token] = invertedIndex.containsKey(token) ? {token: 1} : {};
        continue;
      }
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
        final tf =
            document.termFrequency[entry.key] ??
            (!document.detailsLoaded &&
                    invertedIndex[entry.key]?.contains(
                          document.conversation.id,
                        ) ==
                        true
                ? 1
                : 0);
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
    final normalized = fold(text);
    return _word
        .allMatches(normalized)
        .map((match) => match.group(0)!)
        .toList(growable: false);
  }

  /// Lowercases and folds accents the way [tokenize] does.
  static String fold(String text) {
    return text
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
  }
}
