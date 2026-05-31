import 'dart:async';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'app_state.dart';

class ShareIntentService {
  ShareIntentService._();

  static final ShareIntentService instance = ShareIntentService._();

  LifenizerAppState? _state;
  bool _started = false;
  bool _draining = false;

  final List<_SharedPayload> _pending = [];
  final Set<String> _seen = <String>{};

  StreamSubscription<List<SharedMediaFile>>? _mediaSub;

  Future<void> start(LifenizerAppState state) async {
    if (_started) return;
    _started = true;
    _state = state;

    state.addListener(_drainIfReady);

    if (kIsWeb) return;

    _mediaSub = ReceiveSharingIntent.instance.getMediaStream().listen((items) {
      _enqueueMedia(items);
      _drainIfReady();
    });

    final initialMedia = await ReceiveSharingIntent.instance.getInitialMedia();
    if (initialMedia.isNotEmpty) {
      _enqueueMedia(initialMedia);
    }

    _drainIfReady();
  }

  Future<void> stop() async {
    _state?.removeListener(_drainIfReady);
    _state = null;
    _started = false;
    await _mediaSub?.cancel();
    _mediaSub = null;
  }

  void _enqueueMedia(List<SharedMediaFile> items) {
    for (final item in items) {
      if (item.type == SharedMediaType.text ||
          item.type == SharedMediaType.url) {
        _enqueueText(item.path.isNotEmpty ? item.path : (item.message ?? ''));
        continue;
      }

      final key = 'media:${item.path}:${item.type}:${item.mimeType}';
      if (!_seen.add(key)) continue;
      _pending.add(
        _SharedPayload(
          filePath: item.path,
          fileName: item.path.split('/').last,
          mimeType: item.mimeType,
        ),
      );
    }
  }

  void _enqueueText(String value) {
    final text = value.trim();
    if (text.isEmpty) return;
    final key = 'text:$text';
    if (!_seen.add(key)) return;
    _pending.add(_SharedPayload(text: text, mimeType: 'text/plain'));
  }

  Future<void> _drainIfReady() async {
    final state = _state;
    if (state == null ||
        !state.isAuthenticated ||
        _draining ||
        _pending.isEmpty) {
      return;
    }
    _draining = true;
    try {
      while (_pending.isNotEmpty) {
        final payload = _pending.removeAt(0);
        List<int>? bytes;
        if (payload.filePath != null && payload.filePath!.isNotEmpty) {
          try {
            bytes = await XFile(payload.filePath!).readAsBytes();
          } catch (_) {
            // Skip unreadable entries without failing the whole queue.
          }
        }

        await state.importSharedPayload(
          fileName: payload.fileName,
          mimeType: payload.mimeType,
          text: payload.text,
          bytes: bytes,
          metadata: const {'ingestedBy': 'android-share-target'},
        );
      }
    } finally {
      _draining = false;
    }
  }
}

class _SharedPayload {
  const _SharedPayload({
    this.text,
    this.filePath,
    this.fileName,
    this.mimeType,
  });

  final String? text;
  final String? filePath;
  final String? fileName;
  final String? mimeType;
}
