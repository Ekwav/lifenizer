import 'dart:async';
import 'dart:io';

import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/services/document_credentials.dart';
import 'package:app/services/document_folder_watch_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Vault extends LifenizerAppState {
  bool unlocked = true;
  @override
  bool get isAuthenticated => unlocked;
  void setUnlocked(bool value) {
    unlocked = value;
    notifyListeners();
  }
}

class _Store extends DocumentCredentialStore {
  final saved = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>?> read(String identity, String source) async =>
      saved['$identity/$source'];
  @override
  Future<void> write(
    String identity,
    String source,
    Map<String, dynamic> value,
  ) async => saved['$identity/$source'] = value;
}

Future<File> _document(String path, String contents) async {
  final file = await File(path).writeAsString(contents);
  await file.setLastModified(
    DateTime.now().subtract(const Duration(minutes: 1)),
  );
  return file;
}

Future<void> _settled(DocumentFolderWatchService watcher) async {
  while (watcher.working) {
    final changed = Completer<void>();
    void listener() {
      watcher.removeListener(listener);
      changed.complete();
    }

    watcher.addListener(listener);
    await changed.future.timeout(const Duration(seconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'folder imports retry failures, skip links/subfolders and clear on lock',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lifenizer-doc-watch-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final pdf = await _document('${directory.path}/scan.pdf', 'PDF one');
      await _document('${directory.path}/notes.txt', 'not a PDF');
      final nested = await Directory('${directory.path}/nested').create();
      await _document('${nested.path}/hidden.pdf', 'not enrolled');
      await Link('${directory.path}/linked.pdf').create(pdf.path);
      final state = _Vault()
        ..session = AuthSession(
          authToken: 'token',
          userId: 'owner',
          vaultId: 'vault',
          vaultSalt: 'salt',
        );
      addTearDown(state.dispose);
      final store = _Store();
      final imports = <String>[];
      var successful = false;
      final watcher = DocumentFolderWatchService(
        state,
        store: store,
        importFile: (path) async {
          imports.add(path);
          return successful;
        },
      );
      addTearDown(watcher.dispose);
      watcher.start();
      await _settled(watcher);
      await watcher.addFolder(directory.path);
      expect(imports, [pdf.path]);
      expect((store.saved.values.single['stamps'] as Map), isEmpty);
      successful = true;
      await watcher.check();
      expect(imports, [pdf.path, pdf.path]);
      await watcher.check();
      expect(imports.length, 2);
      state.setUnlocked(false);
      expect(watcher.folders, isEmpty);
      await _document(pdf.path, 'Updated PDF contents');
      await watcher.check();
      expect(imports.length, 2);
      state.setUnlocked(true);
      await _settled(watcher);
      expect(watcher.folders, [directory.path]);
      expect(imports.length, 3);
      await watcher.removeFolder(directory.path);
      await _document(pdf.path, 'Later document');
      await watcher.check();
      expect(imports.length, 3);
    },
  );
  test(
    'recent writes wait and selected symbolic-link directories are rejected',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lifenizer-doc-watch-',
      );
      addTearDown(() => directory.delete(recursive: true));
      await File(
        '${directory.path}/downloading.pdf',
      ).writeAsString('still writing');
      final linked = Link('${directory.path}/folder-link');
      await linked.create(directory.path);
      final state = _Vault()
        ..session = AuthSession(
          authToken: 'token',
          userId: 'owner',
          vaultId: 'vault',
          vaultSalt: 'salt',
        );
      addTearDown(state.dispose);
      var imported = 0;
      final watcher = DocumentFolderWatchService(
        state,
        store: _Store(),
        importFile: (_) async {
          imported++;
          return true;
        },
      );
      addTearDown(watcher.dispose);
      watcher.start();
      await _settled(watcher);
      await expectLater(watcher.addFolder(linked.path), throwsFormatException);
      await watcher.addFolder(directory.path);
      expect(imported, 0);
    },
  );
}
