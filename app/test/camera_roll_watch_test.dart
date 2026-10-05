import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/services/camera_roll_watch_service.dart';
import 'package:app/services/document_credentials.dart';
import 'package:flutter_test/flutter_test.dart';

class _Vault extends LifenizerAppState {
  @override
  bool get isAuthenticated => true;
}

class _Store extends DocumentCredentialStore {
  final saved = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>?> read(String identity, String source) async =>
      saved['$identity/$source'];
  @override
  Future<void> write(
    String identity,
    String source,
    Map<String, dynamic> value,
  ) async => saved['$identity/$source'] = value;
}

class _Platform implements CameraRollPlatform {
  _Platform({this.granted = true});
  bool granted;
  int requests = 0;
  @override
  bool get isMobile => true;
  @override
  Future<List<String>> cameraFolders() async => ['/DCIM/Camera'];
  @override
  Future<bool> hasImagesPermission() async => granted;
  @override
  Future<bool> requestImagesPermission() async {
    requests++;
    return granted;
  }
}

final _t0 = DateTime.utc(2026, 10, 1, 12);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Vault state;
  late DateTime now;
  late List<CameraPhotoFile> files;
  late List<String> imported;
  late List<String> kept;
  late CameraRollWatchService service;
  late _Store store;
  Object? keeperError;
  String? Function(CameraPhotoFile) importResult = (p) => 'conv-${p.name}';

  CameraPhotoFile photo(String name, DateTime modified, {int size = 1000}) =>
      CameraPhotoFile(
        path: '/DCIM/Camera/$name',
        size: size,
        modified: modified,
      );

  Future<void> settle() async {
    while (service.working) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> create({_Platform? platform}) async {
    state = _Vault()
      ..session = AuthSession(
        authToken: 't',
        userId: 'u',
        vaultId: 'v',
        vaultSalt: 's',
      );
    addTearDown(state.dispose);
    store = _Store();
    service = CameraRollWatchService(
      state,
      store: store,
      platform: platform ?? _Platform(),
      now: () => now,
      lister: (_) async => List.of(files),
      importer: (p) async {
        final id = importResult(p);
        if (id != null) imported.add(p.name);
        return id;
      },
      keeper: (p, id) async {
        if (keeperError != null) throw keeperError!;
        kept.add('${p.name}->$id');
      },
    );
    addTearDown(service.dispose);
    service.start();
    await settle();
  }

  setUp(() {
    now = _t0;
    files = [];
    imported = [];
    kept = [];
    keeperError = null;
    importResult = (p) => 'conv-${p.name}';
  });

  test(
    'initial stamp skips old photos; a new photo is imported exactly once',
    () async {
      await create();
      files = [photo('old.jpg', _t0.subtract(const Duration(days: 2)))];
      await service.setEnabled(true);
      expect(imported, isEmpty);
      expect(service.permission, CameraPermission.granted);

      files.add(photo('new.jpg', _t0.add(const Duration(minutes: 5))));
      now = _t0.add(const Duration(minutes: 10));
      await service.check();
      expect(imported, ['new.jpg']);
      expect(kept, ['new.jpg->conv-new.jpg']);
      expect(service.imported, 1);

      now = _t0.add(const Duration(minutes: 20));
      await service.check();
      await service.check();
      expect(imported, ['new.jpg'], reason: 'must not import twice');
      expect(service.lastCheck, now);
      expect(service.error, isNull);
    },
  );

  test('"last 7 days" imports recent photos but not older ones', () async {
    await create();
    files = [
      photo('three-days.jpg', _t0.subtract(const Duration(days: 3))),
      photo('ten-days.jpg', _t0.subtract(const Duration(days: 10))),
    ];
    await service.setEnabled(true, includeLastWeek: true);
    expect(imported, ['three-days.jpg']);
  });

  test('photos over 25 MiB and hidden/trashed files are skipped', () async {
    await create();
    await service.setEnabled(true);
    files = [
      photo(
        'huge.jpg',
        _t0.add(const Duration(minutes: 1)),
        size: cameraPhotoMaxBytes + 1,
      ),
      photo('.trashed-123-a.jpg', _t0.add(const Duration(minutes: 2))),
      photo('movie.mp4', _t0.add(const Duration(minutes: 3))),
      photo('ok.heic', _t0.add(const Duration(minutes: 4))),
    ];
    now = _t0.add(const Duration(minutes: 10));
    await service.check();
    expect(imported, ['ok.heic']);
    expect(service.skipped, 1);
    now = _t0.add(const Duration(minutes: 20));
    await service.check();
    expect(imported, ['ok.heic']);
    expect(service.skipped, 1, reason: 'skipped file is not re-counted');
  });

  test('image vault quota failure does not fail the OCR import', () async {
    await create();
    await service.setEnabled(true);
    keeperError = QuotaExceededException('full');
    files = [photo('a.jpg', _t0.add(const Duration(minutes: 1)))];
    now = _t0.add(const Duration(minutes: 10));
    await service.check();
    expect(imported, ['a.jpg']);
    expect(service.imported, 1);
    expect(service.failed, 0);
    expect(service.error, isNull);
    expect(service.vaultNote, contains('quota'));
    // The photo is not retried: the OCR import succeeded.
    now = _t0.add(const Duration(minutes: 20));
    await service.check();
    expect(imported, ['a.jpg']);
  });

  test('keep-in-vault off never uploads the image', () async {
    await create();
    await service.setKeepInVault(false);
    await service.setEnabled(true);
    files = [photo('a.jpg', _t0.add(const Duration(minutes: 1)))];
    now = _t0.add(const Duration(minutes: 10));
    await service.check();
    expect(imported, ['a.jpg']);
    expect(kept, isEmpty);
  });

  test('failed imports are retried and show an inline error', () async {
    await create();
    await service.setEnabled(true);
    files = [photo('a.jpg', _t0.add(const Duration(minutes: 1)))];
    importResult = (_) => null;
    now = _t0.add(const Duration(minutes: 10));
    await service.check();
    expect(service.failed, 1);
    expect(service.error, contains('a.jpg'));
    importResult = (p) => 'conv-${p.name}';
    now = _t0.add(const Duration(minutes: 20));
    await service.check();
    expect(imported, ['a.jpg']);
    expect(service.error, isNull);
  });

  test('permission denial keeps the feature off with a message', () async {
    await create(platform: _Platform(granted: false));
    await service.setEnabled(true);
    expect(service.enabled, isFalse);
    expect(service.permission, CameraPermission.denied);
    expect(service.error, contains('Allow access'));
  });

  test('settings and stamp persist per vault identity', () async {
    await create();
    await service.setEnabled(true);
    files = [photo('a.jpg', _t0.add(const Duration(minutes: 1)))];
    now = _t0.add(const Duration(minutes: 10));
    await service.check();
    final saved = store.saved.values.single;
    expect(saved['enabled'], isTrue);
    expect(saved['imported'], 1);
    expect(
      DateTime.parse(saved['stamp'] as String),
      _t0.add(const Duration(minutes: 1)),
    );
  });
}
