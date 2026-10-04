import 'package:app/services/sync_progress.dart';
import 'package:app/widgets/sync_progress_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows real byte progress for a batch and no invented total', (
    tester,
  ) async {
    Future<void> show(SyncProgress progress) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SyncProgressIndicator(progress: progress)),
      ),
    );
    await show(
      const SyncProgress(
        stage: SyncStage.downloading,
        batch: 3,
        receivedBytes: 1024 * 1024,
        totalBytes: 2 * 1024 * 1024,
        downloaded: 1000,
        uploaded: 2,
      ),
    );
    expect(find.text('Downloading encrypted batch 3'), findsOneWidget);
    expect(find.text('1.0 MB / 2.0 MB in this batch'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      .5,
    );
    await show(
      const SyncProgress(
        stage: SyncStage.downloading,
        batch: 3,
        receivedBytes: 1024 * 1024,
      ),
    );
    expect(find.text('1.0 MB received in this batch'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      isNull,
    );
    await show(const SyncProgress(stage: SyncStage.failed, downloaded: 1000));
    expect(find.text('Sync interrupted · retry to continue'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
}
