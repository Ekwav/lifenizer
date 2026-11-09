import 'dart:async';

/// Lets the UI abort a long-running request, such as an audio transcription.
///
/// [whenCancelled] is handed to `package:http` as the request's
/// `abortTrigger`, so cancelling closes the connection instead of only
/// abandoning the Future.
class RequestCancellation {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  void throwIfCancelled() {
    if (isCancelled) throw const RequestCancelledException();
  }
}

/// Thrown when a [RequestCancellation] stops a request. It is not an error.
class RequestCancelledException implements Exception {
  const RequestCancelledException();

  @override
  String toString() => 'Request cancelled.';
}
