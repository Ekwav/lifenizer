import 'package:sembast_web/sembast_web.dart';

Future<Database> openVaultDatabase() =>
    databaseFactoryWeb.openDatabase('lifenizer-vaults');
