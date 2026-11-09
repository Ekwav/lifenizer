import 'local_vault_store.dart';
import 'vault_chunk_store.dart';
import 'vault_chunk_store_sembast.dart';

Future<VaultChunkStore> openVaultChunkStore(LocalVaultStore store) async =>
    SembastVaultChunkStore(store);
