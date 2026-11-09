import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../services/export_file_reader.dart';
import '../services/recording_playback.dart';
import '../services/source_links.dart';
import 'recording_audio_player.dart';
import 'replacement_sentence_recorder.dart';

Future<void> showTranscriptionCorrection(
  BuildContext context,
  LifenizerAppState state,
  Conversation conversation,
  ConversationSegment segment,
) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => TranscriptionCorrectionDialog(
    state: state,
    conversation: conversation,
    segment: segment,
  ),
);

/// Edit and replay first; review a compact, explicit consent step before sharing.
class TranscriptionCorrectionDialog extends StatefulWidget {
  const TranscriptionCorrectionDialog({
    required this.state,
    required this.conversation,
    required this.segment,
    this.engineFactory,
    super.key,
  });
  final LifenizerAppState state;
  final Conversation conversation;
  final ConversationSegment segment;
  final RecordingAudioEngine Function()? engineFactory;

  @override
  State<TranscriptionCorrectionDialog> createState() =>
      _TranscriptionCorrectionDialogState();
}

class _TranscriptionCorrectionDialogState
    extends State<TranscriptionCorrectionDialog> {
  late final _text = TextEditingController(text: widget.segment.text);
  Map<String, dynamic>? _notice;
  Map<String, dynamic>? _consent;
  List<int>? _audio;
  String? _audioName;
  ({List<int> audio, String text})? _replacement;
  String? _error;
  bool _review = false;
  bool _ownVoice = false;
  bool _acceptTerms = false;
  bool _working = false;
  bool _loading = false;
  bool _recordingReplacement = false;

  bool get _changed =>
      _text.text.trim().isNotEmpty &&
      _text.text.trim() != widget.segment.text.trim();
  String get _version => _notice?['version'] as String? ?? '';
  bool get _trainingAvailable => (_notice?['purposes'] as List? ?? const [])
      .whereType<Map>()
      .any((purpose) => purpose['value'] == 4);
  bool get _canWithdraw => (_consent?['receipts'] as List? ?? const [])
      .whereType<Map>()
      .any((receipt) => ((receipt['purposes'] as int? ?? 0) & 4) != 0);
  bool get _canShare =>
      !_loading &&
      _version.isNotEmpty &&
      _trainingAvailable &&
      _ownVoice &&
      _acceptTerms &&
      _changed;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final values = await Future.wait([
        widget.state.tabTrainingNotice(),
        widget.state.tabTrainingConsent(),
      ]);
      if (!mounted) return;
      setState(() {
        if (_version != values[0]?['version']) _acceptTerms = false;
        _notice = values[0];
        _consent = values[1];
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not load the training notice. Retry.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _attach() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['wav'],
        withReadStream: true,
      );
      if (picked == null || !mounted) return;
      final file = picked.files.single;
      if (!file.name.toLowerCase().endsWith('.wav')) {
        throw const FormatException('Choose the original WAV recording.');
      }
      final bytes = await readExportBytes(file);
      if (!mounted) return;
      setState(() {
        _audio = bytes;
        _audioName = file.name;
        _replacement = null;
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Choose the original 16 kHz mono WAV, up to 64 MiB.',
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _recordReplacement() async {
    if (_recordingReplacement || _working) return;
    FocusManager.instance.primaryFocus?.unfocus();
    // Release preview audio before opening the microphone.
    setState(() => _recordingReplacement = true);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final result = await recordReplacementSentence(
      context,
      state: widget.state,
      text: _replacement?.text ?? _text.text.trim(),
    );
    if (mounted) {
      setState(() {
        _recordingReplacement = false;
        if (result != null) _replacement = result;
        _error = null;
      });
    }
  }

  void _next() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _review = true;
      _ownVoice = false;
      _acceptTerms = false;
      _error = null;
    });
    unawaited(_load());
  }

  void _back() => setState(() {
    _review = false;
    _error = null;
  });

  Future<void> _cancel() async {
    if (_changed || _replacement != null) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Discard correction?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep editing'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Discard'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _submit() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final accepted = await widget.state.submitTranscriptionCorrection(
        conversation: widget.conversation,
        segment: widget.segment,
        correctedText: _text.text.trim(),
        acceptTerms: _acceptTerms,
        consentVersion: _version,
        audioOverride: _audio,
        replacement: _replacement,
      );
      if (!mounted) return;
      if (accepted) {
        Navigator.of(context).pop();
      } else {
        setState(
          () => _error =
              widget.state.error ??
              'Could not share. Retry or go back to edit.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Could not share. Your edits are kept; retry or go back.',
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _withdraw() async {
    setState(() => _working = true);
    try {
      if (await widget.state.withdrawTabTrainingConsent()) {
        if (mounted) {
          setState(() {
            _consent = null;
            _acceptTerms = false;
          });
        }
      } else if (mounted) {
        setState(() => _error = 'Could not withdraw consent. Try again.');
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _link(String link) async {
    if (!await openExternalLink(link) && mounted) {
      setState(() => _error = 'Could not open this link in another app.');
    }
  }

  Future<void> _fullNotice() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('TAB training notice'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Version $_version'),
            for (final key in ['information', 'terms'])
              if (_notice?[key] is String) ...[
                const SizedBox(height: 12),
                SelectableText(_notice![key] as String),
              ],
            for (final purpose
                in (_notice?['purposes'] as List? ?? const []).whereType<Map>())
              if (purpose['value'] == 4)
                Text('${purpose['title']}\n${purpose['description']}'),
            if (_canWithdraw)
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  unawaited(_withdraw());
                },
                child: const Text('Withdraw training consent'),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    ),
  );

  @override
  void dispose() {
    _text.dispose();
    _audio = null;
    _replacement = null;
    super.dispose();
  }

  Widget _editor() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        children: [
          const Expanded(child: Text('Original sentence')),
          PopupMenuButton<String>(
            tooltip: 'Audio options',
            enabled: !_working,
            onSelected: (value) {
              if (value == 'attach') {
                unawaited(_attach());
              } else {
                setState(() {
                  _audio = null;
                  _audioName = null;
                  _replacement = null;
                });
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'attach',
                child: Text('Attach original WAV'),
              ),
              if (_replacement != null || _audio != null)
                const PopupMenuItem(
                  value: 'original',
                  child: Text('Use original sentence audio'),
                ),
            ],
          ),
        ],
      ),
      SelectableText(widget.segment.text, maxLines: 3),
      if (!_recordingReplacement)
        RecordingAudioPlayer(
          key: ValueKey(_audio),
          state: widget.state,
          loader: () => widget.state.loadTranscriptionSentence(
            conversation: widget.conversation,
            segment: widget.segment,
            audioOverride: _audio,
          ),
          engineFactory: widget.engineFactory,
        ),
      if (_audioName != null) Text('Attached: $_audioName'),
      const SizedBox(height: 12),
      TextField(
        key: const Key('corrected-sentence'),
        controller: _text,
        enabled: !_working,
        minLines: 2,
        maxLines: 5,
        maxLength: 10000,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(
          labelText: 'Corrected sentence',
          counterText: '',
        ),
      ),
      const SizedBox(height: 16),
      const Text(
        'Prefer not to share the original audio? Record a non-private sentence using the corrected word.',
      ),
      TextButton.icon(
        onPressed: !_working && !_recordingReplacement
            ? _recordReplacement
            : null,
        icon: const Icon(Icons.mic_none),
        label: Text(
          _replacement == null ? 'Record a replacement' : 'Change replacement',
        ),
      ),
      if (_replacement != null) ...[
        const Text('Replacement for training (original stays private):'),
        SelectableText(_replacement!.text),
        if (!_recordingReplacement)
          RecordingAudioPlayer(
            key: ValueKey(_replacement!.audio),
            state: widget.state,
            loader: () async => RecordingAudio(bytes: _replacement!.audio),
            engineFactory: widget.engineFactory,
          ),
      ],
    ],
  );

  Widget _privacy() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        _replacement == null
            ? 'Only this sentence’s audio and corrected text go to TAB for speech-recognition training.'
            : 'Only your replacement recording and its typed sentence go to TAB for speech-recognition training. Original audio and text stay private.',
      ),
      const SizedBox(height: 12),
      CheckboxListTile(
        key: const Key('correction-own-voice'),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        dense: true,
        value: _ownVoice,
        onChanged: !_working
            ? (value) => setState(() => _ownVoice = value!)
            : null,
        title: const Text('My voice; no confidential content.'),
      ),
      CheckboxListTile(
        key: const Key('correction-training-consent'),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        dense: true,
        value: _acceptTerms,
        onChanged: !_working && !_loading && _trainingAvailable
            ? (value) => setState(() => _acceptTerms = value!)
            : null,
        title: const Text('I allow Coflnet speech-recognition training.'),
      ),
      Wrap(
        spacing: 8,
        children: [
          if (_notice != null)
            TextButton(
              onPressed: _fullNotice,
              child: const Text('Full notice & terms'),
            ),
          if (_notice?['privacyUrl'] case final String url)
            if (externalLinkUri(url) != null)
              TextButton(
                onPressed: () => _link(url),
                child: const Text('Privacy notice'),
              ),
        ],
      ),
      if (_loading) const LinearProgressIndicator(),
      if (_notice == null && !_loading)
        TextButton(onPressed: _load, child: const Text('Retry notice')),
    ],
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && !_working) {
        if (_review) {
          _back();
        } else {
          unawaited(_cancel());
        }
      }
    },
    child: Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _review ? 'Share for training' : 'Correct sentence',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _review ? _privacy() : _editor(),
                      if (_error != null)
                        Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (_working) const LinearProgressIndicator(),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: _working
                        ? null
                        : _review
                        ? _back
                        : _cancel,
                    child: Text(_review ? 'Back' : 'Cancel'),
                  ),
                  Flexible(
                    child: FilledButton(
                      onPressed: _working
                          ? null
                          : _review
                          ? (_canShare ? _submit : null)
                          : (_changed ? _next : null),
                      child: Text(_review ? 'Share correction' : 'Next'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
