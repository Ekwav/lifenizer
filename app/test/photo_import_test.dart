import 'dart:convert';
import 'dart:io';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String _photoResult() => jsonEncode({
  'source': 'photo',
  'plaintextCompute': false,
  'message': 'ok',
  'participants': <dynamic>[],
  'conversations': [
    {
      'title': 'Receipt 12.50',
      'source': 'photo',
      'sourceThreadId': 'photo:abc123',
      'participantNames': <String>[],
      'metadata': {'ocr': 'tesseract', 'hasGps': 'false'},
      'segments': [
        {'text': 'Receipt 12.50 EUR', 'sourceMessageId': 'abc123:0'},
      ],
    },
  ],
});

void main() {
  late LifenizerAppState state;
  late List<http.Request> requests;
  late Directory directory;

  setUp(() async {
    requests = [];
    directory = await Directory.systemTemp.createTemp('lifenizer-photo-');
    addTearDown(() => directory.delete(recursive: true));
    final client = MockClient((request) async {
      requests.add(request);
      if (request.url.path == '/api/sync/push') {
        return http.Response(jsonEncode({'cursor': 1}), 200);
      }
      if (request.url.path == '/api/imports/photo') {
        return http.Response(_photoResult(), 200);
      }
      if (request.url.path.startsWith('/api/imports/')) {
        return http.Response(
          jsonEncode({
            'source': request.url.pathSegments.last,
            'plaintextCompute': false,
            'message': 'ok',
            'participants': <dynamic>[],
            'conversations': <dynamic>[],
          }),
          200,
        );
      }
      return http.Response('nope', 404);
    });
    state = LifenizerAppState();
    await state.debugAuthenticateForTesting(
      LifenizerApiClient(
        baseUrl: 'http://127.0.0.1:5075',
        authToken: 't',
        client: client,
      ),
    );
    state.session = AuthSession(
      authToken: 't',
      userId: 'u',
      vaultId: 'v',
      vaultSalt: 's',
    );
    addTearDown(state.dispose);
  });

  http.Request lastImport() =>
      requests.lastWhere((r) => r.url.path.startsWith('/api/imports/'));

  Map<String, dynamic> lastBody() =>
      jsonDecode(
            requests
                .lastWhere((r) => r.url.path.startsWith('/api/imports/'))
                .body,
          )
          as Map<String, dynamic>;

  test(
    'importPhotoFile sends the photo source with capture metadata',
    () async {
      final file = File('${directory.path}/IMG_1.jpg')
        ..writeAsBytesSync([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]);
      final taken = DateTime.utc(2026, 9, 1, 8, 30);
      file.setLastModifiedSync(taken);

      final id = await state.importPhotoFile(file.path);
      expect(state.error, isNull);
      expect(requests.map((r) => r.url.path), contains('/api/imports/photo'));
      final body = lastBody();
      expect(body['originalFileName'], 'IMG_1.jpg');
      expect(body['mimeType'], 'image/jpeg');
      expect(
        body['payloadBase64'],
        base64Encode([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]),
      );
      final metadata = body['metadata'] as Map;
      expect(DateTime.parse(metadata['capturedAt'] as String), taken);
      expect(
        metadata['utcOffsetMinutes'],
        '${taken.toLocal().timeZoneOffset.inMinutes}',
      );
      expect(state.conversations.single.source, 'photo');
      expect(state.conversations.single.id, id);

      // Re-import is idempotent (same sourceThreadId).
      expect(await state.importPhotoFile(file.path), id);
      expect(state.conversations, hasLength(1));
    },
  );

  test('importPhotoFile rejects files over 25 MiB', () async {
    final file = File('${directory.path}/big.jpg')
      ..writeAsBytesSync(List.filled(maxPhotoBytes + 1, 0));
    expect(await state.importPhotoFile(file.path), isNull);
    expect(state.error, contains('25 MiB'));
    expect(requests.where((r) => r.url.path == '/api/imports/photo'), isEmpty);
  });

  test(
    'importDocumentFile routes images to photo and PDFs to scanned-pdf',
    () async {
      final image = File('${directory.path}/scan.PNG')
        ..writeAsBytesSync([1, 2]);
      final pdf = File('${directory.path}/doc.pdf')..writeAsBytesSync([3, 4]);
      expect(await state.importDocumentFile(image.path), isTrue);
      expect(lastImport().url.path, '/api/imports/photo');
      expect(await state.importDocumentFile(pdf.path), isTrue);
      expect(lastImport().url.path, '/api/imports/scanned-pdf');
    },
  );

  test(
    'shared images use photo; shared watch-history ZIPs use the right entry',
    () async {
      await state.importSharedPayload(fileName: 'IMG_9.heic', bytes: [1, 2, 3]);
      expect(lastImport().url.path, '/api/imports/photo');
      expect(
        (lastBody()['metadata'] as Map).containsKey('utcOffsetMinutes'),
        isTrue,
      );

      final archive = Archive()
        ..addFile(ArchiveFile('Takeout/readme.txt', 2, utf8.encode('hi')))
        ..addFile(
          ArchiveFile(
            'Takeout/YouTube and YouTube Music/history/watch-history.json',
            2,
            utf8.encode('[]'),
          ),
        );
      await state.importSharedPayload(
        fileName: 'takeout.zip',
        bytes: ZipEncoder().encode(archive),
      );
      expect(state.error, isNull);
      expect(lastImport().url.path, '/api/imports/youtube-watch-history');
      final body = lastBody();
      expect(body['originalFileName'], 'watch-history.json');
      expect(utf8.decode(base64Decode(body['payloadBase64'] as String)), '[]');
    },
  );
}
