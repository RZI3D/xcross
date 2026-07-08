import 'package:args/command_runner.dart';
import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:xcross/src/cli/flutter/flutter_operations.dart';
import 'package:xcross/src/device/core_device_launcher.dart';
import 'package:xcross/src/device/debug_launcher.dart';
import 'package:xcross/src/device/os_version.dart';
import 'package:xcross/src/models/cli/pack_result.dart';
import 'package:xcross/src/models/device/device.dart';
import 'package:xcross/src/util/logging.dart';
import 'package:xcross/src/xtool/xtool_cli.dart';

part 'flutter_run_args.g.dart';

enum DeviceConnection { attached, wireless, both }

@CliOptions(createCommand: true)
class FlutterRunArgs {
  const FlutterRunArgs({
    this.target = 'lib/main.dart',
    this.flavor,
    this.dartDefine = const [],
    this.dartDefineFromFile = const [],
    this.pub = true,
    this.deviceId,
    this.udid,
    this.usb = false,
    this.wifi = false,
    this.deviceConnection = DeviceConnection.both,
    this.route,
    this.dartEntrypointArgs = const [],
    this.verbose = false,
  });

  @CliOption(
    abbr: 't',
    defaultsTo: 'lib/main.dart',
    help: 'The main entry-point file of the application.',
  )
  final String target;

  @CliOption(help: 'Build a custom app flavor (sets FLUTTER_APP_FLAVOR).')
  final String? flavor;

  @CliOption(
    abbr: 'D',
    name: 'dart-define',
    help: 'Pass a KEY=VALUE define to the Dart compiler.',
  )
  final List<String> dartDefine;

  @CliOption(
    name: 'dart-define-from-file',
    help: 'Load dart-defines from a .json or .env file.',
  )
  final List<String> dartDefineFromFile;

  @CliOption(
    defaultsTo: true,
    help: 'Run "flutter pub get" before building.',
  )
  final bool pub;

  @CliOption(
    abbr: 'd',
    name: 'device-id',
    help: 'Target device id or name (flutter-style).',
  )
  final String? deviceId;

  @CliOption(
    abbr: 'u',
    help: 'Target device UDID (xtool-style).',
  )
  final String? udid;

  @CliOption(
    negatable: false,
    help: 'Search USB devices only.',
  )
  final bool usb;

  @CliOption(
    negatable: false,
    help: 'Search Wi-Fi devices only.',
  )
  final bool wifi;

  @CliOption(
    name: 'device-connection',
    defaultsTo: DeviceConnection.both,
    help: 'Discovery: attached (USB), wireless (Wi-Fi), or both.',
  )
  final DeviceConnection deviceConnection;

  @CliOption(help: 'Initial route the app navigates to on launch.')
  final String? route;

  @CliOption(
    abbr: 'a',
    name: 'dart-entrypoint-args',
    help: 'Pass arguments to the app main() (repeatable).',
  )
  final List<String> dartEntrypointArgs;

  @CliOption(
    abbr: 'v',
    negatable: false,
    help: 'Verbose output.',
  )
  final bool verbose;
}

/// `xcross flutter run` — build, sign+install (via xtool), launch, and (for
/// iOS 17+ debug builds) hot-reload a Flutter app on a connected device.
///
/// Always builds a debug (JIT) app and always launches with hot reload (the
/// flutter default). Accepts a mix of the original xtool flags (`-u/--udid`,
/// `--usb/--wifi`) and the official `flutter run` flags (`-t/--target`,
/// `-d/--device-id`, `-D/--dart-define`, `--dart-define-from-file`,
/// `--[no-]pub`, `--route`, `-a/--dart-entrypoint-args`, `--device-connection`,
/// `--flavor`).
class FlutterRunCommand extends _$FlutterRunArgsCommand<void> {
  @override
  String get name => 'run';

  @override
  String get description =>
      'Build, install, and run a Flutter iOS app on a device.';

  String? get deviceSelector => _options.udid ?? _options.deviceId;

  DeviceSearchMode get searchMode {
    if (_options.usb) return DeviceSearchMode.usb;
    if (_options.wifi) return DeviceSearchMode.wifi;
    return switch (_options.deviceConnection) {
      DeviceConnection.attached => DeviceSearchMode.usb,
      DeviceConnection.wireless => DeviceSearchMode.wifi,
      DeviceConnection.both => DeviceSearchMode.all,
    };
  }

  /// App-level arguments passed to the launched binary (`--route`, then any
  /// `--dart-entrypoint-args`).
  List<String> get appArguments {
    final args = <String>[];
    final route = _options.route;
    if (route != null) args.add('--route=$route');
    args.addAll(_options.dartEntrypointArgs);
    return args;
  }

  @override
  Future<void> run() async {
    if (_options.verbose) setVerbose();
    // 1. Build the Flutter iOS debug .app (JIT; always debug for hot reload).
    final options = await resolveBuildOptions(
      target: _options.target,
      dartDefine: _options.dartDefine,
      dartDefineFromFile: _options.dartDefineFromFile,
      pub: _options.pub,
      flavor: _options.flavor,
    );
    final pack = await flutterPack(options: options);

    // 2. Resolve target device + sign/install via the original xtool.
    final xtool = XtoolCli();
    final device =
        await xtool.resolveDevice(selector: deviceSelector, mode: searchMode);
    logStatus(
        '[xtool] installing to device: ${device.name} (udid: ${device.udid})');

    // iOS 17+ removed the classic lockdown debugserver: launch (and process
    // control) go through the CoreDevice/RSD tunnel. Determine this up front so
    // we can close a still-running instance before installing.
    final osMajor = await deviceOSMajorVersion(device.udid);
    final useCoreDevice = osMajor != null && osMajor >= 17;

    // Close the app if it happens to be running at install time, so the install
    // and relaunch don't collide with a live instance.
    if (useCoreDevice) {
      await CoreDeviceLauncher.terminateIfRunning(
          udid: device.udid, bundleId: pack.bundleId);
    }

    await xtool.install(pack.appPath, udid: device.udid, mode: searchMode);

    // Flutter debug runs the Dart VM in JIT mode, which only works while a
    // debugger is attached (CS_DEBUGGED). run is always debug → stay attached.
    const keepAttached = true;

    // 3a. iOS 17+: CoreDevice/RSD tunnel — supports hot reload.
    if (useCoreDevice) {
      await _launchCoreDevice(
        pack: pack,
        device: device,
        keepAttached: keepAttached,
        target: _options.target,
        dartDefines: options.dartDefines,
      );
      return;
    }

    // 3b. Pre-iOS-17: classic debugserver path (delegates to `xtool launch`).
    logStatus('[xtool] launching ${pack.bundleId} (debug/JIT)...');
    await DebugLauncher.launch(
      udid: device.udid,
      bundleId: pack.bundleId,
      keepAttached: keepAttached,
      xtool: xtool,
    );
  }

  /// Launch on iOS 17+ via CoreDevice/RSD, with hot reload when available.
  ///
  /// [xtool] is intentionally absent here — CoreDevice launch goes through
  /// [CoreDeviceLauncher] directly; xtool is only needed for the pre-17 path.
  Future<void> _launchCoreDevice({
    required PackResult pack,
    required Device device,
    required bool keepAttached,
    required String target,
    required List<String> dartDefines,
  }) async {
    // Always hot reload (flutter default). Degrades to attach-only if a
    // frontend_server artifact is missing.
    final hotReload = await buildHotReloadConfig(
      target: target,
      dartDefines: dartDefines,
      verbose: _options.verbose,
    );

    final hint = hotReload != null
        ? " (debug/JIT — hot reload enabled; press 'r' to reload)"
        : ' (debug/JIT — staying attached via CoreDevice)';
    logStatus('[xcross] launching ${pack.bundleId}$hint...');

    await CoreDeviceLauncher.launch(
      udid: device.udid,
      bundleId: pack.bundleId,
      arguments: appArguments,
      keepAttached: keepAttached,
      checkedMode: true,
      hotReload: hotReload,
    );
  }
}
