import 'dart:async';
import 'dart:convert';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/pages/imports_page.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

AuthSession _session(String id) =>
    AuthSession(authToken: 'test', userId: id, vaultId: id, vaultSalt: 'salt');

class _Picker extends FilePickerPlatform {
  PlatformFile? file;
  Object? failure;
  void Function()? beforeReturn;

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
    expect(withData, isFalse);
    expect(withReadStream, isTrue);
    if (failure != null) throw failure!;
    beforeReturn?.call();
    return file == null ? null : FilePickerResult([file!]);
  }
}

class _Fixture {
  final state = LifenizerAppState();
  final picker = _Picker();
  final imports = <Map<String, dynamic>>[];

  Future<void> open(WidgetTester tester, {required bool audio}) async {
    addTearDown(state.dispose);
    final previous = FilePickerPlatform.instance;
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = previous);
    await tester.runAsync(
      () => state.debugAuthenticateForTesting(
        LifenizerApiClient(
          baseUrl: 'https://vault.example.test',
          client: MockClient((request) async {
            if (request.url.path.startsWith('/api/imports/')) {
              imports.add(jsonDecode(request.body) as Map<String, dynamic>);
              return http.Response(
                jsonEncode({
                  'source': request.url.pathSegments.last,
                  'plaintextCompute': false,
                  'message': 'Imported',
                  'participants': <dynamic>[],
                  'conversations': <dynamic>[],
                }),
                200,
              );
            }
            return http.Response('{"cursor":0,"envelopes":[]}', 200);
          }),
        ),
      ),
    );
    state.session = _session('first');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ImportsPage(state: state)),
      ),
    );
    if (audio) {
      await tester.enterText(find.byKey(const Key('imports-search')), 'audio');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('import-adapter-audio')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Title (optional)'),
        'Recording draft',
      );
    }
  }

  Future<void> choose(
    WidgetTester tester, {
    required bool audio,
    bool expectImport = false,
  }) async {
    final button = find.byKey(
      Key(audio ? 'import-audio-button' : 'imports-auto-file'),
    );
    await tester.ensureVisible(button);
    final action = tester.widget<FilledButton>(button).onPressed!;
    await tester.runAsync(() async {
      final finished = Completer<void>();
      var started = false;
      void observeImport() {
        started = started || state.busy;
        if (started && !state.busy && !finished.isCompleted) {
          finished.complete();
        }
      }

      if (expectImport) state.addListener(observeImport);
      try {
        action();
        if (expectImport) {
          await finished.future.timeout(const Duration(seconds: 30));
        }
        await Future<void>.delayed(Duration.zero);
      } finally {
        if (expectImport) state.removeListener(observeImport);
      }
    });
    await tester.pumpAndSettle();
  }

  PlatformFile file({required bool audio, Stream<List<int>>? stream}) =>
      PlatformFile(
        name: audio ? 'recording.m4a' : 'message.eml',
        size: 3,
        readStream: stream ?? Stream.value([1, 2, 3]),
      );
}

void main() {
  testWidgets(
    'audio rejects oversized metadata without reading, and empty streams, preserving details',
    (tester) async {
      final f = _Fixture();
      await f.open(tester, audio: true);
      var read = false;
      f.picker.file = PlatformFile(
        name: 'large.m4a',
        size: 128 * 1024 * 1024 + 1,
        readStream: Stream.multi((sink) {
          read = true;
          sink.close();
        }),
      );
      await f.choose(tester, audio: true);
      expect(read, isFalse);
      expect(find.textContaining('at most 128 MiB'), findsOneWidget);
      f.picker.file = f.file(
        audio: true,
        stream: const Stream<List<int>>.empty(),
      );
      await f.choose(tester, audio: true);
      expect(find.textContaining('selected export is empty'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.widgetWithText(TextField, 'Title (optional)'),
            )
            .controller!
            .text,
        'Recording draft',
      );
      expect(f.imports, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'audio picker failure preserves metadata and allows a successful retry',
    (tester) async {
      final f = _Fixture();
      await f.open(tester, audio: true);
      f.picker.failure = StateError('Picker unavailable');
      await f.choose(tester, audio: true);
      expect(
        find.textContaining('Choose the file again to retry'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      f.picker.failure = null;
      f.picker.file = f.file(audio: true);
      await f.choose(tester, audio: true, expectImport: true);
      expect(f.imports, hasLength(1));
      expect(f.state.busy, isFalse);
      expect(f.state.error, isNull);
      expect(f.imports.single['title'], 'Recording draft');
      expect(f.imports.single['payloadBase64'], base64Encode([1, 2, 3]));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final audio in [false, true]) {
    for (final duringRead in [false, true]) {
      testWidgets(
        '${audio ? 'audio' : 'generic'} picker ignores ${duringRead ? 'a server change during read' : 'an account change during selection'}',
        (tester) async {
          final f = _Fixture();
          await f.open(tester, audio: audio);
          void changeIdentity() {
            if (duringRead) {
              f.state.apiBaseUrl = 'https://second.example.test';
            } else {
              f.state.session = _session('second');
            }
          }

          f.picker.file = f.file(
            audio: audio,
            stream: duringRead
                ? Stream.multi((sink) {
                    changeIdentity();
                    sink.add([1, 2, 3]);
                    sink.close();
                  })
                : null,
          );
          if (!duringRead) f.picker.beforeReturn = changeIdentity;
          await f.choose(tester, audio: audio);
          expect(f.imports, isEmpty);
          expect(f.state.error, isNull);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }

    testWidgets(
      '${audio ? 'audio' : 'generic'} picker reports a busy operation and permits retry',
      (tester) async {
        final f = _Fixture();
        await f.open(tester, audio: audio);
        f.picker.file = f.file(audio: audio);
        f.picker.beforeReturn = () => f.state.busy = true;
        await f.choose(tester, audio: audio);
        if (audio) {
          expect(
            find.textContaining('Wait for the current operation'),
            findsOneWidget,
          );
        } else {
          expect(f.state.error, contains('Wait for the current operation'));
        }
        expect(f.imports, isEmpty);
        f.state.busy = false;
        f.picker.beforeReturn = null;
        f.state.reportUnlockProgress(null);
        await tester.pumpAndSettle();
        await f.choose(tester, audio: audio, expectImport: true);
        expect(f.imports, hasLength(1));
        expect(f.state.busy, isFalse);
        expect(f.state.error, isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
