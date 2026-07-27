import 'dart:io';

import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';

/// Thin helpers for interactive `sudo -v` and locating the `sudo` binary.
abstract final class Sudo {
  /// Absolute path to `sudo`, or null if not on PATH.
  static Future<String?> resolve() => _which('sudo');

  /// Prompt once via `sudo -v` (inheritStdio) so later `sudo -n …` calls can
  /// run without holding the TTY open.
  ///
  /// No-op when `sudo` is not available (already root / passwordless path).
  static Future<void> cacheCredentials({String? manualHint}) async {
    final sudo = await resolve();
    if (sudo == null) return;

    logStatus(
      '[sudo] confirming access '
      '(you may be asked for your password once)…',
    );
    final proc = await Process.start(
      sudo,
      const ['-v'],
      mode: ProcessStartMode.inheritStdio,
    );
    final code = await proc.exitCode;
    if (code != 0) {
      final hint = manualHint ?? 'Retry with an interactive sudo session.';
      throw XcrossError('sudo authentication failed (exit $code).\n$hint');
    }
  }

  static Future<String?> _which(String name) async {
    final pathEnv = Platform.environment['PATH'] ?? '';
    for (final dir in pathEnv.split(':')) {
      if (dir.isEmpty) continue;
      final file = File('$dir/$name');
      if (file.existsSync()) return file.path;
    }
    return null;
  }
}
