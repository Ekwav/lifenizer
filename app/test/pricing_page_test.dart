import 'dart:async';
import 'dart:convert';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/main.dart';
import 'package:app/models.dart';
import 'package:app/pricing_page.dart';
import 'package:app/image_widgets.dart';
import 'package:app/pages/login_page.dart';
import 'package:app/services/quick_action_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _SignedInState extends LifenizerAppState {
  @override
  bool get isAuthenticated => true;
}

void main() {
  setUp(() => QuickActionService.instance.consume());
  tearDown(() => QuickActionService.instance.consume());

  testWidgets(
    'upgrade intent survives login navigator replacement without activating storage',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      var activations = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/api/premium/activate') activations++;
        return http.Response(
          jsonEncode({
            'plan': 'Free',
            'usedBytes': 0,
            'limitBytes': 50 * 1024 * 1024,
            'usedPercent': 0.0,
            'freePremiumEnabled': true,
          }),
          200,
        );
      });
      final state = LifenizerAppState();
      addTearDown(state.dispose);
      addTearDown(client.close);
      await tester.pumpWidget(LifenizerApp(state: state));
      Navigator.of(tester.element(find.byType(LoginPage))).push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(body: PricingPage(state: state)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign in to upgrade'));
      await tester.pumpAndSettle();
      expect(QuickActionService.instance.pending?.action, 'pricing');
      expect(find.byType(LoginPage), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.runAsync(
        () => state.debugAuthenticateForTesting(
          LifenizerApiClient(
            baseUrl: 'https://vault.example.test',
            client: client,
          ),
        ),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      state.session = AuthSession(
        authToken: 'same-account',
        userId: 'owner',
        vaultId: 'vault',
        vaultSalt: 'salt',
      );
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byType(PricingPage), findsOneWidget);
      expect(
        Navigator.of(tester.element(find.byType(PricingPage))).canPop(),
        isFalse,
      );
      expect(find.text('Activate free Premium'), findsOneWidget);
      expect(state.quotaStatus!.plan, 'Free');
      expect(activations, 0);
      expect(QuickActionService.instance.pending, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

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
        await tester.ensureVisible(find.text('Activate free Premium'));
        await tester.tap(find.text('Activate free Premium'));
        await tester.pumpAndSettle();
        expect(state.quotaStatus!.plan, 'Free');
        expect(
          find.textContaining(RegExp('retry', caseSensitive: false)),
          findsOneWidget,
        );
        await tester.ensureVisible(find.text('Activate free Premium'));
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

  for (final dialog in [false, true]) {
    testWidgets(
      'cancel demo confirms, retries and reactivates at 320px (dialog: $dialog)',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var activated = true;
        var cancellations = 0;
        var activations = 0;
        Map<String, dynamic> quota() => {
          'plan': activated ? 'Premium' : 'Free',
          'usedBytes': 60 * 1024 * 1024,
          'limitBytes': activated ? 10 * 1024 * 1024 * 1024 : 50 * 1024 * 1024,
          'usedPercent': activated ? 0.6 : 120.0,
          'freePremiumEnabled': true,
          if (activated) 'freePremiumActivatedAt': '2026-10-25T12:00:00Z',
        };
        final client = MockClient((request) async {
          if (request.url.path == '/api/premium/cancel-free') {
            expect(request.method, 'POST');
            cancellations++;
            if (cancellations == 1) return http.Response('unavailable', 503);
            activated = false;
          } else if (request.url.path == '/api/premium/activate') {
            activations++;
            activated = true;
          } else {
            expect(request.url.path, '/api/premium/status');
          }
          return http.Response(jsonEncode(quota()), 200);
        });
        final state = _SignedInState()
          ..rememberedEmail = 'owner@example.test'
          ..apiBaseUrl = 'https://vault.example.test';
        await tester.runAsync(
          () => state.debugAuthenticateForTesting(
            LifenizerApiClient(
              baseUrl: state.apiBaseUrl,
              authToken: 'same-account',
              client: client,
            ),
          ),
        );
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
        expect(find.text('Premium+'), findsWidgets);
        expect(cancellations, 0);
        Future<void> openConfirmation() async {
          await tester.ensureVisible(find.text('Cancel Premium'));
          await tester.tap(find.text('Cancel Premium'));
          await tester.pumpAndSettle();
        }

        final freeCardAction = dialog
            ? find.descendant(
                of: find.ancestor(
                  of: find.text('Free'),
                  matching: find.byType(Card),
                ),
                matching: find.widgetWithText(FilledButton, 'Switch to Free'),
              )
            : find.text('Switch to Free');
        await tester.ensureVisible(freeCardAction);
        await tester.tap(freeCardAction);
        await tester.pumpAndSettle();
        expect(
          find.textContaining('immediately returns to 50 MB'),
          findsOneWidget,
        );
        expect(find.textContaining('remains readable'), findsOneWidget);
        await tester.tap(find.text('Keep current plan'));
        await tester.pumpAndSettle();
        expect(cancellations, 0);
        await openConfirmation();
        await tester.tap(find.text('Confirm cancellation'));
        await tester.pumpAndSettle();
        expect(cancellations, 1);
        expect(state.quotaStatus!.freePremiumActivatedAt, isNotNull);
        expect(
          find.textContaining('Check your connection and retry'),
          findsOneWidget,
        );
        await openConfirmation();
        await tester.tap(find.text('Confirm cancellation'));
        await tester.pumpAndSettle();
        expect(cancellations, 2);
        expect(state.quotaStatus!.plan, 'Free');
        expect(state.quotaStatus!.freePremiumActivatedAt, isNull);
        expect(state.quotaStatus!.usedBytes, 60 * 1024 * 1024);
        expect(state.quotaStatus!.isOverLimit, isTrue);
        await tester.ensureVisible(find.text('Activate free Premium'));
        await tester.tap(find.text('Activate free Premium'));
        await tester.pumpAndSettle();
        expect(activations, 1);
        expect(state.quotaStatus!.plan, 'Premium');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'free activation can end with offer disabled without claiming paid cancellation (dialog: $dialog)',
      (tester) async {
        final state = _SignedInState()
          ..quotaStatus = QuotaStatus.fromJson({
            'plan': 'PremiumPlus',
            'usedBytes': 0,
            'limitBytes': 100 * 1024 * 1024 * 1024,
            'usedPercent': 0.0,
            'freePremiumEnabled': false,
            'freePremiumActivatedAt': '2026-10-25T12:00:00Z',
            'expiresAt': '2026-12-25T12:00:00Z',
          });
        addTearDown(state.dispose);
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
        expect(find.text('Cancel Premium'), findsNothing);
        await tester.ensureVisible(find.text('End free activation').first);
        await tester.tap(find.text('End free activation').first);
        await tester.pumpAndSettle();
        expect(
          find.textContaining('does not cancel a paid subscription'),
          findsOneWidget,
        );
        expect(find.textContaining('paid entitlement'), findsOneWidget);
        expect(
          find.textContaining('immediately returns to 50 MB'),
          findsNothing,
        );
        await tester.tap(find.text('Keep current plan'));
        await tester.pumpAndSettle();
        expect(state.quotaStatus!.plan, 'PremiumPlus');
      },
    );
  }

  for (final dialog in [false, true]) {
    for (final changeServer in [false, true]) {
      testWidgets(
        'cancel confirmation is bound to the account and server (dialog: $dialog, server change: $changeServer)',
        (tester) async {
          var cancellations = 0;
          final quota = {
            'plan': 'Premium',
            'usedBytes': 0,
            'limitBytes': 10 * 1024 * 1024 * 1024,
            'usedPercent': 0.0,
            'freePremiumEnabled': true,
            'freePremiumActivatedAt': '2026-10-25T12:00:00Z',
          };
          final client = MockClient((request) async {
            if (request.url.path == '/api/premium/cancel-free') cancellations++;
            return http.Response(jsonEncode(quota), 200);
          });
          final state = _SignedInState()
            ..apiBaseUrl = 'https://first.example.test';
          await tester.runAsync(
            () => state.debugAuthenticateForTesting(
              LifenizerApiClient(
                baseUrl: state.apiBaseUrl,
                authToken: 'first-account',
                client: client,
              ),
            ),
          );
          state.session = AuthSession(
            authToken: 'first-account',
            userId: 'first',
            vaultId: 'first-vault',
            vaultSalt: 'first-salt',
          );
          state.quotaStatus = QuotaStatus.fromJson(quota);
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
          await tester.ensureVisible(find.text('Cancel Premium'));
          await tester.tap(find.text('Cancel Premium'));
          await tester.pumpAndSettle();
          if (changeServer) {
            state.apiBaseUrl = 'https://second.example.test';
          } else {
            state.session = AuthSession(
              authToken: 'second-account',
              userId: 'second',
              vaultId: 'second-vault',
              vaultSalt: 'second-salt',
            );
          }
          await tester.tap(find.text('Confirm cancellation'));
          await tester.pumpAndSettle();
          expect(cancellations, 0);
          expect(state.quotaStatus!.freePremiumActivatedAt, isNotNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
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
    'temporary free Premium shows paid Plus preview with checkout paused',
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
      expect(find.text('Premium+'), findsWidgets);
      expect(find.text('100 GB vault storage'), findsOneWidget);
      expect(find.text('PREVIEW'), findsOneWidget);
      expect(find.text('MOST POPULAR'), findsNothing);
      final paused = find.widgetWithText(FilledButton, 'Paid checkout paused');
      expect(tester.widget<FilledButton>(paused).onPressed, isNull);
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
