import 'package:flutter/foundation.dart';

import '../app_state.dart';
import 'document_credentials.dart';

class DocumentFolderWatchService extends ChangeNotifier {
  DocumentFolderWatchService(
    LifenizerAppState state, {
    DocumentCredentialStore? store,
    Future<bool> Function(String)? importFile,
  });
  List<String> get folders => const [];
  bool get working => false;
  String? get status => null;
  String? get error => null;
  String? get downloadsPath => null;
  void start() {}
  Future<void> addFolder(String path) async =>
      throw UnsupportedError('Use the desktop app to watch document folders.');
  Future<void> removeFolder(String path) async {}
  Future<void> check() async {}
}
