import 'dart:async';
import 'dart:convert';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/pricing_page.dart';
import 'package:app/image_widgets.dart';
import 'package:app/pages/login_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _SignedInState extends LifenizerAppState {
  @override
  bool get isAuthenticated => true;
}

void main() {
  testWidgets(
    'upgrade requires login and opens the account connection screen',
    (tester) async {
      final state = LifenizerAppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PricingPage(state: state)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Activate free Premium'), findsNothing);
      await tester.tap(find.text('Sign in to upgrade'));
      await tester.pumpAndSettle();
      expect(find.byType(LoginPage), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final dialog in [false, true]) {
    testWidgets(
      'free upgrade requires explicit activation and retries without changing vault (dialog: $dialog)',
      (tester) async {
        var attempts = 0;
        var activated = false;
        Map<String, dynamic> quota() => {
          'plan': activated ? 'Premium' : 'Free',
          'usedBytes': 123,
          'limitBytes': activated ? 10 * 1024 * 1024 * 1024 : 50 * 1024 * 1024,
          'usedPercent': 0.0,
          'freePremiumEnabled': true,
        };
        final client = MockClient((request) async {
          expect(request.headers['authorization'], 'Bearer same-session');
          if (request.url.path == '/api/premium/activate') {
            expect(request.method, 'POST');
            attempts++;
            if (attempts == 1) return http.Response('unavailable', 503);
            activated = true;
          } else {
            expect(request.url.path, '/api/premium/status');
          }
          return http.Response(jsonEncode(quota()), 200);
        });
        final state = LifenizerAppState()
          ..rememberedEmail = 'owner@example.test'
          ..apiBaseUrl = 'https://vault.example.test';
        await tester.runAsync(
          () => state.debugAuthenticateForTesting(
            LifenizerApiClient(
              baseUrl: state.apiBaseUrl,
              authToken: 'same-session',
              client: client,
            ),
          ),
        );
        final session = AuthSession(
          authToken: 'same-session',
          userId: 'owner',
          vaultId: 'existing-vault',
          vaultSalt: 'unchanged-salt',
        );
        state.session = session;
        state.quotaStatus = QuotaStatus.fromJson(quota());
        addTearDown(state.dispose);
        addTearDown(client.close);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: dialog
                  ? UpgradeDialog(state: state)
                  : PricingPage(state: state),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(attempts, 0);
        expect(find.textContaining('owner@example.test'), findsOneWidget);
        expect(
          find.textContaining('https://vault.example.test'),
          findsOneWidget,
        );
        expect(find.text('Current plan: Free'), findsOneWidget);
        await tester.tap(find.text('Activate free Premium'));
        await tester.pumpAndSettle();
        expect(state.quotaStatus!.plan, 'Free');
        expect(
          find.textContaining(RegExp('retry', caseSensitive: false)),
          findsOneWidget,
        );
        await tester.tap(find.text('Activate free Premium'));
        await tester.pumpAndSettle();
        expect(attempts, 2);
        expect(state.quotaStatus!.plan, 'Premium');
        expect(state.quotaStatus!.limitBytes, 10 * 1024 * 1024 * 1024);
        expect(state.session, same(session));
        expect(find.text('Current plan: Premium'), findsOneWidget);
        expect(find.text('Activate free Premium'), findsNothing);
        expect(find.text('Your storage plan is active.'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

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
    final state = _SignedInState();
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
      final state = _SignedInState()
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

  testWidgets(
    'PremiumPlus API status marks Plus active and disables checkout',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final state = _SignedInState()
        ..quotaStatus = QuotaStatus.fromJson({
          'plan': 'PremiumPlus',
          'usedBytes': 0,
          'limitBytes': 100 * 1024 * 1024 * 1024,
          'usedPercent': 0.0,
        });
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PricingPage(state: state)),
        ),
      );

      expect(find.text('Upgrade to Premium+'), findsNothing);
      final active = find.widgetWithText(FilledButton, 'Active');
      expect(active, findsOneWidget);
      expect(tester.widget<FilledButton>(active).onPressed, isNull);
      expect(find.text('Upgrade to Premium'), findsOneWidget);
    },
  );
}
