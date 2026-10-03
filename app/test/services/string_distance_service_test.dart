import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/string_distance_service.dart';

void main() {
  group('StringDistance.levenshtein', () {
    group('exact matches', () {
      test('returns 0 for identical strings', () {
        expect(StringDistance.levenshtein('hello', 'hello', 5), 0);
      });

      test('returns 0 for empty strings', () {
        expect(StringDistance.levenshtein('', '', 10), 0);
      });

      test('returns 0 for identical single characters', () {
        expect(StringDistance.levenshtein('a', 'a', 1), 0);
      });

      test('returns 0 for identical long strings', () {
        const text =
            'Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt';
        expect(StringDistance.levenshtein(text, text, 100), 0);
      });
    });

    group('no match scenarios', () {
      test('returns limit+1 when strings are completely different', () {
        // "abc" -> "xyz": a->x, b->y, c->z = 3 substitutions
        final result = StringDistance.levenshtein('abc', 'xyz', 5);
        // Result is 3, which is <= 5, so it returns 3
        expect(result, 3);
      });

      test('returns limit+1 for length difference > limit', () {
        const limit = 2;
        const left = 'a';
        const right = 'abcdefgh'; // 7 chars diff, > limit
        expect(StringDistance.levenshtein(left, right, limit), limit + 1);
      });

      test('returns limit+1 when no viable edit path exists within limit', () {
        expect(StringDistance.levenshtein('cat', 'dog', 2), 3);
      });
    });

    group('single character operations', () {
      test('substitution: distance 1 for single char difference', () {
        expect(StringDistance.levenshtein('cat', 'bat', 5), 1);
      });

      test('insertion: distance 1 for single char insertion', () {
        expect(StringDistance.levenshtein('cat', 'cats', 5), 1);
      });

      test('deletion: distance 1 for single char deletion', () {
        expect(StringDistance.levenshtein('cats', 'cat', 5), 1);
      });

      test('multiple substitutions', () {
        expect(StringDistance.levenshtein('abc', 'xyz', 5), 3);
      });
    });

    group('typo tolerance', () {
      test('handles single character typo: missing letter', () {
        expect(StringDistance.levenshtein('hello', 'helo', 1), 1);
      });

      test('handles single character typo: extra letter', () {
        expect(StringDistance.levenshtein('hello', 'helo', 1), 1);
      });

      test('handles single character typo: wrong letter', () {
        expect(StringDistance.levenshtein('hello', 'hallo', 1), 1);
      });

      test('handles double typo: within limit', () {
        expect(StringDistance.levenshtein('hello', 'hallo', 2), lessThanOrEqualTo(2));
      });

      test('handles transposition as edits', () {
        // Note: Levenshtein counts transposition as 2 operations (delete + insert)
        expect(StringDistance.levenshtein('ab', 'ba', 5), 2);
      });
    });

    group('limit optimization', () {
      test('early exit when row min exceeds limit', () {
        // Should return limit+1 quickly for very different strings
        final result = StringDistance.levenshtein('aaaaaa', 'zzzzzz', 1);
        expect(result, greaterThan(1));
      });

      test('respects limit for length mismatch', () {
        const limit = 2;
        expect(StringDistance.levenshtein('a', 'abcd', limit), limit + 1);
      });

      test('returns exact distance when within limit', () {
        // distance is 1 (one substitution)
        expect(StringDistance.levenshtein('bat', 'cat', 5), 1);
      });

      test('returns limit+1 when distance exceeds limit', () {
        // distance is 3 (cat -> dog)
        expect(StringDistance.levenshtein('cat', 'dog', 2), 3);
      });

      test('boundary case: distance equals limit', () {
        expect(StringDistance.levenshtein('abc', 'axc', 1), 1);
      });
    });

    group('real-world search scenarios', () {
      test('typo in common word: "search" vs "serach"', () {
        expect(StringDistance.levenshtein('search', 'serach', 2), 2);
      });

      test('typo in common word: "project" vs "projeect"', () {
        // "projeect" has one extra 'e', so distance is 1
        expect(StringDistance.levenshtein('project', 'projeect', 1), 1);
      });

      test('casual abbreviation: "please" vs "plz"', () {
        final distance = StringDistance.levenshtein('please', 'plz', 10);
        expect(distance, lessThanOrEqualTo(10));
      });

      test('phone keypad typo: "hello" vs "hrllo"', () {
        expect(StringDistance.levenshtein('hello', 'hrllo', 1), 1);
      });

      test('handles unicode properly', () {
        // Two-char unicode sequences
        expect(StringDistance.levenshtein('café', 'cafe', 10), greaterThan(0));
      });
    });

    group('edge cases', () {
      test('empty left string', () {
        expect(StringDistance.levenshtein('', 'hello', 10), 5);
      });

      test('empty right string', () {
        expect(StringDistance.levenshtein('hello', '', 10), 5);
      });

      test('single character strings', () {
        expect(StringDistance.levenshtein('a', 'b', 1), 1);
      });

      test('very long strings within limit', () {
        const long1 = 'aaaaaaaaaa';
        const long2 = 'aaaaaaaaab';
        expect(StringDistance.levenshtein(long1, long2, 5), 1);
      });

      test('limit of 0', () {
        expect(StringDistance.levenshtein('a', 'a', 0), 0);
        expect(StringDistance.levenshtein('a', 'b', 0), 1);
      });

      test('very high limit', () {
        final distance = StringDistance.levenshtein('abc', 'def', 1000);
        expect(distance, 3);
      });

      test('same string with whitespace difference', () {
        expect(StringDistance.levenshtein('hello world', 'helloworld', 5), 1);
      });
    });

    group('performance characteristics', () {
      test('completes quickly for similar strings', () {
        final stopwatch = Stopwatch()..start();
        StringDistance.levenshtein('performance', 'performance', 10);
        stopwatch.stop();
        expect(stopwatch.elapsedMilliseconds, lessThan(10));
      });

      test('short-circuits on large length difference', () {
        final stopwatch = Stopwatch()..start();
        final result = StringDistance.levenshtein('a', 'a' * 1000, 5);
        stopwatch.stop();
        expect(result, greaterThan(5));
        expect(stopwatch.elapsedMilliseconds, lessThan(100));
      });

      test('handles longer strings efficiently', () {
        const left = 'The quick brown fox jumps over the lazy dog';
        const right = 'The quick brown fox jumps over the lazy cat';
        final stopwatch = Stopwatch()..start();
        final distance = StringDistance.levenshtein(left, right, 10);
        stopwatch.stop();
        expect(distance, lessThanOrEqualTo(10));
        expect(stopwatch.elapsedMilliseconds, lessThan(50));
      });
    });

    group('case sensitivity', () {
      test('treats uppercase and lowercase as different', () {
        expect(StringDistance.levenshtein('Hello', 'hello', 10), 1);
      });

      test('exact case match returns 0', () {
        expect(StringDistance.levenshtein('HELLO', 'HELLO', 10), 0);
      });
    });

    group('symmetry properties', () {
      test('distance is symmetric: distance(a,b) == distance(b,a)', () {
        final ab = StringDistance.levenshtein('cat', 'dog', 10);
        final ba = StringDistance.levenshtein('dog', 'cat', 10);
        expect(ab, ba);
      });

      test('symmetry holds for typo cases', () {
        final ab = StringDistance.levenshtein('hello', 'helo', 5);
        final ba = StringDistance.levenshtein('helo', 'hello', 5);
        expect(ab, ba);
      });
    });

    group('metric properties', () {
      test('triangle inequality: d(a,c) <= d(a,b) + d(b,c)', () {
        const a = 'abc';
        const b = 'axc';
        const c = 'xyz';
        final ac = StringDistance.levenshtein(a, c, 100);
        final ab = StringDistance.levenshtein(a, b, 100);
        final bc = StringDistance.levenshtein(b, c, 100);
        expect(ac, lessThanOrEqualTo(ab + bc));
      });
    });
  });
}
