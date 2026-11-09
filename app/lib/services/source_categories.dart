/// Coarse grouping of import sources used to rank search results.
///
/// Things the user wrote or said (chats, mail, recordings) outrank things they
/// merely consumed (watched videos, browsing) so a strong lexical match in a
/// watched video does not bury a personal conversation.
enum SourceCategory {
  personal,
  consumed,
  documents;

  /// Human label for badges; personal items carry no badge.
  String? get displayLabel => switch (this) {
    SourceCategory.personal => null,
    SourceCategory.consumed => 'Consumed',
    SourceCategory.documents => 'Documents',
  };
}

/// Ranking weight of [SourceCategory.personal] (the baseline).
const double personalCategoryWeight = 1.0;

/// Ranking weight of [SourceCategory.consumed] media.
const double consumedCategoryWeight = 0.6;

/// Ranking weight of [SourceCategory.documents].
const double documentsCategoryWeight = 0.9;

const Set<String> _consumedSources = {
  'youtube-watch-history',
  'tiktok-watch-history',
  'youtube-transcript',
  'browser-history',
  'google-search-history',
  'bookmarks',
  'browser-capture',
};

const Set<String> _documentSources = {'scanned-pdf', 'paperless', 'photo'};

SourceCategory categoryForSource(String source) {
  final normalized = source.trim().toLowerCase();
  if (_consumedSources.contains(normalized)) return SourceCategory.consumed;
  if (_documentSources.contains(normalized)) return SourceCategory.documents;
  return SourceCategory.personal;
}

double categoryWeight(SourceCategory category) => switch (category) {
  SourceCategory.personal => personalCategoryWeight,
  SourceCategory.consumed => consumedCategoryWeight,
  SourceCategory.documents => documentsCategoryWeight,
};

/// Weight applied to the final score of a conversation from [source].
double weightForSource(String source) =>
    categoryWeight(categoryForSource(source));
