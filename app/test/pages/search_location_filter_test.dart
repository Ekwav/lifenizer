import 'package:app/models.dart';
import 'package:app/pages/search/search_filters.dart';
import 'package:app/pages/search/search_input_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'compact location picker combines town or venue with existing search and filters',
    (tester) async {
      tester.view.physicalSize = const Size(320, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final model = SearchViewModel(
        queryController: TextEditingController(text: 'exhibition alice'),
        sourceFilter: 'audio',
        participantFilter: 'alice',
        tagFilter: 'Work',
      );
      addTearDown(model.queryController.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => Padding(
                padding: const EdgeInsets.all(20),
                child: SearchFilters(
                  viewModel: model,
                  availableSources: const ['audio'],
                  availableParticipants: const ['alice'],
                  availableTags: const ['Work'],
                  participantName: (_) => 'Alice',
                  availableLocations: [
                    RecordingLocation(
                      town: 'Berlin',
                      venue: 'North Atelier',
                      address: 'Main Street 4',
                    ),
                    RecordingLocation(town: 'Hamburg'),
                  ],
                  onFilterChanged: () => setState(() {}),
                  onClearFilters: () => setState(model.clearFilters),
                  onSaveSearch: () {},
                  isBusy: false,
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('search-location-filter')));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Berlin')).dy,
        lessThan(
          tester.getTopLeft(find.text('Berlin North Atelier Main Street 4')).dy,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('filter-option-Berlin')));
      await tester.pumpAndSettle();
      expect(model.queryController.text, 'exhibition alice town:"Berlin"');
      expect(model.participantFilter, 'alice');
      expect(model.sourceFilter, 'audio');
      expect(model.tagFilter, 'Work');
      await tester.tap(find.byKey(const ValueKey('search-location-filter')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('search-filter-query')),
        'atelier',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const ValueKey('filter-option-Berlin North Atelier Main Street 4'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        model.queryController.text,
        'exhibition alice location:"Berlin North Atelier Main Street 4"',
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(model.queryController.text, isEmpty);
      expect(model.participantFilter, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
