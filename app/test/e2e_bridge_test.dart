import 'package:flutter_test/flutter_test.dart';
import 'package:app/e2e_bridge.dart';

void main() {
  test('e2e bridge is disabled unless LIFENIZER_E2E is defined at build time', () {
    expect(e2eBridgeEnabled, isFalse);
  });
}
