import 'package:path_provider/path_provider.dart';

import 'local_vault_store.dart';
import 'vault_chunk_file_store.dart';
import 'vault_chunk_store.dart';

Future<VaultChunkStore> openVaultChunkStore(LocalVaultStore store) async {
  final directory = await getApplicationSupportDirectory();
  return FileVaultChunkStore('${directory.path}/lifenizer-vaults');
}
