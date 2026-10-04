import 'dart:convert';
import 'dart:io';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/pages/imports_page.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:app/services/discord_archive.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void writeFixture(
  String path, {
  bool updated = false,
  bool largeActivity = false,
}) {
  final archive = Archive();
  void add(String name, Object value) {
    archive.addFile(ArchiveFile.bytes(name, utf8.encode(jsonEncode(value))));
  }

  add('Account/user.json', {
    'id': '111',
    'username': 'Author',
    'email': 'author@example.test',
    'relationships': [
      {
        'nickname': 'Friend nickname',
        'user': {'id': '222', 'username': 'Friend'},
      },
    ],
  });
  add('Nachrichten/index.json', {'333': 'Direct Message with Former friend'});
  add('Nachrichten/c333/channel.json', {
    'id': '333',
    'type': 'DM',
    'recipients': ['444', 'Deleted User'],
  });
  add('Nachrichten/c333/messages.json', [
    {
      'ID': 9007199254740993,
      'Timestamp': '2020-01-01 12:00:00',
      'Contents': updated ? 'Edited atlas plan' : 'Atlas plan',
      'Attachments': 'https://example.test/attachment',
    },
    if (!updated)
      {
        'ID': 9007199254740994,
        'Timestamp': '2020-01-02 12:00:00',
        'Contents': '',
        'Attachments': '',
      },
    if (updated)
      {
        'ID': 9007199254740995,
        'Timestamp': '2020-01-03 12:00:00',
        'Contents': 'New atlas update',
        'Attachments': '',
      },
  ]);
  if (largeActivity) {
    add('Activity/analytics/events.json', 'x' * (9 * 1024 * 1024));
  }
  File(path).writeAsBytesSync(ZipEncoder().encode(archive));
}

void main() {
  late Directory directory;
  late String path;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('discord-import-');
    path = '${directory.path}/package.zip';
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test(
    'local ZIP selects messages only, preserving exact IDs, empty messages, attachments and deleted recipients',
    () async {
      writeFixture(path, largeActivity: true);
      expect(await isDiscordArchive(path), isTrue);
      final result = (await readDiscordArchive(path).toList()).single;
      expect(result.plaintextCompute, isFalse);
      final conversation = result.conversations.single;
      expect(conversation.title, 'DM · Former friend');
      expect(conversation.sourceThreadId, 'discord:333');
      expect(conversation.participantIdentifiers, [
        'discord:111',
        'discord:444',
      ]);
      expect(conversation.segments, hasLength(2));
      expect(
        conversation.segments.first.sourceMessageId,
        'discord:9007199254740993',
      );
      expect(
        conversation.segments.first.createdAt,
        DateTime.utc(2020, 1, 1, 12),
      );
      expect(conversation.segments.first.attachmentUrls, [
        'https://example.test/attachment',
      ]);
      expect(
        result.participants.first.identifiers,
        contains('email:author@example.test'),
      );
      expect(result.participants.last.displayName, 'Former friend');
    },
  );

  test(
    'locked archive import cannot read a local path or create vault entities',
    () async {
      final state = LifenizerAppState();
      await state.importDiscordArchive('${directory.path}/does-not-exist.zip');
      expect(state.error, contains('Unlock the vault'));
      expect(state.participants, isEmpty);
      expect(state.conversations, isEmpty);
      state.dispose();
    },
  );

  test(
    'selected JSON is bounded and closes the archive after errors',
    () async {
      writeFixture(path);
      await expectLater(
        readDiscordArchive(path, maxEntryBytes: 32).toList(),
        throwsFormatException,
      );
      File(path).renameSync('${directory.path}/closed.zip');
    },
  );

  testWidgets(
    'desktop file drop imports the local ZIP and disables dropping while locked',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      writeFixture(path);
      final state = LifenizerAppState();
      await tester.runAsync(
        () => state.debugAuthenticateForTesting(
          LifenizerApiClient(
            baseUrl: 'https://vault.example.test',
            client: MockClient(
              (request) async => http.Response(
                jsonEncode(
                  request.url.path.endsWith('/push')
                      ? {'cursor': 1}
                      : {'cursor': 1, 'envelopes': []},
                ),
                200,
              ),
            ),
          ),
        ),
      );
      state.session = AuthSession(
        authToken: 'test',
        userId: 'user',
        vaultId: 'vault',
        vaultSalt: 'test-salt',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: AnimatedBuilder(
            animation: state,
            builder: (context, _) => Scaffold(body: ImportsPage(state: state)),
          ),
        ),
      );
      final target = tester.widget<DropTarget>(find.byType(DropTarget));
      expect(target.enable, isTrue);
      await tester.runAsync(() async {
        await Function.apply(target.onDragDone!, [
          DropDoneDetails(
            files: [DropItemFile(path)],
            localPosition: Offset.zero,
            globalPosition: Offset.zero,
          ),
        ]);
      });
      await tester.pump();
      expect(state.error, isNull);
      expect(state.conversations.single.sourceThreadId, 'discord:333');
      state.session = null;
      state.notifyListeners();
      await tester.pump();
      expect(
        tester.widget<DropTarget>(find.byType(DropTarget)).enable,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  test(
    're-import merges edits and new messages, retains missing history and user edits, and independently generated IDs agree',
    () async {
      writeFixture(path);
      LifenizerAppState device() => LifenizerAppState();
      Future<void> unlock(LifenizerAppState state) async {
        await state.debugAuthenticateForTesting(
          LifenizerApiClient(
            baseUrl: 'https://vault.example.test',
            client: MockClient(
              (request) async => http.Response(
                jsonEncode(
                  request.url.path.endsWith('/push')
                      ? {'cursor': 1}
                      : {'cursor': 1, 'envelopes': []},
                ),
                200,
              ),
            ),
          ),
        );
        state.session = AuthSession(
          authToken: 'test',
          userId: 'user',
          vaultId: 'vault',
          vaultSalt: 'test-salt',
        );
      }

      final state = device();
      final other = device();
      await unlock(state);
      await unlock(other);
      await state.importDiscordArchive(path);
      await other.importDiscordArchive(path);
      expect(state.error, isNull);
      final original = state.conversations.single;
      expect(other.conversations.single.id, original.id);
      expect(
        other.conversations.single.segments.first.id,
        original.segments.first.id,
      );
      state.conversations[0] = Conversation.fromJson({
        ...original.toJson(),
        'isFavorite': true,
        'tags': [...original.tags, 'custom'],
      });
      await state.importDiscordArchive(path);
      expect(state.conversations, hasLength(1));
      expect(state.conversations.single.segments, hasLength(2));
      expect(state.status, contains('0 conversation(s) added or updated'));
      writeFixture(path, updated: true);
      await state.importDiscordArchive(path);
      expect(state.error, isNull);
      final updated = state.conversations.single;
      expect(updated.id, original.id);
      expect(updated.isFavorite, isTrue);
      expect(updated.tags, contains('custom'));
      expect(updated.segments, hasLength(3));
      expect(updated.segments.first.id, original.segments.first.id);
      expect(updated.segments.first.text, 'Edited atlas plan');
      expect(updated.segments.last.createdAt, DateTime.utc(2020, 1, 3, 12));
      expect(state.search('atlas'), hasLength(1));
      state.dispose();
      other.dispose();
    },
  );
}
