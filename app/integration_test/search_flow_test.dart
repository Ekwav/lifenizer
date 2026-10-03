import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/widgets/vault_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Search and navigation integration', () {
    testWidgets('opens search page by default', (tester) async {
      final state = _seedState();
      await _pumpVault(tester, state);

      expect(find.text('Search'), findsOneWidget);
      expect(find.text('Search text, people, relations'), findsOneWidget);
    });

    testWidgets('types query and sees filtered result count', (tester) async {
      final state = _seedState();
      await _pumpVault(tester, state);

      await tester.enterText(
        find.byType(TextField).first,
        'temporal archive',
      );
      await tester.pumpAndSettle();

      expect(find.text('1 result'), findsOneWidget);
      expect(find.text('Importer retrospective (last year)'), findsOneWidget);
    });

    testWidgets('temporal intent phrase shows same-time-last-year conversation', (tester) async {
      final state = _seedState();
      await _pumpVault(tester, state);

      await tester.enterText(
        find.byType(TextField).first,
        'importer same time last year',
      );
      await tester.pumpAndSettle();

      expect(find.text('Importer retrospective (last year)'), findsOneWidget);
    });

    testWidgets('applies source filter in search flow', (tester) async {
      final state = _seedState();
      await _pumpVault(tester, state);

      await tester.enterText(find.byType(TextField).first, 'release');
      await tester.pumpAndSettle();
      expect(find.text('2 results'), findsOneWidget);

      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('email').last);
      await tester.pumpAndSettle();

      expect(find.text('1 result'), findsOneWidget);
      expect(find.text('Release prep mail'), findsOneWidget);
    });

    testWidgets('opens conversation detail from search results', (tester) async {
      final state = _seedState();
      await _pumpVault(tester, state);

      await tester.enterText(find.byType(TextField).first, 'release prep');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Release prep mail').first);
      await tester.pumpAndSettle();

      expect(find.text('Transcript'), findsOneWidget);
      expect(find.textContaining('release prep details'), findsOneWidget);
    });

    testWidgets('all eight pages are accessible from bottom navigation', (tester) async {
      final state = _seedState();
      await _pumpVault(tester, state);

      final pages = [
        ('Insights', 'Insights'),
        ('Capture', 'Capture'),
        ('Imports', 'Imports'),
        ('People', 'People'),
        ('Relations', 'Relations'),
        ('Sync', 'Sync'),
        ('Plans', 'Pricing'),
        ('Search', 'Search'),
      ];

      for (final page in pages) {
        await tester.tap(find.text(page.$1).last);
        await tester.pumpAndSettle();
        expect(find.text(page.$2), findsOneWidget);
      }
    });

    testWidgets('back-forward style tab switching keeps app data state', (tester) async {
      final state = _seedState();
      await _pumpVault(tester, state);

      await tester.tap(find.text('Search').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'importer');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sync').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Search').last);
      await tester.pumpAndSettle();

      expect(find.text('2 results'), findsOneWidget);
      expect(state.conversations.length, greaterThanOrEqualTo(4));
    });

    testWidgets('saved search survives page navigation and returns on search page', (tester) async {
      final state = _seedState();
      await _pumpVault(tester, state);

      await tester.enterText(find.byType(TextField).first, 'release');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save search'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Insights').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Search').last);
      await tester.pumpAndSettle();

      expect(find.byType(ActionChip), findsWidgets);
      expect(state.savedSearches, isNotEmpty);
    });

    testWidgets('capture page is reachable with core controls visible', (tester) async {
      final state = _seedState();
      await _pumpVault(tester, state);

      await tester.tap(find.text('Capture').last);
      await tester.pumpAndSettle();

      expect(find.text('Capture'), findsOneWidget);
      expect(find.text('Manual text'), findsOneWidget);
      expect(find.text('Start session'), findsOneWidget);
    });

    testWidgets('imports page is reachable with import actions visible', (tester) async {
      final state = _seedState();
      await _pumpVault(tester, state);

      await tester.tap(find.text('Imports').last);
      await tester.pumpAndSettle();

      expect(find.text('Imports'), findsOneWidget);
      expect(find.text('Import and encrypt'), findsOneWidget);
      expect(find.text('whatsapp'), findsWidgets);
    });
  });
}

Future<void> _pumpVault(WidgetTester tester, LifenizerAppState state) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      home: VaultShell(state: state),
    ),
  );
  await tester.pumpAndSettle();
}

LifenizerAppState _seedState() {
  final state = LifenizerAppState();

  final alice = Participant(id: 'p-alice', displayName: 'Alice');
  final bob = Participant(id: 'p-bob', displayName: 'Bob');
  state.participants.addAll([alice, bob]);

  final now = DateTime.now().toUtc();
  final sameTimeLastYear = DateTime.utc(
    now.year - 1,
    now.month,
    now.day > 28 ? 28 : now.day,
    now.hour,
    now.minute,
  );

  state.conversations.addAll([
    Conversation(
      id: 'c-last-year',
      title: 'Importer retrospective (last year)',
      source: 'manual-text',
      participantIds: [alice.id],
      tags: const ['work'],
      segments: [
        ConversationSegment(id: 's-1', text: 'temporal archive notes'),
      ],
      startedAt: sameTimeLastYear,
      endedAt: sameTimeLastYear,
    ),
    Conversation(
      id: 'c-release-email',
      title: 'Release prep mail',
      source: 'email',
      participantIds: [alice.id, bob.id],
      tags: const ['work'],
      segments: [
        ConversationSegment(id: 's-2', text: 'release prep details and rollout'),
      ],
      startedAt: now.subtract(const Duration(days: 1)),
      endedAt: now.subtract(const Duration(days: 1)),
    ),
    Conversation(
      id: 'c-release-chat',
      title: 'Release prep chat',
      source: 'chat',
      participantIds: [bob.id],
      tags: const ['personal'],
      segments: [
        ConversationSegment(id: 's-3', text: 'release checklist and reminders'),
      ],
      startedAt: now.subtract(const Duration(days: 2)),
      endedAt: now.subtract(const Duration(days: 2)),
    ),
    Conversation(
      id: 'c-random',
      title: 'Weekend errands',
      source: 'manual-text',
      participantIds: [alice.id],
      tags: const ['personal'],
      segments: [
        ConversationSegment(id: 's-4', text: 'grocery and bike repair'),
      ],
      startedAt: now.subtract(const Duration(days: 3)),
      endedAt: now.subtract(const Duration(days: 3)),
    ),
  ]);

  return state;
}
