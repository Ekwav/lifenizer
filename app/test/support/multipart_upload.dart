import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// One part of a multipart/form-data body.
class UploadPart {
  UploadPart(this.headers, this.bytes);
  final Map<String, String> headers;
  final Uint8List bytes;

  String? get contentType => headers['content-type'];
}

/// The `metadata` and `audio` parts of POST /api/imports/audio/upload.
class AudioUpload {
  AudioUpload(this.parts);
  final Map<String, UploadPart> parts;

  Map<String, dynamic> get metadata =>
      jsonDecode(utf8.decode(parts['metadata']!.bytes)) as Map<String, dynamic>;
  Uint8List get audio => parts['audio']!.bytes;
  String? get audioType => parts['audio']!.contentType;

  static AudioUpload parse(http.Request request) =>
      AudioUpload(parseMultipart(request));

  /// For fake clients, which receive the unfinalized multipart request.
  static Future<AudioUpload> read(http.BaseRequest request) async {
    final bytes = await request.finalize().toBytes();
    final copy = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..bodyBytes = bytes;
    return parse(copy);
  }
}

/// Parts by their `name`; good enough for bodies built by package:http.
Map<String, UploadPart> parseMultipart(http.Request request) {
  final type = request.headers['content-type']!;
  final boundary = RegExp(r'boundary=(.+)$').firstMatch(type)!.group(1)!;
  final body = latin1.decode(request.bodyBytes);
  final parts = <String, UploadPart>{};
  for (final raw in body.split('--$boundary').skip(1)) {
    if (raw.startsWith('--')) break;
    final split = raw.indexOf('\r\n\r\n');
    final headers = _headers(raw.substring(2, split));
    final content = raw.substring(split + 4, raw.length - 2);
    final name = RegExp(
      r'name="([^"]+)"',
    ).firstMatch(headers['content-disposition']!)!.group(1)!;
    parts[name] = UploadPart(
      headers,
      Uint8List.fromList(latin1.encode(content)),
    );
  }
  return parts;
}

Map<String, String> _headers(String block) => {
  for (final line in block.split('\r\n'))
    line.substring(0, line.indexOf(':')).toLowerCase(): line
        .substring(line.indexOf(':') + 1)
        .trim(),
};

/// The import source of a request to `/api/imports/<source>`.
String importSourceOf(Uri url) =>
    url.path == '/api/imports/audio/upload' ? 'audio' : url.pathSegments.last;

/// A JSON import body; audio uploads are flattened back to their metadata
/// plus `payloadBase64`, so assertions work for every import source.
Map<String, dynamic> importBodyOf(http.Request request) {
  if (request.url.path != '/api/imports/audio/upload') {
    return jsonDecode(request.body) as Map<String, dynamic>;
  }
  final upload = AudioUpload.parse(request);
  return {...upload.metadata, 'payloadBase64': base64Encode(upload.audio)};
}
