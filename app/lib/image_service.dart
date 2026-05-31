import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';

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
      imageQuality: _jpegQuality,
    );
    if (file == null) return null;
    return _processXFile(file);
  }

  static Future<CapturedImage> _processXFile(XFile file) async {
    final rawBytes = await file.readAsBytes();

    // On web there is no FlutterImageCompress support; skip recompression.
    if (kIsWeb) {
      return CapturedImage(
        bytes: rawBytes,
        fileName: _safeFileName(file.name),
        contentType: 'image/jpeg',
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
