import 'app_state.dart';
import 'e2e_bridge_stub.dart'
    if (dart.library.html) 'e2e_bridge_web.dart'
    as bridge;

void installE2eBridge(LifenizerAppState state) {
  bridge.installE2eBridge(state);
}
