import 'package:app/models.dart';
import 'package:app/app_state.dart';
import 'package:app/widgets/recording_context_editor.dart';
import 'package:app/services/recording_location_service.dart';
import 'package:app/widgets/recording_location_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('recording context protects unsaved location edits', (
    tester,
  ) async {
    final state = LifenizerAppState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => RecordingContextEditor(
                  state: state,
                  conversation: Conversation(
                    id: 'recording',
                    title: 'Conversation',
                    source: 'audio',
                    participantIds: [],
                    segments: [],
                  ),
                ),
              ),
              child: const Text('Edit recording'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Edit recording'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Town or city'),
      'Berlin',
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Berlin'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard changes'));
    await tester.pumpAndSettle();
    expect(find.text('Recording details'), findsNothing);
  });

  testWidgets('town and venue edits preserve the snapshot and can remove it', (
    tester,
  ) async {
    RecordingLocation? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecordingLocationFields(
            location: RecordingLocation(
              town: 'Berlin',
              latitude: 52.5,
              longitude: 13.4,
            ),
            onChanged: (value) => selected = value,
          ),
        ),
      ),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Venue'),
      'Café North',
    );
    expect(selected!.searchableText, startsWith('Berlin Café North'));
    expect(selected!.latitude, 52.5);
    await tester.tap(find.text('Remove location'));
    await tester.pump();
    expect(selected, isNull);
    expect(find.widgetWithText(TextField, 'Berlin'), findsNothing);
  });

  testWidgets(
    'location permission denial retains manual input with recovery',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        RecordingLocationService.channel,
        (call) async => false,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          RecordingLocationService.channel,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RecordingLocationFields(
              location: RecordingLocation(town: 'Dresden', venue: 'Museum'),
              onChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.tap(find.text('Use current location'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Enter the town and venue manually'),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextField, 'Dresden'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Museum'), findsOneWidget);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );
}
