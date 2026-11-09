import 'package:flutter/foundation.dart';
import '../app_state.dart';

class ExportWatchService extends ChangeNotifier {
  ExportWatchService({Future<void> Function(String)? importFile});
  static final instance = ExportWatchService();
  String? get path => null;
  Future<void> start(LifenizerAppState state) async {}
  Future<void> watch(String path) async =>
      throw UnsupportedError('Use the desktop app to watch exports.');
  Future<void> stopWatching() async {}
  Future<void> checkForChanges() async {}
}
