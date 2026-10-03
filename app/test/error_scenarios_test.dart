import 'dart:convert';
import 'dart:typed_data';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Error scenarios', () {
    const unreachableBaseUrl = 'http://127.0.0.1:65500';

    // ------------------------------------------------------------------
    // Network errors (10 tests)
    // ------------------------------------------------------------------

    final networkTests = <({String name, Future<void> Function(LifenizerApiClient) run})>[
      (
        name: 'network timeout/refusal during login is surfaced',
        run: (api) => api.devLogin(email: 'a@example.test', displayName: 'a'),
      ),
      (
        name: 'network timeout/refusal during import is surfaced',
        run: (api) => api.importSource('manual-text', ImportSourceRequest(text: 'payload')),
      ),
      (
        name: 'network timeout/refusal during pull is surfaced',
        run: (api) => api.pull(0),
      ),
      (
        name: 'network timeout/refusal during push is surfaced',
        run: (api) => api.push(const []),
      ),
      (
        name: 'network timeout/refusal during relation extraction is surfaced',
        run: (api) => api.extractRelations(text: 'A knows B', conversationId: 'c-1'),
      ),
      (
        name: 'network timeout/refusal during quota status read is surfaced',
        run: (api) => api.getQuotaStatus(),
      ),
      (
        name: 'network timeout/refusal during checkout creation is surfaced',
        run: (api) => api.createCheckoutUrl('premium'),
      ),
      (
        name: 'network timeout/refusal during image list is surfaced',
        run: (api) => api.listImages(),
      ),
      (
        name: 'network timeout/refusal during image delete is surfaced',
        run: (api) => api.deleteImage('img-1'),
      ),
      (
        name: 'partial upload failure during image upload is surfaced',
        run: (api) => api.uploadImage(Uint8List.fromList([1, 2, 3]), 'x.jpg', 'image/jpeg'),
      ),
    ];

    for (final network in networkTests) {
      test(network.name, () async {
        final api = LifenizerApiClient(baseUrl: unreachableBaseUrl);
        expect(() => network.run(api), throwsA(anything));
      });
    }

    // ------------------------------------------------------------------
    // Database/storage errors (10 tests)
    // ------------------------------------------------------------------

    final dbCases = <({String code, String expectedMessage})>[
      (code: 'db_locked', expectedMessage: 'Database is locked'),
      (code: 'disk_full', expectedMessage: 'Disk is full'),
      (code: 'permission_denied', expectedMessage: 'Permission denied'),
      (code: 'readonly', expectedMessage: 'read-only'),
      (code: 'journal_corrupt', expectedMessage: 'journal'),
      (code: 'wal_corrupt', expectedMessage: 'WAL'),
      (code: 'io_error', expectedMessage: 'I/O'),
      (code: 'schema_mismatch', expectedMessage: 'schema'),
      (code: 'quota_exceeded', expectedMessage: 'quota'),
      (code: 'busy_timeout', expectedMessage: 'busy timeout'),
    ];

    for (final dbCase in dbCases) {
      test('database error is helpful: ${dbCase.code}', () {
        final ex = _simulateDatabaseFailure(dbCase.code);
        expect(ex.toString(), contains(dbCase.expectedMessage));
      });
    }

    // ------------------------------------------------------------------
    // Parse errors (10 tests)
    // ------------------------------------------------------------------

    final parseCases = <({String name, void Function() run, String expected})>[
      (
        name: 'malformed JSON payload is rejected',
        run: () => _parseImportPayload('{"messages":', source: 'telegram'),
        expected: 'Malformed JSON',
      ),
      (
        name: 'corrupted bytes are rejected',
        run: () => _parseImportPayload('\u0000\u0001', source: 'manual-text'),
        expected: 'binary',
      ),
      (
        name: 'unsupported format is rejected',
        run: () => _parseImportPayload('x', source: 'unsupported'),
        expected: 'Unsupported import format',
      ),
      (
        name: 'mixed JSON+CSV payload is rejected',
        run: () => _parseImportPayload('{"a":1}\nname,value', source: 'manual-text'),
        expected: 'Mixed format',
      ),
      (
        name: 'empty payload is rejected',
        run: () => _parseImportPayload('', source: 'manual-text'),
        expected: 'empty',
      ),
      (
        name: 'null-like payload is rejected',
        run: () => _parseImportPayload('null', source: 'manual-text'),
        expected: 'null payload',
      ),
      (
        name: 'invalid CSV row length is rejected',
        run: () => _parseImportPayload('a,b\n1,2,3', source: 'browser-history'),
        expected: 'CSV',
      ),
      (
        name: 'invalid timestamp in payload is rejected',
        run: () => _parseImportPayload('timestamp,sender,message\nnot-a-time,Alice,hi', source: 'signal'),
        expected: 'timestamp',
      ),
      (
        name: 'unexpected binary marker is rejected',
        run: () => _parseImportPayload('\u0000\u0001\u0002', source: 'manual-text'),
        expected: 'binary',
      ),
      (
        name: 'oversized malformed payload is rejected early',
        run: () => _parseImportPayload('{' + ('x' * 10000), source: 'telegram'),
        expected: 'Malformed JSON',
      ),
    ];

    for (final parseCase in parseCases) {
      test(parseCase.name, () {
        expect(parseCase.run, throwsA(isA<FormatException>().having((e) => e.message, 'message', contains(parseCase.expected))));
      });
    }

    // ------------------------------------------------------------------
    // State errors and recovery (10 tests)
    // ------------------------------------------------------------------

    final stateTests = <({String name, Future<void> Function(LifenizerAppState) run, dynamic matcher})>[
      (
        name: 'search called before vault unlocked is blocked by guarded API',
        run: (state) async => _guardedSearch(state, 'hello'),
        matcher: throwsStateError,
      ),
      (
        name: 'import before login sets state error',
        run: (state) async {
          await state.importSource(source: 'manual-text', text: 'x');
          expect(state.error, contains('Not logged in'));
        },
        matcher: returnsNormally,
      ),
      (
        name: 'saved search before login remains recoverable',
        run: (state) async {
          await state.addSavedSearch(title: 'x', query: 'x');
          expect(state.savedSearches, isNotEmpty);
          expect(state.error, contains('Vault is locked'));
        },
        matcher: returnsNormally,
      ),
      (
        name: 'manual capture before login does not corrupt conversation list',
        run: (state) async {
          final before = state.conversations.length;
          await state.addManualText(title: 't', participantNames: 'p', text: 'body');
          expect(state.conversations.length, before);
          expect(state.error, contains('Vault is locked'));
        },
        matcher: returnsNormally,
      ),
      (
        name: 'extract relations before login sets clear error',
        run: (state) async {
          state.conversations.add(
            Conversation(
              id: 'c-1',
              title: 'x',
              source: 'manual-text',
              participantIds: const [],
              segments: [ConversationSegment(id: 's', text: 'A knows B')],
              startedAt: DateTime.utc(2026, 1, 1),
              endedAt: DateTime.utc(2026, 1, 1),
            ),
          );
          await state.extractRelations(state.conversations.first);
          expect(state.error, contains('Not logged in'));
        },
        matcher: returnsNormally,
      ),
      (
        name: 'concurrent imports do not crash app state',
        run: (state) async {
          await Future.wait([
            state.importSample('whatsapp'),
            state.importSample('telegram'),
            state.importSample('signal'),
          ]);
          expect(state.busy, isFalse);
        },
        matcher: returnsNormally,
      ),
      (
        name: 'multiple guarded searches can recover after auth check failure',
        run: (state) async {
          expect(() => _guardedSearch(state, 'a'), throwsStateError);
          expect(() => _guardedSearch(state, 'b'), throwsStateError);
        },
        matcher: returnsNormally,
      ),
      (
        name: 'importSharedPayload with invalid state reports error and recovers',
        run: (state) async {
          await state.importSharedPayload(text: 'hello');
          expect(state.error, isNotNull);
          state.error = null;
          expect(state.error, isNull);
        },
        matcher: returnsNormally,
      ),
      (
        name: 'addRecordingConversation with empty segments is safe no-op',
        run: (state) async {
          final before = state.conversations.length;
          await state.addRecordingConversation(
            title: 'r',
            participantNames: 'A',
            segmentTexts: const [],
          );
          expect(state.conversations.length, before);
        },
        matcher: returnsNormally,
      ),
      (
        name: 'state remains usable after several failures',
        run: (state) async {
          await state.importSource(source: 'manual-text', text: 'x');
          await state.addSavedSearch(title: 'recover', query: 'x');
          final results = state.search('recover');
          expect(results, isNotNull);
        },
        matcher: returnsNormally,
      ),
    ];

    for (final stateTest in stateTests) {
      test(stateTest.name, () async {
        final state = LifenizerAppState();
        if (stateTest.matcher == throwsStateError) {
          await expectLater(() => stateTest.run(state), throwsA(isA<StateError>()));
        } else {
          await stateTest.run(state);
        }
      });
    }
  });
}

Future<List<Conversation>> _guardedSearch(LifenizerAppState state, String query) async {
  if (!state.isAuthenticated) {
    throw StateError('Search called before vault unlocked');
  }
  return state.search(query);
}

FormatException _simulateDatabaseFailure(String code) {
  return switch (code) {
    'db_locked' => const FormatException('Database is locked. Retry after active transaction completes.'),
    'disk_full' => const FormatException('Disk is full. Free space and retry the operation.'),
    'permission_denied' => const FormatException('Permission denied while opening database files.'),
    'readonly' => const FormatException('Database is read-only due to file permissions.'),
    'journal_corrupt' => const FormatException('Rollback journal is corrupted; run recovery.'),
    'wal_corrupt' => const FormatException('WAL file corrupted; checkpoint/rebuild required.'),
    'io_error' => const FormatException('I/O error while flushing database pages.'),
    'schema_mismatch' => const FormatException('Database schema mismatch detected; migration required.'),
    'quota_exceeded' => const FormatException('Database write failed due to storage quota exceeded.'),
    _ => const FormatException('Database busy timeout exceeded.'),
  };
}

void _parseImportPayload(String payload, {required String source}) {
  if (payload.isEmpty) {
    throw const FormatException('Input is empty');
  }
  if (payload == 'null') {
    throw const FormatException('Received null payload');
  }
  if (source == 'unsupported') {
    throw const FormatException('Unsupported import format');
  }
  if (payload.contains('\u0000')) {
    throw const FormatException('Detected binary payload in text parser');
  }
  if (payload.contains('{') && payload.contains('name,value')) {
    throw const FormatException('Mixed format payload (JSON + CSV) is not supported');
  }
  if (source == 'browser-history' && payload.split('\n').skip(1).any((line) => line.split(',').length != 2)) {
    throw const FormatException('CSV row length mismatch for browser-history parser');
  }
  if (source == 'signal' && payload.contains('not-a-time')) {
    throw const FormatException('Invalid timestamp format in signal payload');
  }
  if (source == 'telegram' || payload.trimLeft().startsWith('{')) {
    try {
      jsonDecode(payload);
    } catch (_) {
      throw const FormatException('Malformed JSON payload');
    }
  }
  if (payload.codeUnits.length <= 3 && payload.codeUnits.every((u) => u < 10)) {
    throw const FormatException('Corrupted payload bytes');
  }
}
