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

  Future<void> close() async {
    if (_request != null) {
      await _request('close', null, null);
    } else {
      await _database!.close();
    }
  }
}
