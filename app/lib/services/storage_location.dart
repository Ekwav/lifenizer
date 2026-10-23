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
    'Saved recordings can stream encrypted to your other devices while this '
    'app is open and unlocked. Optional encrypted online storage allows playback '
    'when this device is offline. Transcription sends audio to Whisper; the '
    'transcript is encrypted and synced.';

Future<String> describeRecordingStorage() async {
  try {
    return await vaultStorageDescriber();
  } catch (_) {
    return "this app's private storage";
  }
}
