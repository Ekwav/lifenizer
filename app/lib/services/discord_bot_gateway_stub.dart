class DiscordBotGateway {
  DiscordBotGateway({
    required String token,
    required void Function(String, Map<String, dynamic>) onEvent,
    required void Function(String) onStatus,
  });
  Future<void> start() async =>
      throw UnsupportedError('Discord live import requires the native app.');
  Future<void> close() async {}
}
