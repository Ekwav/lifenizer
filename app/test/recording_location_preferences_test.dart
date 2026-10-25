import 'package:app/services/recording_location_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'missing preference backend keeps optional location off without blocking recording',
    () async {
      final service = RecordingLocationService();
      await service.load();
      expect(service.enabled, isFalse);
    },
  );
}
