import 'dart:convert';
import 'dart:io';

import 'package:app/api_client.dart';
import 'package:app/services/discord_bot_import_service.dart';
import 'package:app/app_state.dart';
import 'package:app/services/local_vault_store.dart';
import 'package:app/services/shared_import_source.dart';
import 'package:app/services/export_file_reader.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sembast/sembast_memory.dart';

const backupFixture =
    '{"conversations":[{"title":"Atlas","segments":[{"text":"Atlas deadline"}]},{"title":"Travel","segments":[{"text":"Travel deadline"}]}]}';

class _ImportServer {
  final envelopes = <Map<String, dynamic>>[];
  final importSources = <String>[];
  Map<String, dynamic>? lastImport;
  bool failImport = false;
  Map<String, dynamic>? normalizedOverride;
  Future<http.Response> handle(http.Request request) async {
    Object body;
    final path = request.url.path;
    if (path.startsWith('/api/auth/')) {
      body = {
        'authToken': 'token',
        'userId': 'user',
        'vaultId': 'vault',
        'vaultSalt': 'stable-salt',
      };
    } else if (path == '/api/imports/capabilities') {
      body = [];
    } else if (path.startsWith('/api/imports/')) {
      lastImport = Map<String, dynamic>.from(jsonDecode(request.body));
      if (failImport) return http.Response('Invalid export', 400);
      final source = path.split('/').last;
      importSources.add(source);
      body = {
        'source': source,
        'plaintextCompute': true,
        'message': 'Normalized export',
        'participants': [],
        'conversations': [
          for (final title in ['Atlas', 'Travel'])
            {
              'title': title,
              'source': source,
              'participantNames': ['Alice'],
              'segments': [
                {
                  'text': '$title deadline',
                  'participantName': 'Alice',
                  'createdAt': '2025-06-15T09:00:00Z',
                },
              ],
            },
        ],
      };
    } else if (path == '/api/sync/push') {
      for (final raw in jsonDecode(request.body)['envelopes'] as List) {
        if (!envelopes.any((e) => e['id'] == raw['id'])) {
          envelopes.add({
            ...Map<String, dynamic>.from(raw),
            'serverSequence': envelopes.length + 1,
          });
        }
      }
      body = {'cursor': envelopes.length};
    } else if (path == '/api/sync/pull') {
      final since = int.parse(request.url.queryParameters['since']!);
      body = {
        'cursor': envelopes.length,
        'envelopes': envelopes
            .where((e) => (e['serverSequence'] as int) > since)
            .toList(),
      };
    } else {
      return http.Response('not found', 404);
    }
    if (path.startsWith('/api/imports/') &&
        path != '/api/imports/capabilities' &&
        normalizedOverride != null) {
      body = normalizedOverride!;
    }
    return http.Response(jsonEncode(body), 200);
  }
}

void main() {
  test(
    'export reader rejects declared oversize before reading and stops unknown-size streams at the bound',
    () async {
      var consumed = 0;
      Stream<List<int>> chunks() async* {
        for (var i = 0; i < 3; i++) {
          consumed++;
          yield [1, 2, 3];
        }
      }

      await expectLater(
        readExportBytes(
          PlatformFile(name: 'huge.json', size: 100, readStream: chunks()),
          maxBytes: 5,
        ),
        throwsFormatException,
      );
      expect(consumed, 0);
      await expectLater(
        readExportBytes(
          PlatformFile(name: 'unknown.json', size: 0, readStream: chunks()),
          maxBytes: 5,
        ),
        throwsFormatException,
      );
      expect(consumed, 2);
    },
  );
  test(
    'shared PDFs send binary content for extraction and preserve explicitly supplied OCR text',
    () async {
      final server = _ImportServer();
      final state = LifenizerAppState();
      await state.debugAuthenticateForTesting(
        LifenizerApiClient(
          baseUrl: 'https://vault.example.test',
          client: MockClient(server.handle),
        ),
      );
      await state.importSharedPayload(
        fileName: 'invoice.pdf',
        mimeType: 'application/pdf',
        bytes: [1, 2, 3],
      );
      expect(state.error, isNull);
      expect(server.importSources.last, 'scanned-pdf');
      expect(server.lastImport!['payloadBase64'], isNotEmpty);
      await state.importSharedPayload(
        fileName: 'scan.pdf',
        bytes: utf8.encode('%PDF-1.7 synthetic'),
      );
      expect(state.error, isNull);
      expect(server.importSources.last, 'scanned-pdf');
      expect(server.lastImport!['payloadBase64'], isNotEmpty);
      await state.importSharedPayload(
        fileName: 'invoice.pdf',
        mimeType: 'application/pdf',
        bytes: [1, 2, 3],
        text: 'Extracted invoice text',
      );
      expect(state.error, isNull);
      expect(server.importSources, [
        'scanned-pdf',
        'scanned-pdf',
        'scanned-pdf',
      ]);
      expect(server.lastImport!['text'], 'Extracted invoice text');
      state.dispose();
    },
  );
  test(
    'detects backup structures and WhatsApp before considering filenames',
    () {
      String source(String text, [String name = 'result.json']) =>
          detectSharedImportSource(
            fileName: name,
            mimeType: 'application/octet-stream',
            text: text,
          );
      expect(source(backupFixture), 'lifenizer-backup');
      expect(
        source('{"messages":[{"from":"Alice","text":"Atlas"}]}'),
        'telegram',
      );
      expect(source('{"chats":{"list":[]}}'), 'telegram');
      expect(
        source('[20.05.2026, 10:00] Alice: Atlas', 'backup.txt'),
        'whatsapp',
      );
      expect(
        source('5/20/2026, 9:41 AM - Alice: Atlas', 'notes.txt'),
        'whatsapp',
      );
      expect(
        detectSharedImportSource(
          fileName: 'WhatsApp Chat backup.zip',
          mimeType: 'application/zip',
        ),
        'whatsapp',
      );
      expect(() => source('{"unrecognized":"data"}'), throwsFormatException);
      expect(
        () => source('{"cipherText":"synthetic","nonce":"synthetic"}'),
        throwsFormatException,
      );
      expect(() => source('not valid JSON'), throwsFormatException);
      expect(() => source('sender,text', 'export.csv'), throwsFormatException);
      expect(
        () => detectSharedImportSource(
          fileName: 'backup.zip',
          mimeType: 'application/zip',
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'bot replies merge with exports, index counterparts and survive encrypted restart',
    () async {
      final server = _ImportServer();
      final disk = LocalVaultStore(
        await databaseFactoryMemory.openDatabase('bot-merge'),
      );
      final state = LifenizerAppState(
        localStore: disk,
        apiFactory: (url) =>
            LifenizerApiClient(baseUrl: url, client: MockClient(server.handle)),
      );
      addTearDown(() async {
        state.dispose();
        await disk.close();
      });
      Future<void> login({bool offline = false}) => state.login(
        baseUrl: 'https://vault.example.test',
        email: 'ekwav@example.test',
        passphrase: 'private test vault phrase',
        offline: offline,
      );
      await login();
      final own = normalizeDiscordBotMessages(
        {'id': '100', 'guild_id': '200', 'name': 'Project'},
        [
          {
            'id': '301',
            'author': {'id': '1', 'username': 'ekwav'},
            'content': 'Meet tomorrow',
            'timestamp': '2026-10-01T12:00:00Z',
          },
        ],
      );
      expect(await state.importDiscordBotBatch(own), isTrue);
      final conversationId = state.conversations.single.id;
      final bot = normalizeDiscordBotMessages(
        {'id': '100', 'guild_id': '200', 'name': 'Project'},
        [
          {
            'id': '301',
            'author': {'id': '1', 'username': 'ekwav'},
            'content': 'Meet tomorrow',
            'timestamp': '2026-10-01T12:00:00Z',
          },
          {
            'id': '302',
            'author': {'id': '2', 'username': 'carol'},
            'content': 'Rendezvous at noon',
            'timestamp': '2026-10-01T12:01:00Z',
          },
        ],
        ownUserId: '1',
      );
      expect(await state.importDiscordBotBatch(bot), isTrue);
      expect(state.conversations.single.id, conversationId);
      expect(state.conversations.single.segments, hasLength(2));
      expect(state.search('carol rendezvous').single.id, conversationId);
      expect(
        state.participants.where((p) => p.identifiers.contains('discord:2')),
        hasLength(1),
      );
      expect(jsonEncode(server.envelopes), isNot(contains('Rendezvous')));
      await state.lock();
      expect(await state.importDiscordBotBatch(bot), isFalse);
      await login(offline: true);
      expect(state.search('carol rendezvous').single.id, conversationId);
    },
  );

  test(
    'watched PDF bytes reach extraction and stable document text updates remain searchable',
    () async {
      final server = _ImportServer();
      Map<String, dynamic> extracted(String text) => {
        'source': 'scanned-pdf',
        'plaintextCompute': true,
        'message': 'Extracted PDF',
        'participants': [],
        'conversations': [
          {
            'title': 'Scan',
            'source': 'scanned-pdf',
            'sourceThreadId': 'scan:stable',
            'participantNames': [],
            'segments': [
              {
                'text': text,
                'sourceMessageId': 'scan:stable',
                'createdAt': '2026-10-01T12:00:00Z',
              },
            ],
          },
        ],
      };
      server.normalizedOverride = extracted('Invoice orchid amount 42');
      final disk = LocalVaultStore(
        await databaseFactoryMemory.openDatabase('document-import'),
      );
      final state = LifenizerAppState(
        localStore: disk,
        apiFactory: (url) =>
            LifenizerApiClient(baseUrl: url, client: MockClient(server.handle)),
      );
      final directory = await Directory.systemTemp.createTemp(
        'lifenizer-document-test-',
      );
      addTearDown(() async {
        state.dispose();
        await disk.close();
        await directory.delete(recursive: true);
      });
      await state.login(
        baseUrl: 'https://vault.example.test',
        email: 'alice@example.test',
        passphrase: 'private test vault phrase',
      );
      final file = File('${directory.path}/invoice.pdf');
      await file.writeAsBytes(
        utf8.encode('%PDF-1.7 synthetic transport fixture'),
      );
      expect(await state.importDocumentFile(file.path), isTrue);
      expect(
        server.lastImport!['payloadBase64'],
        base64Encode(await file.readAsBytes()),
      );
      final documentId = (server.lastImport!['metadata'] as Map)['documentId'];
      expect(documentId, isNot(contains(directory.path)));
      expect(state.search('orchid'), hasLength(1));
      server.normalizedOverride = extracted('Invoice violet amount 84');
      expect(await state.importDocumentFile(file.path), isTrue);
      expect((server.lastImport!['metadata'] as Map)['documentId'], documentId);
      expect(state.conversations, hasLength(1));
      expect(state.conversations.single.segments, hasLength(1));
      expect(state.search('violet'), hasLength(1));
      expect(state.search('orchid'), isEmpty);
      expect(jsonEncode(server.envelopes), isNot(contains('Invoice violet')));
      state.busy = true;
      expect(await state.importDocumentFile(file.path), isFalse);
      state.busy = false;
    },
  );

  test(
    'backup receipts survive encrypted restart and second-device sync; renamed repeat creates no duplicates',
    () async {
      final server = _ImportServer();
      final disk = LocalVaultStore(
        await databaseFactoryMemory.openDatabase('backup-receipts'),
      );
      LifenizerAppState device(LocalVaultStore store) => LifenizerAppState(
        localStore: store,
        apiFactory: (url) =>
            LifenizerApiClient(baseUrl: url, client: MockClient(server.handle)),
      );
      Future<void> login(LifenizerAppState state, {bool offline = false}) =>
          state.login(
            baseUrl: 'https://vault.example.test',
            email: 'alice@example.test',
            password: 'account password',
            passphrase: 'private vault phrase',
            offline: offline,
          );
      var state = device(disk);
      await login(state);
      final bytes = utf8.encode(backupFixture);
      await state.importSharedPayload(fileName: 'export.json', bytes: bytes);
      expect(state.error, isNull);
      expect(state.conversations, hasLength(2));
      final fingerprint = state.conversations.first.importFingerprint!;
      expect(
        state.search('atlas').single.startedAt,
        DateTime.utc(2025, 6, 15, 9),
      );
      await state.importSharedPayload(fileName: 'renamed.json', bytes: bytes);
      expect(state.conversations, hasLength(2));
      expect(state.status, contains('2 conversation(s) skipped'));
      final stored = jsonEncode(
        await disk.read(
          'vault:${jsonEncode(['https://vault.example.test', 'alice@example.test'])}',
        ),
      );
      expect(stored, isNot(contains(fingerprint)));
      expect(stored, isNot(contains('Atlas deadline')));
      expect(jsonEncode(server.envelopes), isNot(contains(fingerprint)));
      await state.lock();
      state.dispose();
      state = device(disk);
      await login(state, offline: true);
      await state.importSharedPayload(fileName: 'export.json', bytes: bytes);
      expect(state.error, isNull);
      expect(state.conversations, hasLength(2));
      expect(state.conversations.first.importFingerprint, fingerprint);
      final otherDisk = LocalVaultStore(
        await databaseFactoryMemory.openDatabase('backup-second-device'),
      );
      final other = device(otherDisk);
      await login(other);
      await other.importSharedPayload(fileName: 'export.json', bytes: bytes);
      expect(other.error, isNull);
      expect(other.conversations, hasLength(2));
      expect(
        server.envelopes.where((e) => e['entityType'] == 'conversation'),
        hasLength(2),
      );
      state.dispose();
      other.dispose();
      await disk.close();
      await otherDisk.close();
    },
  );

  test(
    'failed normalization leaves backup retryable and unknown JSON never becomes manual text',
    () async {
      final server = _ImportServer()..failImport = true;
      final state = LifenizerAppState();
      await state.debugAuthenticateForTesting(
        LifenizerApiClient(
          baseUrl: 'https://vault.example.test',
          client: MockClient(server.handle),
        ),
      );
      await state.importSource(source: 'lifenizer-backup', text: backupFixture);
      expect(state.error, isNotNull);
      expect(state.conversations, isEmpty);
      server.failImport = false;
      await state.importSource(source: 'lifenizer-backup', text: backupFixture);
      expect(state.error, isNull);
      expect(state.conversations, hasLength(2));
      await state.importSharedPayload(
        fileName: 'result.json',
        bytes: utf8.encode('{"unsupported":true}'),
      );
      expect(state.error, contains('Unrecognized JSON'));
      expect(state.conversations, hasLength(2));
      state.dispose();
    },
  );
}
