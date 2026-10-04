import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import 'quick_action_desktop_stub.dart'
    if (dart.library.io) 'quick_action_desktop.dart'
    as desktop;

class QuickAction {
  const QuickAction({
    this.action = 'search',
    this.query = '',
    this.conversationId,
    this.connectionUri,
  });

  final String action;
  final String query;
  final String? conversationId;
  final String? connectionUri;

  static QuickAction? fromUri(Uri uri) {
    final action = uri.scheme == 'lifenizer'
        ? uri.host
        : uri.queryParameters['action'];
    if (!const ['search', 'capture', 'imports', 'connect'].contains(action)) {
      return null;
    }
    return QuickAction(
      action: action!,
      connectionUri: action == 'connect' ? uri.toString() : null,
      query: uri.queryParameters['q'] ?? '',
      conversationId: uri.queryParameters['conversation'],
    );
  }
}

/// Actions stay in memory while the vault is locked and are consumed on unlock.
class QuickActionService extends ChangeNotifier {
  static final instance = QuickActionService();
  static const channel = MethodChannel('com.lifenizer/quick_actions');

  LifenizerAppState? _state;
  QuickAction? _pending;
  QuickAction? get pending => _pending;

  void request(QuickAction action) {
    if (action.action == 'connect' &&
        action.connectionUri != null &&
        _state != null) {
      unawaited(_state!.pairing.connect(action.connectionUri!));
      return;
    }
    _pending = action;
    notifyListeners();
  }

  QuickAction? consume() {
    final action = _pending;
    _pending = null;
    return action;
  }

  Future<void> start(
    LifenizerAppState state, {
    List<String> arguments = const [],
  }) async {
    _state = state;
    if (kIsWeb) {
      final action = QuickAction.fromUri(Uri.base);
      if (action != null) request(action);
      return;
    }
    for (final argument in arguments) {
      final uri = Uri.tryParse(argument);
      final action = uri == null ? null : QuickAction.fromUri(uri);
      if (action != null) request(action);
    }
    channel.setMethodCallHandler((call) async {
      if (call.method == 'action') _receive(call.arguments);
    });
    if (defaultTargetPlatform == TargetPlatform.android) {
      _receive(await channel.invokeMethod<Object?>('initialAction'));
    } else if (defaultTargetPlatform == TargetPlatform.linux) {
      await desktop.startDesktopRunner(state, request);
    }
  }

  void _receive(Object? value) {
    if (value is! Map) return;
    final action = value['action'];
    if (!const ['search', 'capture', 'imports', 'connect'].contains(action)) {
      return;
    }
    request(
      QuickAction(
        action: action as String,
        connectionUri: value['uri'] as String?,
        query: value['query'] as String? ?? '',
        conversationId: value['conversationId'] as String?,
      ),
    );
  }
}
