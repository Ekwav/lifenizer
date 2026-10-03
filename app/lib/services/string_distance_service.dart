import 'dart:collection';

/// String distance calculation utilities for fuzzy matching.
///
/// Provides efficient Levenshtein distance computation with bounded early exit
/// for typo tolerance in search.
class StringDistance {
  static const int _cacheCapacity = 1024;
  static final LinkedHashMap<_DistanceCacheKey, int> _cache =
      LinkedHashMap<_DistanceCacheKey, int>();

  /// Computes the Levenshtein edit distance between [left] and [right].
  ///
  /// Returns at most [limit] + 1 if the actual distance exceeds [limit],
  /// enabling early exit without computing the full matrix.
  ///
  /// Parameters:
  /// - [left]: First string to compare
  /// - [right]: Second string to compare
  /// - [limit]: Maximum distance to compute before early exit
  ///
  /// Returns: The edit distance, capped at [limit] + 1 for efficiency
  static int levenshtein(String left, String right, int limit) {
    if (identical(left, right) || left == right) {
      return 0;
    }

    if (limit <= 0) {
      return 1;
    }

    final leftLength = left.length;
    final rightLength = right.length;

    if (leftLength == 0) {
      return rightLength <= limit ? rightLength : limit + 1;
    }
    if (rightLength == 0) {
      return leftLength <= limit ? leftLength : limit + 1;
    }

    if ((leftLength - rightLength).abs() > limit) {
      return limit + 1;
    }

    final shouldCache = (leftLength + rightLength) >= 128;
    _DistanceCacheKey? cacheKey;
    if (shouldCache) {
      cacheKey = _normalizedKey(left, right, limit);
      final cached = _cache.remove(cacheKey);
      if (cached != null) {
        // Reinsert to keep hot entries near the end (LRU-ish behavior).
        _cache[cacheKey] = cached;
        return cached;
      }
    }

    var previous = List<int>.generate(rightLength + 1, (index) => index);
    var current = List<int>.filled(rightLength + 1, 0);
    for (var i = 1; i <= leftLength; i++) {
      current[0] = i;
      var rowMin = current[0];
      for (var j = 1; j <= rightLength; j++) {
        final cost = left.codeUnitAt(i - 1) == right.codeUnitAt(j - 1) ? 0 : 1;
        final deletion = previous[j] + 1;
        final insertion = current[j - 1] + 1;
        final substitution = previous[j - 1] + cost;
        var min = deletion < insertion ? deletion : insertion;
        if (substitution < min) {
          min = substitution;
        }
        current[j] = min;
        if (min < rowMin) {
          rowMin = min;
        }
      }
      if (rowMin > limit) {
        final result = limit + 1;
        if (cacheKey != null) {
          _putCache(cacheKey, result);
        }
        return result;
      }
      final swap = previous;
      previous = current;
      current = swap;
    }
    final result = previous[rightLength];
    if (cacheKey != null) {
      _putCache(cacheKey, result);
    }
    return result;
  }

  static _DistanceCacheKey _normalizedKey(
    String left,
    String right,
    int limit,
  ) {
    if (left.length < right.length) {
      return _DistanceCacheKey(left, right, limit);
    }
    if (left.length > right.length) {
      return _DistanceCacheKey(right, left, limit);
    }
    if (left.compareTo(right) <= 0) {
      return _DistanceCacheKey(left, right, limit);
    }
    return _DistanceCacheKey(right, left, limit);
  }

  static void _putCache(_DistanceCacheKey key, int value) {
    _cache[key] = value;
    if (_cache.length > _cacheCapacity) {
      _cache.remove(_cache.keys.first);
    }
  }
}

class _DistanceCacheKey {
  const _DistanceCacheKey(this.left, this.right, this.limit);

  final String left;
  final String right;
  final int limit;

  @override
  bool operator ==(Object other) {
    return other is _DistanceCacheKey &&
        left == other.left &&
        right == other.right &&
        limit == other.limit;
  }

  @override
  int get hashCode => Object.hash(left, right, limit);
}
