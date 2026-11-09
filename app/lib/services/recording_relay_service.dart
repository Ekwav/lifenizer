import 'dart:async';
import 'package:http/http.dart' as http;
import '../app_state.dart';

/// Advertises locally cached audio while this vault is unlocked and running.
class RecordingRelayService {
  RecordingRelayService(this.state, {http.Client Function()? clientFactory})
    : _clientFactory = clientFactory ?? http.Client.new;
  final LifenizerAppState state;
  final http.Client Function() _clientFactory;
  http.Client? _client;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  Timer? _retry;
  String? _identity;
  int _generation = 0;
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    state.addListener(_changed);
    _changed();
  }

  void _changed() {
    final identity = state.recordingIdentity;
    if (_identity == identity) return;
    _stop();
    _identity = identity;
    if (identity != null) _connect();
  }

  void _stop() {
    _generation++;
    _retry?.cancel();
    _retry = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _client?.close();
    _client = null;
  }

  void _connect() {
    final generation = _generation;
    final identity = _identity;
    final api = state.recordingApi;
    final client = _clientFactory();
    _client = client;
    void disconnected() {
      if (generation != _generation || !_started || _retry != null) return;
      client.close();
      _retry = Timer(const Duration(seconds: 5), () {
        _retry = null;
        if (generation == _generation && _identity != null) _connect();
      });
    }

    _subscription = api
        .recordingRequests(client)
        .listen(
          (request) async {
            final id = request['conversationId'];
            final requestId = request['requestId'];
            if (id is! String ||
                requestId is! String ||
                id.length > 512 ||
                requestId.length > 512) {
              return;
            }
            try {
              final encrypted = await state.encryptedRecordingForRelay(id);
              if (encrypted == null ||
                  generation != _generation ||
                  state.recordingIdentity != identity) {
                return;
              }
              await api.answerRecordingRequest(
                requestId,
                encrypted,
                client: client,
              );
            } catch (_) {
              // Missing local audio or an expired request needs no user interruption.
            }
          },
          onError: (Object _) => disconnected(),
          onDone: disconnected,
          cancelOnError: true,
        );
  }

  void dispose() {
    if (_started) state.removeListener(_changed);
    _started = false;
    _identity = null;
    _stop();
  }
}
