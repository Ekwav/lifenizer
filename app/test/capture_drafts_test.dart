import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/pages/capture_page.dart';
import 'package:app/services/quick_action_service.dart';
import 'package:app/widgets/vault_shell.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _State extends LifenizerAppState {
  _State() {
    session = _session('first');
  }
  static AuthSession _session(String id) => AuthSession(
    authToken: 'test',
    userId: id,
    vaultId: id,
    vaultSalt: 'salt',
  );
  @override
  bool get isAuthenticated => session != null;
  bool fail = false;
  List<String>? savedSegments;
  String? savedText;
  int fileImports = 0;
  @override
  Future<void> addManualText({
    required String title,
    required String participantNames,
    required String text,
    String source = 'manual-text',
    List<String> participantIds = const [],
  }) async {
    error = fail ? 'Disk full' : null;
    if (!fail) savedText = text;
  }

  @override
  Future<void> addRecordingConversation({
    required String title,
    required String participantNames,
    required List<String> segmentTexts,
    List<String> participantIds = const [],
  }) async {
    error = fail ? 'Disk full' : null;
    if (!fail) savedSegments = List.of(segmentTexts);
  }

  @override
  Future<void> importSharedPayload({
    String? fileName,
    List<int>? bytes,
    String? mimeType,
    String? text,
    Map<String, String> metadata = const {},
  }) async {
    fileImports++;
  }
}

class _Picker extends FilePickerPlatform {
  PlatformFile? file;
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
    beforeReturn?.call();
    return file == null ? null : FilePickerResult([file!]);
  }
}

void main() {
  Future<void> click(WidgetTester tester, String label) async {
    final button = find.text(label);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  for (final width in [390.0, 1200.0]) {
    testWidgets('capture drafts survive navigation and quick actions at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = _State();
      addTearDown(state.dispose);
      QuickActionService.instance.consume();
      await tester.pumpWidget(MaterialApp(home: VaultShell(state: state)));
      await click(tester, 'Capture');
      final capture = tester.widget<CapturePage>(find.byType(CapturePage));
      final draft = capture.draft!;
      draft.textController.text = 'Manual draft';
      await click(tester, 'Start session');
      draft.segments.add('First segment');
      draft.segmentController.text = 'Pending segment';
      QuickActionService.instance.request(const QuickAction(query: 'lookup'));
      await tester.pumpAndSettle();
      expect(find.byType(CapturePage), findsNothing);
      await click(tester, 'Capture');
      expect(
        tester.widget<CapturePage>(find.byType(CapturePage)).draft,
        same(draft),
      );
      expect(draft.textController.text, 'Manual draft');
      expect(draft.segmentController.text, 'Pending segment');
      expect(draft.segments, ['First segment']);
      expect(draft.recording, isTrue);
      // A library change while Capture is visible must mount fresh controllers.
      state.session = _State._session('second');
      await tester.pumpWidget(MaterialApp(home: VaultShell(state: state)));
      await tester.pumpAndSettle();
      final fresh = tester.widget<CapturePage>(find.byType(CapturePage)).draft!;
      expect(fresh, isNot(same(draft)));
      expect(fresh.textController.text, isEmpty);
      expect(fresh.recording, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'session saves the final segment and retains all notes on failure',
    (tester) async {
      final state = _State();
      final draft = CaptureDraft()..recording = true;
      addTearDown(state.dispose);
      addTearDown(draft.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CapturePage(state: state, draft: draft),
          ),
        ),
      );
      await click(tester, 'Stop session');
      expect(draft.recording, isTrue);
      expect(state.error, contains('Add a note'));
      draft.segments.add('Added');
      draft.segmentController.text = 'Final';
      state.fail = true;
      await click(tester, 'Stop session');
      expect(draft.segments, ['Added']);
      expect(draft.segmentController.text, 'Final');
      expect(draft.recording, isTrue);
      state.fail = false;
      await click(tester, 'Stop session');
      expect(state.savedSegments, ['Added', 'Final']);
      expect(draft.segments, isEmpty);
      expect(draft.segmentController.text, isEmpty);
      expect(draft.recording, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'manual input remains after failure and clears after successful save',
    (tester) async {
      final state = _State();
      final draft = CaptureDraft();
      addTearDown(state.dispose);
      addTearDown(draft.dispose);
      draft.textController.text = 'Keep this';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CapturePage(state: state, draft: draft),
          ),
        ),
      );
      state.fail = true;
      await click(tester, 'Encrypt import');
      expect(draft.textController.text, 'Keep this');
      state.fail = false;
      await click(tester, 'Encrypt import');
      expect(state.savedText, 'Keep this');
      expect(draft.textController.text, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'file import bounds streamed input and ignores a changed library',
    (tester) async {
      final state = _State();
      addTearDown(state.dispose);
      final previous = FilePickerPlatform.instance;
      final picker = _Picker();
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = previous);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: CapturePage(state: state)),
        ),
      );
      picker.file = PlatformFile(
        name: 'too-large.txt',
        size: 65 * 1024 * 1024,
        readStream: Stream.value([1]),
      );
      await click(tester, 'Choose file');
      expect(state.error, contains('64 MiB'));
      expect(state.fileImports, 0);
      picker.file = PlatformFile(
        name: 'empty.txt',
        size: 0,
        readStream: const Stream.empty(),
      );
      await click(tester, 'Choose file');
      expect(state.error, contains('empty'));
      picker.file = PlatformFile(
        name: 'note.txt',
        size: 1,
        readStream: Stream.value([1]),
      );
      picker.beforeReturn = () => state.session = _State._session('other');
      await click(tester, 'Choose file');
      expect(state.fileImports, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
