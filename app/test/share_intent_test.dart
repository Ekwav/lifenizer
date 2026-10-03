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
}
