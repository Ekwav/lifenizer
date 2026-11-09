import 'package:app/pages/search/search_filters.dart';
import 'package:app/pages/search/search_input_field.dart';
import 'package:app/services/search_source_groups.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'source picker offers present groups before unchanged raw sources',
    (tester) async {
      final model = SearchViewModel(
        queryController: TextEditingController(),
        sourceFilter: '',
        participantFilter: 'alice',
        tagFilter: 'Work',
      );
      addTearDown(model.queryController.dispose);
      const sources = [
        'youtube-transcript',
        'scanned-pdf',
        'email',
        'imap',
        'discord',
        'slack',
        'manual-text',
      ];
      var changes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => SearchFilters(
                viewModel: model,
                availableSources: sources,
                availableParticipants: const ['alice'],
                availableTags: const ['Work'],
                participantName: (_) => 'Alice',
                onFilterChanged: () => setState(() => changes++),
                onClearFilters: model.clearFilters,
                onSaveSearch: () {},
                isBusy: false,
              ),
            ),
          ),
        ),
      );
      final picker = tester.widget<DropdownButton<String>>(
        find.byType(DropdownButton<String>),
      );
      expect(picker.items!.map((item) => item.value), [
        '',
        for (final group in SearchSourceGroup.values) sourceGroupFilter(group),
        ...sources,
      ]);
      expect(picker.items!.map((item) => (item.child as Text).data), [
        'All',
        'Consumed media',
        'Scans and documents',
        'Email',
        'Chats',
        'Other sources',
        ...sources,
      ]);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chats').last);
      await tester.pumpAndSettle();
      expect(model.sourceFilter, 'group:chat');
      expect(
        sources.where(
          (source) => matchesSourceFilter(model.sourceFilter, source),
        ),
        ['discord', 'slack'],
      );
      expect(model.participantFilter, 'alice');
      expect(model.tagFilter, 'Work');
      expect(changes, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('source picker excludes absent groups', (tester) async {
    final model = SearchViewModel(
      queryController: TextEditingController(),
      sourceFilter: '',
      participantFilter: '',
      tagFilter: '',
    );
    addTearDown(model.queryController.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchFilters(
            viewModel: model,
            availableSources: const ['discord'],
            availableParticipants: const [],
            availableTags: const [],
            participantName: (id) => id,
            onFilterChanged: () {},
            onClearFilters: model.clearFilters,
            onSaveSearch: () {},
            isBusy: false,
          ),
        ),
      ),
    );
    final picker = tester.widget<DropdownButton<String>>(
      find.byType(DropdownButton<String>),
    );
    expect(picker.items!.map((item) => item.value), [
      '',
      'group:chat',
      'discord',
    ]);
  });
}
