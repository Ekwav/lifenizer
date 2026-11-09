import 'package:app/app_state.dart';
import 'package:app/main.dart';
import 'package:app/pages/search/search_input_field.dart';
import 'package:app/services/pairing_store.dart';
import 'package:app/services/quick_action_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Vault extends LifenizerAppState {
  _Vault({super.pairingStore});
  bool unlocked = false;
  @override
  bool get isAuthenticated => unlocked;

  void unlock() {
    startupLoading = false;
    unlocked = true;
    notifyListeners();
  }
}

/// A paired device. Password protection opens no OS prompt on its own;
/// biometric protection runs [onPrompt] where the OS prompt would show.
class _PairedStore extends PairingCredentialStore {
  _PairedStore({this.protection = 'password', this.onPrompt});
  final String protection;
  final void Function()? onPrompt;

  @override
  Future<Map<String, dynamic>?> read() async => {
    'server': 'https://example.test',
    'email': 'linked@example.test',
    'deviceId': 'device',
    'until': 1,
    'protection': protection,
  };

  @override
  Future<Map<String, dynamic>?> readForUnlock({
    String? password,
    bool authenticate = false,
  }) async {
    onPrompt?.call();
    throw PlatformException(code: 'cancelled');
  }

  @override
  Future<void> write(Map<String, dynamic> credentials) async {}
}

Future<_Vault> _showLocked(
  WidgetTester tester, {
  PairingCredentialStore? store,
  bool startup = true,
}) async {
  final state = _Vault(pairingStore: store)..startupLoading = startup;
  await tester.pumpWidget(LifenizerApp(state: state));
  if (store != null) {
    await tester.runAsync(() => state.pairing.restore(autoUnlock: false));
  }
  await tester.pump();
  return state;
}

Future<void> _close(WidgetTester tester, LifenizerAppState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  state.dispose();
}

TextField _field(WidgetTester tester, Finder scope) => tester.widget<TextField>(
  find.descendant(of: scope, matching: find.byType(TextField)),
);

TextField _lockedField(WidgetTester tester) =>
    _field(tester, find.byType(Scaffold));

TextField _unlockedField(WidgetTester tester) =>
    _field(tester, find.byType(SearchInputField));

Iterable<String> _inputCalls(WidgetTester tester) =>
    tester.testTextInput.log.map((call) => call.method);

void _simulateOsPrompt(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.testTextInput.hide();
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

const _typed = TextEditingValue(
  text: 'meeting notes',
  selection: TextSelection.collapsed(offset: 7),
  composing: TextRange(start: 0, end: 7),
);

void main() {
  // Widget tests run as Android unless a variant says otherwise.
  setUp(QuickActionService.instance.consume);
  tearDown(QuickActionService.instance.consume);

  testWidgets(
    'Android focuses the locked search and hands it to the unlocked search without closing the keyboard',
    (tester) async {
      final state = await _showLocked(tester, store: _PairedStore());
      expect(_lockedField(tester).focusNode!.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);

      tester.testTextInput.updateEditingValue(_typed);
      await tester.pump();
      tester.testTextInput.log.clear();

      state.unlock();
      await tester.pump();
      await tester.pump();

      final field = _unlockedField(tester);
      expect(field.focusNode!.hasFocus, isTrue);
      expect(field.controller!.value, _typed);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(_inputCalls(tester), isNot(contains('TextInput.hide')));
      expect(state.pendingSearch, TextEditingValue.empty);
      await _close(tester, state);
    },
  );

  testWidgets(
    'locked search keeps focus when startup switches to the unlock page',
    (tester) async {
      final state = await _showLocked(tester, store: _PairedStore());
      expect(_lockedField(tester).focusNode!.hasFocus, isTrue);
      tester.testTextInput.log.clear();

      state.startupLoading = false;
      state.notifyListeners();
      await tester.pump();
      await tester.pump();

      expect(_lockedField(tester).focusNode!.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(_inputCalls(tester), isNot(contains('TextInput.hide')));
      await _close(tester, state);
    },
  );

  testWidgets(
    'locked search reopens the keyboard after the OS unlock prompt returns',
    (tester) async {
      final store = _PairedStore(
        protection: 'biometric',
        onPrompt: () => _simulateOsPrompt(tester),
      );
      final state = await _showLocked(tester, store: store, startup: false);
      expect(_lockedField(tester).focusNode!.hasFocus, isTrue);

      await tester.tap(find.text('Unlock this device'));
      await tester.pumpAndSettle();

      expect(_lockedField(tester).focusNode!.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      await _close(tester, state);
    },
  );

  testWidgets('other resumes leave a dismissed keyboard closed', (
    tester,
  ) async {
    final state = await _showLocked(
      tester,
      store: _PairedStore(),
      startup: false,
    );
    _simulateOsPrompt(tester);
    await tester.pump();

    expect(_lockedField(tester).focusNode!.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isFalse);
    await _close(tester, state);
  });

  testWidgets('unpaired devices leave the startup search unfocused', (
    tester,
  ) async {
    final state = await _showLocked(tester);
    expect(_lockedField(tester).focusNode!.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    await _close(tester, state);
  });

  testWidgets('record shortcut leaves the locked search unfocused', (
    tester,
  ) async {
    QuickActionService.instance.request(const QuickAction(action: 'record'));
    final state = await _showLocked(tester, store: _PairedStore());
    expect(_lockedField(tester).focusNode!.hasFocus, isFalse);
    await _close(tester, state);
  });

  testWidgets(
    'other platforms leave the locked search unfocused',
    (tester) async {
      final state = await _showLocked(tester, store: _PairedStore());
      expect(_lockedField(tester).focusNode!.hasFocus, isFalse);
      await _close(tester, state);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets(
    'a search not taken over at unlock keeps its text but not the IME composing range',
    (tester) async {
      final state = await _showLocked(tester, store: _PairedStore());
      tester.testTextInput.updateEditingValue(_typed);
      await tester.pump();

      await tester.pumpWidget(const SizedBox.shrink());

      expect(state.pendingSearch, _typed.copyWith(composing: TextRange.empty));
      state.dispose();
    },
  );
}
