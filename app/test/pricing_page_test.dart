import 'dart:async';
import 'dart:convert';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/pricing_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('entry loads actual quota and retries a failed request', (
    tester,
  ) async {
    var calls = 0;
    final response = Completer<http.Response>();
    final client = MockClient((request) async {
      expect(request.url.path, '/api/premium/status');
      calls++;
      return calls == 1 ? http.Response('unavailable', 503) : response.future;
    });
    final state = LifenizerAppState();
    await tester.runAsync(
      () => state.debugAuthenticateForTesting(
        LifenizerApiClient(baseUrl: 'https://example.test', client: client),
      ),
    );
    addTearDown(state.dispose);
    addTearDown(client.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PricingPage(state: state)),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Upgrade to Premium'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('Could not load your storage plan.'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    response.complete(
      http.Response(
        jsonEncode({
          'plan': 'Premium',
          'usedBytes': 0,
          'limitBytes': 10 * 1024 * 1024 * 1024,
          'usedPercent': 0.0,
          'freePremiumEnabled': true,
        }),
        200,
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(state.quotaStatus!.freePremiumEnabled, isTrue);
    expect(find.text('Premium is free for now'), findsOneWidget);
    expect(find.text('0 KB of 10.0 GB used'), findsOneWidget);
    expect(find.text('Upgrade to Premium'), findsNothing);
  });

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
