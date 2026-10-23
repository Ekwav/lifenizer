import 'package:flutter/material.dart';
import '../app_state.dart';
import '../services/recording_playback.dart';

class RecordingAudioPlayer extends StatefulWidget {
  const RecordingAudioPlayer({
    required this.state,
    this.conversationId,
    this.loader,
    this.engineFactory,
    super.key,
  }) : assert(conversationId != null || loader != null);
  final LifenizerAppState state;
  final String? conversationId;
  final Future<RecordingAudio> Function()? loader;
  final RecordingAudioEngine Function()? engineFactory;
  @override
  State<RecordingAudioPlayer> createState() => _RecordingAudioPlayerState();
}

class _RecordingAudioPlayerState extends State<RecordingAudioPlayer> {
  late final RecordingPlayback _playback = RecordingPlayback(
    loader: () =>
        widget.loader?.call() ??
        widget.state.loadRecordingAudio(widget.conversationId!),
    engineFactory: widget.engineFactory,
  );
  String? _identity;
  bool _syncing = false;
  bool _transcribing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _identity = widget.state.recordingIdentity;
    widget.state.addListener(_changed);
  }

  void _changed() {
    final identity = widget.state.recordingIdentity;
    if (identity != _identity) {
      _identity = identity;
      _playback.clear();
    }
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(RecordingAudioPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_changed);
      widget.state.addListener(_changed);
    }
    if (oldWidget.state != widget.state ||
        oldWidget.conversationId != widget.conversationId ||
        oldWidget.loader != widget.loader) {
      _identity = widget.state.recordingIdentity;
      _playback.clear();
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_changed);
    _playback.dispose();
    super.dispose();
  }

  Future<void> _sync(bool enabled) async {
    setState(() {
      _syncing = true;
      _error = null;
    });
    try {
      await widget.state.setRecordingOnlineSync(
        widget.conversationId!,
        enabled,
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              widget.state.pendingRecordingOnlineSync(widget.conversationId!) ==
                  null
              ? 'Could not change online recording storage. Try again.'
              : null,
        );
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _transcribe() async {
    setState(() {
      _transcribing = true;
      _error = null;
    });
    try {
      await widget.state.transcribeRecording(widget.conversationId!);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not transcribe the recording. Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _transcribing = false);
    }
  }

  String _time(Duration value) =>
      '${value.inMinutes}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _playback,
    builder: (context, _) {
      final conversation = widget.state.conversations
          .where((c) => c.id == widget.conversationId)
          .firstOrNull;
      final pendingSync = widget.conversationId == null
          ? null
          : widget.state.pendingRecordingOnlineSync(widget.conversationId!);
      final total = _playback.duration.inMilliseconds.toDouble();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                key: const Key('recording-play-pause'),
                tooltip: _playback.playing
                    ? 'Pause recording'
                    : 'Play recording',
                onPressed: _playback.loading || !widget.state.isAuthenticated
                    ? null
                    : _playback.toggle,
                icon: _playback.loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(_playback.playing ? Icons.pause : Icons.play_arrow),
              ),
              Expanded(
                child: Slider(
                  key: const Key('recording-seek'),
                  max: total > 0 ? total : 1,
                  value: _playback.position.inMilliseconds.toDouble().clamp(
                    0,
                    total > 0 ? total : 1,
                  ),
                  onChanged: total > 0
                      ? (value) => _playback.seek(
                          Duration(milliseconds: value.round()),
                        )
                      : null,
                ),
              ),
              Text(
                '${_time(_playback.position)} / ${_time(_playback.duration)}',
              ),
            ],
          ),
          if (conversation?.source == 'audio' &&
              conversation!.segmentCount == 0) ...[
            FilledButton.icon(
              onPressed:
                  _transcribing ||
                      widget.state.busy ||
                      !widget.state.isAuthenticated
                  ? null
                  : _transcribe,
              icon: const Icon(Icons.transcribe),
              label: const Text('Send to Whisper and transcribe'),
            ),
            const Text(
              'Sends this recording to your configured server for transcription.',
            ),
          ],
          if (conversation != null)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Store encrypted recording online'),
              subtitle: Text(
                pendingSync == true
                    ? 'Waiting to upload encrypted audio. Sync retries automatically while unlocked.'
                    : pendingSync == false
                    ? 'Waiting to remove online audio. Sync retries automatically while unlocked.'
                    : 'Play on other devices even when this device is offline. Otherwise, keep this app open and unlocked to share playback.',
              ),
              value:
                  pendingSync ??
                  conversation.metadata['recordingSync'] == 'true',
              onChanged:
                  _syncing || widget.state.busy || !widget.state.isAuthenticated
                  ? null
                  : _sync,
            ),
          if (_playback.error ?? _error case final String message)
            Text(
              message,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      );
    },
  );
}
