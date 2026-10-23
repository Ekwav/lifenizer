import 'package:app/app_state.dart';
import 'package:app/main.dart';
import 'package:app/services/quick_action_service.dart';
import 'package:app/services/recording_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingVault extends LifenizerAppState {
  bool unlocked = false;
  @override
  bool get isAuthenticated => unlocked;
  late final _recorder = _Recorder(this);
  @override
  _Recorder get recording => _recorder;
}

class _Recorder extends RecordingController {
  _Recorder(super.state);
  int starts = 0;
  @override
  Future<void> start() async {
    starts++;
  }

  @override
  Future<void> stop() async {
    recording = false;
  }

  @override
  void dispose() {
    recording = false;
    super.dispose();
  }
}

void main() {
  setUp(() {
    QuickActionService.instance.consume();
  });
  tearDown(() {
    QuickActionService.instance.consume();
  });

  testWidgets(
    'record shortcut survives unlock, starts once and capture only navigates',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final state = _RecordingVault();
      QuickActionService.instance.request(
        QuickAction.fromUri(Uri.parse('lifenizer://record'))!,
      );
      await tester.pumpWidget(LifenizerApp(state: state));
      await tester.pump();
      expect(state.recording.starts, 0);
      expect(QuickActionService.instance.pending?.action, 'record');
      state.unlocked = true;
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(state.recording.starts, 1);
      expect(find.text('Start microphone recording'), findsOneWidget);
      expect(QuickActionService.instance.pending, isNull);
      state.notifyListeners();
      await tester.pump();
      expect(state.recording.starts, 1);
      QuickActionService.instance.request(const QuickAction(action: 'capture'));
      await tester.pumpAndSettle();
      expect(state.recording.starts, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  testWidgets('record request waits for resumed foreground before starting', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final state = _RecordingVault()..unlocked = true;
    await tester.pumpWidget(LifenizerApp(state: state));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    QuickActionService.instance.request(const QuickAction(action: 'record'));
    await tester.pump();
    expect(state.recording.starts, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(state.recording.starts, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  for (final guard in ['draft', 'recording', 'working', 'busy']) {
    testWidgets(
      '$guard keeps recording shortcut from starting another microphone',
      (tester) async {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        final state = _RecordingVault()..unlocked = true;
        if (guard == 'draft') {
          state.audioDraft = {
            'recordedAt': DateTime.utc(2026).toIso8601String(),
            'detailsPrompted': true,
          };
        }
        if (guard == 'recording') {
          state.recording.recording = true;
          state.recording.startedAt = DateTime.now();
        }
        if (guard == 'working') state.recording.working = true;
        if (guard == 'busy') state.busy = true;
        QuickActionService.instance.request(
          const QuickAction(action: 'record'),
        );
        await tester.pumpWidget(LifenizerApp(state: state));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(state.recording.starts, 0);
        if (guard == 'draft') {
          expect(find.text('Save recording to library'), findsOneWidget);
          expect(find.text('Discard recording'), findsOneWidget);
          expect(state.error, contains('Save or discard'));
        } else if (guard == 'busy') {
          expect(state.error, contains('then tap Start microphone recording'));
        } else if (guard == 'recording') {
          expect(find.text('Stop and save recording'), findsOneWidget);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
      },
    );
  }
}
