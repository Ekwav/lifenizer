part of '../app_state.dart';

extension VaultEmail on LifenizerAppState {
  Future<Map<String, dynamic>> imapSettings() => _requireApi().imapSettings();

  /// A cursor is usable only after this method returns a persisted result.
  Future<NormalizedImportResult?> importEmailPage(
    Map<String, String> metadata,
  ) async {
    NormalizedImportResult? saved;
    await _run(() async {
      if (!isAuthenticated) {
        throw StateError('Unlock the vault to import email.');
      }
      final owner = session!.userId;
      final result = await _requireApi().importSource(
        'email',
        ImportSourceRequest(metadata: metadata),
        timeout: const Duration(minutes: 10),
      );
      if (!isAuthenticated || session!.userId != owner) {
        throw StateError(
          'The vault changed before the email import completed.',
        );
      }
      await _ingestNormalizedImport(result);
      await _persistLocal();
      saved = result;
    });
    return saved;
  }
}
