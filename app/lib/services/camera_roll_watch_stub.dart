import 'package:flutter/foundation.dart';

import '../app_state.dart';
import 'camera_roll_types.dart';
import 'document_credentials.dart';

/// Web build: camera folders are not readable from the browser.
class CameraRollWatchService extends ChangeNotifier {
  CameraRollWatchService(
    LifenizerAppState state, {
    DocumentCredentialStore? store,
    CameraFolderLister? lister,
    CameraPhotoImporter? importer,
    CameraPhotoKeeper? keeper,
    CameraRollPlatform? platform,
    DateTime Function()? now,
  });
  bool get supported => false;
  bool get needsFolderChoice => false;
  bool get enabled => false;
  bool get keepInVault => true;
  List<String> get folders => const [];
  CameraPermission get permission => CameraPermission.unknown;
  bool get working => false;
  String? get status => null;
  String? get error => null;
  String? get vaultNote => null;
  DateTime? get lastCheck => null;
  int get imported => 0;
  int get skipped => 0;
  int get failed => 0;
  String? get lastFile => null;
  void start() {}
  Future<void> setEnabled(bool value, {bool includeLastWeek = false}) async =>
      throw UnsupportedError('Use the Android or desktop app.');
  Future<void> setKeepInVault(bool value) async {}
  Future<void> addFolder(String path) async =>
      throw UnsupportedError('Use the desktop app to watch a camera folder.');
  Future<void> removeFolder(String path) async {}
  Future<void> check() async {}
}
