/// Per-user config location shared by every xcross credential store.
library;

import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// `%APPDATA%/xcross` on Windows, `$XDG_CONFIG_HOME/xcross` (falling back
/// to `~/.config/xcross`) elsewhere.
///
/// Credentials live here and never in the project tree — project files are
/// commonly committed to git, which is the wrong place for secret material.
@useResult
String xcrossConfigDir() => p.join(_baseConfigDir(), 'xcross');

String _baseConfigDir() {
  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'];
    if (appData != null && appData.isNotEmpty) return appData;
  }
  final xdg = Platform.environment['XDG_CONFIG_HOME'];
  if (xdg != null && xdg.isNotEmpty) return xdg;
  final home =
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '.';
  return p.join(home, '.config');
}
