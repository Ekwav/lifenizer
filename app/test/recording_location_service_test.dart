import 'dart:async';

import 'package:app/services/recording_location_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <String>[];

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({});
    calls.clear();
    messenger.setMockMethodCallHandler(RecordingLocationService.channel, (
      call,
    ) async {
      calls.add(call.method);
      if (call.method == 'permission') return true;
      return {'town': 'Berlin', 'latitude': 52.52, 'longitude': 13.405};
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(RecordingLocationService.channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'location preference defaults off and survives service reload without permission prompt',
    () async {
      final service = RecordingLocationService();
      await service.load();
      expect(service.enabled, isFalse);
      await service.setEnabled(true);
      final reloaded = RecordingLocationService();
      await reloaded.load();
      expect(reloaded.enabled, isTrue);
      await reloaded.setEnabled(false);
      await service.load();
      expect(service.enabled, isFalse);
      expect(calls, isEmpty);
    },
  );

  test(
    'only explicit permission action prompts; location lookup returns town and coordinates',
    () async {
      final service = RecordingLocationService();
      final location = await service.getCurrentLocation();
      expect(location?.town, 'Berlin');
      expect(location?.latitude, 52.52);
      expect(calls, ['current']);
      expect(await service.requestPermission(), isTrue);
      expect(calls, ['current', 'permission']);
    },
  );

  test('denial and unavailable provider remain optional', () async {
    messenger.setMockMethodCallHandler(RecordingLocationService.channel, (
      call,
    ) async {
      if (call.method == 'permission') return false;
      throw PlatformException(code: 'location_unavailable');
    });
    final service = RecordingLocationService();
    expect(await service.requestPermission(), isFalse);
    expect(await service.getCurrentLocation(), isNull);
  });

  test('other platforms never call Android location channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final service = RecordingLocationService();
    expect(service.supported, isFalse);
    expect(await service.requestPermission(), isFalse);
    expect(await service.getCurrentLocation(), isNull);
    expect(calls, isEmpty);
  });

  testWidgets('lookup times out without a permission prompt', (tester) async {
    final response = Completer<Object?>();
    messenger.setMockMethodCallHandler(RecordingLocationService.channel, (
      call,
    ) {
      calls.add(call.method);
      return response.future;
    });
    final pending = RecordingLocationService().getCurrentLocation();
    await tester.pump(const Duration(seconds: 8));
    expect(await pending, isNull);
    expect(calls, ['current']);
    response.complete(null);
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;
  });
}
