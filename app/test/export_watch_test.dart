import 'dart:io';

import 'package:app/app_state.dart';
import 'package:app/services/export_watch_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _WatchVault extends LifenizerAppState {
  bool unlocked = true;
  int imports = 0;
  @override
  bool get isAuthenticated => unlocked;

  Future<void> recordImport(String path) async {
    imports++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('watched exports resume securely and wait while locked', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp('lifenizer-watch-');
    final file = File('${directory.path}/package.zip');
    await file.writeAsString('first export');
    final state = _WatchVault()..rememberedEmail = 'owner@example.test';
    var watcher = ExportWatchService(importFile: state.recordImport);
    try {
      await watcher.start(state);
      await pumpEventQueue();
      await watcher.watch(file.path);
      expect(state.imports, 1);
      await watcher.checkForChanges();
      expect(state.imports, 1);
      watcher.dispose();
      watcher = ExportWatchService(importFile: state.recordImport);
      await watcher.start(state);
      await pumpEventQueue();
      expect(watcher.path, file.path);
      expect(state.imports, 1);
      state.unlocked = false;
      await file.writeAsString('changed export with another message');
      await watcher.checkForChanges();
      expect(state.imports, 1);
      state.unlocked = true;
      await watcher.checkForChanges();
      expect(state.imports, 2);
      await watcher.stopWatching();
      await file.writeAsString('another update after stopping');
      await watcher.checkForChanges();
      expect(state.imports, 2);
    } finally {
      watcher.dispose();
      state.dispose();
      await directory.delete(recursive: true);
    }
  });
}
