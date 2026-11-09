import 'package:sembast/sembast.dart';

import 'local_vault_store_io.dart'
    if (dart.library.js_interop) 'local_vault_store_web.dart'
    as platform;

/// Only encrypted snapshots and non-secret connection preferences enter this DB.
class LocalVaultStore {
  LocalVaultStore(Database database) : _database = database, _request = null;
  LocalVaultStore.remote(this._request) : _database = null;

  final Database? _database;
  final Future<Object?> Function(String, String?, Map<String, dynamic>?)?
  _request;
  final _records = stringMapStoreFactory.store('vaults');

  static Future<LocalVaultStore> open() => platform.openVaultStore();

  /// Native SQLite sidecars share the vault's directory, never its plaintext.
  Future<String?> get sqlitePath async => _request == null
      ? null
      : await _request('sqlitePath', null, null) as String?;

  Future<Map<String, dynamic>?> read(String key) async {
    final value = _request == null
        ? await _records.record(key).get(_database!)
        : await _request('read', key, null) as Map<String, dynamic>?;
    return value == null ? null : Map<String, dynamic>.from(value);
  }

  Future<void> write(String key, Map<String, dynamic> value) async {
    if (_request != null) {
      await _request('write', key, value);
    } else {
      await _records.record(key).put(_database!, value);
    }
  }

  /// Writes several records (chunks first, core last). The file-backed store
  /// does it in one transaction and one compaction, so a chunked save is atomic
  /// and does not rewrite the database file once per record.
  Future<void> writeMany(Map<String, Map<String, dynamic>> values) async {
    if (values.isEmpty) return;
    if (_request != null) {
      await _request('writeMany', null, Map<String, dynamic>.of(values));
    } else {
      // Chunks are listed before the core record, so an interrupted write
      // leaves the previous core pointing at a nonce mismatch (detected on
      // load) rather than a core that describes chunks that do not exist.
      for (final entry in values.entries) {
        await write(entry.key, entry.value);
      }
    }
  }

  /// Removes records (missing keys are ignored).
  Future<void> deleteMany(Iterable<String> keys) async {
    final list = keys.toList();
    if (list.isEmpty) return;
    if (_request != null) {
      await _request('deleteMany', null, {'keys': list});
    } else {
      for (final key in list) {
        await _records.record(key).delete(_database!);
      }
    }
  }

  Future<void> close() async {
    if (_request != null) {
      await _request('close', null, null);
    } else {
      await _database!.close();
    }
  }
}
