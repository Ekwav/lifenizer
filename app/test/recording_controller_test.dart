import 'dart:async';
import 'dart:convert';

import 'package:app/app_state.dart';
import 'package:app/widgets/microphone_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// The recorder's public interface is used to simulate native audio events.
// ignore: depend_on_referenced_packages
import 'package:record_platform_interface/record_platform_interface.dart';

class _Recorder extends RecordPlatform {
  final pcm = StreamController<Uint8List>.broadcast(sync: true);
  final disposed = Completer<void>();
  bool created = false;
  int starts = 0;
  int stops = 0;

  @override
  Future<void> create(String recorderId) async {
    created = true;
  }

  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async =>
      true;
  @override
  Stream<RecordState> onStateChanged(String recorderId) => const Stream.empty();
  @override
  Future<Stream<Uint8List>> startStream(
    String recorderId,
    RecordConfig config,
  ) async {
    starts++;
    return pcm.stream;
  }

  @override
  Future<String?> stop(String recorderId) async {
    stops++;
    return null;
  }

  @override
  Future<void> dispose(String recorderId) async {
    disposed.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _State extends LifenizerAppState {
  @override
  bool get isAuthenticated => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Recorder recorder;
  late _State state;
  late RecordPlatform previous;
  final nativeCalls = <String>[];
  const channel = MethodChannel('com.lifenizer/recording');

  setUp(() {
    previous = RecordPlatform.instance;
    recorder = _Recorder();
    RecordPlatform.instance = recorder;
    state = _State();
    nativeCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          nativeCalls.add(call.method);
          return null;
        });
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  Future<void> close(WidgetTester tester) async {
    await tester.runAsync(() async {
      await state.recording.stop();
      state.dispose();
      if (recorder.created) await recorder.disposed.future;
      await recorder.pcm.close();
    });
  }

  tearDown(() {
    RecordPlatform.instance = previous;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets(
    'Android recording survives leaving Capture and screen lock',
    (tester) async {
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: MicrophonePanel(state: state)),
          ),
        );
        await tester.runAsync(state.recording.start);
        recorder.pcm.add(Uint8List.fromList([1, 2, 3, 4]));
        await tester.pump();
        await tester.pumpWidget(const SizedBox());
        WidgetsBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.paused,
        );
        await tester.pump();
        expect(state.recording.recording, isTrue);
        expect(recorder.starts, 1);
        expect(recorder.stops, 0);
        await tester.runAsync(state.stopRecording!);
        expect(
          base64Decode(state.audioDraft!['payload'] as String).sublist(44),
          [1, 2, 3, 4],
        );
        expect(nativeCalls, ['notificationPermission', 'start', 'stop']);
      } finally {
        await close(tester);
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'notification Stop saves captured PCM and stops the service',
    (tester) async {
      try {
        await tester.runAsync(state.recording.start);
        recorder.pcm.add(Uint8List.fromList([5, 6]));
        await tester.pump();
        await tester.runAsync(() async {
          final reply = Completer<void>();
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .handlePlatformMessage(
                channel.name,
                const StandardMethodCodec().encodeMethodCall(
                  const MethodCall('stop'),
                ),
                (_) => reply.complete(),
              );
          await reply.future;
        });
        expect(state.recording.recording, isFalse);
        expect(
          base64Decode(state.audioDraft!['payload'] as String).sublist(44),
          [5, 6],
        );
        expect(recorder.stops, 1);
        expect(nativeCalls.last, 'stop');
      } finally {
        await close(tester);
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'background attempts never start the service or microphone',
    (tester) async {
      try {
        WidgetsBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.paused,
        );
        await tester.runAsync(state.recording.start);
        expect(state.recording.recording, isFalse);
        expect(recorder.starts, 0);
        expect(nativeCalls, isNot(contains('start')));
        expect(state.recording.error, contains('while Lifenizer is open'));
      } finally {
        await close(tester);
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
