import 'package:url_launcher/url_launcher.dart';

import '../models.dart';

Uri? externalLinkUri(String? value) {
  final uri = value == null ? null : Uri.tryParse(value);
  return uri != null &&
          ['http', 'https'].contains(uri.scheme) &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty
      ? uri
      : null;
}

/// Discord uses the channel ID, not the recipient's user ID, in DM links.
String? discordMessageUrl(
  Conversation conversation,
  ConversationSegment segment,
) {
  final uri = externalLinkUri(conversation.sourceUrl);
  final messageId = segment.sourceMessageId;
  if (conversation.source != 'discord' ||
      uri == null ||
      uri.host != 'discord.com' ||
      uri.pathSegments.length != 3 ||
      uri.pathSegments.first != 'channels' ||
      !RegExp(r'^(?:@me|\d+)$').hasMatch(uri.pathSegments[1]) ||
      !RegExp(r'^\d+$').hasMatch(uri.pathSegments[2]) ||
      messageId == null ||
      !RegExp(r'^discord:\d+$').hasMatch(messageId)) {
    return null;
  }
  return uri
      .replace(
        path: '${uri.path}/${messageId.substring(8)}',
        query: null,
        fragment: null,
      )
      .toString();
}

Future<bool> openExternalLink(String value) async {
  final uri = externalLinkUri(value);
  if (uri == null) return false;
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}
