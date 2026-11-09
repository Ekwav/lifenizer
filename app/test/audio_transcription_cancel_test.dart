import 'dart:async';
import 'dart:convert';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/services/audio_payload_codec.dart';
import 'package:app/services/request_cancellation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support/multipart_upload.dart';

const _base = 'http://127.0.0.1:5075';
const _uploadPath = '/api/imports/audio/upload';

/// Holds audio uploads open until their abort trigger fires, like a server
/// still transcribing a long recording. [failWith] answers immediately.
class _HangingAudioClient extends http.BaseClient {
  _HangingAudioClient({this.failWith});
  final int? failWith;
  final uploads = <AudioUpload>[];
  final uploading = Completer<void>();
  final aborted = Completer<void>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path != _uploadPath) return _json('{}', 200);
    final trigger = request is http.Abortable ? request.abortTrigger : null;
    if (trigger == null) throw StateError('Audio upload is not abortable.');
    uploads.add(await AudioUpload.read(request));
    if (!uploading.isCompleted) uploading.complete();
    if (failWith case final status?) return _json('{"error":"x"}', status);
    await trigger;
    aborted.complete();
    throw http.RequestAbortedException(request.url);
  }

  http.StreamedResponse _json(String body, int status) =>
      http.StreamedResponse(Stream.value(utf8.encode(body)), status);
}

Future<LifenizerAppState> _signedIn(http.Client client) async {
  final state = LifenizerAppState();
  await state.debugAuthenticateForTesting(
    LifenizerApiClient(baseUrl: _base, authToken: 'token', client: client),
  );
  return state;
}

/// Calls [action] once, on the first change after the upload ended while
/// the import is still busy (its search index is not prepared yet).
void _onceAfterUpload(LifenizerAppState state, void Function() action) {
  var started = false;
  var done = false;
  state.addListener(() {
    if (state.isTranscribingAudio) started = true;
    if (!started || done || state.isTranscribingAudio || !state.busy) return;
    done = true;
    action();
  });
}

void main() {
  test('cancelling aborts the in-flight upload without an error', () async {
    final client = _HangingAudioClient();
    final state = await _signedIn(client);

    final import = state.importAudioBytes(bytes: [1, 2, 3], fileName: 'a.wav');
    await client.uploading.future;
    expect(state.busy, isTrue);
    expect(state.isTranscribingAudio, isTrue);

    state.cancelAudioTranscription();

    expect(await import, isFalse);
    await client.aborted.future.timeout(const Duration(seconds: 5));
    expect(state.busy, isFalse);
    expect(state.error, isNull);
    expect(state.isTranscribingAudio, isFalse);
    expect(state.status, 'Transcription cancelled.');
    expect(state.conversations, isEmpty);
  });

  test('cancelling with no running transcription does nothing', () async {
    final state = await _signedIn(_HangingAudioClient());
    state.cancelAudioTranscription();
    expect(state.status, isNot('Cancelling transcription…'));
    expect(state.error, isNull);
  });

  test('the cancel handle ends with the request, before the import ends', () {
    return Future.wait([
      _cancelAfterUploadKeepsStatus(cancelFirst: true),
      _cancelAfterUploadKeepsStatus(cancelFirst: false),
    ]);
  });

  test('a busy vault reports why nothing is transcribed', () async {
    final client = _HangingAudioClient();
    final state = await _signedIn(client);
    state.busy = true;

    expect(await state.importAudioBytes(bytes: [1], fileName: 'a'), isFalse);

    expect(state.status, 'Wait for the current vault operation to finish.');
    expect(client.uploads, isEmpty);
    state.busy = false;
  });

  test('disposing the app state aborts a running upload', () async {
    final client = _HangingAudioClient();
    final state = await _signedIn(client);

    final import = state.importAudioBytes(bytes: [1, 2, 3], fileName: 'a.wav');
    await client.uploading.future;
    state.dispose();

    await client.aborted.future.timeout(const Duration(seconds: 5));
    expect(await import, isFalse);
  });

  test('the timeout aborts the request, not just the Future', () async {
    final client = _HangingAudioClient();
    final api = LifenizerApiClient(
      baseUrl: _base,
      authToken: 'token',
      client: client,
    );

    await expectLater(
      api.importAudio(
        ImportSourceRequest(originalFileName: 'a.wav', mimeType: 'audio/wav'),
        audio: [1, 2, 3],
        timeout: const Duration(milliseconds: 50),
      ),
      throwsA(isA<TimeoutException>()),
    );
    await client.aborted.future.timeout(const Duration(seconds: 5));
  });

  test('a cancel during the 401 refresh never opens the retry', () async {
    final cancellation = RequestCancellation();
    final client = _HangingAudioClient(failWith: 401);
    final api = LifenizerApiClient(
      baseUrl: _base,
      authToken: 'expired',
      client: client,
      refreshAuth: () async {
        cancellation.cancel();
        return 'fresh';
      },
    );

    await expectLater(
      api.importAudio(
        ImportSourceRequest(originalFileName: 'a.wav', mimeType: 'audio/wav'),
        audio: [1, 2, 3],
        timeout: const Duration(minutes: 1),
        cancellation: cancellation,
      ),
      throwsA(isA<RequestCancelledException>()),
    );
    expect(client.uploads, hasLength(1));
  });

  group('multipart upload', () {
    Future<AudioUpload> uploadOf(List<int> audio, String fileName) async {
      final client = _HangingAudioClient();
      final state = await _signedIn(client);
      final import = state.importAudioBytes(
        bytes: audio,
        fileName: fileName,
        title: 'Memo',
        mimeType: 'audio/mpeg',
      );
      await client.uploading.future;
      state.cancelAudioTranscription();
      await import;
      return client.uploads.single;
    }

    test('keeps the claimed type for other files', () async {
      final upload = await uploadOf([1, 2, 3], 'song.mp3');
      expect(upload.audioType, 'audio/mpeg');
    });
  });

  test('base64 helpers round-trip in the worker', () async {
    final audio = List<int>.generate(70000, (i) => i % 251);
    final text = await base64EncodeInWorker(audio);
    expect(text, base64Encode(audio));
    expect(await base64DecodeInWorker(text), audio);
  });
}

/// Regression: the Cancel button used to outlive the request, so a tap while
/// the search index was prepared replaced the final status for good.
Future<void> _cancelAfterUploadKeepsStatus({required bool cancelFirst}) async {
  final client = _HangingAudioClient(failWith: cancelFirst ? null : 500);
  final state = await _signedIn(client);
  var sawHandle = true;
  _onceAfterUpload(state, () {
    sawHandle = state.isTranscribingAudio;
    state.cancelAudioTranscription();
  });

  final import = state.importAudioBytes(bytes: [1, 2, 3], fileName: 'a.wav');
  await client.uploading.future;
  if (cancelFirst) state.cancelAudioTranscription();
  await import;

  expect(sawHandle, isFalse);
  expect(state.status, isNot('Cancelling transcription…'));
  if (cancelFirst) {
    expect(state.status, 'Transcription cancelled.');
    expect(state.error, isNull);
  } else {
    expect(state.error, contains('500'));
  }
}
