import 'dart:convert';
import 'dart:js_interop';

import 'app_state.dart';

@JS('window')
external JSObject get _window;

extension type _E2EWindow(JSObject _) implements JSObject {
  external set lifenizerE2eLogin(JSFunction value);
  external set lifenizerE2eImportText(JSFunction value);
  external set lifenizerE2eImportBackend(JSFunction value);
  external set lifenizerE2eRecording(JSFunction value);
  external set lifenizerE2eExtractRelations(JSFunction value);
  external set lifenizerE2eSaveSearch(JSFunction value);
  external set lifenizerE2ePull(JSFunction value);
  external set lifenizerE2eSnapshot(JSFunction value);
}

void installE2eBridge(LifenizerAppState state) {
  final window = _E2EWindow(_window);

  window.lifenizerE2eLogin = ((JSString email, JSString apiUrl) {
    state.login(
      baseUrl: apiUrl.toDart,
      email: email.toDart,
      passphrase: 'correct horse battery staple',
    );
  }).toJS;

  window.lifenizerE2eImportText = (() {
    state.addManualText(
      title: 'Coffee with Person X',
      participantNames: 'Person X, Person Y',
      text: "Person X is Person Y's brother. Person X works with Person Z.",
    );
  }).toJS;

  window.lifenizerE2eImportBackend = (() {
    state.importSample('whatsapp');
  }).toJS;

  window.lifenizerE2eRecording = (() {
    state.addRecordingConversation(
      title: 'Browser recording session',
      participantNames: 'Person X, Person Y',
      segmentTexts: [
        'Person Y mentioned a paper invoice.',
        'Person X replied with the Paperless import plan.',
      ],
    );
  }).toJS;

  window.lifenizerE2eExtractRelations = (() {
    if (state.conversations.isNotEmpty) {
      state.extractRelations(state.conversations.first);
    }
  }).toJS;

  window.lifenizerE2eSaveSearch = (() {
    state.addSavedSearch(
      title: 'Person X WhatsApp',
      query: 'Person X',
      source: 'whatsapp',
      tag: 'whatsapp',
    );
  }).toJS;

  window.lifenizerE2ePull = (() {
    state.pullSync();
  }).toJS;

  window.lifenizerE2eSnapshot = (() {
    return jsonEncode({
      'authenticated': state.isAuthenticated,
      'cursor': state.syncCursor,
      'participants': state.participants
          .map((participant) => participant.toJson())
          .toList(),
      'conversations': state.conversations
          .map((conversation) => conversation.toJson())
          .toList(),
      'relations': state.relations
          .map((relation) => relation.toJson())
          .toList(),
      'savedSearches': state.savedSearches
          .map((savedSearch) => savedSearch.toJson())
          .toList(),
      'tags': state.allTags,
      'insights': {
        'totalConversations': state.insights.totalConversations,
        'totalSegments': state.insights.totalSegments,
        'sources': state.insights.sourceFacets
            .map((facet) => {'source': facet.source, 'count': facet.count})
            .toList(),
        'participants': state.insights.participantFacets
            .map(
              (facet) => {
                'displayName': facet.participant.displayName,
                'count': facet.count,
              },
            )
            .toList(),
      },
      'imports': state.importCapabilities
          .map((capability) => capability.source)
          .toList(),
      'status': state.status,
      'error': state.error,
    }).toJS;
  }).toJS;
}
