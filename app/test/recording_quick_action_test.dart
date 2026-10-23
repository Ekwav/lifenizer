import 'package:app/app_state.dart';
import 'package:app/main.dart';
import 'package:app/services/quick_action_service.dart';
import 'package:app/services/recording_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
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
  @override
  bool get supportsBackground => false;
  int starts = 0;
  int stops = 0;
  void setActive() {
    recording = true;
    notifyListeners();
  }

  @override
  Future<void> start() async {
    starts++;
  }

  @override
  Future<void> stop() async {
    stops++;
    recording = false;
    notifyListeners();
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

  testWidgets('query entered during startup survives the unlocked app tree', (
    tester,
  ) async {
    final state = _RecordingVault()..startupLoading = true;
    await tester.pumpWidget(LifenizerApp(state: state));
    await tester.enterText(find.byType(TextField), 'planning tomorrow');
    state.startupLoading = false;
    state.unlocked = true;
    state.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('planning tomorrow'), findsOneWidget);
    expect(state.pendingSearchQuery, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('Android record shortcut starts once before unlock', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final state = _RecordingVault()
      ..startupLoading = true
      ..rememberedEmail = 'linked@example.test';
    try {
      QuickActionService.instance.request(const QuickAction(action: 'record'));
      await tester.pumpWidget(LifenizerApp(state: state));
      await tester.pump();
      expect(state.recording.starts, 1);
      expect(QuickActionService.instance.pending?.action, 'capture');
      state.unlocked = true;
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(state.recording.starts, 1);
      expect(QuickActionService.instance.pending, isNull);
      expect(find.text('Start microphone recording'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Android startup exposes explicit start and stop before unlock', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final state = _RecordingVault()
      ..startupLoading = true
      ..rememberedEmail = 'linked@example.test';
    try {
      await tester.pumpWidget(LifenizerApp(state: state));
      await tester.tap(find.text('Start microphone recording'));
      await tester.pump();
      expect(state.recording.starts, 1);
      expect(state.isAuthenticated, false);
      state.recording.setActive();
      await tester.pump();
      await tester.tap(find.text('Stop and save recording'));
      await tester.pump();
      expect(state.recording.stops, 1);
      expect(state.isAuthenticated, false);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('startup actions scroll when the keyboard leaves little height', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final state = _RecordingVault()
      ..startupLoading = true
      ..rememberedEmail = 'linked@example.test';
    await tester.binding.setSurfaceSize(const Size(320, 160));
    try {
      await tester.pumpWidget(LifenizerApp(state: state));
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Start microphone recording'));
      expect(find.text('Search conversations'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      debugDefaultTargetPlatformOverride = null;
      await tester.binding.setSurfaceSize(null);
    }
  });

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
