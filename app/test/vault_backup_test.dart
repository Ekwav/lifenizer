import 'dart:convert';
import 'dart:io';

import 'package:app/api_client.dart';
import 'package:app/crypto_service.dart';
import 'package:app/image_service.dart';
import 'package:app/services/audio_cache_io.dart' as audio_cache;
import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/services/backup_archive.dart';
import 'package:app/services/local_vault_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sembast/sembast_memory.dart';

class _Target implements BackupTarget {
  final files = <String, List<int>>{};
  String? current;
  bool aborted = false;
  @override
  String get label => 'memory';
  @override
  Future<void> openPart(String name) async {
    current = name;
    files[name] = [];
  }

  @override
  Future<void> write(Uint8List bytes) async => files[current]!.addAll(bytes);
  @override
  Future<void> closePart() async => current = null;
  @override
  Future<void> abort() async {
    aborted = true;
    files.clear();
  }

  List<BackupPart> get parts => files.entries
      .map(
        (entry) => BackupPart(
          name: entry.key,
          openRead: () => Stream.value(entry.value),
        ),
      )
      .toList();
}

class _Server {
  _Server({this.imagePrefix = 'image'});
  final String imagePrefix;
  bool offline = false;
  bool failImages = false;
  final images = <ImageItem>[];
  final imageBytes = <String, List<int>>{};
  int uploads = 0;
  final requests = <http.Request>[];
  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    if (offline) throw const SocketException('offline');
    final path = request.url.path;
    final Object body;
    if (path.startsWith('/api/auth/')) {
      body = {
        'authToken': 'private-auth-token',
        'userId': 'user',
        'vaultId': 'vault',
        'vaultSalt': 'test-salt',
      };
    } else if (path == '/api/sync/pull') {
      body = {'cursor': 0, 'envelopes': []};
    } else if (path == '/api/sync/push') {
      body = {'cursor': 0};
    } else if (path == '/api/images') {
      if (failImages) return http.Response('media unavailable', 403);
      if (request.method == 'POST') {
        final encrypted = utf8.encode(
          request.body.substring(
            request.body.indexOf('{'),
            request.body.lastIndexOf('}') + 1,
          ),
        );
        final conversationId = RegExp(
          'name="conversationId"\\r\\n\\r\\n([^\\r]+)',
        ).firstMatch(request.body)?.group(1);
        final item = ImageItem(
          id: '$imagePrefix-${uploads++}',
          fileName: RegExp(
            'filename="([^"]+)"',
          ).firstMatch(request.body)!.group(1)!,
          contentType: 'application/octet-stream',
          sizeBytes: encrypted.length,
          uploadedAt: DateTime.utc(2026),
          conversationId: conversationId,
        );
        images.add(item);
        imageBytes[item.id] = encrypted;
        body = item.toJson();
      } else {
        body = images.map((image) => image.toJson()).toList();
      }
    } else if (path.startsWith('/api/images/')) {
      return http.Response.bytes(imageBytes[path.split('/').last]!, 200);
    } else if (path == '/api/premium/status') {
      body = {
        'plan': 'free',
        'usedBytes': 0,
        'limitBytes': 10000000,
        'usedPercent': 0,
      };
    } else if (path == '/api/imports/capabilities') {
      body = [];
    } else {
      return http.Response('not found', 404);
    }
    return http.Response(jsonEncode(body), 200);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('vault-backup-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => directory.path);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    await directory.delete(recursive: true);
  });

  Future<LifenizerAppState> device(_Server server, String name) async {
    final disk = LocalVaultStore(
      await databaseFactoryMemory.openDatabase(name),
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
    await state.login(
      baseUrl: 'https://vault.example.test',
      email: '$name@example.test',
      password: 'account-password',
      passphrase: '$name-private-vault-phrase',
    );
    expect(state.error, isNull);
    return state;
  }

  Future<void> offline(
    LifenizerAppState state,
    _Server server,
    String name,
  ) async {
    await state.lock();
    await state.login(
      baseUrl: 'https://vault.example.test',
      email: '$name@example.test',
      passphrase: '$name-private-vault-phrase',
      offline: true,
    );
    expect(state.error, isNull);
    server.offline = true;
  }

  void populate(LifenizerAppState state) {
    state.participants.add(
      Participant(
        id: 'person',
        displayName: 'Alice private',
        identifiers: ['email:alice@example.test'],
        aliases: ['Ally'],
      ),
    );
    state.conversations.addAll([
      Conversation(
        id: 'conversation',
        title: 'Private meeting',
        source: 'manual',
        participantIds: ['person'],
        tags: ['private-tag'],
        isFavorite: true,
        importFingerprint: 'stable-receipt',
        segments: [
          ConversationSegment(
            id: 'segment',
            text: 'Private orchid message',
            participantId: 'person',
            sourceMessageId: 'source-message',
            createdAt: DateTime.utc(2026, 10, 1),
          ),
        ],
      ),
      Conversation(
        id: 'audio-without-transcript',
        title: 'Untranscribed voice',
        source: 'audio',
        participantIds: ['person'],
        segments: [],
        artifactNames: ['recording.wav'],
      ),
    ]);
    state.relations.add(
      RelationEdge(
        id: 'relation',
        subject: 'Alice',
        relation: 'knows',
        object: 'Bob',
        evidence: 'Private orchid message',
        confidence: .8,
        evidenceConversationId: 'conversation',
      ),
    );
    state.savedSearches.add(
      SavedSearch(
        id: 'search',
        title: 'Private saved search',
        query: 'orchid',
        participantId: 'person',
        tag: 'private-tag',
        hideConsumed: true,
        from: DateTime.utc(2026),
        createdAt: DateTime.utc(2026, 10, 1),
      ),
    );
  }

  Map<String, dynamic> snapshot(LifenizerAppState state) => {
    'participants': state.participants.map((p) => p.toJson()).toList(),
    'conversations': state.conversations.map((c) => c.toJson()).toList(),
    'relations': state.relations.map((r) => r.toJson()).toList(),
    'searches': state.savedSearches.map((s) => s.toJson()).toList(),
  };

  test(
    'offline library backup preserves identities and metadata, retries preserve current edits',
    () async {
      final server = _Server();
      final source = await device(server, 'source');
      populate(source);
      final targetState = await device(server, 'target');
      await offline(source, server, 'source');
      final target = _Target();
      final beforeRequests = server.requests.length;
      final summary = await source.makeBackup(
        target: target,
        password: 'backup-password',
        includeMedia: false,
      );
      expect(summary.parts, 1);
      expect(server.requests.length, beforeRequests);
      expect(source.busy, isFalse);
      final raw = String.fromCharCodes(target.files.values.expand((b) => b));
      for (final secret in [
        'Private meeting',
        'Private orchid message',
        'Alice private',
        'private-auth-token',
        'account-password',
        'source-private-vault-phrase',
        'backup-password',
      ]) {
        expect(raw, isNot(contains(secret)));
      }
      final records = await readBackup(
        target.parts,
        password: 'backup-password',
      ).toList();
      final clear = jsonEncode(records);
      expect(clear, isNot(contains('authToken')));
      expect(clear, isNot(contains('private-auth-token')));
      expect(clear, isNot(contains('source-private-vault-phrase')));
      server.offline = false;
      await offline(targetState, server, 'target');
      expect(
        await targetState.restoreBackup(
          parts: target.parts,
          password: 'backup-password',
        ),
        5,
      );
      expect(
        targetState.participants.single.toJson(),
        source.participants.single.toJson(),
      );
      expect(
        (await targetState.loadConversation('conversation')).toJson(),
        (await source.loadConversation('conversation')).toJson(),
      );
      final audio = await targetState.loadConversation(
        'audio-without-transcript',
      );
      expect(audio.segments, isEmpty);
      expect(audio.artifactNames, ['recording.wav']);
      expect(
        targetState.relations.single.toJson(),
        source.relations.single.toJson(),
      );
      expect(
        targetState.savedSearches.single.toJson(),
        source.savedSearches.single.toJson(),
      );
      await targetState.addParticipantIdentity(
        'person',
        'email:newer@example.test',
      );
      final beforeRetry = snapshot(targetState);
      expect(
        await targetState.restoreBackup(
          parts: target.parts,
          password: 'backup-password',
        ),
        0,
      );
      expect(snapshot(targetState), beforeRetry);
      await offline(targetState, server, 'target');
      expect(targetState.conversations, hasLength(2));
      expect(
        targetState.participants.single.identifiers,
        contains('email:newer@example.test'),
      );
      expect(targetState.savedSearches.single.id, 'search');
    },
  );

  test(
    'wrong passwords and truncated archives cannot mutate existing state',
    () async {
      final server = _Server();
      final state = await device(server, 'validation');
      populate(state);
      final target = _Target();
      await state.makeBackup(
        target: target,
        password: 'backup-password',
        includeMedia: false,
      );
      final recipient = await device(server, 'validation-target');
      await recipient.addManualText(
        title: 'Keep current',
        participantNames: '',
        text: 'Existing destination message',
      );
      final before = snapshot(recipient);
      await expectLater(
        recipient.restoreBackup(parts: target.parts, password: 'wrong'),
        throwsA(anything),
      );
      expect(snapshot(recipient), before);
      expect(recipient.busy, isFalse);
      // All records can decode, but the authenticated final marker is missing.
      target.files.values.last.removeLast();
      await expectLater(
        recipient.restoreBackup(
          parts: target.parts,
          password: 'backup-password',
        ),
        throwsA(anything),
      );
      expect(snapshot(recipient), before);
      expect(recipient.busy, isFalse);
    },
  );

  test(
    'full backup saves pending audio as playable recording without replacing destination draft',
    () async {
      final server = _Server();
      final source = await device(server, 'draft-source');
      final destination = await device(server, 'draft-target');
      final payload = [82, 73, 70, 70, 0, 1, 2, 3, 4, 5];
      source.participants.addAll([
        Participant(
          id: 'alex-first',
          displayName: 'Alex',
          identifiers: ['email:first@example.test'],
        ),
        Participant(
          id: 'alex-selected',
          displayName: 'Alex',
          identifiers: ['email:selected@example.test'],
        ),
      ]);
      final location = RecordingLocation(
        town: 'Berlin',
        venue: 'North Atelier',
        address: 'Main Street 4',
        latitude: 52.52,
        longitude: 13.4,
      );
      await source.saveAudioDraft(
        payload,
        DateTime.utc(2026, 10, 1),
        location: location,
      );
      await source.updateAudioDraftDetails(
        title: 'Pending private voice',
        // Older draft metadata can retain a name alongside the exact selected ID.
        participantNames: ['Alex'],
        participantIds: ['alex-selected'],
      );
      await destination.saveAudioDraft([9, 8, 7], DateTime.utc(2026, 10, 2));
      final target = _Target();
      await source.makeBackup(target: target, password: 'backup-password');
      expect(
        await destination.restoreBackup(
          parts: target.parts,
          password: 'backup-password',
        ),
        3,
      );
      final recording = destination.conversations.single;
      expect(recording.title, 'Pending private voice');
      expect(recording.source, 'audio');
      expect(recording.participantIds, ['alex-selected']);
      expect(recording.participantIds, isNot(contains('alex-first')));
      expect(
        destination.participants.where(
          (person) => person.displayName == 'Alex',
        ),
        hasLength(2),
      );
      expect(recording.location!.toJson(), location.toJson());
      expect(
        destination
            .search('town:Berlin', participantId: 'alex-selected')
            .single
            .id,
        recording.id,
      );
      expect(
        destination.search('town:Berlin', participantId: 'alex-first'),
        isEmpty,
      );
      expect(recording.segments, isEmpty);
      expect(
        (await destination.loadRecordingAudio(recording.id)).bytes,
        payload,
      );
      expect(await destination.loadAudioDraftPayload(), [9, 8, 7]);
      final crypto = VaultCrypto();
      await crypto.unlock(
        email: 'draft-target@example.test',
        passphrase: 'draft-target-private-vault-phrase',
        vaultSalt: 'test-salt',
      );
      final vaultKey =
          'vault:${jsonEncode(['https://vault.example.test', 'draft-target@example.test'])}';
      final newer = await crypto.encryptJson({
        'vaultKey': vaultKey,
        'conversationId': recording.id,
        'bytes': base64Encode([6, 5, 4]),
        'fileName': 'newer.wav',
        'contentType': 'audio/wav',
      });
      crypto.lock();
      await audio_cache.writeAudioCache('$vaultKey:audio:${recording.id}', {
        'cipherText': newer.cipherText,
        'nonce': newer.nonce,
      });
      expect(
        await destination.restoreBackup(
          parts: target.parts,
          password: 'backup-password',
        ),
        0,
      );
      expect(destination.conversations.single.id, recording.id);
      expect((await destination.loadRecordingAudio(recording.id)).bytes, [
        6,
        5,
        4,
      ]);
      await Directory('${directory.path}/audio').delete(recursive: true);
      expect(
        await destination.restoreBackup(
          parts: target.parts,
          password: 'backup-password',
        ),
        0,
      );
      expect(
        (await destination.loadRecordingAudio(recording.id)).bytes,
        payload,
      );
      final diskFiles = await directory
          .list(recursive: true)
          .where((file) => file is File)
          .cast<File>()
          .toList();
      expect(diskFiles, isNotEmpty);
      for (final file in diskFiles) {
        final stored = await file.readAsString();
        expect(stored, isNot(contains(base64Encode(payload))));
        expect(stored, isNot(contains('Pending private voice')));
      }
    },
  );

  test(
    'full backup reencrypts uploaded photos for another vault and retries do not upload duplicates',
    () async {
      final sourceServer = _Server(imagePrefix: 'source-image');
      final source = await device(sourceServer, 'photo-source');
      await source.addManualText(
        title: 'Photo owner',
        participantNames: '',
        text: 'Associated conversation',
      );
      final conversationId = source.conversations.single.id;
      final photo = CapturedImage(
        bytes: Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 42]),
        fileName: 'private-photo.png',
        contentType: 'image/png',
      );
      final uploaded = await source.uploadCapturedImage(
        photo,
        conversationId: conversationId,
      );
      final target = _Target();
      await source.makeBackup(target: target, password: 'backup-password');
      final destinationServer = _Server(imagePrefix: 'target-image');
      final destination = await device(destinationServer, 'photo-target');
      expect(
        await destination.restoreBackup(
          parts: target.parts,
          password: 'backup-password',
        ),
        1,
      );
      expect(destinationServer.uploads, 1);
      final restored = destinationServer.images.single;
      expect(restored.id, isNot(uploaded.id));
      expect(restored.fileName, 'backup-${uploaded.id}.bin');
      expect(restored.contentType, 'application/octet-stream');
      expect(restored.conversationId, conversationId);
      final downloaded = await destination.decryptedImage(restored);
      expect(downloaded.bytes, photo.bytes);
      expect(downloaded.fileName, photo.fileName);
      expect(downloaded.contentType, photo.contentType);
      final transport = utf8.decode(destinationServer.imageBytes[restored.id]!);
      expect(transport, isNot(contains(photo.fileName)));
      expect(transport, isNot(contains(base64Encode(photo.bytes))));
      // The source vault key cannot decrypt the destination's newly encrypted upload.
      final sourceCrypto = VaultCrypto();
      await sourceCrypto.unlock(
        email: 'photo-source@example.test',
        passphrase: 'photo-source-private-vault-phrase',
        vaultSalt: 'test-salt',
      );
      await expectLater(
        ImageService.decryptImage(
          Uint8List.fromList(destinationServer.imageBytes[restored.id]!),
          sourceCrypto,
        ),
        throwsA(anything),
      );
      sourceCrypto.lock();
      expect(
        await destination.restoreBackup(
          parts: target.parts,
          password: 'backup-password',
        ),
        0,
      );
      expect(destinationServer.uploads, 1);
      expect(destinationServer.images, hasLength(1));
    },
  );

  test(
    'failed image listing aborts a full backup and releases busy state',
    () async {
      final server = _Server();
      final state = await device(server, 'media-failure');
      await state.addManualText(
        title: 'Preserve',
        participantNames: '',
        text: 'Existing data',
      );
      final before = snapshot(state);
      server.failImages = true;
      final target = _Target();
      await expectLater(
        state.makeBackup(target: target, password: 'backup-password'),
        throwsA(anything),
      );
      expect(target.aborted, isTrue);
      expect(target.files, isEmpty);
      expect(state.busy, isFalse);
      expect(snapshot(state), before);
    },
  );
}
