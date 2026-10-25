import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';

/// Location is opt-in. Only the explicit permission action can show a prompt.
class RecordingLocationService extends ChangeNotifier {
  static final instance = RecordingLocationService();
  static const channel = MethodChannel('com.lifenizer/recording_location');
  static const _preference = 'recording_location_enabled';

  bool _enabled = false;
  bool get enabled => _enabled;
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> load() async {
    try {
      _enabled =
          (await SharedPreferences.getInstance()).getBool(_preference) ?? false;
    } on PlatformException {
      _enabled = false;
    } on MissingPluginException {
      _enabled = false;
    }
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (!await (await SharedPreferences.getInstance()).setBool(
      _preference,
      value,
    )) {
      throw StateError('Could not save the location preference. Try again.');
    }
    _enabled = value;
    notifyListeners();
  }

  Future<bool> requestPermission() async {
    if (!supported) return false;
    try {
      return await channel.invokeMethod<bool>('permission') == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<RecordingLocation?> getCurrentLocation() async {
    if (!supported) return null;
    try {
      final value = await channel
          .invokeMapMethod<String, dynamic>('current')
          .timeout(const Duration(seconds: 8), onTimeout: () => null);
      return value == null ? null : RecordingLocation.fromJson(value);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
