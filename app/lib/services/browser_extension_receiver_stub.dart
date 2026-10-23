import 'package:flutter/foundation.dart';

import '../app_state.dart';
import '../models.dart';
import 'browser_history_types.dart';
import 'document_credentials.dart';

/// Web and mobile builds cannot listen for the browser extension.
class BrowserExtensionReceiverService extends ChangeNotifier {
  BrowserExtensionReceiverService(
    LifenizerAppState state, {
    DocumentCredentialStore? store,
    ViewingBatchImporter? importer,
    Future<int?> Function(NormalizedImportResult)? messageImporter,
    Future<void> Function(int imported)? onImported,
    DateTime Function()? now,
    int? defaultPort,
    bool? supportedOverride,
  });
  bool get supported => false;
  bool get enabled => false;
  bool get listening => false;
  int get port => 47615;
  String? get token => null;
  String? get error => null;
  DateTime? get lastSync => null;
  int get visitsAccepted => 0;
  int get videosImported => 0;
  void start() {}
  Future<void> setEnabled(bool value) async =>
      throw UnsupportedError('Use the desktop app.');
  Future<void> setPort(int value) async {}
  Future<void> regenerateToken() async {}
}
