import 'dart:async';

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
import 'device_security_dialog.dart';

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

class _VaultShellState extends State<VaultShell> with WidgetsBindingObserver {
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
  bool _recordRequested = false;
  (String?, bool)? _lastMessage;
  bool _messageDismissed = false;
  Timer? _messageTimer;
  CaptureDraft? _captureDraft;
  String? _captureIdentity;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    QuickActionService.instance.addListener(_receiveAction);
    _applyAction();
  }

  @override
  void dispose() {
    _messageTimer?.cancel();
    _captureDraft?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    QuickActionService.instance.removeListener(_receiveAction);
    super.dispose();
  }

  void _receiveAction() {
    if (mounted) setState(_applyAction);
  }

  void _dismissMessage() {
    _messageTimer?.cancel();
    setState(() => _messageDismissed = true);
  }

  Future<void> _lock() async {
    final identity = widget.state.recordingIdentity;
    final draft = _captureDraft;
    if (draft?.hasUnsavedChanges ?? false) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Discard drafts and lock?'),
          content: const Text(
            'Your unsaved text and typed session notes will be lost. Save them before locking to keep them.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep editing'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Discard drafts and lock'),
            ),
          ],
        ),
      );
      if (discard != true ||
          !mounted ||
          widget.state.recordingIdentity != identity ||
          !identical(_captureDraft, draft) ||
          widget.state.busy) {
        return;
      }
    }
    if (!widget.state.pairing.matchesVault(
          widget.state.apiBaseUrl,
          widget.state.rememberedEmail,
        ) ||
        widget.state.pairing.higherSecurity) {
      await widget.state.lock();
      return;
    }
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Lock vault'),
        content: Text(
          'This device unlocks from ${widget.state.pairing.secureStorageLabel} without an app password. Device security adds an optional unlock prompt.\n\nVault storage and sync are encrypted. Server processing can read submitted content; original source files keep their own protection.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('security'),
            child: const Text('Device security'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop('lock'),
            child: const Text('Lock vault'),
          ),
        ],
      ),
    );
    if (!mounted ||
        widget.state.recordingIdentity != identity ||
        !identical(_captureDraft, draft)) {
      return;
    }
    if (action == 'security') {
      await showDeviceSecurityDialog(context, widget.state);
    } else if (action == 'lock') {
      await widget.state.lock();
    }
  }

  void _applyAction() {
    final action = QuickActionService.instance.consume();
    if (action == null) return;
    final page = switch (action.action) {
      'capture' || 'record' => AppPage.capture,
      'imports' => AppPage.imports,
      'pricing' => AppPage.pricing,
      _ => AppPage.search,
    };
    _selectedPageIndex = page.index;
    _recordRequested = action.action == 'record';
    if (_recordRequested) _scheduleRecording();
    if (page == AppPage.search) {
      _searchAction = action;
      _searchRevision++;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed && _recordRequested) {
      _scheduleRecording();
    }
  }

  void _scheduleRecording() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_recordRequested ||
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        return;
      }
      _recordRequested = false;
      if (!widget.state.isAuthenticated ||
          _selectedPageIndex != AppPage.capture.index) {
        return;
      }
      final recording = widget.state.recording;
      if (recording.recording || recording.working) return;
      if (widget.state.audioDraft != null) {
        widget.state.reportError(
          'Save or discard the pending recording before starting another.',
        );
      } else if (widget.state.busy) {
        widget.state.reportError(
          'Wait for the current operation, then tap Start microphone recording.',
        );
      } else {
        unawaited(recording.start());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final identity = widget.state.recordingIdentity;
    if (_captureIdentity != identity) {
      _captureDraft?.dispose();
      _captureDraft = null;
      _captureIdentity = identity;
    }
    final selectedPage = AppPage.values[_selectedPageIndex];
    final message =
        widget.state.error ?? widget.state.syncError ?? widget.state.status;
    final hasError =
        widget.state.error != null || widget.state.syncError != null;
    final colors = Theme.of(context).colorScheme;
    final messageForeground = hasError
        ? colors.onErrorContainer
        : colors.onSecondaryContainer;
    final currentMessage = (message, hasError);
    if (_lastMessage != currentMessage) {
      _messageTimer?.cancel();
      _lastMessage = currentMessage;
      _messageDismissed = false;
      if (message != null && !hasError) {
        _messageTimer = Timer(const Duration(seconds: 8), _dismissMessage);
      }
    }

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
              onPressed: widget.state.busy ? null : _lock,
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
        bottomSheet: message == null || _messageDismissed
            ? null
            : Material(
                elevation: 8,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  color: !hasError
                      ? colors.secondaryContainer
                      : colors.errorContainer,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          message,
                          style: TextStyle(color: messageForeground),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Dismiss message',
                        color: messageForeground,
                        icon: const Icon(Icons.close),
                        onPressed: _dismissMessage,
                      ),
                    ],
                  ),
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
      AppPage.capture => CapturePage(
        key: ValueKey(state.recordingIdentity),
        state: state,
        draft: _captureDraft ??= CaptureDraft(),
      ),
      AppPage.imports => ImportsPage(state: state),
      AppPage.participants => ParticipantsPage(state: state),
      AppPage.relations => RelationsPage(state: state),
      AppPage.sync => SyncPage(state: state),
      AppPage.pricing => PricingPage(state: state),
    };
  }
}
