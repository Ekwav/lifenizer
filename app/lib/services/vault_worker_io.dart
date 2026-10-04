import 'dart:isolate';

Future<T> runVaultWork<T>(Future<T> Function() operation) =>
    Isolate.run(operation, debugName: 'vault');
