import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Connections and successful-import cursors are scoped to this device's vault.
class DocumentCredentialStore {
  const DocumentCredentialStore();
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
  );
  String _key(String identity, String source) =>
      'lifenizer.documents.$source.${base64UrlEncode(utf8.encode(identity))}';
  Future<Map<String, dynamic>?> read(String identity, String source) async {
    if (kIsWeb) return null;
    final value = await _storage.read(key: _key(identity, source));
    return value == null
        ? null
        : Map<String, dynamic>.from(jsonDecode(value) as Map);
  }

  Future<void> write(
    String identity,
    String source,
    Map<String, dynamic> value,
  ) async {
    if (kIsWeb) {
      throw UnsupportedError('Remembering documents requires the native app.');
    }
    await _storage.write(key: _key(identity, source), value: jsonEncode(value));
  }

  Future<void> remove(String identity, String source) async {
    if (!kIsWeb) await _storage.delete(key: _key(identity, source));
  }
}
