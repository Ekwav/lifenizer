import 'package:app/app_state.dart';
import 'package:app/main.dart';
import 'package:app/models.dart';
import 'package:app/pages/login_page.dart';
import 'package:app/widgets/vault_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _UnlockedVault extends LifenizerAppState {
  @override
  bool get isAuthenticated => true;
}

double _contrast(Color foreground, Color background) {
  final a = foreground.computeLuminance();
  final b = background.computeLuminance();
  return a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
}

void main() {
  testWidgets('login starts dark and follows OS brightness changes', (
    tester,
  ) async {
    final platform = tester.binding.platformDispatcher;
    platform.platformBrightnessTestValue = Brightness.dark;
    addTearDown(platform.clearPlatformBrightnessTestValue);
    final state = LifenizerAppState();
    addTearDown(state.dispose);
    await tester.pumpWidget(LifenizerApp(state: state));
    await tester.pumpAndSettle();
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.system,
    );
    for (final brightness in [
      Brightness.dark,
      Brightness.light,
      Brightness.dark,
    ]) {
      platform.platformBrightnessTestValue = brightness;
      await tester.pumpAndSettle();
      final theme = Theme.of(tester.element(find.byType(LoginPage)));
      expect(theme.brightness, brightness);
      expect(
        theme.scaffoldBackgroundColor.computeLuminance(),
        brightness == Brightness.dark ? lessThan(.1) : greaterThan(.8),
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'search and its open picker follow OS changes without losing input',
    (tester) async {
      final platform = tester.binding.platformDispatcher;
      platform.platformBrightnessTestValue = Brightness.light;
      addTearDown(platform.clearPlatformBrightnessTestValue);
      final state = _UnlockedVault();
      addTearDown(state.dispose);
      await tester.pumpWidget(LifenizerApp(state: state));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'keep this query');
      await tester.tap(find.byKey(const Key('search-participant-filter')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('search-filter-query')),
        'Alice',
      );
      platform.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(AlertDialog))).brightness,
        Brightness.dark,
      );
      final editable = find.descendant(
        of: find.byKey(const Key('search-filter-query')),
        matching: find.byType(EditableText),
      );
      expect(tester.widget<EditableText>(editable).controller.text, 'Alice');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'keep this query',
      );
      expect(
        Theme.of(tester.element(find.byType(VaultShell))).brightness,
        Brightness.dark,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'status, error and storage banners stay readable in $brightness',
      (tester) async {
        final platform = tester.binding.platformDispatcher;
        platform.platformBrightnessTestValue = brightness;
        addTearDown(platform.clearPlatformBrightnessTestValue);
        final state = _UnlockedVault()..status = 'Saved locally';
        addTearDown(state.dispose);
        state.quotaStatus = QuotaStatus(
          plan: 'free',
          usedBytes: 85,
          limitBytes: 100,
          usedPercent: 85,
        );
        await tester.pumpWidget(LifenizerApp(state: state));
        await tester.pumpAndSettle();
        // This UI-only vault has no API; discard its startup sync failure.
        state.syncError = null;
        state.notifyListeners();
        await tester.pumpAndSettle();
        final colors = Theme.of(
          tester.element(find.byType(VaultShell)),
        ).colorScheme;
        void checkBanner(String message, Color background, Color foreground) {
          final text = find.text(message);
          final container = tester.widget<Container>(
            find.ancestor(of: text, matching: find.byType(Container)),
          );
          expect(container.color, background);
          expect(tester.widget<Text>(text).style!.color, foreground);
          expect(_contrast(foreground, background), greaterThanOrEqualTo(4.5));
        }

        checkBanner(
          'Saved locally',
          colors.secondaryContainer,
          colors.onSecondaryContainer,
        );
        var quota = tester.widget<MaterialBanner>(find.byType(MaterialBanner));
        expect(quota.backgroundColor, colors.tertiaryContainer);
        expect(
          _contrast(quota.contentTextStyle!.color!, quota.backgroundColor!),
          greaterThanOrEqualTo(4.5),
        );
        state.quotaStatus = QuotaStatus(
          plan: 'free',
          usedBytes: 100,
          limitBytes: 100,
          usedPercent: 100,
        );
        state.reportError('Could not sync');
        await tester.pumpAndSettle();
        checkBanner(
          'Could not sync',
          colors.errorContainer,
          colors.onErrorContainer,
        );
        quota = tester.widget<MaterialBanner>(find.byType(MaterialBanner));
        expect(quota.backgroundColor, colors.errorContainer);
        expect(
          _contrast(quota.contentTextStyle!.color!, quota.backgroundColor!),
          greaterThanOrEqualTo(4.5),
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
