import 'dart:async';
import 'dart:convert';

import 'package:app/app_state.dart';
import 'package:app/api_client.dart';
import 'package:app/share_intent_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _ShareVault extends LifenizerAppState {
  bool unlocked = false;
  final imported = Completer<void>();
  List<int>? receivedBytes;
  bool failFirstImport = false;
  int attempts = 0;
  @override
  bool get isAuthenticated => unlocked;
  void unlock() {
    unlocked = true;
    notifyListeners();
  }

  void setBusy(bool value) {
    busy = value;
    notifyListeners();
  }

  @override
  Future<void> importSharedPayload({
    String? fileName,
    String? mimeType,
    String? text,
    List<int>? bytes,
    Map<String, String> metadata = const {},
  }) async {
    if (failFirstImport && attempts++ == 0) {
      throw StateError('sensitive payload');
    }
    receivedBytes = bytes;
    imported.complete();
  }
}

class _BackupVault extends LifenizerAppState {
  bool unlocked = false;
  @override
  bool get isAuthenticated => unlocked;
  void unlock() {
    unlocked = true;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'repeated shared Telegram backup retains URI until both imports and skips duplicate conversation',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final vault = _BackupVault();
      final released = Completer<void>();
      var grantAvailable = true;
      var reads = 0;
      final sources = <String>[];
      await vault.debugAuthenticateForTesting(
        LifenizerApiClient(
          baseUrl: 'https://vault.example.test',
          client: MockClient((request) async {
            if (request.url.path.startsWith('/api/imports/')) {
              sources.add(request.url.path.split('/').last);
              return http.Response(
                jsonEncode({
                  'source': 'telegram',
                  'plaintextCompute': true,
                  'message': 'Normalized Telegram export',
                  'participants': [],
                  'conversations': [
                    {
                      'title': 'Atlas',
                      'source': 'telegram',
                      'participantNames': [],
                      'segments': [
                        {'text': 'Atlas deadline'},
                      ],
                    },
                  ],
                }),
                200,
              );
            }
            return http.Response(
              jsonEncode({'cursor': 1, 'envelopes': []}),
              200,
            );
          }),
        ),
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ShareIntentService.channel, (call) async {
            if (call.method == 'initialShares') {
              return [
                for (var i = 0; i < 2; i++)
                  {
                    'uri': 'content://synthetic/result.json',
                    'fileName': 'result.json',
                    'mimeType': 'application/json',
                  },
              ];
            }
            if (call.method == 'readSharedFile') {
              expect(grantAvailable, isTrue);
              reads++;
              return Uint8List.fromList(
                utf8.encode(
                  '{"name":"Atlas","messages":[{"from":"Alice","text":"Atlas deadline"}]}',
                ),
              );
            }
            if (call.method == 'releaseSharedFile') {
              grantAvailable = false;
              released.complete();
              return null;
            }
            throw MissingPluginException();
          });
      try {
        await ShareIntentService.instance.start(vault);
        expect(reads, 0);
        vault.unlock();
        await released.future;
        expect(reads, 2);
        expect(sources, ['telegram', 'telegram']);
        expect(vault.conversations, hasLength(1));
        expect(vault.status, contains('Already imported'));
      } finally {
        await ShareIntentService.instance.stop();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(ShareIntentService.channel, null);
        debugDefaultTargetPlatformOverride = null;
        vault.dispose();
      }
    },
  );
  test(
    'shared content waits for unlock and releases URI after import',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final calls = <String>[];
      final released = Completer<void>();
      final vault = _ShareVault();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ShareIntentService.channel, (call) async {
            calls.add(call.method);
            switch (call.method) {
              case 'initialShares':
                return [
                  {
                    'uri': 'content://synthetic/file',
                    'fileName': 'notes.txt',
                    'mimeType': 'text/plain',
                  },
                ];
              case 'readSharedFile':
                expect(call.arguments, 'content://synthetic/file');
                return Uint8List.fromList([65, 66]);
              case 'releaseSharedFile':
                released.complete();
                return null;
            }
            throw MissingPluginException();
          });
      try {
        await ShareIntentService.instance.start(vault);
        expect(calls, ['initialShares']);
        vault.unlock();
        await vault.imported.future;
        await released.future;
        expect(vault.receivedBytes, [65, 66]);
        expect(calls, ['initialShares', 'readSharedFile', 'releaseSharedFile']);
      } finally {
        await ShareIntentService.instance.stop();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(ShareIntentService.channel, null);
        debugDefaultTargetPlatformOverride = null;
        vault.dispose();
      }
    },
  );
  for (final interruption in ['busy', 'locked']) {
    test(
      'shared file retains URI and retries when vault becomes $interruption during native read',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final reading = Completer<void>();
        final firstRead = Completer<Uint8List>();
        final released = Completer<void>();
        var reads = 0;
        final vault = _ShareVault();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(ShareIntentService.channel, (call) async {
              switch (call.method) {
                case 'initialShares':
                  return [
                    {
                      'uri': 'content://synthetic/busy-file',
                      'fileName': 'notes.txt',
                      'mimeType': 'text/plain',
                    },
                  ];
                case 'readSharedFile':
                  reads++;
                  if (reads == 1) {
                    reading.complete();
                    return firstRead.future;
                  }
                  return Uint8List.fromList([65, 66]);
                case 'releaseSharedFile':
                  released.complete();
                  return null;
              }
              throw MissingPluginException();
            });
        try {
          await ShareIntentService.instance.start(vault);
          vault.unlock();
          await reading.future;
          if (interruption == 'busy') {
            vault.setBusy(true);
          } else {
            vault.unlocked = false;
            vault.notifyListeners();
          }
          firstRead.complete(Uint8List.fromList([65, 66]));
          // Let the platform response and the service's microtasks complete.
          await Future<void>.delayed(Duration.zero);
          expect(vault.imported.isCompleted, isFalse);
          expect(released.isCompleted, isFalse);
          if (interruption == 'busy') {
            vault.setBusy(false);
          } else {
            vault.unlock();
          }
          await vault.imported.future;
          await released.future;
          expect(vault.receivedBytes, [65, 66]);
          expect(reads, 2);
        } finally {
          await ShareIntentService.instance.stop();
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(ShareIntentService.channel, null);
          debugDefaultTargetPlatformOverride = null;
          vault.dispose();
        }
      },
    );
  }

  test(
    'mixed shared export, document, audio and photo files use automatic source detection after unlock',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final vault = _BackupVault();
      final sources = <String>[];
      final released = Completer<void>();
      var releaseCount = 0;
      final files = [
        (
          'chat.json',
          'application/json',
          utf8.encode(
            '{"name":"Chat","messages":[{"from":"Alice","text":"Hello"}]}',
          ),
        ),
        ('invoice.pdf', 'application/octet-stream', [1, 2, 3]),
        ('voice.mp3', 'application/octet-stream', [4, 5, 6]),
        ('Shared image', 'image/jpeg', [7, 8, 9]),
      ];
      await vault.debugAuthenticateForTesting(
        LifenizerApiClient(
          baseUrl: 'https://vault.example.test',
          client: MockClient((request) async {
            if (request.url.path.startsWith('/api/imports/')) {
              final source = request.url.path.split('/').last;
              sources.add(source);
              expect(jsonDecode(request.body)['payloadBase64'], isNotEmpty);
              return http.Response(
                jsonEncode({
                  'source': source,
                  'plaintextCompute': true,
                  'message': 'Indexed',
                  'participants': [],
                  'conversations': [],
                }),
                200,
              );
            }
            return http.Response(
              jsonEncode({'cursor': 0, 'envelopes': []}),
              200,
            );
          }),
        ),
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ShareIntentService.channel, (call) async {
            if (call.method == 'initialShares') {
              return [
                for (var i = 0; i < files.length; i++)
                  {
                    'uri': 'content://files/$i',
                    'fileName': files[i].$1,
                    'mimeType': files[i].$2,
                  },
              ];
            }
            if (call.method == 'readSharedFile') {
              return Uint8List.fromList(
                files[int.parse((call.arguments as String).split('/').last)].$3,
              );
            }
            if (call.method == 'releaseSharedFile' &&
                ++releaseCount == files.length) {
              released.complete();
            }
            return null;
          });
      try {
        await ShareIntentService.instance.start(vault);
        expect(sources, isEmpty);
        vault.unlock();
        await released.future;
        expect(sources, ['telegram', 'scanned-pdf', 'audio', 'photo']);
        expect(vault.error, isNull);
      } finally {
        await ShareIntentService.instance.stop();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(ShareIntentService.channel, null);
        debugDefaultTargetPlatformOverride = null;
        vault.dispose();
      }
    },
  );

  for (final failure in ['null read', 'read failure', 'import failure']) {
    test(
      '$failure reports a bounded error and continues with the next shared file',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final vault = _ShareVault()..unlocked = true;
        vault.failFirstImport = failure == 'import failure';
        final released = Completer<void>();
        var releases = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(ShareIntentService.channel, (call) async {
              if (call.method == 'initialShares') {
                return [
                  for (var i = 0; i < 2; i++)
                    {
                      'uri': 'content://files/$i',
                      'fileName': 'notes.txt',
                      'mimeType': 'text/plain',
                    },
                ];
              }
              if (call.method == 'readSharedFile') {
                if (call.arguments == 'content://files/0') {
                  if (failure == 'null read') return null;
                  if (failure == 'read failure') {
                    throw PlatformException(
                      code: 'share',
                      message: 'File grant expired. Share the file again.',
                    );
                  }
                }
                return Uint8List.fromList([65, 66]);
              }
              if (call.method == 'releaseSharedFile' && ++releases == 2) {
                released.complete();
              }
              return null;
            });
        try {
          await ShareIntentService.instance.start(vault);
          await vault.imported.future;
          await released.future;
          expect(vault.receivedBytes, [65, 66]);
          expect(vault.error, isNotNull);
          expect(vault.error, isNot(contains('sensitive payload')));
        } finally {
          await ShareIntentService.instance.stop();
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(ShareIntentService.channel, null);
          debugDefaultTargetPlatformOverride = null;
          vault.dispose();
        }
      },
    );
  }

  test(
    'stopping during a native read cancels the old import and drains new shares for the new state',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final old = _ShareVault()..unlocked = true;
      final next = _ShareVault()..unlocked = true;
      final reading = Completer<void>(), release = Completer<void>();
      final bytes = Completer<Uint8List>();
      var starting = 0, releases = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ShareIntentService.channel, (call) async {
            if (call.method == 'initialShares') {
              return [
                {
                  'uri': 'content://files/${starting++}',
                  'fileName': 'notes.txt',
                  'mimeType': 'text/plain',
                },
              ];
            }
            if (call.method == 'readSharedFile') {
              if (call.arguments == 'content://files/0') {
                reading.complete();
                return bytes.future;
              }
              return Uint8List.fromList([67, 68]);
            }
            if (call.method == 'releaseSharedFile' && ++releases == 2) {
              release.complete();
            }
            return null;
          });
      try {
        await ShareIntentService.instance.start(old);
        await reading.future;
        await ShareIntentService.instance.stop();
        await ShareIntentService.instance.start(next);
        bytes.complete(Uint8List.fromList([65, 66]));
        await next.imported.future;
        await release.future;
        expect(old.imported.isCompleted, isFalse);
        expect(next.receivedBytes, [67, 68]);
      } finally {
        await ShareIntentService.instance.stop();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(ShareIntentService.channel, null);
        debugDefaultTargetPlatformOverride = null;
        old.dispose();
        next.dispose();
      }
    },
  );
}
