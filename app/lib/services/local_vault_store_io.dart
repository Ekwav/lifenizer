import 'package:path_provider/path_provider.dart';
import 'local_vault_store.dart';
import 'vault_database_worker.dart';

Future<LocalVaultStore> openVaultStore() async {
  final directory = await getApplicationSupportDirectory();
  await directory.create(recursive: true);
  return LocalVaultStore.remote(
    await openVaultDatabaseWorker('${directory.path}/lifenizer-vaults.db'),
  );
}
