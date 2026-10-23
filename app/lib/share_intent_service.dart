import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_state.dart';
import 'services/quick_action_service.dart';

/// Android grants access to shared content URIs; files are read directly into
/// memory once the vault is unlocked, without a plaintext cache on disk.
class ShareIntentService {
  ShareIntentService._();
  static final instance = ShareIntentService._();
  static const channel = MethodChannel('com.lifenizer/shares');

  LifenizerAppState? _state;
  bool _draining = false;
  final List<Map<String, dynamic>> _pending = [];

  Future<void> start(LifenizerAppState state) async {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        _state != null) {
      return;
    }
    _state = state;
    state.addListener(_drainIfReady);
    channel.setMethodCallHandler((call) async {
      if (call.method == 'shares') _enqueue(call.arguments);
    });
    _enqueue(await channel.invokeMethod<Object?>('initialShares'));
  }

  Future<void> stop() async {
    _state?.removeListener(_drainIfReady);
    _state = null;
    channel.setMethodCallHandler(null);
    _pending.clear();
  }

  void _enqueue(Object? items) {
    if (items is! List) {
      return;
    }
    _pending.addAll(
      items.whereType<Map>().map((item) => Map<String, dynamic>.from(item)),
    );
    if (_pending.isNotEmpty) {
      QuickActionService.instance.request(const QuickAction(action: 'imports'));
    }
    _drainIfReady();
  }

  Future<void> _drainIfReady() async {
    final state = _state;
    if (state == null || !state.isAuthenticated || state.busy || _draining) {
      return;
    }
    _draining = true;
    try {
      while (identical(_state, state) &&
          _pending.isNotEmpty &&
          state.isAuthenticated &&
          !state.busy) {
        final payload = _pending.removeAt(0);
        final uri = payload['uri'] as String?;
        try {
          final bytes = uri == null
              ? null
              : await channel.invokeMethod<Uint8List>('readSharedFile', uri);
          if (!identical(_state, state)) return;
          if (!state.isAuthenticated || state.busy) {
            _pending.insert(0, payload);
            return;
          }
          if (uri != null && (bytes == null || bytes.isEmpty)) {
            throw PlatformException(
              code: 'share',
              message:
                  'The shared file is empty or could not be read. Share it again or choose it in Imports.',
            );
          }
          await state.importSharedPayload(
            fileName: payload['fileName'] as String?,
            mimeType: payload['mimeType'] as String?,
            text: payload['text'] as String?,
            bytes: bytes,
            metadata: const {'ingestedBy': 'android-share-target'},
          );
        } on PlatformException catch (error) {
          if (identical(_state, state)) {
            state.reportError(
              error.message ?? 'The shared file could not be read.',
            );
          }
        } catch (_) {
          if (identical(_state, state)) {
            state.reportError(
              'The shared file could not be imported. Share it again or choose it in Imports.',
            );
          }
        } finally {
          if (uri != null && !_pending.any((item) => item['uri'] == uri)) {
            try {
              await channel.invokeMethod<void>('releaseSharedFile', uri);
            } catch (_) {
              // An expired grant must not block the next shared item.
            }
          }
        }
      }
    } finally {
      _draining = false;
      if (_pending.isNotEmpty) _drainIfReady();
    }
  }
}
