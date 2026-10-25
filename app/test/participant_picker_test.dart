import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/pages/capture_page.dart';
import 'package:app/pages/imports_page.dart';
import 'package:app/widgets/participant_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _CaptureState extends LifenizerAppState {
  List<String>? savedIds;
  String? savedNames;

  @override
  Future<void> addManualText({
    required String title,
    required String participantNames,
    required String text,
    String source = 'manual-text',
    List<String> participantIds = const [],
  }) async {
    savedIds = participantIds;
    savedNames = participantNames;
  }
}

void main() {
  final first = Participant(
    id: 'first-alex',
    displayName: 'Alex',
    identifiers: ['email:first@example.test'],
  );
  final second = Participant(
    id: 'second-alex',
    displayName: 'Alex',
    aliases: ['Sasha'],
    identifiers: ['email:second@example.test'],
  );

  testWidgets(
    'aliases and identifiers select distinct IDs while preserving new names',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = LifenizerAppState()..participants.addAll([first, second]);
      final controller = TextEditingController();
      addTearDown(state.dispose);
      addTearDown(controller.dispose);
      var selected = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => ParticipantPicker(
                state: state,
                controller: controller,
                selectedIds: selected,
                onChanged: (ids) => setState(() => selected = ids),
              ),
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'New friend, Sasha');
      await tester.pumpAndSettle();
      expect(find.textContaining('second@example.test'), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(selected, ['second-alex']);
      expect(controller.text, 'New friend,');
      await tester.enterText(
        find.byType(TextField),
        'New friend, first@example',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('first@example.test'));
      await tester.pumpAndSettle();
      expect(selected, ['second-alex', 'first-alex']);
      expect(controller.text, 'New friend,');
      expect(find.byType(InputChip), findsNWidgets(2));
      final chip = tester.widget<InputChip>(
        find.byKey(const ValueKey('selected-participant-second-alex')),
      );
      chip.onDeleted!();
      await tester.pumpAndSettle();
      expect(selected, ['first-alex']);
      await tester.enterText(find.byType(TextField), 'New friend, Alex');
      await tester.pumpAndSettle();
      expect(find.textContaining('second@example.test'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'keyboard highlighting selects the intended duplicate-name contact',
    (tester) async {
      final state = LifenizerAppState()..participants.addAll([first, second]);
      final controller = TextEditingController();
      addTearDown(state.dispose);
      addTearDown(controller.dispose);
      var selected = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => ParticipantPicker(
                state: state,
                controller: controller,
                selectedIds: selected,
                onChanged: (ids) => setState(() => selected = ids),
              ),
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'Alex');
      await tester.pumpAndSettle();
      expect(find.byType(ListTile), findsNWidgets(2));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        tester.widget<ListTile>(find.byType(ListTile).last).selected,
        isTrue,
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(selected, ['second-alex']);
      expect(controller.text, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('capture submits selected identity separately from typed names', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = _CaptureState()..participants.addAll([first, second]);
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CapturePage(state: state)),
      ),
    );
    final picker = find.byType(ParticipantPicker).first;
    final input = find.descendant(of: picker, matching: find.byType(TextField));
    await tester.ensureVisible(input);
    await tester.enterText(input, 'New friend, second@example');
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('second@example.test'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Encrypt import'));
    await tester.tap(find.text('Encrypt import'));
    await tester.pumpAndSettle();
    expect(state.savedIds, ['second-alex']);
    expect(state.savedNames, 'New friend,');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'import setup keeps multiple selected identities across reopening',
    (tester) async {
      final state = LifenizerAppState()..participants.addAll([first, second]);
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ImportsPage(state: state)),
        ),
      );
      final setup = find.byKey(const Key('import-adapter-manual'));
      await tester.ensureVisible(setup);
      await tester.tap(setup);
      await tester.pumpAndSettle();
      final input = find.descendant(
        of: find.byType(ParticipantPicker),
        matching: find.byType(TextField),
      );
      for (final email in ['second@example', 'first@example']) {
        await tester.ensureVisible(input);
        await tester.enterText(input, email);
        await tester.pumpAndSettle();
        await tester.tap(find.textContaining('$email.test'));
        await tester.pumpAndSettle();
      }
      expect(find.byType(InputChip), findsNWidgets(2));
      await tester.tap(find.byTooltip('Close setup'));
      await tester.pumpAndSettle();
      await tester.tap(setup);
      await tester.pumpAndSettle();
      final picker = tester.widget<ParticipantPicker>(
        find.byType(ParticipantPicker),
      );
      expect(picker.selectedIds, ['second-alex', 'first-alex']);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
