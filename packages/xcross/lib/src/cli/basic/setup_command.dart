import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:pure/pure.dart';
import 'package:xcross/src/errors.dart';

/// `apt`-installable packages from the README Requirements table, plus the
/// Swift toolchain's own build dependencies. Swift and Flutter stay manual.
const _aptPackages = [
  'clang',
  'lld',
  'llvm',
  'python3',
  'python3-pip',
  'python3-venv',
  'usbmuxd',
  'usbutils',
  'libimobiledevice-utils',
  'linux-tools-common',
  'pkg-config',
  'zlib1g-dev',
  'libpython3-dev',
  'libstdc++-13-dev',
  'libxml2-dev',
  'libncurses-dev',
  'libz3-dev',
  'gnupg2',
  'libc6-dev',
  'libcurl4-openssl-dev',
  'libgcc-13-dev',
];

const _requiredTools = ['swift', 'clang', 'clang++', 'llvm-ar', 'ld64.lld'];

/// `xcross setup` — `sudo apt install` every apt-installable Requirement.
final class SetupCommand extends Command<void> {
  @override
  String get name => 'setup';

  @override
  String get description => 'Install or verify host requirements';

  @override
  Future<void> run() => Platform.isWindows ? _setupWindows() : _setupAptLinux();

  Future<void> _setupAptLinux() async {
    if (await ProcessRunner.which('apt-get') == null) {
      throw XcrossError(
        'apt-get not found; xcross setup only supports apt-based distros. '
        'Install manually:\n    sudo apt install ${_aptPackages.join(' ')}',
      );
    }

    await Sudo.cacheCredentials(
      manualHint:
          'Install manually:\n'
          '    sudo apt install ${_aptPackages.join(' ')}',
    );
    await _aptInstall();
    await _linkVersionedLd64Lld();

    final missing = await _missingTools(_requiredTools);
    if (missing.isNotEmpty) {
      throw XcrossError(
        'Missing Linux requirements on PATH after apt install: '
        '${missing.join(', ')}.\n'
        'Install the Swift toolchain manually and ensure its bin directory is '
        'on PATH. The lld package must provide ld64.lld.',
      );
    }

    final pipx = await _ensurePipx();
    await _ensurePymd();
    await _pipxEnsurePath(pipx);
    Log.logDone('Requirements installed');
  }

  Future<void> _setupWindows() async {
    final missing = await _missingTools(['flutter', ..._requiredTools]);
    if (missing.isNotEmpty) {
      throw XcrossError(
        'Missing Windows requirements on PATH: ${missing.join(', ')}.\n'
        'Install Flutter, Swift, and the official LLVM Windows toolchain, '
        'then retry.',
      );
    }
    await _ensurePymd();
    Log.logDone('Windows requirements found');
  }

  /// Spinner with a streamed tail (not inheritStdio): apt's own progress shows
  /// collapsed under the spinner. `sudo -v` already cached the credential, so
  /// this runs without a password prompt.
  Future<void> _aptInstall() async {
    final step = Log.beginStep('Installing apt requirements');
    try {
      await ProcessRunner.runChecked(
        'sudo',
        ['apt-get', 'install', '-y', ..._aptPackages],
        label: 'apt-get install',
        tail: step,
      );
      step.done();
    } on Object {
      step.fail();
      rethrow;
    }
  }

  /// Some distros only ship `ld64.lld-<version>`; point a stable name at the
  /// newest one so the toolchain lookup finds it.
  Future<void> _linkVersionedLd64Lld() async {
    if (await _locate('ld64.lld') != null) return;

    final versioned =
        Directory('/usr/bin')
            .listSync()
            .where(
              (entry) =>
                  (entry is File || entry is Link) &&
                  p.basename(entry.path).startsWith('ld64.lld-'),
            )
            .toList()
          ..sort(compare((entry) => entry.path));
    if (versioned.isEmpty) return;

    await ProcessRunner.runChecked('sudo', [
      'ln',
      '-sf',
      versioned.last.path,
      '/usr/local/bin/ld64.lld',
    ], label: 'link ld64.lld');
  }

  /// pipx is the only pip route left on PEP 668 distros, and it keeps
  /// pymobiledevice3 in its own venv. Prefer the distro package; fall back to
  /// a `--user` pip install when the distro is too old to ship one.
  static Future<String> _ensurePipx() async {
    final existing = await Pymd.resolvePipx();
    if (existing != null) return existing;

    final step = Log.beginStep('Installing pipx');
    for (final attempt in await _pipxInstallAttempts()) {
      Log.logTrace('[pipx] running: ${attempt.join(' ')}');
      final result = await ProcessRunner.run(attempt.first, attempt.sublist(1));
      if (result.exitCode != 0) continue;
      final pipx = await Pymd.resolvePipx();
      if (pipx != null) {
        step.done();
        return pipx;
      }
    }

    step.fail();
    throw XcrossError(
      'Could not install pipx. Install it manually:\n'
      '    sudo apt install pipx',
    );
  }

  static Future<List<List<String>>> _pipxInstallAttempts() async {
    final sudo = await Sudo.resolve();
    final py = await ProcessRunner.which('python3') ?? 'python3';
    return <List<String>>[
      if (sudo != null) [sudo, 'apt-get', 'install', '-y', 'pipx'],
      [py, '-m', 'pip', 'install', '--user', '--break-system-packages', 'pipx'],
      [py, '-m', 'pip', 'install', '--user', 'pipx'],
    ];
  }

  /// Appends pipx's bin directory to the shell profile so the freshly linked
  /// `pymobiledevice3` resolves in new shells. Never fatal: xcross itself
  /// looks in that directory regardless.
  static Future<void> _pipxEnsurePath(String pipx) async {
    try {
      await ProcessRunner.runChecked(
        pipx,
        ['ensurepath'],
        label: 'pipx ensurepath',
      );
    } on Object catch (error) {
      Log.logWarn('pipx ensurepath failed, add ~/.local/bin to PATH: $error');
    }
  }

  static Future<void> _ensurePymd() async {
    if (!await Pymd.ensureInstalled()) {
      throw XcrossError('pymobiledevice3 install failed; see above.');
    }
  }

  static Future<List<String>> _missingTools(List<String> tools) async {
    final missing = <String>[];
    for (final tool in tools) {
      if (await _locate(tool) == null) missing.add(tool);
    }
    return missing;
  }

  /// PATH lookup that refuses swiftly's `ld64.lld` shim — see
  /// [DarwinSdk.resolveLd64Lld] for why that one cannot link iOS.
  static Future<String?> _locate(String tool) => ProcessRunner.which(
    tool,
    accept: tool == 'ld64.lld' ? DarwinSdk.usableLd64Lld : null,
  );
}
