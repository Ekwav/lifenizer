import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models.dart';

class PaperlessException implements Exception {
  const PaperlessException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Reads extracted text directly from a user's Paperless instance.
class PaperlessClient {
  PaperlessClient({http.Client? client}) : _client = client;

  final http.Client? _client;
  static const _maxBytes = 25 * 1024 * 1024;

  static Uri validateBaseUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !const ['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException(
        'Enter a Paperless HTTP or HTTPS URL without credentials, query, or fragment.',
      );
    }
    if (uri.scheme == 'http') {
      final host = uri.host.toLowerCase().replaceAll(RegExp(r'^\[|\]$'), '');
      final address = InternetAddress.tryParse(host);
      final bytes = address?.rawAddress;
      final local =
          host == 'localhost' ||
          host.endsWith('.localhost') ||
          host.endsWith('.local') ||
          (bytes != null &&
              (bytes.length == 4
                  ? bytes[0] == 127 ||
                        bytes[0] == 10 ||
                        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
                        (bytes[0] == 192 && bytes[1] == 168) ||
                        (bytes[0] == 169 && bytes[1] == 254)
                  : (bytes.take(15).every((byte) => byte == 0) &&
                            bytes[15] == 1) ||
                        bytes[0] & 0xfe == 0xfc ||
                        (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)));
      if (!local) {
        throw const FormatException(
          'Use HTTPS for public Paperless servers. HTTP is allowed only on localhost or a private network.',
        );
      }
    }
    return uri.replace(path: '${uri.path.replaceFirst(RegExp(r'/+$'), '')}/');
  }

  Future<NormalizedImportResult> fetchPage({
    required String baseUrl,
    required String token,
    required Map<String, String> metadata,
  }) async {
    final Uri root;
    try {
      root = validateBaseUrl(baseUrl);
    } on FormatException catch (error) {
      throw PaperlessException(error.message);
    }
    if (token.trim().isEmpty || token.contains(RegExp(r'[\r\n]'))) {
      throw const PaperlessException('Enter a valid Paperless API token.');
    }
    final page = int.tryParse(metadata['page'] ?? '1');
    if (page == null || page <= 0) {
      throw const PaperlessException(
        'Paperless page must be a positive integer.',
      );
    }
    final limit = (int.tryParse(metadata['limit'] ?? '') ?? 10).clamp(1, 50);
    final since = metadata['modifiedAfter'];
    var latest = since == null ? null : DateTime.tryParse(since);
    if (since != null && latest == null) {
      throw const PaperlessException(
        'Paperless modifiedAfter must be an ISO date-time.',
      );
    }
    final client = _client ?? http.Client();
    try {
      final listed = await _get(
        client,
        root
            .resolve('api/documents/')
            .replace(
              queryParameters: {
                'page_size': '$limit',
                'page': '$page',
                'ordering': 'id',
                'modified__gte': ?since,
              },
            ),
        token,
      );
      final results = listed['results'];
      if (results is! List) throw const FormatException();
      final conversations = <NormalizedConversation>[];
      final correspondents = <String, String>{};
      final names = <String>{};
      var documentsWithoutText = 0;
      for (final entry in results) {
        if (entry is! Map<String, dynamic>) throw const FormatException();
        final id = _id(entry['id']);
        var document = entry;
        if ((_text(document['content']) ?? '').trim().isEmpty) {
          document = await _get(
            client,
            root.resolve('api/documents/$id/'),
            token,
          );
          if (_id(document['id']) != id) throw const FormatException();
        }
        final content = _text(document['content']);
        final hasText = content != null && content.trim().isNotEmpty;
        if (!hasText) documentsWithoutText++;
        final correspondent = document['correspondent'];
        String? name;
        if (correspondent is num) {
          final personId = _id(correspondent);
          name = correspondents[personId];
          if (name == null) {
            final person = await _get(
              client,
              root.resolve('api/correspondents/$personId/'),
              token,
            );
            name = _text(person['name']) ?? 'Paperless';
            correspondents[personId] = name;
          }
        } else if (correspondent is Map) {
          name =
              _text(correspondent['name']) ??
              _text(correspondent['display_name']);
        } else {
          name = _text(correspondent);
        }
        name ??= 'Paperless';
        names.add(name);
        final identity = 'paperless:$root:$id';
        final modified = DateTime.tryParse(_text(document['modified']) ?? '');
        if (modified != null && (latest == null || modified.isAfter(latest))) {
          latest = modified;
        }
        final fileName = _text(document['original_file_name']);
        conversations.add(
          NormalizedConversation(
            title: _text(document['title']) ?? fileName ?? 'Paperless document',
            source: 'paperless',
            participantNames: [name],
            sourceThreadId: identity,
            sourceUrl: root.resolve('documents/$id/details').toString(),
            artifactNames: [?fileName],
            metadata: {
              for (final key in [
                'id',
                'created',
                'modified',
                'document_type',
                'archive_serial_number',
              ])
                if (_text(document[key]) case final String value) key: value,
            },
            segments: [
              if (hasText)
                NormalizedSegment(
                  text: content,
                  participantName: name,
                  createdAt: DateTime.tryParse(
                    _text(document['created']) ?? '',
                  ),
                  sourceMessageId: identity,
                ),
            ],
          ),
        );
      }
      // Treat next only as a continuation flag; never send a token to its URL.
      final hasMore = (listed['next']?.toString() ?? '').trim().isNotEmpty;
      return NormalizedImportResult(
        source: 'paperless',
        plaintextCompute: false,
        message:
            'Fetched and normalized ${conversations.length} Paperless document(s).',
        conversations: conversations,
        participants: names
            .map((name) => NormalizedParticipant(displayName: name))
            .toList(),
        diagnostics: {
          'baseUrl': root.toString(),
          'documentsWithoutText': '$documentsWithoutText',
          'hasMore': '$hasMore',
          'nextPage': hasMore ? '${page + 1}' : '',
          'nextModifiedAfter': latest?.toUtc().toIso8601String() ?? '',
        },
      );
    } on TimeoutException {
      throw PaperlessException(
        'Paperless timed out. Check the server and retry.',
      );
    } on http.ClientException {
      throw PaperlessException(
        'Cannot reach Paperless at $root. Check the URL and network, then retry.',
      );
    } on SocketException {
      throw PaperlessException(
        'Cannot reach Paperless at $root. Check the URL and network, then retry.',
      );
    } on FormatException {
      throw PaperlessException(
        'Paperless returned an invalid document response. Check the server and retry.',
      );
    } finally {
      if (_client == null) client.close();
    }
  }

  static String? _text(dynamic value) =>
      value is String || value is num ? value.toString() : null;

  static String _id(dynamic value) {
    final id = _text(value) ?? '';
    if (!RegExp(r'^[0-9]+$').hasMatch(id) || (int.tryParse(id) ?? 0) <= 0) {
      throw const FormatException('Paperless document ID is invalid.');
    }
    return id;
  }

  Future<Map<String, dynamic>> _get(
    http.Client client,
    Uri uri,
    String token,
  ) async {
    return (() async {
      final request = http.Request('GET', uri)
        ..followRedirects = false
        ..headers['Authorization'] = 'Token ${token.trim()}';
      final response = await client.send(request);
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw PaperlessException(
          'Paperless rejected the API token. Check the token and its document viewing permissions, then retry.',
        );
      }
      if (response.statusCode >= 300 && response.statusCode < 400) {
        throw PaperlessException(
          'Paperless redirected the request. Enter the final server URL and retry.',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw PaperlessException(
          'Paperless request failed with status ${response.statusCode}. Check the server and retry.',
        );
      }
      if ((response.contentLength ?? 0) > _maxBytes) throw _tooLarge();
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > _maxBytes) throw _tooLarge();
        bytes.add(chunk);
      }
      final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      return decoded;
    })().timeout(const Duration(seconds: 30));
  }

  static PaperlessException _tooLarge() => PaperlessException(
    'Paperless response exceeds 25 MiB. Reduce the page size and retry.',
  );
}
