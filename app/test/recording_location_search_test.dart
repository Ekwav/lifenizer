import 'dart:convert';
import 'package:app/crypto_service.dart';
import 'package:app/models.dart';
import 'package:app/services/conversation_search_index.dart';
import 'package:app/services/search_criteria.dart';
import 'package:app/services/search_scorer.dart';
import 'package:app/services/search_service.dart';
import 'package:flutter_test/flutter_test.dart';

Conversation conversation(
  String id, {
  RecordingLocation? location,
  String person = 'alice',
}) => Conversation(
  id: id,
  title: 'Recording',
  source: 'audio',
  participantIds: [person],
  location: location,
  segments: [ConversationSegment(id: id, text: 'Planning the exhibition')],
  startedAt: DateTime.utc(2026),
  endedAt: DateTime.utc(2026),
);
List<String> search(
  ConversationSearchIndex index,
  String query, {
  String? person,
  String? location,
}) {
  final criteria = SearchCriteria(
    query: query,
    participantId: person,
    location: location,
  );
  final tokens = ConversationSearchIndex.tokenize(criteria.normalized);
  return SearchService(index)
      .rankConversations(
        criteria,
        SearchScorer(
          temporalIntent: null,
          normalizedQuery: criteria.normalized,
          now: DateTime.utc(2026),
        ),
        tokens,
        tokens.join(' '),
      )
      .map((conversation) => conversation.id)
      .toList();
}

ConversationSearchIndex build(List<Conversation> items) =>
    ConversationSearchIndex.build(
      conversations: items,
      participantById: const {'alice': 'Alice', 'bob': 'Bob'},
      relationTextByConversation: const {},
    );
void main() {
  test('location validates coordinate pairs and preserves legacy JSON', () {
    final location = RecordingLocation(
      town: ' Berlin ',
      venue: ' Atelier ',
      address: ' Main Street 4 ',
      latitude: 52.5,
      longitude: 13.4,
    );
    expect(location.town, 'Berlin');
    expect(location.searchableText, 'Berlin Atelier Main Street 4');
    expect(location.displayName, 'Berlin · Atelier · Main Street 4');
    for (final coordinates in [
      (double.nan, 12.0),
      (91.0, 12.0),
      (23.0, double.infinity),
      (23.0, -181.0),
    ]) {
      final invalid = RecordingLocation(
        latitude: coordinates.$1,
        longitude: coordinates.$2,
      );
      expect(invalid.latitude, isNull);
      expect(invalid.longitude, isNull);
      expect(jsonEncode(invalid.toJson()), '{}');
    }
    expect(RecordingLocation(latitude: 52).latitude, isNull);
    expect(
      RecordingLocation.fromJson({
        'latitude': 'invalid',
        'longitude': 13,
      }).latitude,
      isNull,
    );
    final legacy = conversation('old').toJson();
    expect(legacy, isNot(contains('location')));
    expect(Conversation.fromJson(legacy).location, isNull);
    expect(
      Conversation.fromSummaryJson(
        conversation('old').toSummaryJson(),
      ).location,
      isNull,
    );
  });
  test(
    'encrypted full, summary and JSON backup round trips retain location',
    () async {
      final original = conversation(
        'private',
        location: RecordingLocation(
          town: 'Berlin',
          venue: 'Atelier',
          address: 'Main Street 4',
          latitude: 52.5,
          longitude: 13.4,
        ),
      );
      final crypto = VaultCrypto()
        ..unlockDeviceKey(List.generate(32, (i) => i));
      addTearDown(crypto.lock);
      final payload = await crypto.encryptJson(original.toJson());
      expect(payload.cipherText, isNot(contains('Berlin')));
      final restored = Conversation.fromJson(
        await crypto.decryptJson(
          cipherText: payload.cipherText,
          nonce: payload.nonce,
        ),
      );
      final summary = Conversation.fromSummaryJson(
        jsonDecode(jsonEncode(original.toSummaryJson()))
            as Map<String, dynamic>,
      );
      final backup = Conversation.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );
      for (final item in [restored, summary, backup]) {
        expect(item.location!.toJson(), original.location!.toJson());
      }
      expect(summary.isLoaded, isFalse);
    },
  );
  test(
    'town and venue searches combine with participant and explicit location filters',
    () {
      final index = build([
        conversation(
          'berlin-alice',
          location: RecordingLocation(
            town: 'Berlin',
            venue: 'North Atelier',
            address: 'Main Street 4',
          ),
        ),
        conversation(
          'berlin-bob',
          person: 'bob',
          location: RecordingLocation(town: 'Berlin', venue: 'North Atelier'),
        ),
        conversation(
          'hamburg',
          location: RecordingLocation(town: 'Hamburg', venue: 'North Atelier'),
        ),
        conversation('missing'),
      ]);
      expect(search(index, 'berlin atelier alice'), ['berlin-alice']);
      expect(search(index, 'town:Berlin atelier alice'), ['berlin-alice']);
      expect(
        search(
          index,
          'location:"North Atelier" alice',
          location: 'Main Street',
        ),
        ['berlin-alice'],
      );
      expect(search(index, 'town:Berlin', person: 'bob'), ['berlin-bob']);
      expect(search(index, 'town:Hamburg'), ['hamburg']);
      expect(search(index, '', location: 'Main Street 4'), ['berlin-alice']);
      expect(search(index, 'town:"New York"'), isEmpty);
      expect(
        SearchCriteria(query: 'town:"New York').normalized,
        'town:"new york',
      );
    },
  );
  test('prepared catalog retains location filtering and ranking', () {
    final original = build([
      conversation('town', location: RecordingLocation(town: 'Berlin')),
      conversation('venue', location: RecordingLocation(venue: 'Berlin')),
    ]);
    final full = ConversationSearchIndex.fromJson(
      jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
    );
    final catalogJson = original.toJson(includeDetails: false);
    expect(catalogJson['version'], 2);
    final catalog = ConversationSearchIndex.fromJson(
      jsonDecode(jsonEncode(catalogJson)) as Map<String, dynamic>,
    );
    for (final index in [original, full, catalog]) {
      expect(search(index, 'berlin').first, 'town');
      expect(search(index, 'town:Berlin'), ['town']);
      expect(search(index, 'location:Berlin'), containsAll(['town', 'venue']));
    }
    expect(catalog.documents['town']!.detailsLoaded, isFalse);
    expect(catalog.documents['town']!.conversation.isLoaded, isFalse);
    expect(catalog.documents['town']!.conversation.location!.town, 'Berlin');
  });
}
