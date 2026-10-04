import 'package:sembast_web/sembast_web.dart';
import 'local_vault_store.dart';

Future<LocalVaultStore> openVaultStore() async =>
    LocalVaultStore(await databaseFactoryWeb.openDatabase('lifenizer-vaults'));
