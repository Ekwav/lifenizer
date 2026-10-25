import 'dart:async';
import 'dart:convert';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('demo plan changes require an authenticated account', () async {
    final state = LifenizerAppState();
    addTearDown(state.dispose);
    await expectLater(state.activateFreePremium(), throwsStateError);
    await expectLater(state.cancelFreePremium(), throwsStateError);
  });

  test(
    'a delayed cancellation cannot overwrite another account quota',
    () async {
      final started = Completer<void>();
      final response = Completer<http.Response>();
      final client = MockClient((request) {
        expect(request.url.path, '/api/premium/cancel-free');
        expect(request.headers['authorization'], 'Bearer original-account');
        started.complete();
        return response.future;
      });
      addTearDown(client.close);
      final state = LifenizerAppState();
      addTearDown(state.dispose);
      await state.debugAuthenticateForTesting(
        LifenizerApiClient(
          baseUrl: 'https://vault.example.test',
          authToken: 'original-account',
          client: client,
        ),
      );
      state.session = AuthSession(
        authToken: 'original-account',
        userId: 'original',
        vaultId: 'original-vault',
        vaultSalt: 'original-salt',
      );
      final cancellation = state.cancelFreePremium();
      await started.future;
      await state.debugAuthenticateForTesting(
        LifenizerApiClient(baseUrl: 'https://other.example.test'),
      );
      final otherSession = AuthSession(
        authToken: 'other-account',
        userId: 'other',
        vaultId: 'other-vault',
        vaultSalt: 'other-salt',
      );
      final otherQuota = QuotaStatus(
        plan: 'PremiumPlus',
        usedBytes: 123,
        limitBytes: 100 * 1024 * 1024 * 1024,
        usedPercent: 0,
      );
      state.session = otherSession;
      state.quotaStatus = otherQuota;
      response.complete(
        http.Response(
          jsonEncode({
            'plan': 'Free',
            'usedBytes': 0,
            'limitBytes': 50 * 1024 * 1024,
            'usedPercent': 0,
          }),
          200,
        ),
      );
      await cancellation;
      expect(state.quotaStatus, same(otherQuota));
      expect(state.session, same(otherSession));
    },
  );
}
