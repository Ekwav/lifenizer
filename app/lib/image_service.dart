import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';

import 'crypto_service.dart';

/// Maximum size of the longer dimension (pixels) after on-device compression.
const int _maxDimension = 2048;

/// JPEG quality (0-100) used for compression.
const int _jpegQuality = 82;

class ImageService {
  ImageService._();

  static final _picker = ImagePicker();

  /// Opens the camera, captures a photo, compresses it and returns the bytes
  /// together with a suggested filename.
  /// Returns `null` if the user cancels.
  static Future<CapturedImage?> captureFromCamera() async {
    final file = await _picker.pickImage(
      source: ImageSource.camera,
      maxWidth: _maxDimension.toDouble(),
      maxHeight: _maxDimension.toDouble(),
      imageQuality: _jpegQuality,
    );
    if (file == null) return null;
    return _processXFile(file);
  }

  /// Opens the gallery, lets the user pick one image, compresses it and
  /// returns the bytes together with a suggested filename.
  /// Returns `null` if the user cancels.
  static Future<CapturedImage?> pickFromGallery() async {
    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: _maxDimension.toDouble(),
      maxHeight: _maxDimension.toDouble(),
      imageQuality: _jpegQuality,
    );
    if (file == null) return null;
    return _processXFile(file);
  }

  static Future<CapturedImage> _processXFile(XFile file) async {
    final rawBytes = await file.readAsBytes();

    // Compression plugins support Android, iOS and macOS. Desktop picking
    // already receives size limits, so retain its bytes on other platforms.
    if (kIsWeb ||
        ![
          TargetPlatform.android,
          TargetPlatform.iOS,
          TargetPlatform.macOS,
        ].contains(defaultTargetPlatform)) {
      return CapturedImage(
        bytes: rawBytes,
        fileName: _safeFileName(file.name),
        contentType: _contentType(rawBytes),
      );
    }

    final compressed = await FlutterImageCompress.compressWithList(
      rawBytes,
      minWidth: _maxDimension,
      minHeight: _maxDimension,
      quality: _jpegQuality,
      format: CompressFormat.jpeg,
    );

    final bytes = Uint8List.fromList(compressed);
    return CapturedImage(
      bytes: bytes,
      fileName: _safeFileName(file.name, forceJpeg: true),
      contentType: 'image/jpeg',
    );
  }

  static Future<Uint8List> encryptImage(
    CapturedImage image,
    VaultCrypto crypto,
  ) async {
    final payload = await crypto.encryptJson({
      'bytes': base64Encode(image.bytes),
      'fileName': image.fileName,
      'contentType': image.contentType,
    });
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'cipherText': payload.cipherText,
          'nonce': payload.nonce,
          'keyId': payload.keyId,
        }),
      ),
    );
  }

  static Future<CapturedImage> decryptImage(
    Uint8List bytes,
    VaultCrypto crypto,
  ) async {
    if (!crypto.isUnlocked) throw StateError('Vault is locked.');
    final envelope = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    if (envelope['keyId'] != VaultCrypto.keyId) {
      throw const FormatException('Unsupported encrypted image format.');
    }
    final payload = await crypto.decryptJson(
      cipherText: envelope['cipherText'] as String,
      nonce: envelope['nonce'] as String,
    );
    return CapturedImage(
      bytes: base64Decode(payload['bytes'] as String),
      fileName: payload['fileName'] as String,
      contentType: payload['contentType'] as String,
    );
  }

  static String _contentType(Uint8List bytes) {
    if (bytes.length >= 4 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46) {
      return 'image/gif';
    }
    if (bytes.length >= 12 &&
        ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
      return 'image/webp';
    }
    return 'image/jpeg';
  }

  static String _safeFileName(String name, {bool forceJpeg = false}) {
    final sanitised = name.replaceAll(RegExp(r'[^\w.\-]'), '_');
    if (forceJpeg && !sanitised.toLowerCase().endsWith('.jpg')) {
      final base = sanitised.contains('.')
          ? sanitised.substring(0, sanitised.lastIndexOf('.'))
          : sanitised;
      return '$base.jpg';
    }
    return sanitised;
  }
}

class CapturedImage {
  const CapturedImage({
    required this.bytes,
    required this.fileName,
    required this.contentType,
  });

  final Uint8List bytes;
  final String fileName;
  final String contentType;
}
