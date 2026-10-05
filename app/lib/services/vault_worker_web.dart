Future<T> runVaultWork<T>(Future<T> Function() operation) => operation();

/// The browser fallback keeps a single sequential lane.
int vaultWorkerCount() => 1;
