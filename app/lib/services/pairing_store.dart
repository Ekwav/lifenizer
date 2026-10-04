import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Native credentials never enter vault snapshots, settings, or web storage.
class PairingCredentialStore {
  static const _key = 'lifenizer.paired-device.v1';
  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
  );

  Future<Map<String, dynamic>?> read() async {
    if (kIsWeb) {
      throw UnsupportedError('Device pairing requires the native app.');
    }
    final value = await _storage.read(key: _key);
    return value == null
        ? null
        : Map<String, dynamic>.from(jsonDecode(value) as Map);
  }

  Future<void> write(Map<String, dynamic> credentials) async {
    if (kIsWeb) {
      throw UnsupportedError('Device pairing requires the native app.');
    }
    await _storage.write(key: _key, value: jsonEncode(credentials));
  }
}
