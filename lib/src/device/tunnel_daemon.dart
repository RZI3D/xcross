import 'dart:async';
import 'dart:io';

import 'package:xcross/src/device/pymd.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';

/// Manages the `pymobiledevice3 remote tunneld` daemon lifecycle.
///
/// * If tunneld REST API is already reachable → reuse it (no ownership taken).
/// * Otherwise → start `[sudo] pymobiledevice3 remote tunneld` as background
///   child, wait up to 40 s for it to come up.
/// * [stop] tears down only a daemon we started ourselves.
///
/// TunnelDaemon.swift:23
class TunnelDaemon {
  TunnelDaemon({
    this.host = '127.0.0.1',
    this.port = 49151,
  });

  final String host;
  final int port;

  Process? _process;
  bool _ownsDaemon = false;

  bool get isOwner => _ownsDaemon;

  /// Ensure a tunneld REST API is reachable; start one if needed.
  /// TunnelDaemon.swift:64
  Future<void> ensureRunning() async {
    if (await _isReachable()) {
      logStatus('[xtool] RSD tunnel daemon already running (reusing it)');
      return;
    }

    // Need to start it ourselves — requires root. TunnelDaemon.swift:71
    final inv = await Pymd.resolve();
    final sudo = await _which('sudo');
    final usbmux = Pymd.resolvedUsbmuxAddress();

    // Cache sudo credentials interactively first, then start the long-lived
    // daemon with piped stdio (never inheritStdio — that steals `r`/`R`/`q`
    // from the hot-reload keypress loop for the whole session).
    if (sudo != null) {
      await _cacheSudoCredentials(sudo);
    }

    // Build: [sudo -n] [env USBMUXD_SOCKET_ADDRESS=…] <exe> … remote tunneld
    // sudo strips the env by default; without the unix socket path,
    // Linux pymobiledevice3 targets 127.0.0.1:27015 and fails under usbipd.
    // `-n` is safe here because `_cacheSudoCredentials` just refreshed the
    // timestamp (or we are already root / passwordless).
    final argv = <String>[
      if (sudo != null) ...[sudo, '-n'],
      if (sudo != null && usbmux != null) ...[
        'env',
        'USBMUXD_SOCKET_ADDRESS=$usbmux',
      ],
      inv.executable,
      ...inv.prefixArgs,
      'remote',
      'tunneld',
    ];

    logStatus(
      '[pymobiledevice3] starting RSD tunnel daemon'
      '${sudo != null ? ' (needs root)' : ''}:\n'
      '    ${argv.join(' ')}',
    );

    // Log daemon output to \$TMPDIR/xtool-tunneld.log. TunnelDaemon.swift:90
    final tmpDir = Platform.environment['TMPDIR'] ?? '/tmp';
    final logPath = '$tmpDir/xtool-tunneld.log';
    final logFile = File(logPath);
    if (!logFile.existsSync()) logFile.createSync(recursive: true);

    late Process proc;
    try {
      proc = await Process.start(
        argv[0],
        argv.sublist(1),
        environment: Pymd.usbmuxEnvironment(),
      );
    } catch (e) {
      throw XcrossError('could not start tunneld: $e');
    }

    // Detach from our TTY completely — daemon must not consume keypresses.
    try {
      await proc.stdin.close();
    } catch (_) {}
    final logSink = logFile.openWrite(mode: FileMode.append);
    proc.stdout.listen(logSink.add, onError: (_) {});
    proc.stderr.listen(logSink.add, onError: (_) {});
    unawaited(proc.exitCode.then((_) async {
      try {
        await logSink.flush();
        await logSink.close();
      } catch (_) {}
    }));

    _process = proc;
    _ownsDaemon = true;

    // Wait up to 40 s for the REST API to come up. TunnelDaemon.swift:106
    final deadline = DateTime.now().add(const Duration(seconds: 40));
    while (DateTime.now().isBefore(deadline)) {
      if (await _isReachable()) {
        logStatus('[pymobiledevice3] RSD tunnel daemon is up');
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    throw XcrossError(
      'tunneld did not come up. Try starting it manually in another terminal:\n'
      '    sudo pymobiledevice3 remote tunneld\n'
      'See $logPath for daemon output.',
    );
  }

  /// Prompt once via `sudo -v` (inheritStdio) so the subsequent non-interactive
  /// `sudo -n … tunneld` can start without holding the TTY open.
  static Future<void> _cacheSudoCredentials(String sudo) async {
    logStatus(
      '[pymobiledevice3] confirming sudo access '
      '(you may be asked for your password once)…',
    );
    final proc = await Process.start(
      sudo,
      const ['-v'],
      mode: ProcessStartMode.inheritStdio,
    );
    final code = await proc.exitCode;
    if (code != 0) {
      throw XcrossError(
        'sudo authentication failed (exit $code). Start tunneld manually:\n'
        '    sudo pymobiledevice3 remote tunneld',
      );
    }
  }

  /// Tear down only the daemon WE started. Safe to call multiple times.
  /// TunnelDaemon.swift:122
  void stop() {
    if (!_ownsDaemon) return;
    final proc = _process;
    _process = null;
    _ownsDaemon = false;
    if (proc == null) return;

    logStatus('[xtool] stopping RSD tunnel daemon…');

    // The daemon runs under sudo (root); escalate via sudo kill. TunnelDaemon.swift:135
    _which('sudo').then((sudo) {
      if (sudo != null) {
        Process.run(sudo, ['kill', '-TERM', '${proc.pid}']);
      } else {
        proc.kill();
      }
    });
    // Best-effort direct signal.
    proc.kill();
  }

  // TunnelDaemon.swift:154
  Future<bool> _isReachable() async {
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 3);
      try {
        final req = await client.getUrl(Uri.parse('http://$host:$port/'));
        final resp = await req.close();
        await resp.drain<void>();
        return resp.statusCode >= 200 && resp.statusCode < 300;
      } finally {
        client.close();
      }
    } catch (_) {
      return false;
    }
  }

  static Future<String?> _which(String name) async {
    final pathEnv = Platform.environment['PATH'] ?? '';
    for (final dir in pathEnv.split(':')) {
      if (dir.isEmpty) continue;
      final f = File('$dir/$name');
      final fExists = f.existsSync();
      if (fExists) return f.path;
    }
    return null;
  }
}
