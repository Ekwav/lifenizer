import 'package:flutter/foundation.dart';

import '../app_state.dart';
import 'browser_history_types.dart';
import 'document_credentials.dart';

/// Web build: browser history databases are not readable from the browser.
class BrowserHistoryWatchService extends ChangeNotifier {
  BrowserHistoryWatchService(
    LifenizerAppState state, {
    DocumentCredentialStore? store,
    BrowserProfileDiscoverer? discoverer,
    BrowserVisitReader? reader,
    ViewingBatchImporter? importer,
    TranscriptAutoFetcher? fetcher,
    DateTime Function()? now,
    bool? supportedOverride,
  });
  bool get supported => false;
  bool get enabled => false;
  bool get working => false;
  List<BrowserProfile> get profiles => const [];
  Set<String> get selected => const {};
  Duration get interval => defaultBrowserPollInterval;
  bool get autoTranscripts => false;
  int get transcriptsPerDay => defaultAutoTranscriptsPerDay;
  int get transcriptsToday => 0;
  String? get status => null;
  String? get error => null;
  DateTime? get lastCheck => null;
  int get visitsFound => 0;
  int get videosImported => 0;
  void start() {}
  Future<void> refreshProfiles() async {}
  Future<void> setProfileSelected(
    String path,
    bool value, {
    int backfillDays = 0,
  }) async {}
  Future<void> addProfileFile(String path) async =>
      throw UnsupportedError('Use the desktop app.');
  Future<void> setEnabled(bool value) async =>
      throw UnsupportedError('Use the desktop app.');
  Future<void> setInterval(Duration value) async {}
  Future<void> setAutoTranscripts(bool value) async {}
  Future<void> setTranscriptsPerDay(int value) async {}
  Future<void> check() async {}
  Future<void> afterExternalImport(int newVideos) async {}
}
