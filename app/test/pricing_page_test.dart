import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/pricing_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'temporary free Premium shows active storage without paid offers',
    (tester) async {
      final state = LifenizerAppState()
        ..quotaStatus = QuotaStatus.fromJson({
          'plan': 'Premium',
          'usedBytes': 0,
          'limitBytes': 10 * 1024 * 1024 * 1024,
          'usedPercent': 0.0,
          'freePremiumEnabled': true,
        });
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PricingPage(state: state)),
        ),
      );
      expect(find.text('Premium is free for now'), findsOneWidget);
      expect(find.text('Current plan: Premium'), findsOneWidget);
      expect(find.text('0 KB of 10.0 GB used'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      expect(state.quotaStatus!.toJson()['freePremiumEnabled'], isTrue);
    },
  );

  testWidgets('PremiumPlus API status marks Plus active and disables checkout', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final state = LifenizerAppState()
      ..quotaStatus = QuotaStatus.fromJson({
        'plan': 'PremiumPlus',
        'usedBytes': 0,
        'limitBytes': 100 * 1024 * 1024 * 1024,
        'usedPercent': 0.0,
      });
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: PricingPage(state: state))),
    );

    expect(find.text('Upgrade to Premium+'), findsNothing);
    final active = find.widgetWithText(FilledButton, 'Active');
    expect(active, findsOneWidget);
    expect(tester.widget<FilledButton>(active).onPressed, isNull);
    expect(find.text('Upgrade to Premium'), findsOneWidget);
  });
}
