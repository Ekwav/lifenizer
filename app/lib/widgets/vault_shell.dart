import 'package:flutter/material.dart';
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
  int _selectedPageIndex = 0;

  @override
  Widget build(BuildContext context) {
    final selectedPage = AppPage.values[_selectedPageIndex];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Lifenizer'),
        actions: [
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
            selectedIndex: _selectedPageIndex,
            onDestinationSelected: (index) =>
                setState(() => _selectedPageIndex = index),
            destinations: [
              for (final page in AppPage.values) page.navDestination,
            ],
          );
        },
      ),
      bottomSheet: widget.state.error == null && widget.state.status == null
          ? null
          : Material(
              elevation: 8,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                color: widget.state.error == null
                    ? const Color(0xffecfeff)
                    : const Color(0xffffebee),
                child: Text(widget.state.error ?? widget.state.status ?? ''),
              ),
            ),
    );
  }

  /// Builds the appropriate page widget based on the selected page.
  Widget _buildPage(AppPage page, LifenizerAppState state) {
    return switch (page) {
      AppPage.search => SearchPage(state: state),
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
