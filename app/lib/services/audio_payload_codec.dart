import 'dart:convert';
import 'dart:typed_data';

import 'vault_worker_io.dart'
    if (dart.library.js_interop) 'vault_worker_web.dart';

// Large audio payloads (a 30-minute WAV is ~58 MB, ~77 MB as base64) are
// base64-coded in a worker isolate so the UI keeps rendering. On the web the
// work runs inline, like `compute`.

Future<String> base64EncodeInWorker(List<int> bytes) =>
    runVaultWork(() async => base64Encode(bytes));

Future<Uint8List> base64DecodeInWorker(String text) =>
    runVaultWork(() async => base64Decode(text));
