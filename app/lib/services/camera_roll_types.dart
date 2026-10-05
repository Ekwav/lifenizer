import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A candidate image found in a camera folder.
class CameraPhotoFile {
  const CameraPhotoFile({
    required this.path,
    required this.size,
    required this.modified,
  });
  final String path;
  final int size;
  final DateTime modified;

  String get name => path.split(RegExp(r'[\\/]')).last;
}

/// Lists image files in [folders] (non-recursive).
typedef CameraFolderLister =
    Future<List<CameraPhotoFile>> Function(List<String> folders);

/// Imports one photo via the `photo` source. Returns the conversation id, or
/// null when the import failed.
typedef CameraPhotoImporter = Future<String?> Function(CameraPhotoFile photo);

/// Stores a compressed copy in the image vault, linked to the conversation.
typedef CameraPhotoKeeper =
    Future<void> Function(CameraPhotoFile photo, String conversationId);

enum CameraPermission { unknown, granted, denied, notNeeded }

/// Android bridge for the public camera folder and the media permission.
abstract class CameraRollPlatform {
  /// True on Android, where the app finds the camera folder itself.
  bool get isMobile;
  Future<List<String>> cameraFolders();
  Future<bool> hasImagesPermission();
  Future<bool> requestImagesPermission();
}

/// `com.lifenizer/media` MethodChannel implemented in MainActivity.kt.
class MediaChannelPlatform implements CameraRollPlatform {
  const MediaChannelPlatform();
  static const _channel = MethodChannel('com.lifenizer/media');

  @override
  bool get isMobile =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<List<String>> cameraFolders() async =>
      (await _channel.invokeListMethod<String>('cameraFolders')) ?? const [];

  @override
  Future<bool> hasImagesPermission() async =>
      (await _channel.invokeMethod<bool>('hasImagesPermission')) ?? false;

  @override
  Future<bool> requestImagesPermission() async =>
      (await _channel.invokeMethod<bool>('requestImagesPermission')) ?? false;
}

/// Largest photo the `photo` importer accepts.
const int cameraPhotoMaxBytes = 25 * 1024 * 1024;

final RegExp cameraImagePattern = RegExp(
  r'\.(jpe?g|png|webp|heic|heif)$',
  caseSensitive: false,
);
