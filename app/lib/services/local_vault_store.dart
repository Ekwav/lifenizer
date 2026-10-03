import 'package:sembast/sembast.dart';

import 'local_vault_store_io.dart'
    if (dart.library.js_interop) 'local_vault_store_web.dart'
    as platform;

/// Only encrypted snapshots and non-secret connection preferences enter this DB.
class LocalVaultStore {
  LocalVaultStore(this.database);

  final Database database;
  final _records = stringMapStoreFactory.store('vaults');

  static Future<LocalVaultStore> open() async =>
      LocalVaultStore(await platform.openVaultDatabase());

  Future<Map<String, dynamic>?> read(String key) async {
    final value = await _records.record(key).get(database);
    return value == null ? null : Map<String, dynamic>.from(value);
  }

  Future<void> write(String key, Map<String, dynamic> value) async {
    await _records.record(key).put(database, value);
  }
}
