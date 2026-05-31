import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'app_state.dart';
import 'e2e_bridge.dart';
import 'image_widgets.dart';
import 'models.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SemanticsBinding.instance.ensureSemantics();
  final appState = LifenizerAppState();
  installE2eBridge(appState);
  runApp(LifenizerApp(state: appState));
}

class LifenizerApp extends StatelessWidget {
  const LifenizerApp({required this.state, super.key});

  final LifenizerAppState state;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        return MaterialApp(
          title: 'Lifenizer',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xff0f766e),
              brightness: Brightness.light,
            ),
            useMaterial3: true,
            cardTheme: const CardThemeData(
              margin: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(8)),
              ),
            ),
          ),
          home: state.isAuthenticated
              ? VaultShell(state: state)
              : LoginPage(state: state),
        );
      },
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({required this.state, super.key});

  final LifenizerAppState state;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late final TextEditingController _apiController;
  final TextEditingController _emailController = TextEditingController(
    text: 'alice@example.test',
  );
  final TextEditingController _passphraseController = TextEditingController(
    text: 'correct horse battery staple',
  );

  @override
  void initState() {
    super.initState();
    _apiController = TextEditingController(text: widget.state.apiBaseUrl);
  }

  @override
  void dispose() {
    _apiController.dispose();
    _emailController.dispose();
    _passphraseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Lifenizer',
                    style: Theme.of(context).textTheme.displaySmall,
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _apiController,
                    decoration: const InputDecoration(
                      labelText: 'API URL',
                      prefixIcon: Icon(Icons.dns_outlined),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _emailController,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      prefixIcon: Icon(Icons.alternate_email),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _passphraseController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Vault passphrase',
                      prefixIcon: Icon(Icons.key_outlined),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: widget.state.busy
                        ? null
                        : () => widget.state.login(
                            baseUrl: _apiController.text,
                            email: _emailController.text,
                            passphrase: _passphraseController.text,
                          ),
                    icon: const Icon(Icons.lock_open),
                    label: const Text('Enter vault'),
                  ),
                  if (widget.state.error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      widget.state.error!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class VaultShell extends StatefulWidget {
  const VaultShell({required this.state, super.key});

  final LifenizerAppState state;

  @override
  State<VaultShell> createState() => _VaultShellState();
}

class _VaultShellState extends State<VaultShell> {
  int selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      SearchPage(state: widget.state),
      InsightsPage(state: widget.state),
      CapturePage(state: widget.state),
      ImportsPage(state: widget.state),
      ParticipantsPage(state: widget.state),
      RelationsPage(state: widget.state),
      SyncPage(state: widget.state),
    ];

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
          final pageArea = LayoutBuilder(
            builder: (context, innerConstraints) {
              if (wide) {
                return Row(
                  children: [
                    NavigationRail(
                      selectedIndex: selectedIndex,
                      onDestinationSelected: (index) =>
                          setState(() => selectedIndex = index),
                      labelType: NavigationRailLabelType.all,
                      destinations: const [
                        NavigationRailDestination(
                          icon: Icon(Icons.search),
                          label: Text('Search'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.insights_outlined),
                          label: Text('Insights'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.add_circle_outline),
                          label: Text('Capture'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.input),
                          label: Text('Imports'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.people_outline),
                          label: Text('People'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.account_tree_outlined),
                          label: Text('Relations'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.sync),
                          label: Text('Sync'),
                        ),
                      ],
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: pages[selectedIndex]),
                  ],
                );
              }
              return pages[selectedIndex];
            },
          );
          return Column(
            children: [
              StorageQuotaBanner(state: widget.state),
              Expanded(child: pageArea),
            ],
          );
        },
      ),
      bottomNavigationBar: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 820) return const SizedBox.shrink();
          return NavigationBar(
            selectedIndex: selectedIndex,
            onDestinationSelected: (index) =>
                setState(() => selectedIndex = index),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
              NavigationDestination(
                icon: Icon(Icons.insights_outlined),
                label: 'Insights',
              ),
              NavigationDestination(
                icon: Icon(Icons.add_circle_outline),
                label: 'Capture',
              ),
              NavigationDestination(icon: Icon(Icons.input), label: 'Imports'),
              NavigationDestination(
                icon: Icon(Icons.people_outline),
                label: 'People',
              ),
              NavigationDestination(
                icon: Icon(Icons.account_tree_outlined),
                label: 'Relations',
              ),
              NavigationDestination(icon: Icon(Icons.sync), label: 'Sync'),
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
}

class PageFrame extends StatelessWidget {
  const PageFrame({required this.title, required this.child, super.key});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 80),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1120),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 16),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

class SearchPage extends StatefulWidget {
  const SearchPage({required this.state, super.key});

  final LifenizerAppState state;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _queryController = TextEditingController();
  String _sourceFilter = '';
  String _participantFilter = '';
  String _tagFilter = '';

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final results = widget.state.search(
      _queryController.text,
      source: _sourceFilter,
      participantId: _participantFilter,
      tag: _tagFilter,
    );
    return RefreshIndicator(
      onRefresh: widget.state.pullSync,
      child: PageFrame(
        title: 'Search',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _queryController,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                FocusScope.of(context).unfocus();
                setState(() {});
              },
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                labelText: 'Search text, people, relations',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                SizedBox(
                  width: 220,
                  child: _FilterDropdown(
                    label: 'Source',
                    value: _sourceFilter,
                    items: widget.state.availableSources,
                    onChanged: (value) => setState(() => _sourceFilter = value),
                  ),
                ),
                SizedBox(
                  width: 260,
                  child: _FilterDropdown(
                    label: 'Participant',
                    value: _participantFilter,
                    items: widget.state.participants
                        .map((item) => item.id)
                        .toList(),
                    itemLabel: widget.state.participantName,
                    onChanged: (value) =>
                        setState(() => _participantFilter = value),
                  ),
                ),
                SizedBox(
                  width: 220,
                  child: _FilterDropdown(
                    label: 'Tag',
                    value: _tagFilter,
                    items: widget.state.allTags,
                    onChanged: (value) => setState(() => _tagFilter = value),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () => setState(() {
                    _sourceFilter = '';
                    _participantFilter = '';
                    _tagFilter = '';
                    _queryController.clear();
                  }),
                  icon: const Icon(Icons.filter_alt_off_outlined),
                  label: const Text('Clear'),
                ),
                FilledButton.icon(
                  onPressed: widget.state.busy ? null : _saveCurrentSearch,
                  icon: const Icon(Icons.bookmark_add_outlined),
                  label: const Text('Save search'),
                ),
              ],
            ),
            if (widget.state.savedSearches.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final savedSearch in widget.state.savedSearches)
                    ActionChip(
                      avatar: const Icon(Icons.bookmark_outline),
                      label: Text(savedSearch.title),
                      onPressed: () => setState(() {
                        _queryController.text = savedSearch.query;
                        _sourceFilter = savedSearch.source ?? '';
                        _participantFilter = savedSearch.participantId ?? '';
                        _tagFilter = savedSearch.tag ?? '';
                      }),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _Metric(
                  label: 'Conversations',
                  value: '${widget.state.conversations.length}',
                ),
                _Metric(
                  label: 'Participants',
                  value: '${widget.state.participants.length}',
                ),
                _Metric(
                  label: 'Relations',
                  value: '${widget.state.relations.length}',
                ),
                _Metric(
                  label: 'Saved',
                  value: '${widget.state.savedSearches.length}',
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (results.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    widget.state.conversations.isEmpty
                        ? 'No conversations yet. Capture or import something to get started.'
                        : 'No matches. Try a different query or clear the filters.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '${results.length} result${results.length == 1 ? '' : 's'}',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
              for (final conversation in results) ...[
                ConversationCard(
                  state: widget.state,
                  conversation: conversation,
                ),
                const SizedBox(height: 12),
              ],
            ],
          ],
        ),
      ), // PageFrame
    ); // RefreshIndicator
  }

  Future<void> _saveCurrentSearch() async {
    final parts = <String>[
      if (_queryController.text.trim().isNotEmpty) _queryController.text.trim(),
      if (_sourceFilter.isNotEmpty) _sourceFilter,
      if (_tagFilter.isNotEmpty) '#$_tagFilter',
      if (_participantFilter.isNotEmpty)
        widget.state.participantName(_participantFilter),
    ];
    await widget.state.addSavedSearch(
      title: parts.isEmpty ? 'All conversations' : parts.join(' / '),
      query: _queryController.text,
      source: _sourceFilter,
      participantId: _participantFilter,
      tag: _tagFilter,
    );
  }
}

class InsightsPage extends StatelessWidget {
  const InsightsPage({required this.state, super.key});

  final LifenizerAppState state;

  @override
  Widget build(BuildContext context) {
    final insights = state.insights;
    return PageFrame(
      title: 'Insights',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _Metric(
                label: 'Conversations',
                value: '${insights.totalConversations}',
              ),
              _Metric(label: 'Segments', value: '${insights.totalSegments}'),
              _Metric(label: 'Artifacts', value: '${insights.totalArtifacts}'),
              _Metric(label: 'Tags', value: '${insights.tags.length}'),
            ],
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 900;
              final panels = [
                _FacetPanel(
                  title: 'Sources',
                  icon: Icons.source_outlined,
                  rows: insights.sourceFacets
                      .map((facet) => _FacetRow(facet.source, facet.count))
                      .toList(),
                ),
                _FacetPanel(
                  title: 'People',
                  icon: Icons.people_outline,
                  rows: insights.participantFacets
                      .map(
                        (facet) => _FacetRow(
                          facet.participant.displayName,
                          facet.count,
                        ),
                      )
                      .toList(),
                ),
                _FacetPanel(
                  title: 'Timeline',
                  icon: Icons.calendar_month_outlined,
                  rows: insights.timeline
                      .map(
                        (bucket) =>
                            _FacetRow(_formatDay(bucket.day), bucket.count),
                      )
                      .toList(),
                ),
                _TagsPanel(tags: insights.tags),
              ];
              if (!wide) {
                return Column(
                  children: panels
                      .expand((panel) => [panel, const SizedBox(height: 12)])
                      .toList(),
                );
              }
              return Wrap(
                spacing: 16,
                runSpacing: 16,
                children: panels
                    .map(
                      (panel) => SizedBox(
                        width: (constraints.maxWidth - 16) / 2,
                        child: panel,
                      ),
                    )
                    .toList(),
              );
            },
          ),
        ],
      ),
    );
  }

  String _formatDay(DateTime day) {
    final month = day.month.toString().padLeft(2, '0');
    final date = day.day.toString().padLeft(2, '0');
    return '${day.year}-$month-$date';
  }
}

class CapturePage extends StatefulWidget {
  const CapturePage({required this.state, super.key});

  final LifenizerAppState state;

  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> {
  final TextEditingController _titleController = TextEditingController(
    text: 'Coffee with Person X',
  );
  final TextEditingController _participantsController = TextEditingController(
    text: 'Person X, Person Y',
  );
  final TextEditingController _textController = TextEditingController(
    text: "Person X is Person Y's brother and Person X works with Person Z.",
  );
  final TextEditingController _recordingTitleController = TextEditingController(
    text: 'Live session',
  );
  final TextEditingController _recordingParticipantsController =
      TextEditingController(text: 'Person X, Person Y');
  final TextEditingController _segmentController = TextEditingController();
  final List<String> _segments = [];
  bool _recording = false;

  @override
  void dispose() {
    _titleController.dispose();
    _participantsController.dispose();
    _textController.dispose();
    _recordingTitleController.dispose();
    _recordingParticipantsController.dispose();
    _segmentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PageFrame(
      title: 'Capture',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final twoColumns = constraints.maxWidth >= 900;
          final children = [
            _ManualTextPanel(
              titleController: _titleController,
              participantsController: _participantsController,
              textController: _textController,
              onSubmit: () => widget.state.addManualText(
                title: _titleController.text,
                participantNames: _participantsController.text,
                text: _textController.text,
              ),
            ),
            _RecordingPanel(
              recording: _recording,
              titleController: _recordingTitleController,
              participantsController: _recordingParticipantsController,
              segmentController: _segmentController,
              segments: _segments,
              onStart: () => setState(() {
                _segments.clear();
                _recording = true;
              }),
              onAddSegment: () => setState(() {
                if (_segmentController.text.trim().isNotEmpty) {
                  _segments.add(_segmentController.text.trim());
                  _segmentController.clear();
                }
              }),
              onStop: () async {
                await widget.state.addRecordingConversation(
                  title: _recordingTitleController.text,
                  participantNames: _recordingParticipantsController.text,
                  segmentTexts: _segments,
                );
                setState(() => _recording = false);
              },
            ),
            _FilePanel(
              participantsController: _participantsController,
              onPick: () async {
                final result = await FilePicker.pickFiles(withData: true);
                final file = result?.files.single;
                if (file != null) {
                  await widget.state.addFileArtifact(
                    participantNames: _participantsController.text,
                    file: file,
                  );
                }
              },
            ),
          ];
          if (twoColumns) {
            return Wrap(
              spacing: 16,
              runSpacing: 16,
              children: children
                  .map(
                    (child) => SizedBox(
                      width: (constraints.maxWidth - 16) / 2,
                      child: child,
                    ),
                  )
                  .toList(),
            );
          }
          return Column(
            children: children
                .expand((child) => [child, const SizedBox(height: 16)])
                .toList(),
          );
        },
      ),
    );
  }
}

class ImportsPage extends StatefulWidget {
  const ImportsPage({required this.state, super.key});

  final LifenizerAppState state;

  @override
  State<ImportsPage> createState() => _ImportsPageState();
}

class _ImportsPageState extends State<ImportsPage> {
  final TextEditingController _sourceController = TextEditingController(
    text: 'whatsapp',
  );
  final TextEditingController _titleController = TextEditingController(
    text: 'Imported conversation',
  );
  final TextEditingController _participantsController = TextEditingController();
  final TextEditingController _textController = TextEditingController(
    text:
        '[20.05.2026, 10:00] Alice: Person X works with Person Z.\n[20.05.2026, 10:01] Bob: Person Y is Person X\'s sister.',
  );
  final TextEditingController _fileController = TextEditingController();
  final TextEditingController _mimeController = TextEditingController();
  final TextEditingController _metadataController = TextEditingController(
    text: '{}',
  );

  @override
  void dispose() {
    _sourceController.dispose();
    _titleController.dispose();
    _participantsController.dispose();
    _textController.dispose();
    _fileController.dispose();
    _mimeController.dispose();
    _metadataController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PageFrame(
      title: 'Imports',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Run import',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      SizedBox(
                        width: 220,
                        child: TextField(
                          controller: _sourceController,
                          decoration: const InputDecoration(
                            labelText: 'Source',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 300,
                        child: TextField(
                          controller: _titleController,
                          decoration: const InputDecoration(
                            labelText: 'Title',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 300,
                        child: TextField(
                          controller: _participantsController,
                          decoration: const InputDecoration(
                            labelText: 'Participants',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 240,
                        child: TextField(
                          controller: _fileController,
                          decoration: const InputDecoration(
                            labelText: 'Original file',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 220,
                        child: TextField(
                          controller: _mimeController,
                          decoration: const InputDecoration(
                            labelText: 'MIME type',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _textController,
                    minLines: 5,
                    maxLines: 9,
                    decoration: const InputDecoration(
                      labelText: 'Text or export payload',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _metadataController,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Provider metadata JSON',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: widget.state.busy ? null : _runImport,
                        icon: const Icon(Icons.input),
                        label: const Text('Import and encrypt'),
                      ),
                      for (final source in const [
                        'whatsapp',
                        'telegram',
                        'signal',
                        'browser-history',
                        'youtube-transcript',
                        'audio',
                        'scanned-pdf',
                      ])
                        OutlinedButton(
                          onPressed: widget.state.busy
                              ? null
                              : () => widget.state.importSample(source),
                          child: Text(source),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final capability in widget.state.importCapabilities)
                SizedBox(
                  width: 340,
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                capability.availableNow
                                    ? Icons.check_circle_outline
                                    : Icons.pending_outlined,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  capability.displayName,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(capability.source),
                          const SizedBox(height: 8),
                          Text(capability.status),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _runImport() async {
    final decoded = _metadataController.text.trim().isEmpty
        ? <String, dynamic>{}
        : decodeJsonMap(_metadataController.text);
    final metadata = decoded.map((key, value) => MapEntry(key, '$value'));
    await widget.state.importSource(
      source: _sourceController.text.trim(),
      title: _titleController.text,
      participantNames: _participantsController.text,
      text: _textController.text,
      originalFileName: _fileController.text.trim().isEmpty
          ? null
          : _fileController.text.trim(),
      mimeType: _mimeController.text.trim().isEmpty
          ? null
          : _mimeController.text.trim(),
      metadata: metadata,
    );
  }
}

class ParticipantsPage extends StatelessWidget {
  const ParticipantsPage({required this.state, super.key});

  final LifenizerAppState state;

  @override
  Widget build(BuildContext context) {
    return PageFrame(
      title: 'People',
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final participant in state.participants)
            SizedBox(
              width: 260,
              child: Card(
                child: ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(participant.displayName),
                  subtitle: Text(
                    participant.identifiers.isEmpty
                        ? participant.id
                        : participant.identifiers.join(', '),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class RelationsPage extends StatelessWidget {
  const RelationsPage({required this.state, super.key});

  final LifenizerAppState state;

  @override
  Widget build(BuildContext context) {
    return PageFrame(
      title: 'Relations',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final relation in state.relations) ...[
            Card(
              child: ListTile(
                leading: const Icon(Icons.account_tree_outlined),
                title: Text(
                  '${relation.subject} ${relation.relation} ${relation.object}',
                ),
                subtitle: Text(relation.evidence),
                trailing: Text('${(relation.confidence * 100).round()}%'),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class SyncPage extends StatelessWidget {
  const SyncPage({required this.state, super.key});

  final LifenizerAppState state;

  @override
  Widget build(BuildContext context) {
    final quota = state.quotaStatus;
    return PageFrame(
      title: 'Sync',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('User ${state.session?.userId ?? ''}'),
          Text('Vault ${state.session?.vaultId ?? ''}'),
          Text('Cursor ${state.syncCursor}'),
          const SizedBox(height: 20),
          // Storage indicator
          if (quota != null) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Storage · ${quota.plan}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Text(
                  '${quota.usedFormatted} / ${quota.limitFormatted}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: (quota.usedPercent / 100).clamp(0.0, 1.0),
                minHeight: 8,
                color: quota.isOverLimit
                    ? Theme.of(context).colorScheme.error
                    : quota.isNearLimit
                    ? Colors.orange
                    : null,
              ),
            ),
            if (quota.plan == 'Free') ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.star_outline),
                label: const Text('Upgrade for more storage'),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => UpgradeDialog(state: state),
                ),
              ),
            ],
            const SizedBox(height: 20),
          ],
          FilledButton.icon(
            onPressed: state.busy ? null : state.pullSync,
            icon: const Icon(Icons.sync),
            label: const Text('Pull sync'),
          ),
        ],
      ),
    );
  }
}

class ConversationCard extends StatelessWidget {
  const ConversationCard({
    required this.state,
    required this.conversation,
    super.key,
  });

  final LifenizerAppState state;
  final Conversation conversation;

  void _openDetail(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) =>
          _ConversationDetailSheet(state: state, conversation: conversation),
    );
  }

  @override
  Widget build(BuildContext context) {
    final participants = conversation.participantIds
        .map(state.participantName)
        .join(', ');
    final preview = conversation.segments
        .map((segment) => segment.text)
        .join(' ');
    return Card(
      child: InkWell(
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        onTap: () => _openDetail(context),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      conversation.title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Detect relations',
                    onPressed: () => state.extractRelations(conversation),
                    icon: const Icon(Icons.account_tree_outlined),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text('${conversation.source} • $participants'),
              if (conversation.tags.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final tag in conversation.tags)
                      Chip(
                        label: Text(tag),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Text(preview, maxLines: 3, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConversationDetailSheet extends StatelessWidget {
  const _ConversationDetailSheet({
    required this.state,
    required this.conversation,
  });

  final LifenizerAppState state;
  final Conversation conversation;

  @override
  Widget build(BuildContext context) {
    final participants = conversation.participantIds
        .map(state.participantName)
        .join(', ');
    final fullText = conversation.segments.map((s) => s.text).join('\n\n');

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 1.0,
      expand: false,
      builder: (ctx, scrollController) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: CustomScrollView(
            controller: scrollController,
            slivers: [
              SliverToBoxAdapter(
                child: Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Text(
                  conversation.title,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 12),
                  child: Text(
                    '${conversation.source} • $participants',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              if (conversation.tags.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final tag in conversation.tags)
                          Chip(
                            label: Text(tag),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                  ),
                ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: AnimatedBuilder(
                    animation: state,
                    builder: (_, __) => ImageGallery(
                      state: state,
                      conversationId: conversation.id,
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Text(
                  'Transcript',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    fullText.isEmpty ? 'No transcript.' : fullText,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _FilterDropdown extends StatelessWidget {
  const _FilterDropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.itemLabel,
  });

  final String label;
  final String value;
  final List<String> items;
  final ValueChanged<String> onChanged;
  final String Function(String value)? itemLabel;

  @override
  Widget build(BuildContext context) {
    final selectedValue = items.contains(value) ? value : '';
    return DropdownButtonFormField<String>(
      key: ValueKey('$label-$selectedValue-${items.length}'),
      initialValue: selectedValue,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      items: [
        const DropdownMenuItem(value: '', child: Text('All')),
        for (final item in items)
          DropdownMenuItem(
            value: item,
            child: Text(itemLabel?.call(item) ?? item),
          ),
      ],
      onChanged: (nextValue) => onChanged(nextValue ?? ''),
    );
  }
}

class _FacetRow {
  const _FacetRow(this.label, this.count);

  final String label;
  final int count;
}

class _FacetPanel extends StatelessWidget {
  const _FacetPanel({
    required this.title,
    required this.icon,
    required this.rows,
  });

  final String title;
  final IconData icon;
  final List<_FacetRow> rows;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon),
                const SizedBox(width: 8),
                Text(title, style: Theme.of(context).textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: 12),
            if (rows.isEmpty)
              const Text('No data yet')
            else
              for (final row in rows.take(8))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(row.label, overflow: TextOverflow.ellipsis),
                      ),
                      const SizedBox(width: 12),
                      Text('${row.count}'),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _TagsPanel extends StatelessWidget {
  const _TagsPanel({required this.tags});

  final List<String> tags;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.sell_outlined),
                const SizedBox(width: 8),
                Text('Tags', style: Theme.of(context).textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: 12),
            if (tags.isEmpty)
              const Text('No data yet')
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [for (final tag in tags) Chip(label: Text(tag))],
              ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 180,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: Theme.of(context).textTheme.headlineSmall),
          Text(label),
        ],
      ),
    );
  }
}

class _ManualTextPanel extends StatelessWidget {
  const _ManualTextPanel({
    required this.titleController,
    required this.participantsController,
    required this.textController,
    required this.onSubmit,
  });

  final TextEditingController titleController;
  final TextEditingController participantsController;
  final TextEditingController textController;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Manual text', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            TextField(
              controller: titleController,
              decoration: const InputDecoration(
                labelText: 'Title',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: participantsController,
              decoration: const InputDecoration(
                labelText: 'Participants',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: textController,
              minLines: 5,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: 'Text',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onSubmit,
              icon: const Icon(Icons.lock),
              label: const Text('Encrypt import'),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecordingPanel extends StatelessWidget {
  const _RecordingPanel({
    required this.recording,
    required this.titleController,
    required this.participantsController,
    required this.segmentController,
    required this.segments,
    required this.onStart,
    required this.onAddSegment,
    required this.onStop,
  });

  final bool recording;
  final TextEditingController titleController;
  final TextEditingController participantsController;
  final TextEditingController segmentController;
  final List<String> segments;
  final VoidCallback onStart;
  final VoidCallback onAddSegment;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Recording session',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: titleController,
              decoration: const InputDecoration(
                labelText: 'Session title',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: participantsController,
              decoration: const InputDecoration(
                labelText: 'Participants',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            if (recording) ...[
              TextField(
                controller: segmentController,
                decoration: const InputDecoration(
                  labelText: 'Spoken segment',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: onAddSegment,
                icon: const Icon(Icons.graphic_eq),
                label: const Text('Add segment'),
              ),
              const SizedBox(height: 8),
              Text('${segments.length} segment(s)'),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: onStop,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('Stop session'),
              ),
            ] else
              FilledButton.icon(
                onPressed: onStart,
                icon: const Icon(Icons.mic),
                label: const Text('Start session'),
              ),
          ],
        ),
      ),
    );
  }
}

class _FilePanel extends StatelessWidget {
  const _FilePanel({
    required this.participantsController,
    required this.onPick,
  });

  final TextEditingController participantsController;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'File or audio',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: participantsController,
              decoration: const InputDecoration(
                labelText: 'Participants',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onPick,
              icon: const Icon(Icons.upload_file),
              label: const Text('Choose file'),
            ),
          ],
        ),
      ),
    );
  }
}
