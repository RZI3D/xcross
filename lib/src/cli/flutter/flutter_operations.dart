import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:xcross/src/build/flutter_packer.dart';
import 'package:xcross/src/build/ios_engine_cache.dart';
import 'package:xcross/src/models/cli/pack_result.dart';
import 'package:xcross/src/models/config/pack_schema.dart';
import 'package:xcross/src/models/device/hot_reload_config.dart';
import 'package:xcross/src/models/flutter/flutter_build_options.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';

// Matches line endings (LF or CRLF) for splitting .env-style define files.
final _newlinePattern = RegExp(r'\r?\n');

/// Build the Flutter iOS `.app` for the project in the current directory.
///
/// Mirrors `FlutterPackOperation.run()` (FlutterCommand.swift): prefer
/// `xtool.yml`, otherwise fall back to the default `com.example` schema, delete
/// any prior bundle, then pack.
Future<PackResult> flutterPack({
  required FlutterBuildOptions options,
}) async {
  final projectRoot = Directory.current.path;

  final PackSchema schema;
  final configPath = p.join(projectRoot, 'xtool.yml');
  final configExists = File(configPath).existsSync();
  if (configExists) {
    schema = await PackSchema.fromFile(configPath);
  } else {
    schema = PackSchema.defaultSchema();
    logWarn(
      "Could not locate configuration file 'xtool.yml'. Using default "
      "configuration with 'com.example' organization ID.",
    );
  }

  final packer =
      FlutterPacker(projectRoot: projectRoot, schema: schema, options: options);
  final bundleId = schema.idSpecifier.formBundleId(packer.appName);

  // Always delete any previous bundle BEFORE packing (FlutterCommand.swift).
  final bundleOut =
      p.join(projectRoot, 'build', 'xtool-ios', '${packer.appName}.app');
  final bundleDir = Directory(bundleOut);
  final bundleDirExists = bundleDir.existsSync();
  if (bundleDirExists) await bundleDir.delete(recursive: true);

  final appPath = await packer.pack();
  return PackResult(appPath, bundleId);
}

/// Resolve the paths a persistent `frontend_server` needs for hot reload.
///
/// Returns null (with a warning) if a required artifact is missing — callers
/// then launch without hot reload. Mirrors `FlutterRunCommand.hotReloadConfig()`
/// (uses `try?` to degrade gracefully).
Future<HotReloadConfig?> buildHotReloadConfig({
  required String target,
  required List<String> dartDefines,
  bool verbose = false,
}) async {
  final projectRoot = Directory.current.path;
  final flutterRoot =
      await FlutterPacker.resolveFlutterRoot(projectRoot: projectRoot);
  final engineCache = IosEngineCache(flutterRoot: flutterRoot);

  final frontendServer = engineCache.frontendServer;
  final frontendServerExists = File(frontendServer).existsSync();
  if (!frontendServerExists) {
    logWarn('frontend_server snapshot missing at $frontendServer; '
        'hot reload disabled.');
    return null;
  }

  final sdkRoot = engineCache.patchedSdkRoot;
  final packageConfig =
      p.join(projectRoot, '.dart_tool', 'package_config.json');
  final entrypoint =
      p.isAbsolute(target) ? target : p.join(projectRoot, target);

  // frontend_server is AOT (dartaotruntime) or a kernel snapshot (dart).
  final dartSdkBin = p.join(flutterRoot, 'bin', 'cache', 'dart-sdk', 'bin');
  final isAot = p.basename(frontendServer).contains('_aot');
  final dart = p.join(dartSdkBin, isAot ? 'dartaotruntime' : 'dart');

  // Persistent dill output for incremental reloads.
  final outputDill = p.join(
      projectRoot, 'build', 'xtool-flutter-debug', '.hotreload', 'app.dill');
  await Directory(p.dirname(outputDill)).create(recursive: true);

  return HotReloadConfig(
    dart: dart,
    frontendServer: frontendServer,
    sdkRoot: sdkRoot,
    packageConfig: packageConfig,
    entrypoint: entrypoint,
    projectRoot: projectRoot,
    outputDill: outputDill,
    dartDefines: dartDefines,
    verbose: verbose,
  );
}

/// Build a [FlutterBuildOptions], merging `--dart-define-from-file` entries
/// (lower precedence) with explicit `--dart-define` entries (higher precedence).
Future<FlutterBuildOptions> resolveBuildOptions({
  required String target,
  required List<String> dartDefine,
  required List<String> dartDefineFromFile,
  required bool pub,
  String? buildName,
  String? buildNumber,
  String? flavor,
}) async {
  final defines = await _mergeDartDefines(dartDefineFromFile, dartDefine);
  return FlutterBuildOptions(
    target: target,
    dartDefines: defines,
    pub: pub,
    buildName: buildName,
    buildNumber: buildNumber,
    flavor: flavor,
  );
}

/// Merge dart-define sources into ordered `KEY=VALUE` strings. File entries are
/// emitted first; explicit `--dart-define` entries are appended last so they
/// win when frontend_server resolves duplicate keys (last-wins).
Future<List<String>> _mergeDartDefines(
  List<String> fromFiles,
  List<String> explicit,
) async {
  final result = <String>[];
  for (final path in fromFiles) {
    result.addAll(await _readDefineFile(path));
  }
  result.addAll(explicit);
  return result;
}

/// Parse a `--dart-define-from-file` source (`.json` object or `.env`-style
/// `KEY=VALUE` lines) into `KEY=VALUE` strings.
Future<List<String>> _readDefineFile(String path) async {
  final file = File(path);
  final defineFileExists = file.existsSync();
  if (!defineFileExists) {
    throw XcrossError('--dart-define-from-file: file not found: $path');
  }
  final content = await file.readAsString();
  final trimmed = content.trimLeft();
  if (p.extension(path) == '.json' || trimmed.startsWith('{')) {
    final decoded = jsonDecode(content);
    if (decoded is! Map) {
      throw XcrossError('--dart-define-from-file: $path is not a JSON object');
    }
    return decoded.entries.map((e) => '${e.key}=${e.value}').toList();
  }
  // .env style: KEY=VALUE lines, ignore blanks and # comments.
  final defines = <String>[];
  for (final raw in content.split(_newlinePattern)) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final eq = line.indexOf('=');
    if (eq < 0) continue;
    defines.add(line);
  }
  return defines;
}
