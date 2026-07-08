import 'package:args/command_runner.dart';
import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:xcross/src/cli/flutter/flutter_operations.dart';
import 'package:xcross/src/cli/shared/ipa_packager.dart';
import 'package:xcross/src/util/logging.dart';

part 'flutter_build_args.g.dart';

@CliOptions(createCommand: true)
class FlutterBuildArgs {
  const FlutterBuildArgs({
    this.target = 'lib/main.dart',
    this.flavor,
    this.dartDefine = const [],
    this.dartDefineFromFile = const [],
    this.pub = true,
    this.buildName,
    this.buildNumber,
    this.sign = false,
    this.codesign = false,
    this.ipa = false,
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
    name: 'build-name',
    help: 'Version name (CFBundleShortVersionString).',
  )
  final String? buildName;

  @CliOption(
    name: 'build-number',
    help: 'Version code (CFBundleVersion).',
  )
  final String? buildNumber;

  @CliOption(
    abbr: 's',
    negatable: false,
    help: 'Codesign the built app (delegates to `xtool`).',
  )
  final bool sign;

  @CliOption(help: 'Alias of --sign (flutter-style).')
  final bool codesign;

  @CliOption(
    abbr: 'i',
    negatable: false,
    help: 'Output a .ipa file instead of a .app.',
  )
  final bool ipa;
}

/// `xcross flutter build` — build a Flutter iOS `.app` (optionally sign / ipa).
///
/// xcross is debug-only. Accepts a mix of the original xtool flags (`--sign`,
/// `--ipa`) and the official `flutter build ios` flags (`-t/--target`,
/// `-D/--dart-define`, `--dart-define-from-file`, `--[no-]pub`, `--build-name`,
/// `--build-number`, `--[no-]codesign`, `--flavor`).
class FlutterBuildCommand extends _$FlutterBuildArgsCommand<void> {
  @override
  String get name => 'build';

  @override
  String get description =>
      'Build a Flutter iOS .app from Linux without Xcode.';

  bool get _sign => _options.sign || _options.codesign;

  @override
  Future<void> run() async {
    final options = await resolveBuildOptions(
      target: _options.target,
      dartDefine: _options.dartDefine,
      dartDefineFromFile: _options.dartDefineFromFile,
      pub: _options.pub,
      buildName: _options.buildName,
      buildNumber: _options.buildNumber,
      flavor: _options.flavor,
    );

    final result = await flutterPack(options: options);

    if (_sign) {
      // Upstream xtool has no standalone "sign" command; signing happens at
      // install time (`xtool install`, used by `xcross flutter run`).
      logWarn(
        'xcross delegates signing to `xtool install` (the original xtool has '
        'no standalone sign command). Produced an unsigned .app; use '
        '`xcross flutter run` or `xtool install <app>` to sign + install.',
      );
    }

    final finalPath =
        _options.ipa ? await packageIpa(result.appPath) : result.appPath;
    logInfo('Wrote to $finalPath');
  }
}
