import 'dart:typed_data';

import 'package:app/services/backup_archive.dart';
import 'package:flutter_test/flutter_test.dart';

class _Target implements BackupTarget {
  final files = <String, List<int>>{};
  String? current;
  bool aborted = false;
  @override
  String get label => 'memory';
  @override
  Future<void> openPart(String name) async {
    current = name;
    files[name] = [];
  }

  @override
  Future<void> write(Uint8List bytes) async => files[current]!.addAll(bytes);
  @override
  Future<void> closePart() async => current = null;
  @override
  Future<void> abort() async {
    aborted = true;
    files.clear();
  }

  List<BackupPart> get parts => files.entries
      .map(
        (entry) => BackupPart(
          name: entry.key,
          // Exercise split headers, multibyte characters and authentication tags.
          openRead: () => Stream.fromIterable([
            for (var i = 0; i < entry.value.length; i += 3)
              entry.value.sublist(
                i,
                i + 3 > entry.value.length ? entry.value.length : i + 3,
              ),
          ]),
        ),
      )
      .toList();
}

class _FailingTarget extends _Target {
  @override
  Future<void> write(Uint8List bytes) async {
    await super.write(bytes);
    throw StateError('destination failed');
  }
}

void main() {
  final records = <Map<String, dynamic>>[
    {'kind': 'manifest', 'version': 1},
    {
      'text': 'Hello 世界 🦊 café ' * 12,
      'nested': {'enabled': true},
    },
    {'last': 3},
  ];
  late _Target target;
  setUp(() async {
    target = _Target();
    await writeBackup(
      Stream.fromIterable(records),
      password: 'test password',
      target: target,
      partBytes: 150,
    );
  });

  test(
    'round trips selected parts in any order within the exact size limit',
    () async {
      expect(target.files.length, greaterThan(2));
      expect(target.files.values.every((bytes) => bytes.length <= 150), isTrue);
      expect(target.files.values.any((bytes) => bytes.length == 150), isTrue);
      expect(
        await readBackup(
          target.parts.reversed.toList(),
          password: 'test password',
        ).toList(),
        records,
      );
      final bytes = target.files.values.expand((v) => v).toList();
      expect(String.fromCharCodes(bytes), isNot(contains('manifest')));
    },
  );

  test('rejects wrong passwords and ciphertext tampering', () async {
    await expectLater(
      readBackup(target.parts, password: 'wrong').toList(),
      throwsA(anything),
    );
    target.files.values.first[57] ^= 1;
    await expectLater(
      readBackup(target.parts, password: 'test password').toList(),
      throwsA(anything),
    );
  });

  test(
    'rejects missing first, middle and final parts and duplicates',
    () async {
      final parts = target.parts;
      for (final index in [0, parts.length ~/ 2, parts.length - 1]) {
        await expectLater(
          readBackup(
            [...parts]..removeAt(index),
            password: 'test password',
          ).toList(),
          throwsA(anything),
        );
      }
      await expectLater(
        readBackup([...parts, parts.first], password: 'test password').toList(),
        throwsA(anything),
      );
    },
  );

  test(
    'rejects truncation, appended bytes and extra parts after end',
    () async {
      final last = target.files.values.last;
      final saved = [...last];
      last.removeLast();
      await expectLater(
        readBackup(target.parts, password: 'test password').toList(),
        throwsA(anything),
      );
      last
        ..clear()
        ..addAll(saved)
        ..add(0);
      await expectLater(
        readBackup(target.parts, password: 'test password').toList(),
        throwsA(anything),
      );
      last
        ..clear()
        ..addAll(saved);
      final parts = target.parts;
      await expectLater(
        readBackup([
          ...parts,
          BackupPart(name: 'zz-extra', openRead: () => Stream.value(saved)),
        ], password: 'test password').toList(),
        throwsA(anything),
      );
    },
  );

  test('authenticates headers and frame sequence', () async {
    final first = target.files.values.first;
    first[24] ^= 1;
    await expectLater(
      readBackup(target.parts, password: 'test password').toList(),
      throwsA(anything),
    );
    first[24] ^= 1;
    first[56] ^= 1;
    await expectLater(
      readBackup(target.parts, password: 'test password').toList(),
      throwsA(anything),
    );
  });

  test(
    'minimal part capacity and empty archives require an authenticated end',
    () async {
      final empty = _Target();
      final summary = await writeBackup(
        const Stream.empty(),
        password: 'test password',
        target: empty,
        partBytes: 74,
      );
      expect(summary.bytes, 73);
      expect(summary.parts, 1);
      expect(
        await readBackup(empty.parts, password: 'test password').toList(),
        isEmpty,
      );
      empty.files.values.single.removeRange(44, 73);
      await expectLater(
        readBackup(empty.parts, password: 'test password').toList(),
        throwsA(anything),
      );
    },
  );

  test('aborts incomplete output on record or destination failure', () async {
    final incomplete = _Target();
    final stream = Stream<Map<String, dynamic>>.multi((controller) {
      controller.add({'valid': true});
      controller.addError(StateError('source failed'));
      controller.close();
    });
    await expectLater(
      writeBackup(
        stream,
        password: 'test password',
        target: incomplete,
        partBytes: 150,
      ),
      throwsStateError,
    );
    expect(incomplete.aborted, isTrue);
    expect(incomplete.files, isEmpty);
    final failing = _FailingTarget();
    await expectLater(
      writeBackup(
        Stream.fromIterable(records),
        password: 'test password',
        target: failing,
      ),
      throwsStateError,
    );
    expect(failing.aborted, isTrue);
    expect(failing.files, isEmpty);
    await expectLater(
      writeBackup(
        const Stream.empty(),
        password: 'test password',
        target: incomplete,
        partBytes: 73,
      ),
      throwsArgumentError,
    );
  });
}
