import 'dart:io';

bool get isKdeDesktop {
  final environment = Platform.environment;
  final desktop =
      environment['XDG_CURRENT_DESKTOP'] ??
      environment['XDG_SESSION_DESKTOP'] ??
      environment['DESKTOP_SESSION'] ??
      '';
  return desktop
      .toLowerCase()
      .split(':')
      .any(
        (name) => const [
          'kde',
          'plasma',
          'plasmax11',
          'plasmawayland',
        ].contains(name.trim()),
      );
}
