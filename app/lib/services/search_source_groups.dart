import 'source_categories.dart';

enum SearchSourceGroup { consumed, documents, email, chat, other }

SearchSourceGroup groupForSource(String source) {
  switch (categoryForSource(source)) {
    case SourceCategory.consumed:
      return SearchSourceGroup.consumed;
    case SourceCategory.documents:
      return SearchSourceGroup.documents;
    case SourceCategory.personal:
      break;
  }
  return switch (source.trim().toLowerCase()) {
    'email' || 'imap' || 'mbox' => SearchSourceGroup.email,
    'discord' ||
    'slack' ||
    'teams' ||
    'whatsapp' ||
    'telegram' ||
    'signal' ||
    'facebook-messenger' ||
    'instagram' ||
    'imessage' ||
    'sms' => SearchSourceGroup.chat,
    _ => SearchSourceGroup.other,
  };
}

String sourceGroupFilter(SearchSourceGroup group) => 'group:${group.name}';

SearchSourceGroup? groupFromSourceFilter(String? filter) {
  for (final group in SearchSourceGroup.values) {
    if (filter == sourceGroupFilter(group)) return group;
  }
  return null;
}

String sourceFilterLabel(String source) =>
    switch (groupFromSourceFilter(source)) {
      SearchSourceGroup.consumed => 'Consumed media',
      SearchSourceGroup.documents => 'Scans and documents',
      SearchSourceGroup.email => 'Email',
      SearchSourceGroup.chat => 'Chats',
      SearchSourceGroup.other => 'Other sources',
      null => source,
    };

bool matchesSourceFilter(String? filter, String actualSource) {
  if (filter == null) return true;
  final group = groupFromSourceFilter(filter);
  return group == null
      ? filter == actualSource
      : groupForSource(actualSource) == group;
}
