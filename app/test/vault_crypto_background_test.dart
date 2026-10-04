import 'package:app/crypto_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'background and direct derivation decrypt each other without retaining keys after lock',
    () async {
      final direct = VaultCrypto();
      final worker = VaultCrypto();
      addTearDown(direct.lock);
      addTearDown(worker.lock);
      await direct.unlock(
        email: 'alice@example.test',
        passphrase: 'private test phrase',
        vaultSalt: 'stable-salt',
      );
      await worker.unlock(
        email: 'alice@example.test',
        passphrase: 'private test phrase',
        vaultSalt: 'stable-salt',
        background: true,
      );
      final value = {
        'nested': {'message': 'Private content'},
        'items': [1, 2, 3],
      };
      final fromDirect = await direct.encryptJson(value);
      expect(
        await worker.decryptJson(
          cipherText: fromDirect.cipherText,
          nonce: fromDirect.nonce,
        ),
        value,
      );
      final fromWorker = await worker.encryptJson(value, background: true);
      expect(
        await direct.decryptJson(
          cipherText: fromWorker.cipherText,
          nonce: fromWorker.nonce,
        ),
        value,
      );
      worker.lock();
      expect(worker.isUnlocked, isFalse);
      await expectLater(worker.encryptJson(value), throwsStateError);
    },
  );
}
