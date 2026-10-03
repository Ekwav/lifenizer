import 'dart:async';

import 'package:app/app_state.dart';
import 'package:app/share_intent_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _ShareVault extends LifenizerAppState {
  bool unlocked = false;
  final imported = Completer<void>();
  List<int>? receivedBytes;
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
    receivedBytes = bytes;
    imported.complete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
  test(
    'shared file retains URI and retries when vault becomes busy during native read',
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
        vault.setBusy(true);
        firstRead.complete(Uint8List.fromList([65, 66]));
        // Let the platform response and the service's microtasks complete.
        await Future<void>.delayed(Duration.zero);
        expect(vault.imported.isCompleted, isFalse);
        expect(released.isCompleted, isFalse);
        vault.setBusy(false);
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
