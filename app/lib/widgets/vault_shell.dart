import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../app_state.dart';
import '../image_widgets.dart';
import '../models/app_page.dart';
import '../pages/capture_page.dart';
import '../pages/imports_page.dart';
import '../pages/insights_page.dart';
import '../pages/participants_page.dart';
import '../pages/relations_page.dart';
import '../pages/search_page.dart';
import '../pages/sync_page.dart';
import '../pricing_page.dart';
import '../services/quick_action_service.dart';

/// Refactored shell widget for the Lifenizer vault.
///
/// This widget handles the main navigation layout with:
/// - Wide layout: NavigationRail on left + page content
/// - Narrow layout: Bottom NavigationBar
/// - Storage quota banner above content
/// - Error/status bottom sheet
///
/// Navigation destinations are generated from the [AppPage] enum,
/// eliminating duplicate definitions across rail and bottom nav.
class VaultShell extends StatefulWidget {
  const VaultShell({required this.state, super.key});

  final LifenizerAppState state;

  @override
  State<VaultShell> createState() => _VaultShellState();
}

class _VaultShellState extends State<VaultShell> {
  /// Currently selected page index, mapped to [AppPage] enum.
  static const _mobilePages = [
    AppPage.search,
    AppPage.capture,
    AppPage.imports,
    AppPage.sync,
  ];
  int _selectedPageIndex = 0;
  QuickAction? _searchAction;
  int _searchRevision = 0;

  @override
  void initState() {
    super.initState();
    QuickActionService.instance.addListener(_receiveAction);
    _applyAction();
  }

  @override
  void dispose() {
    QuickActionService.instance.removeListener(_receiveAction);
    super.dispose();
  }

  void _receiveAction() {
    if (mounted) setState(_applyAction);
  }

  void _applyAction() {
    final action = QuickActionService.instance.consume();
    if (action == null) return;
    final page = switch (action.action) {
      'capture' => AppPage.capture,
      'imports' => AppPage.imports,
      _ => AppPage.search,
    };
    _selectedPageIndex = page.index;
    if (page == AppPage.search) {
      _searchAction = action;
      _searchRevision++;
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedPage = AppPage.values[_selectedPageIndex];
    final message =
        widget.state.error ?? widget.state.syncError ?? widget.state.status;
    final hasError =
        widget.state.error != null || widget.state.syncError != null;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
            QuickActionService.instance.request(const QuickAction()),
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
            QuickActionService.instance.request(const QuickAction()),
      },
      child: Scaffold(
        drawer: MediaQuery.sizeOf(context).width >= 820
            ? null
            : Drawer(
                child: SafeArea(
                  child: ListView(
                    children: [
                      for (final page in AppPage.values)
                        ListTile(
                          leading: Icon(page.icon),
                          title: Text(page.label),
                          selected: page == selectedPage,
                          onTap: () {
                            Navigator.of(context).pop();
                            setState(() => _selectedPageIndex = page.index);
                          },
                        ),
                    ],
                  ),
                ),
              ),
        appBar: AppBar(
          title: const Text('Lifenizer'),
          actions: [
            IconButton(
              tooltip: 'Find a conversation (Ctrl+K)',
              icon: const Icon(Icons.search),
              onPressed: () =>
                  QuickActionService.instance.request(const QuickAction()),
            ),
            IconButton(
              tooltip: 'Lock vault',
              icon: const Icon(Icons.lock_outline),
              onPressed: widget.state.busy ? null : widget.state.lock,
            ),
            if (widget.state.busy)
              const Padding(
                padding: EdgeInsets.only(right: 16),
                child: Center(
                  child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
          ],
        ),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 820;

            return Column(
              children: [
                StorageQuotaBanner(state: widget.state),
                Expanded(
                  child: wide
                      ? Row(
                          children: [
                            NavigationRail(
                              selectedIndex: _selectedPageIndex,
                              onDestinationSelected: (index) =>
                                  setState(() => _selectedPageIndex = index),
                              labelType: NavigationRailLabelType.all,
                              destinations: [
                                for (final page in AppPage.values)
                                  page.railDestination,
                              ],
                            ),
                            const VerticalDivider(width: 1),
                            Expanded(
                              child: _buildPage(selectedPage, widget.state),
                            ),
                          ],
                        )
                      : _buildPage(selectedPage, widget.state),
                ),
              ],
            );
          },
        ),
        bottomNavigationBar: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth >= 820) return const SizedBox.shrink();
            return NavigationBar(
              selectedIndex: _mobilePages.contains(selectedPage)
                  ? _mobilePages.indexOf(selectedPage)
                  : 4,
              onDestinationSelected: (index) {
                if (index == 4) {
                  Scaffold.of(context).openDrawer();
                } else {
                  setState(
                    () => _selectedPageIndex = _mobilePages[index].index,
                  );
                }
              },
              destinations: [
                for (final page in _mobilePages) page.navDestination,
                const NavigationDestination(
                  icon: Icon(Icons.more_horiz),
                  label: 'More',
                ),
              ],
            );
          },
        ),
        bottomSheet: message == null
            ? null
            : Material(
                elevation: 8,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  color: !hasError
                      ? const Color(0xffecfeff)
                      : const Color(0xffffebee),
                  child: Text(message),
                ),
              ),
      ),
    );
  }

  /// Builds the appropriate page widget based on the selected page.
  Widget _buildPage(AppPage page, LifenizerAppState state) {
    return switch (page) {
      AppPage.search => SearchPage(
        state: state,
        action: _searchAction,
        actionRevision: _searchRevision,
      ),
      AppPage.insights => InsightsPage(state: state),
      AppPage.capture => CapturePage(state: state),
      AppPage.imports => ImportsPage(state: state),
      AppPage.participants => ParticipantsPage(state: state),
      AppPage.relations => RelationsPage(state: state),
      AppPage.sync => SyncPage(state: state),
      AppPage.pricing => PricingPage(state: state),
    };
  }
}
