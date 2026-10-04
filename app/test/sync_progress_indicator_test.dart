import 'package:app/app_state.dart';
import 'package:app/pages/search_page.dart';
import 'package:app/services/sync_progress.dart';
import 'package:app/widgets/sync_progress_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Search displays preparation progress until the index is ready', (
    tester,
  ) async {
    final state = LifenizerAppState()
      ..busy = true
      ..syncProgress = const SyncProgress(
        stage: SyncStage.indexing,
        completed: 0,
        total: 100,
      );
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SearchPage(state: state)),
        ),
      );
      expect(find.byType(SyncProgressIndicator), findsOneWidget);
      expect(find.text('Calculating estimate…'), findsOneWidget);
      state.syncProgress = const SyncProgress(stage: SyncStage.complete);
      state.busy = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SearchPage(state: state)),
        ),
      );
      expect(find.byType(SyncProgressIndicator), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    }
  });

  testWidgets(
    'local preparation shows elapsed time without fabricated progress',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SyncProgressIndicator(
              progress: SyncProgress(
                stage: SyncStage.derivingKey,
                elapsed: Duration(seconds: 12),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Elapsed 12s'), findsOneWidget);
      expect(
        find.text('No reliable time estimate for this step yet.'),
        findsOneWidget,
      );
      expect(find.textContaining('records received'), findsNothing);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        isNull,
      );
    },
  );

  testWidgets(
    'search preparation uses measured counts and rate for its estimate',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SyncProgressIndicator(
              progress: SyncProgress(
                stage: SyncStage.indexing,
                completed: 25,
                total: 100,
                elapsed: Duration(seconds: 20),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Elapsed 20s'), findsOneWidget);
      expect(find.text('About 1m 0s remaining'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .25,
      );
      expect(find.textContaining('records received'), findsNothing);
    },
  );

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
