import 'package:flutter/material.dart';

import '../app_state.dart';

/// Progress bar for a running transcription, with a way to cancel it.
class TranscriptionProgress extends StatelessWidget {
  const TranscriptionProgress({required this.state, super.key});
  final LifenizerAppState state;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const LinearProgressIndicator(),
      TranscriptionCancelButton(state: state),
    ],
  );
}

/// Shown only while an audio upload can still be cancelled. It stays enabled
/// while the app is busy, because the transcription itself keeps it busy.
class TranscriptionCancelButton extends StatelessWidget {
  const TranscriptionCancelButton({required this.state, super.key});
  final LifenizerAppState state;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      if (!state.isTranscribingAudio) return const SizedBox.shrink();
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const Key('cancel-transcription'),
          onPressed: state.cancelAudioTranscription,
          icon: const Icon(Icons.close),
          label: const Text('Cancel transcription'),
        ),
      );
    },
  );
}
