import 'package:flutter/foundation.dart';

import 'storage_location_io.dart'
    if (dart.library.js_interop) 'storage_location_web.dart'
    as platform;

/// Replaceable in tests, where path_provider has no platform implementation.
@visibleForTesting
Future<String> Function() vaultStorageDescriber = platform.describeVaultStorage;

const recordingStorageHeadline =
    "Stored encrypted in this device's Lifenizer vault";
const recordingStorageExplanation =
    'It is not a normal audio file. The recording leaves this device only when '
    'you send it to Whisper for transcription; the transcript is then '
    'encrypted and synced.';

Future<String> describeRecordingStorage() async {
  try {
    return await vaultStorageDescriber();
  } catch (_) {
    return "this app's private storage";
  }
}
