import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:app/services/discord_bot_import_service.dart';

class MemoryStore extends DiscordBotCredentialStore {
  Map<String, dynamic>? account;
  @override
  Future<Map<String, dynamic>?> read(String identity) async => null;
  @override
  Future<void> write(String identity, Map<String, dynamic> value) async {
    account = jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
  }

  @override
  Future<void> remove(String identity) async {
    account = null;
  }
}

Map<String, dynamic> message(
  String id,
  String user,
  String name,
  String text,
) => {
  'id': id,
  'author': {'id': user, 'username': name},
  'content': text,
  'timestamp': '2026-10-04T12:00:00Z',
  'attachments': [],
};
void main() {
  test(
    'Real authors and replies share archive identifiers and stable links',
    () {
      final result = normalizeDiscordBotMessages(
        {'id': '123', 'guild_id': '456', 'name': 'general'},
        [
          message('102', '9', 'other', 'reply'),
          message('101', '8', 'ekwav', 'hello'),
        ],
        ownUserId: '8',
      );
      final conversation = result.conversations.single;
      expect(conversation.sourceThreadId, 'discord:123');
      expect(conversation.sourceUrl, 'https://discord.com/channels/456/123');
      expect(conversation.participantIdentifiers, ['discord:9', 'discord:8']);
      expect(conversation.segments.map((s) => s.sourceMessageId), [
        '101',
        '102',
      ]);
      expect(conversation.segments.map((s) => s.participantIdentifier), [
        'discord:8',
        'discord:9',
      ]);
      expect(conversation.metadata['ownDiscordId'], '8');
      expect(result.plaintextCompute, false);
    },
  );
  test('Attachment-only messages retain real author and original ID', () {
    final m = message('101', '8', 'ekwav', '');
    m['attachments'] = [
      {'url': 'https://cdn.discordapp.com/x.pdf'},
    ];
    final result = normalizeDiscordBotMessages(
      {'id': '123', 'guild_id': '456'},
      [m],
    );
    expect(result.conversations.single.segments.single.attachmentUrls, [
      'https://cdn.discordapp.com/x.pdf',
    ]);
  });
  test(
    'Refuses a personal-account token before reading server channels',
    () async {
      final paths = <String>[];
      final client = MockClient((request) async {
        paths.add(request.url.path);
        expect(request.headers['Authorization'], 'Bot secret');
        return http.Response('{"id":"8","bot":false}', 200);
      });
      final service = DiscordBotImportService(
        liveUpdates: false,
        ingest: (_) async => true,
        store: MemoryStore(),
        client: client,
      );
      service.setIdentity('test');
      await Future<void>.delayed(Duration.zero);
      await service.connect(token: 'secret', channels: ['123']);
      expect(service.error, contains('bot token'));
      expect(paths, ['/api/v10/users/@me']);
      expect(service.connected, false);
      service.dispose();
    },
  );
  test(
    'Paused encrypted ingestion does not advance or persist history cursor',
    () async {
      final store = MemoryStore();
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/users/@me')) {
          return http.Response('{"id":"7","bot":true}', 200);
        }
        if (request.url.path.endsWith('/channels/123')) {
          return http.Response(
            '{"id":"123","guild_id":"456","name":"general"}',
            200,
          );
        }
        return http.Response(
          jsonEncode([message('101', '8', 'ekwav', 'hello')]),
          200,
        );
      });
      final service = DiscordBotImportService(
        liveUpdates: false,
        ingest: (_) async => false,
        store: store,
        client: client,
      );
      service.setIdentity('test');
      await Future<void>.delayed(Duration.zero);
      await service.connect(token: 'secret', channels: ['123']);
      expect((store.account!['cursors'] as Map).isEmpty, true);
      expect(service.status, contains('waiting'));
      service.dispose();
    },
  );
  test(
    'History resumes before oldest saved message and then fetches missed replies',
    () async {
      final store = MemoryStore();
      final queries = <Map<String, String>>[];
      var calls = 0;
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/users/@me')) {
          return http.Response('{"id":"7","bot":true}', 200);
        }
        if (request.url.path.endsWith('/channels/123')) {
          return http.Response('{"id":"123","guild_id":"456"}', 200);
        }
        queries.add(request.url.queryParameters);
        calls++;
        return http.Response(
          jsonEncode(
            calls == 1
                ? [message('101', '8', 'ekwav', 'hello')]
                : [message('102', '9', 'other', 'reply')],
          ),
          200,
        );
      });
      final imported = <String>[];
      final service = DiscordBotImportService(
        liveUpdates: false,
        ingest: (r) async {
          imported.addAll(
            r.conversations.single.segments.map((s) => s.sourceMessageId!),
          );
          return true;
        },
        store: store,
        client: client,
      );
      service.setIdentity('test');
      await Future<void>.delayed(Duration.zero);
      await service.connect(token: 'secret', channels: ['123']);
      await service.fetch();
      expect(imported, ['101', '102']);
      expect(queries.last['after'], '101');
      expect((store.account!['cursors'] as Map)['123']['latest'], '102');
      expect(
        (store.account!['cursors'] as Map)['123']['historyComplete'],
        true,
      );
      service.dispose();
    },
  );
  test(
    'Bursts of complete live messages ingest once per channel and retain busy batches',
    () async {
      final store = MemoryStore();
      final batches = <int>[];
      var accept = false;
      var getMessageCalls = 0;
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/users/@me')) {
          return http.Response('{"id":"7","bot":true}', 200);
        }
        if (request.url.path.endsWith('/channels/123')) {
          return http.Response('{"id":"123","guild_id":"456"}', 200);
        }
        if (request.url.path.contains('/messages/')) getMessageCalls++;
        return http.Response('[]', 200);
      });
      final service = DiscordBotImportService(
        liveUpdates: false,
        store: store,
        client: client,
        ingest: (r) async {
          batches.add(r.conversations.single.segments.length);
          return accept;
        },
      );
      service.setIdentity('test');
      await Future<void>.delayed(Duration.zero);
      await service.connect(token: 'secret', channels: ['123']);
      for (var i = 0; i < 20; i++) {
        service.queueLiveMessage({
          ...message('${101 + i}', '8', 'ekwav', 'hello'),
          'channel_id': '123',
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 2200));
      expect(batches, [20]);
      expect(getMessageCalls, 0);
      accept = true;
      await service.fetch();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(batches, [20, 20]);
      service.dispose();
    },
  );

  test(
    'Full history pages continue before oldest ID without skipping older messages',
    () async {
      final store = MemoryStore();
      final queries = <Map<String, String>>[];
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/users/@me')) {
          return http.Response('{"id":"7","bot":true}', 200);
        }
        if (request.url.path.endsWith('/channels/123')) {
          return http.Response('{"id":"123","guild_id":"456"}', 200);
        }
        queries.add(request.url.queryParameters);
        return http.Response(
          jsonEncode(
            queries.length == 1
                ? [
                    for (var i = 199; i >= 100; i--)
                      message('$i', '8', 'ekwav', 'hello'),
                  ]
                : [message('99', '9', 'counterparty', 'reply')],
          ),
          200,
        );
      });
      final imported = <String>[];
      final service = DiscordBotImportService(
        liveUpdates: false,
        store: store,
        client: client,
        ingest: (r) async {
          imported.addAll(
            r.conversations.single.segments.map((s) => s.sourceMessageId!),
          );
          return true;
        },
      );
      service.setIdentity('test');
      await Future<void>.delayed(Duration.zero);
      await service.connect(token: 'secret', channels: ['123']);
      expect(queries.length, 2);
      expect(queries.last['before'], '100');
      expect(imported.length, 101);
      expect(imported.last, '99');
      expect(store.account!['cursors']['123']['latest'], '199');
      expect(store.account!['cursors']['123']['historyComplete'], true);
      service.dispose();
    },
  );

  test(
    'Server discovery skips denied channels and still imports authorized history',
    () async {
      final store = MemoryStore();
      final imported = <String>[];
      final client = MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/users/@me')) {
          return http.Response('{"id":"7","bot":true}', 200);
        }
        if (path.endsWith('/guilds/456/channels')) {
          return http.Response(
            '[{"id":"123","type":0},{"id":"124","type":0}]',
            200,
          );
        }
        if (path.endsWith('/channels/124')) return http.Response('{}', 403);
        if (path.endsWith('/channels/123')) {
          return http.Response('{"id":"123","guild_id":"456"}', 200);
        }
        return http.Response(
          jsonEncode([message('101', '8', 'ekwav', 'hello')]),
          200,
        );
      });
      final service = DiscordBotImportService(
        liveUpdates: false,
        store: store,
        client: client,
        ingest: (r) async {
          imported.add(r.conversations.single.sourceThreadId!);
          return true;
        },
      );
      service.setIdentity('test');
      await Future<void>.delayed(Duration.zero);
      await service.connect(token: 'secret', channels: [], guildId: '456');
      expect(service.channelIds, ['123']);
      expect(imported, ['discord:123']);
      expect(service.error, isNull);
      service.dispose();
    },
  );
  test(
    'Live burst drains between history pages before long backfill completes',
    () async {
      final batches = <List<String>>[];
      var page = 0;
      late DiscordBotImportService service;
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/users/@me')) {
          return http.Response('{"id":"7","bot":true}', 200);
        }
        if (request.url.path.endsWith('/channels/123')) {
          return http.Response('{"id":"123","guild_id":"456"}', 200);
        }
        page++;
        return http.Response(
          jsonEncode(
            page == 1
                ? [
                    for (var i = 199; i >= 100; i--)
                      message('$i', '8', 'ekwav', 'old'),
                  ]
                : [message('99', '9', 'other', 'old')],
          ),
          200,
        );
      });
      service = DiscordBotImportService(
        liveUpdates: false,
        store: MemoryStore(),
        client: client,
        ingest: (r) async {
          final ids = r.conversations.single.segments
              .map((s) => s.sourceMessageId!)
              .toList();
          batches.add(ids);
          if (batches.length == 1) {
            for (var i = 0; i < 30; i++) {
              service.queueLiveMessage({
                ...message('${300 + i}', '9', 'other', 'live'),
                'channel_id': '123',
              });
            }
            await Future<void>.delayed(const Duration(milliseconds: 2100));
          }
          return true;
        },
      );
      service.setIdentity('test');
      await Future<void>.delayed(Duration.zero);
      await service.connect(token: 'secret', channels: ['123']);
      expect(batches.length, 3);
      expect(batches[0].length, 100);
      expect(batches[1].length, 30);
      expect(batches[1].first, '300');
      expect(batches[2], ['99']);
      service.dispose();
    },
  );
  test(
    'Deleted partial update does not block a live reply in the same batch',
    () async {
      final imported = <String>[];
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/users/@me')) {
          return http.Response('{"id":"7","bot":true}', 200);
        }
        if (request.url.path.endsWith('/channels/123')) {
          return http.Response('{"id":"123","guild_id":"456"}', 200);
        }
        if (request.url.path.endsWith('/messages/101')) {
          return http.Response('{}', 404);
        }
        return http.Response('[]', 200);
      });
      final service = DiscordBotImportService(
        liveUpdates: false,
        store: MemoryStore(),
        client: client,
        ingest: (r) async {
          imported.addAll(
            r.conversations.single.segments.map((s) => s.sourceMessageId!),
          );
          return true;
        },
      );
      service.setIdentity('test');
      await Future<void>.delayed(Duration.zero);
      await service.connect(token: 'secret', channels: ['123']);
      service.queueLiveMessage({
        'id': '101',
        'channel_id': '123',
      }, partial: true);
      service.queueLiveMessage({
        ...message('102', '9', 'other', 'reply'),
        'channel_id': '123',
      });
      await Future<void>.delayed(const Duration(milliseconds: 2200));
      expect(imported, ['102']);
      expect(service.error, isNull);
      service.dispose();
    },
  );
}
