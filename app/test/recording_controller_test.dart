import 'dart:async';

import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _State extends LifenizerAppState {
  bool unlocked = false;
  bool failImport = false;
  final failedIds = <String>{};
  final imported = <String>[];
  @override
  bool get isAuthenticated => unlocked;
  @override
  Future<void> importPendingRecording(
    List<int> bytes,
    DateTime recordedAt,
    String id, {
    RecordingLocation? location,
  }) async {
    if (failImport || failedIds.contains(id)) throw StateError('disk full');
    expect(bytes.sublist(44), [1, 2, 3, 4]);
    imported.add(id);
  }

  void changed() => notifyListeners();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _State state;
  var capturing = false;
  final pending = <Map<String, Object>>[];
  final calls = <String>[];
  const channel = MethodChannel('com.lifenizer/recording');
  Map<String, Object> status() => {'recording': capturing, 'startedAt': 1000};
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 12; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump();
  }

  setUp(() {
    capturing = false;
    pending.clear();
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'permission':
              return true;
            case 'status':
              return status();
            case 'start':
              capturing = true;
              return status();
            case 'stop':
              if (capturing) {
                pending.add({'id': 'capture-1', 'startedAt': 1000});
              }
              capturing = false;
              return status();
            case 'pending':
              return pending.toList();
            case 'read':
              return Uint8List.fromList([1, 2, 3, 4]);
            case 'ack':
              pending.removeWhere(
                (item) => item['id'] == (call.arguments as Map)['id'],
              );
              return null;
          }
          return null;
        });
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    state = _State()..rememberedEmail = 'owner@example.com';
  });
  tearDown(() {
    state.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets(
    'record before unlock, finish in background, import only on unlocked resume',
    (tester) async {
      await settle(tester);
      await tester.runAsync(state.recording.start);
      expect(state.recording.recording, isTrue);
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      await tester.runAsync(state.recording.stop);
      expect(state.imported, isEmpty);
      expect(pending, hasLength(1));
      state.unlocked = true;
      state.changed();
      await settle(tester);
      expect(state.imported, isEmpty);
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await settle(tester);
      expect(state.imported, ['capture-1']);
      expect(pending, isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'Activity detaches without stopping native recording',
    (tester) async {
      await tester.runAsync(state.recording.start);
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.detached,
      );
      await settle(tester);
      expect(capturing, isTrue);
      expect(calls, isNot(contains('stop')));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'resume recovers notification stop and multiple captures after engine recreation',
    (tester) async {
      await settle(tester);
      pending.addAll([
        {'id': 'one', 'startedAt': 1000},
        {'id': 'two', 'startedAt': 2000},
      ]);
      state.unlocked = true;
      state.changed();
      await settle(tester);
      expect(state.imported, ['one', 'two']);
      expect(pending, isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'native completion event reconciles notification Stop while foreground',
    (tester) async {
      state.unlocked = true;
      await settle(tester);
      await tester.runAsync(state.recording.start);
      capturing = false;
      pending.add({'id': 'notification', 'startedAt': 1000});
      await tester.runAsync(() async {
        final reply = Completer<void>();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              channel.name,
              const StandardMethodCodec().encodeMethodCall(
                const MethodCall('changed'),
              ),
              (_) => reply.complete(),
            );
        await reply.future;
      });
      await settle(tester);
      expect(state.recording.recording, isFalse);
      expect(state.imported, ['notification']);
      expect(pending, isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'busy unlock defers imports and failed vault saves retain native capture',
    (tester) async {
      await settle(tester);
      pending.add({'id': 'one', 'startedAt': 1000});
      state.unlocked = true;
      state.busy = true;
      state.changed();
      await settle(tester);
      expect(calls, isNot(contains('read')));
      state.busy = false;
      state.failImport = true;
      state.changed();
      await settle(tester);
      expect(pending, hasLength(1));
      expect(calls, isNot(contains('ack')));
      state.failImport = false;
      state.changed();
      await settle(tester);
      expect(pending, isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'a failed capture retains its source while later captures import',
    (tester) async {
      await settle(tester);
      pending.addAll([
        {'id': 'failed', 'startedAt': 1000},
        {'id': 'valid', 'startedAt': 2000},
      ]);
      state.unlocked = true;
      state.failedIds.add('failed');
      state.changed();
      await settle(tester);
      expect(state.imported, ['valid']);
      expect(pending.map((item) => item['id']), ['failed']);
      expect(state.recording.error, contains('disk full'));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'background attempts do not request permission or start microphone',
    (tester) async {
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      await tester.runAsync(state.recording.start);
      expect(calls, isNot(contains('permission')));
      expect(calls, isNot(contains('start')));
      expect(state.recording.error, contains('while Lifenizer is open'));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
