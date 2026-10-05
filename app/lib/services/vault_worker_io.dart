import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:isolate';

Future<T> runVaultWork<T>(Future<T> Function() operation) =>
    Isolate.run(operation, debugName: 'vault');

/// Parallel crypto lanes for the chunked vault (isolates are real threads).
int vaultWorkerCount() => math.max(1, math.min(Platform.numberOfProcessors, 6));
