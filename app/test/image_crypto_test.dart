import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/crypto_service.dart';
import 'package:app/image_service.dart';
import 'package:app/image_widgets.dart';
import 'package:app/models.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgZGL+DwABFAEG1rmmRQAAAABJRU5ErkJggg==',
);
final _image = CapturedImage(
  bytes: _png,
  fileName: 'private-holiday-location.png',
  contentType: 'image/png',
);
ImageItem _item({String contentType = 'application/octet-stream'}) => ImageItem(
  id: 'image-id',
  fileName: 'opaque.bin',
  contentType: contentType,
  sizeBytes: 1000,
  uploadedAt: DateTime.utc(2026),
  conversationId: 'conversation',
);
Future<VaultCrypto> _crypto(String passphrase) async {
  final crypto = VaultCrypto();
  await crypto.unlock(
    email: 'images@example.test',
    passphrase: passphrase,
    vaultSalt: 'salt',
  );
  return crypto;
}

class _ImageVault extends LifenizerAppState {
  bool unlocked = true;
  @override
  bool get isAuthenticated => unlocked;
  @override
  Future<void> refreshImages({String? conversationId}) async {}
  @override
  Future<CapturedImage> decryptedImage(ImageItem image) async => _image;
  void changeLock(bool locked) {
    unlocked = !locked;
    notifyListeners();
  }
}

void main() {
  test(
    'new uploads hide image bytes and filename and roundtrip authenticated downloads',
    () async {
      Uint8List? ciphertext;
      final client = MockClient((request) async {
        expect(request.headers['authorization'], 'Bearer token');
        if (request.method == 'POST') {
          expect(request.body, isNot(contains(_image.fileName)));
          expect(request.body, isNot(contains(base64Encode(_png))));
          expect(
            request.body,
            contains('content-type: application/octet-stream'),
          );
          expect(request.body, contains('.bin"'));
          ciphertext = Uint8List.fromList(
            utf8.encode(
              request.body.substring(
                request.body.indexOf('{'),
                request.body.lastIndexOf('}') + 1,
              ),
            ),
          );
          final envelope = jsonDecode(utf8.decode(ciphertext!)) as Map;
          expect(envelope['keyId'], VaultCrypto.keyId);
          expect(base64Decode(envelope['nonce'] as String), hasLength(12));
          return http.Response(jsonEncode(_item().toJson()), 201);
        }
        if (request.url.path == '/api/images/image-id') {
          return http.Response.bytes(ciphertext!, 200);
        }
        return http.Response(
          jsonEncode({
            'plan': 'free',
            'usedBytes': 1000,
            'limitBytes': 10000000,
            'usedPercent': 0.01,
          }),
          200,
        );
      });
      final state = LifenizerAppState();
      await state.debugAuthenticateForTesting(
        LifenizerApiClient(
          baseUrl: 'http://localhost',
          authToken: 'token',
          client: client,
        ),
      );
      final uploaded = await state.uploadCapturedImage(
        _image,
        conversationId: 'conversation',
      );
      final decoded = await state.decryptedImage(uploaded);
      expect(decoded.bytes, _png);
      expect(decoded.fileName, _image.fileName);
      expect(decoded.contentType, 'image/png');
      await state.lock();
      await expectLater(state.decryptedImage(uploaded), throwsStateError);
      client.close();
    },
  );

  test(
    'locking during an authenticated download prevents plaintext delivery',
    () async {
      final response = Completer<http.Response>();
      final client = MockClient((request) => response.future);
      final state = LifenizerAppState();
      await state.debugAuthenticateForTesting(
        LifenizerApiClient(baseUrl: 'http://localhost', client: client),
      );
      final download = state.decryptedImage(_item(contentType: 'image/png'));
      final rejection = expectLater(download, throwsStateError);
      await state.lock();
      response.complete(http.Response.bytes(_png, 200));
      await rejection;
      client.close();
    },
  );

  test('delayed image lists and quota cannot refill a locked vault', () async {
    final images = Completer<http.Response>();
    final quota = Completer<http.Response>();
    final client = MockClient(
      (request) =>
          request.url.path == '/api/images' ? images.future : quota.future,
    );
    final state = LifenizerAppState();
    await state.debugAuthenticateForTesting(
      LifenizerApiClient(baseUrl: 'http://localhost', client: client),
    );
    final imageRequest = state.refreshImages();
    final quotaRequest = state.refreshQuota();
    await state.lock();
    images.complete(http.Response(jsonEncode([_item().toJson()]), 200));
    quota.complete(
      http.Response(
        jsonEncode({
          'plan': 'free',
          'usedBytes': 0,
          'limitBytes': 10000000,
          'usedPercent': 0.0,
        }),
        200,
      ),
    );
    await Future.wait([imageRequest, quotaRequest]);
    expect(state.images, isEmpty);
    expect(state.quotaStatus, isNull);
    client.close();
  });

  test(
    'wrong vault key and locked vault cannot decode encrypted images',
    () async {
      final owner = await _crypto('owner passphrase');
      final encrypted = await ImageService.encryptImage(_image, owner);
      final other = await _crypto('different passphrase');
      await expectLater(
        ImageService.decryptImage(encrypted, other),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      owner.lock();
      await expectLater(
        ImageService.decryptImage(encrypted, owner),
        throwsStateError,
      );
    },
  );

  test('quota precheck counts ciphertext expansion before sending', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return http.Response('{}', 500);
    });
    final state = LifenizerAppState();
    await state.debugAuthenticateForTesting(
      LifenizerApiClient(baseUrl: 'http://localhost', client: client),
    );
    state.quotaStatus = QuotaStatus(
      plan: 'free',
      usedBytes: 0,
      limitBytes: _png.length + 1,
      usedPercent: 0,
    );
    await expectLater(
      state.uploadCapturedImage(_image),
      throwsA(isA<QuotaExceededException>()),
    );
    expect(requests, 0);
    client.close();
  });

  testWidgets('gallery evicts decoded memory image when vault locks', (
    tester,
  ) async {
    final vault = _ImageVault()..images.add(_item());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ImageGallery(state: vault, conversationId: 'conversation'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final provider = tester.widget<Image>(find.byType(Image)).image;
    expect(provider, isA<MemoryImage>());
    final key = await provider.obtainKey(const ImageConfiguration());
    expect(PaintingBinding.instance.imageCache.containsKey(key), isTrue);
    vault.changeLock(true);
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.lock), findsOneWidget);
    expect(PaintingBinding.instance.imageCache.containsKey(key), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    vault.dispose();
  });
}
