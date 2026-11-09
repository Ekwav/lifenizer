import 'app_state.dart';
import 'e2e_bridge_stub.dart'
    if (dart.library.html) 'e2e_bridge_web.dart'
    as bridge;

/// The bridge exposes the decrypted vault to page scripts, so it is only
/// compiled in when building with `--dart-define=LIFENIZER_E2E=true`.
const bool e2eBridgeEnabled = bool.fromEnvironment('LIFENIZER_E2E');

void installE2eBridge(LifenizerAppState state) {
  if (!e2eBridgeEnabled) return;
  bridge.installE2eBridge(state);
}
