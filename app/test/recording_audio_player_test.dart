import 'dart:async';

import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/widgets/recording_audio_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Vault extends LifenizerAppState {
  final transcription = Completer<void>();
  String? requestedId;
  @override
  bool get isAuthenticated => true;
  @override
  Future<void> transcribeRecording(String id) {
    requestedId = id;
    return transcription.future;
  }
}

void main() {
  testWidgets(
    'saved recording explicitly sends once and reports transcription failure',
    (tester) async {
      final state = _Vault();
      state.conversations.add(
        Conversation(
          id: 'recording',
          title: 'Recording',
          source: 'audio',
          participantIds: [],
          segments: [],
        ),
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: RecordingAudioPlayer(
                state: state,
                conversationId: 'recording',
              ),
            ),
          ),
        );
        expect(find.byTooltip('Play recording'), findsOneWidget);
        expect(state.requestedId, isNull);
        await tester.tap(find.text('Send to Whisper and transcribe'));
        await tester.pump();
        expect(state.requestedId, 'recording');
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull,
        );
        state.transcription.completeError(StateError('offline'));
        await tester.pump();
        expect(
          find.text('Could not transcribe the recording. Try again.'),
          findsOneWidget,
        );
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNotNull,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
      }
    },
  );

  testWidgets('existing transcript hides send action and retains playback', (
    tester,
  ) async {
    final state = _Vault();
    state.conversations.add(
      Conversation(
        id: 'recording',
        title: 'Recording',
        source: 'audio',
        participantIds: [],
        segments: [],
        isLoaded: false,
        segmentCount: 1,
      ),
    );
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RecordingAudioPlayer(
              state: state,
              conversationId: 'recording',
            ),
          ),
        ),
      );
      expect(find.text('Send to Whisper and transcribe'), findsNothing);
      expect(find.byTooltip('Play recording'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    }
  });
}
