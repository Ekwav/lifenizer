import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// One native Gateway connection. Resume retains sequence/session across outages.
class DiscordBotGateway {
  DiscordBotGateway({
    required this.token,
    required this.onEvent,
    required this.onStatus,
    Future<WebSocket> Function(String)? connect,
  }) : _connect = connect ?? WebSocket.connect;
  final String token;
  final Future<WebSocket> Function(String) _connect;
  Timer? _firstBeat;
  final void Function(String, Map<String, dynamic>) onEvent;
  final void Function(String) onStatus;
  WebSocket? _socket;
  Timer? _heartbeat;
  Timer? _retry;
  int? _sequence;
  String? _session;
  String _url = 'wss://gateway.discord.gg';
  bool _closed = false;
  bool _acked = true;
  int _attempt = 0;

  Future<void> start() async {
    if (_closed) return;
    try {
      final socket = await _connect('$_url/?v=10&encoding=json');
      if (_closed) {
        await socket.close();
        return;
      }
      _socket = socket;
      socket.listen(
        _receive,
        onError: (_) => _reconnect(),
        onDone: () {
          final code = socket.closeCode;
          if ([4004, 4010, 4011, 4012, 4013, 4014].contains(code)) {
            onStatus(
              code == 4014
                  ? 'Enable Message Content Intent in the Discord Developer Portal, then reconnect.'
                  : 'Discord refused this bot session (code $code). Reconnect after correcting the bot configuration.',
            );
            _closed = true;
            _heartbeat?.cancel();
            _firstBeat?.cancel();
            return;
          }
          if (code == 4007 || code == 4009) {
            _session = null;
            _sequence = null;
          }
          _reconnect();
        },
      );
    } catch (_) {
      _reconnect();
    }
  }

  void _send(int op, Object? data) =>
      _socket?.add(jsonEncode({'op': op, 'd': data}));
  void _beat() {
    if (!_acked) {
      _reconnect();
      return;
    }
    _acked = false;
    _send(1, _sequence);
  }

  void _receive(dynamic raw) {
    try {
      final payload = jsonDecode(raw as String) as Map<String, dynamic>;
      if (payload['s'] is int) _sequence = payload['s'] as int;
      switch (payload['op']) {
        case 10:
          _acked = true;
          _heartbeat?.cancel();
          _firstBeat?.cancel();
          final interval = Duration(
            milliseconds: (payload['d']['heartbeat_interval'] as num).toInt(),
          );
          _firstBeat = Timer(
            Duration(milliseconds: Random().nextInt(interval.inMilliseconds)),
            () {
              _beat();
              _heartbeat = Timer.periodic(interval, (_) => _beat());
            },
          );
          if (_session != null && _sequence != null) {
            _send(6, {
              'token': token,
              'session_id': _session,
              'seq': _sequence,
            });
          } else {
            _send(2, {
              'token': token,
              'intents': 1 | (1 << 9) | (1 << 15),
              'properties': {
                'os': Platform.operatingSystem,
                'browser': 'Lifenizer',
                'device': 'Lifenizer',
              },
            });
          }
        case 11:
          _acked = true;
        case 1:
          _send(1, _sequence);
        case 7:
          _reconnect();
        case 9:
          if (payload['d'] != true) {
            _session = null;
            _sequence = null;
          }
          _reconnect();
        case 0:
          final type = payload['t'] as String;
          final data = Map<String, dynamic>.from(payload['d'] as Map);
          if (type == 'READY') {
            _session = data['session_id'] as String;
            final resume = Uri.tryParse(
              data['resume_gateway_url'] as String? ?? '',
            );
            if (resume?.scheme == 'wss' &&
                (resume!.host == 'discord.gg' ||
                    resume.host.endsWith('.discord.gg'))) {
              _url = resume.toString();
            }
            _attempt = 0;
            onStatus('Live Discord messages connected.');
          }
          if (type == 'RESUMED') {
            _attempt = 0;
            onStatus('Live Discord messages resumed.');
          }
          onEvent(type, data);
      }
    } catch (_) {
      onStatus('Discord sent an unreadable event; reconnecting.');
      _reconnect();
    }
  }

  void _reconnect() {
    if (_closed || _retry?.isActive == true) return;
    _heartbeat?.cancel();
    _firstBeat?.cancel();
    final socket = _socket;
    _socket = null;
    unawaited(socket?.close());
    final seconds = (1 << _attempt.clamp(0, 5)).clamp(1, 30);
    _attempt++;
    onStatus('Discord disconnected. Retrying in $seconds seconds.');
    _retry = Timer(Duration(seconds: seconds), () => unawaited(start()));
  }

  Future<void> close() async {
    _closed = true;
    _retry?.cancel();
    _heartbeat?.cancel();
    _firstBeat?.cancel();
    await _socket?.close();
    _socket = null;
  }
}
