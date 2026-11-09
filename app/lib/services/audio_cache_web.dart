import 'package:sembast_web/sembast_web.dart';

Future<Map<String, dynamic>?> readAudioCache(String key) async {
  final db = await databaseFactoryWeb.openDatabase('lifenizer-audio');
  try {
    return await stringMapStoreFactory.store('audio').record(key).get(db);
  } finally {
    await db.close();
  }
}

Future<void> writeAudioCache(String key, Map<String, dynamic> value) async {
  final db = await databaseFactoryWeb.openDatabase('lifenizer-audio');
  try {
    await stringMapStoreFactory.store('audio').record(key).put(db, value);
  } finally {
    await db.close();
  }
}
