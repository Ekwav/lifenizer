import 'dart:async';
import 'dart:convert';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/services/document_credentials.dart';
import 'package:app/services/local_vault_store.dart';
import 'package:app/services/paperless_client.dart';
import 'package:app/widgets/paperless_import_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sembast/sembast.dart';

class _Database extends Fake implements Database {}

class _ZipPicker extends FilePickerPlatform {
  int size = 3;
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
  }) async {
    expect(allowedExtensions, ['zip']);
    expect(withReadStream, isTrue);
    return FilePickerResult([
      PlatformFile(
        name: 'paperless.zip',
        size: size,
        readStream: Stream.value([1, 2, 3]),
      ),
    ]);
  }
}

class _VaultStore extends LocalVaultStore {
  _VaultStore() : super(_Database());
  final records = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>?> read(String key) async => records[key];
  @override
  Future<void> write(String key, Map<String, dynamic> value) async {
    records[key] = Map.from(value);
  }
}

class _Credentials extends DocumentCredentialStore {
  @override
  Future<Map<String, dynamic>?> read(String identity, String source) async =>
      null;
  @override
  Future<void> write(
    String identity,
    String source,
    Map<String, dynamic> value,
  ) async {}
  @override
  Future<void> remove(String identity, String source) async {}
}

class _Fixture {
  late final LifenizerAppState state;
  bool closed = false;
  void close() {
    if (!closed) {
      state.dispose();
      closed = true;
    }
  }

  String address = 'https://paperless.example.test/paperless/';
  bool configured = true;
  bool settingsFail = false;
  bool importFail = false;
  Completer<void>? settingsGate;
  int settingsRequests = 0;
  final tokens = <String>[];
  final directRequests = <http.Request>[];
  final zipImports = <Map<String, dynamic>>[];

  Future<void> open() async {
    final client = MockClient((request) async {
      if (request.url.path.startsWith('/api/auth/')) {
        return http.Response(
          jsonEncode({
            'authToken': 'auth',
            'userId': 'owner',
            'vaultId': 'vault',
            'vaultSalt': 'salt',
          }),
          200,
        );
      }
      if (request.url.path == '/api/imports/capabilities') {
        return http.Response('[]', 200);
      }
      if (request.url.path == '/api/imports/paperless/settings') {
        settingsRequests++;
        await settingsGate?.future;
        return http.Response(
          settingsFail
              ? '{}'
              : jsonEncode({'configured': configured, 'baseUrl': address}),
          settingsFail ? 503 : 200,
        );
      }
      if (request.url.path == '/api/imports/paperless') {
        tokens.add(
          (jsonDecode(request.body) as Map)['metadata']['token'] as String,
        );
        return http.Response(
          importFail
              ? '{"error":"Invalid API token"}'
              : jsonEncode({
                  'source': 'paperless',
                  'conversations': [],
                  'participants': [],
                  'diagnostics': {'hasMore': 'false', 'nextPage': ''},
                }),
          importFail ? 400 : 200,
        );
      }
      if (request.url.path == '/api/imports/paperless-export') {
        zipImports.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(
          importFail
              ? '{}'
              : '{"source":"paperless-export","conversations":[],"participants":[]}',
          importFail ? 400 : 200,
        );
      }
      return http.Response('{"cursor":0,"envelopes":[]}', 200);
    });
    state = LifenizerAppState(
      localStore: _VaultStore(),
      documentStore: _Credentials(),
      paperlessClient: PaperlessClient(
        client: MockClient((request) async {
          directRequests.add(request);
          return http.Response(
            importFail ? '{}' : '{"results":[],"next":null}',
            importFail ? 401 : 200,
          );
        }),
      ),
      apiFactory: (base) => LifenizerApiClient(baseUrl: base, client: client),
    );
    await state.login(
      baseUrl: 'https://vault.example.test',
      email: 'owner@example.test',
      passphrase: 'a long vault passphrase',
    );
    expect(state.error, isNull);
  }

  Widget get widget => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(child: PaperlessImportPanel(state: state)),
    ),
  );
}

void main() {
  testWidgets(
    'ZIP import needs no server or token and preserves connection inputs on retry',
    (tester) async {
      final f = _Fixture()
        ..configured = false
        ..settingsFail = true
        ..importFail = true;
      await tester.runAsync(f.open);
      addTearDown(f.close);
      final previousPicker = FilePickerPlatform.instance;
      final picker = _ZipPicker();
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = previousPicker);
      await tester.pumpWidget(f.widget);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('paperless-address')),
        'http://127.0.0.1:8002',
      );
      await tester.enterText(
        find.byKey(const Key('paperless-token')),
        'keep-token',
      );
      Future<void> importZip() async {
        final action = tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Import Paperless ZIP'),
            )
            .onPressed!;
        await tester.runAsync(
          () async => await (action as Future<void> Function())(),
        );
        await tester.pumpAndSettle();
      }

      await importZip();
      expect(f.state.error, isNotNull);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('paperless-token')))
            .controller!
            .text,
        'keep-token',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('paperless-address')))
            .controller!
            .text,
        'http://127.0.0.1:8002',
      );
      f.importFail = false;
      await importZip();
      expect(f.state.error, isNull);
      expect(f.zipImports, hasLength(2));
      expect(f.zipImports.last['payloadBase64'], base64Encode([1, 2, 3]));
      expect(f.zipImports.last['originalFileName'], 'paperless.zip');
      expect(f.zipImports.last['metadata'], isNot(contains('token')));
      expect(f.tokens, isEmpty);
      picker.size = 25 * 1024 * 1024 + 1;
      await importZip();
      expect(find.text('Choose an export of at most 25 MiB.'), findsOneWidget);
      expect(f.zipImports, hasLength(2));
      await tester.pumpWidget(const SizedBox.shrink());
      f.close();
    },
  );

  testWidgets(
    'explains tokens and opens the configured installation in an external browser',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(f.close);
      final launches = <MethodCall>[];
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        launches.add(call);
        return true;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(f.widget);
      await tester.pumpAndSettle();
      expect(find.textContaining('access key'), findsOneWidget);
      expect(find.textContaining('My Profile → API token'), findsOneWidget);
      expect(find.textContaining('circular-arrow'), findsOneWidget);
      await tester.tap(find.text('Open Paperless'));
      await tester.pumpAndSettle();
      expect(launches.single.arguments['url'], f.address);
      expect(launches.single.arguments['useWebView'], isFalse);
      expect(launches.single.arguments['useSafariVC'], isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      f.close();
    },
  );

  for (final settingsFail in [false, true]) {
    testWidgets(
      'native setup connects locally without server settings (failure: $settingsFail)',
      (tester) async {
        final f = _Fixture()
          ..configured = false
          ..settingsFail = settingsFail;
        await tester.runAsync(f.open);
        addTearDown(f.close);
        await tester.pumpWidget(f.widget);
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Connect to your Paperless library'),
          findsOneWidget,
        );
        expect(find.text('Retry Paperless setup'), findsNothing);
        final address = find.byKey(const Key('paperless-address'));
        expect(
          tester.widget<TextField>(address).controller!.text,
          'http://127.0.0.1:8002',
        );
        await tester.enterText(address, 'http://127.0.0.1:8002/paperless');
        await tester.enterText(
          find.byKey(const Key('paperless-token')),
          'local-token',
        );
        final action = tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Connect & import'),
            )
            .onPressed!;
        await tester.runAsync(
          () async => await (action as Future<void> Function())(),
        );
        await tester.pumpAndSettle();
        expect(f.directRequests.single.url.path, '/paperless/api/documents/');
        expect(
          f.directRequests.single.headers['Authorization'],
          'Token local-token',
        );
        expect(f.tokens, isEmpty);
        expect(find.text('Check now'), findsOneWidget);
        await tester.tap(find.text('Change API token'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(address).controller!.text,
          'http://127.0.0.1:8002/paperless/',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        f.close();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );
  }

  testWidgets(
    'invalid native addresses preserve inputs and do not send tokens',
    (tester) async {
      final f = _Fixture()..configured = false;
      await tester.runAsync(f.open);
      addTearDown(f.close);
      await tester.pumpWidget(f.widget);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('paperless-address')))
            .controller!
            .text,
        isEmpty,
      );
      await tester.enterText(
        find.byKey(const Key('paperless-token')),
        'private-token',
      );
      for (final address in [
        'https://user:secret@example.test/',
        'https://example.test/?token=secret',
        'javascript:alert(1)',
        'http://public.example.test/',
      ]) {
        await tester.enterText(
          find.byKey(const Key('paperless-address')),
          address,
        );
        await tester.ensureVisible(find.text('Connect & import'));
        await tester.tap(find.text('Connect & import'));
        await tester.pumpAndSettle();
        expect(f.directRequests, isEmpty);
        expect(f.tokens, isEmpty);
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('paperless-token')))
              .controller!
              .text,
          'private-token',
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('paperless-address')))
              .controller!
              .text,
          address,
        );
        expect(
          find.textContaining('Use HTTPS').evaluate().isNotEmpty ||
              find.textContaining('without credentials').evaluate().isNotEmpty,
          isTrue,
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
      f.close();
    },
  );

  testWidgets(
    'failed imports retain the token and successful retry shows compact controls',
    (tester) async {
      final f = _Fixture()..importFail = true;
      await tester.runAsync(f.open);
      addTearDown(f.close);
      await tester.pumpWidget(f.widget);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('paperless-token')),
        'private-api-token',
      );
      Future<void> connect() async {
        await tester.ensureVisible(find.text('Connect & import'));
        final action = tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Connect & import'),
            )
            .onPressed!;
        await tester.runAsync(() async {
          await (action as Future<void> Function())();
        });
        await tester.pumpAndSettle();
      }

      await connect();
      expect(f.state.documentImport.connected, isTrue);
      expect(f.state.documentImport.error, isNotNull);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('paperless-token')))
            .controller!
            .text,
        'private-api-token',
      );
      expect(find.text('Check now'), findsNothing);
      f.importFail = false;
      await connect();
      expect(f.tokens, ['private-api-token', 'private-api-token']);
      expect(find.byKey(const Key('paperless-token')), findsNothing);
      expect(find.text('Check now'), findsOneWidget);
      await tester.tap(find.text('Change API token'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('paperless-token')))
            .controller!
            .text,
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      f.close();
    },
  );
}
