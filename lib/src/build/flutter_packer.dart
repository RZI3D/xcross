// Port of Sources/PackLib/FlutterPacker.swift
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;

import 'package:xcross/src/build/flutter_debug_bundler.dart';
import 'package:xcross/src/build/ios_engine_cache.dart';
import 'package:xcross/src/build/runner_shim.dart';
import 'package:xcross/src/constants/ios_deployment_constants.dart';
import 'package:xcross/src/constants/plist_defaults.dart';
import 'package:xcross/src/models/config/pack_schema.dart';
import 'package:xcross/src/models/flutter/flutter_build_options.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';
import 'package:xcross/src/util/process.dart';
import 'package:xcross/src/xtool/darwin_sdk.dart';

/// Builds a Flutter iOS `.app` bundle using dart + xtool's cross-platform
/// toolchain. Does NOT call `xcrun`.
///
/// Pipeline (debug/JIT only — xcross does not support release/AOT):
///   1. Resolve `FLUTTER_ROOT` and run `flutter pub get`.
///   2. Build `App.framework` via [FlutterDebugBundler] (frontend_server
///      one-shot + clang stub dylib + xtool's ld64.lld).
///   3. Compile the ObjC Runner shim via [RunnerShim].
///   4. Assemble the `.app` bundle and write `Info.plist`.
///
class FlutterPacker {
  final String projectRoot;
  final PackSchema schema;
  final FlutterBuildOptions options;

  /// App name read from `pubspec.yaml` `name:` key.
  /// (FlutterPacker.swift: appName)
  final String appName;

  FlutterPacker({
    required this.projectRoot,
    required this.schema,
    required this.options,
  }) : appName = _parsePubspecNameSync(projectRoot);

  // ---------------------------------------------------------------------------
  // FlutterPacker.swift: pack()
  // ---------------------------------------------------------------------------

  /// Build the Flutter iOS app.
  /// Returns path to `<projectRoot>/build/xtool-ios/<appName>.app`.
  Future<String> pack() async {
    final flutterRoot = await resolveFlutterRoot(projectRoot: projectRoot);
    logStatus('[xcross] Flutter SDK: $flutterRoot');

    // Step 1 — pub get (skipped when --no-pub).
    if (options.pub) {
      await _runFlutterPubGet(flutterRoot);
    } else {
      logStatus('[xcross] skipping flutter pub get (--no-pub).');
    }

    if (options.flavor != null) {
      // Flavor affects resource resolution and signing, neither of which is
      // fully implemented on the Linux debug path.
      logWarn(
        'flavor "${options.flavor}" is not fully supported on the Linux debug '
        'path; the build will proceed without flavor-specific configuration.',
      );
    }

    // Step 2 — App.framework (Dart kernel + stub dylib + assets).
    final appFramework = await _buildAppFramework(flutterRoot);

    // Step 3 — Runner binary (ObjC shim, compiled via clang/ld64.lld).
    final (:xcframework, :runnerBinary) = await _buildRunnerBinary(flutterRoot);

    // Step 4 — Assemble .app bundle and persist to the build output directory.
    return _assembleAndPersistBundle(
      appFramework: appFramework,
      xcframework: xcframework,
      runnerBinary: runnerBinary,
    );
  }

  // ---------------------------------------------------------------------------
  // FlutterPacker.swift: resolveFlutterRoot()
  // ---------------------------------------------------------------------------

  /// Resolve the Flutter SDK root using, in order:
  ///   1. `FLUTTER_ROOT` environment variable.
  ///   2. `<projectRoot>/.fvm/flutter_sdk` symlink (fvm).
  ///   3. `which flutter` → parent of `bin/`.
  ///
  /// (FlutterPacker.swift: resolveFlutterRoot ~L966-977)
  static Future<String> resolveFlutterRoot(
      {required String projectRoot}) async {
    final envRoot = Platform.environment['FLUTTER_ROOT'];
    if (envRoot != null && envRoot.isNotEmpty) return envRoot;

    final fvmLink = p.join(projectRoot, '.fvm', 'flutter_sdk');
    final fvmDirExists = Directory(fvmLink).existsSync();
    final fvmLinkExists = Link(fvmLink).existsSync();
    if (fvmDirExists || fvmLinkExists) {
      return Link(fvmLink).resolveSymbolicLinksSync();
    }

    final flutter = await locateTool('flutter');
    // The `flutter` script lives at <root>/bin/flutter.
    return p.dirname(p.dirname(File(flutter).resolveSymbolicLinksSync()));
  }

  // ---------------------------------------------------------------------------
  // Pack pipeline steps
  // ---------------------------------------------------------------------------

  /// Run `flutter pub get`. Tolerates failures when `package_config.json`
  /// already exists (container builds with ephemeral pub caches).
  /// (FlutterPacker.swift: runFlutterPubGet ~L193-213)
  Future<void> _runFlutterPubGet(String flutterRoot) async {
    final packageConfig =
        p.join(projectRoot, '.dart_tool', 'package_config.json');
    logStatus('[flutter] pub get...');
    try {
      await ProcessRunner.runChecked(
        p.join(flutterRoot, 'bin', 'flutter'),
        ['pub', 'get'],
        workingDirectory: projectRoot,
        inheritStdio: true,
        label: 'flutter',
      );
    } on XcrossError {
      final packageConfigExists = File(packageConfig).existsSync();
      if (packageConfigExists) {
        logWarn(
            'Ignoring flutter pub get error because package_config.json exists.');
        return;
      }
      rethrow;
    }
  }

  /// Build `App.framework` via [FlutterDebugBundler].
  /// Returns the framework directory path.
  Future<String> _buildAppFramework(String flutterRoot) async {
    final assembleOut = p.join(projectRoot, 'build', 'xtool-flutter-debug');
    final assembleDir = Directory(assembleOut);
    final assembleDirExists = assembleDir.existsSync();
    if (assembleDirExists) await assembleDir.delete(recursive: true);
    await assembleDir.create(recursive: true);

    return FlutterDebugBundler(
      projectRoot: projectRoot,
      flutterRoot: flutterRoot,
      outputDir: assembleOut,
      entrypoint: options.target,
      dartDefines: options.dartDefines,
    ).build();
  }

  /// Compile the ObjC Runner shim and return both the xcframework path and the
  /// linked Runner binary path.
  Future<({String xcframework, String runnerBinary})> _buildRunnerBinary(
    String flutterRoot,
  ) async {
    final xcframework =
        IosEngineCache(flutterRoot: flutterRoot).flutterXcframework;

    final darwin = DarwinSdk.current();
    if (darwin == null) {
      throw XcrossError(
        'FlutterPacker: Darwin SDK not found. '
        'Install with `xtool sdk install <Xcode.xip|Xcode.app>`.',
      );
    }

    final runnerBinary = await RunnerShim.buildRunnerBinary(
      projectRoot: projectRoot,
      sdk: darwin,
      flutterXcframework: xcframework,
      outputDir: p.join(projectRoot, 'build', 'xtool-flutter-runner-bin'),
    );

    return (xcframework: xcframework, runnerBinary: runnerBinary);
  }

  /// Copy all bundle contents into a temp directory, write `Info.plist`, then
  /// move the result to `build/xtool-ios/<appName>.app`.
  /// (FlutterPacker.swift: ~L156-188)
  Future<String> _assembleAndPersistBundle({
    required String appFramework,
    required String xcframework,
    required String runnerBinary,
  }) async {
    final flutterFramework =
        p.join(xcframework, 'ios-arm64', 'Flutter.framework');

    // Build the bundle in a temp dir so we can atomically move it to the dest.
    final tmp = await Directory.systemTemp.createTemp('${appName}_app_bundle-');
    final bundleDir = tmp.path;

    final frameworksDir = p.join(bundleDir, 'Frameworks');
    await Directory(frameworksDir).create(recursive: true);

    // Runner executable.
    await File(runnerBinary).copy(p.join(bundleDir, 'Runner'));
    // Make the Runner executable via libc chmod (FFI) — no subprocess.
    if (posix.isPosixSupported) {
      posix.chmod(p.join(bundleDir, 'Runner'), '0755');
    }

    // Embedded frameworks.
    await _copyDirectory(
        flutterFramework, p.join(frameworksDir, 'Flutter.framework'));
    await _copyDirectory(appFramework, p.join(frameworksDir, 'App.framework'));

    // Optional compiled storyboards.
    await _copyOptionalRunnerResources(bundleDir);

    // Info.plist with $(VAR) substitution.
    await _writeInfoPlist(bundleDir);

    // Persist out of tmp to the final output path.
    final dest = p.join(projectRoot, 'build', 'xtool-ios', '$appName.app');
    final destExists = Directory(dest).existsSync();
    if (destExists) {
      await Directory(dest).delete(recursive: true);
    }
    await Directory(p.dirname(dest)).create(recursive: true);
    await _copyDirectory(bundleDir, dest);
    await tmp.delete(recursive: true);

    return dest;
  }

  /// Copy compiled storyboards from `ios/Runner/` into the bundle, if present.
  /// (FlutterPacker.swift: copyOptionalRunnerResources ~L659-673)
  Future<void> _copyOptionalRunnerResources(String bundleDir) async {
    final runnerDir = p.join(projectRoot, 'ios', 'Runner');
    const storyboards = [
      'Base.lproj/LaunchScreen.storyboardc',
      'Base.lproj/Main.storyboardc',
    ];
    for (final rel in storyboards) {
      final src = p.join(runnerDir, rel);
      final srcExists = Directory(src).existsSync();
      if (!srcExists) continue;
      final dst = p.join(bundleDir, p.basename(src));
      final dstExists = Directory(dst).existsSync();
      if (dstExists) {
        await Directory(dst).delete(recursive: true);
      }
      await _copyDirectory(src, dst);
    }
  }

  // ---------------------------------------------------------------------------
  // Info.plist generation (FlutterPacker.swift: writeInfoPlist ~L675-750)
  // ---------------------------------------------------------------------------

  /// Generate and write `Info.plist` into [bundleDir] with `$(VAR)`
  /// substitution, mandatory iOS keys, storyboard stripping, and ObjC class
  /// name normalization.
  Future<void> _writeInfoPlist(String bundleDir) async {
    final bundleId = schema.idSpecifier.formBundleId(appName);

    // Load the user's Info.plist or the minimal fallback.
    var plistXml = await _loadPlistTemplate();

    // Expand $(VAR) / ${VAR} placeholders (version strings come from subs).
    // ORDER MATTERS: vars must be expanded before forcing keys so that
    // forced keys see already-substituted values from the template.
    final subs = await _buildSubstitutionMap(bundleId);
    plistXml = _expandVars(plistXml, subs);

    // Force mandatory iOS keys (FlutterPacker.swift ~L717-723).
    plistXml = _applyIosRequiredKeys(plistXml, bundleId: bundleId);

    // Strip storyboard refs (no ibtool on Linux) and normalize ObjC names.
    plistXml = _stripUnsatisfiableStoryboards(plistXml, bundleDir);
    plistXml = _normalizeObjCClassNames(plistXml);

    await File(p.join(bundleDir, 'Info.plist')).writeAsString(plistXml);
  }

  /// Read `ios/Runner/Info.plist` (or `schema.infoPath`), falling back to
  /// [_fallbackPlist] when neither exists.
  Future<String> _loadPlistTemplate() async {
    final plistPath = schema.infoPath ?? p.join('ios', 'Runner', 'Info.plist');
    final plistFile = File(p.join(projectRoot, plistPath));
    final plistFileExists = plistFile.existsSync();
    if (plistFileExists) return plistFile.readAsString();
    return _fallbackPlist;
  }

  /// Build the `$(VAR)` substitution map.
  ///
  /// Precedence (lowest → highest):
  ///   1. Hard-coded defaults (`1.0.0` / `1`).
  ///   2. `Generated.xcconfig` values from `flutter build` tooling.
  ///   3. Explicit `--build-name` / `--build-number` CLI flags.
  ///
  /// (FlutterPacker.swift: subs ~L698-713)
  Future<Map<String, String>> _buildSubstitutionMap(String bundleId) async {
    final subs = <String, String>{
      'EXECUTABLE_NAME': PlistDefaults.executable,
      'PRODUCT_NAME': PlistDefaults.executable,
      'PRODUCT_MODULE_NAME': PlistDefaults.executable,
      'PRODUCT_BUNDLE_IDENTIFIER': bundleId,
      'DEVELOPMENT_LANGUAGE': 'en',
      // Defaults — may be overridden by xcconfig or CLI flags below.
      'FLUTTER_BUILD_NAME': PlistDefaults.shortVersion,
      'FLUTTER_BUILD_NUMBER': PlistDefaults.bundleVersion,
    };

    // Overlay Generated.xcconfig values (e.g. FLUTTER_BUILD_NAME from
    // `flutter build` tooling). (FlutterPacker.swift ~L707-713)
    final xcconfigFile =
        File(p.join(projectRoot, 'ios', 'Flutter', 'Generated.xcconfig'));
    final xcconfigExists = xcconfigFile.existsSync();
    if (xcconfigExists) {
      subs.addAll(_parseXcconfig(await xcconfigFile.readAsString()));
    }

    // Explicit CLI --build-name / --build-number win over xcconfig values.
    if (options.buildName != null) {
      subs['FLUTTER_BUILD_NAME'] = options.buildName!;
    }
    if (options.buildNumber != null) {
      subs['FLUTTER_BUILD_NUMBER'] = options.buildNumber!;
    }

    return subs;
  }

  /// Overwrite or insert all mandatory iOS bundle keys.
  /// Version strings (CFBundleShortVersionString / CFBundleVersion) are NOT
  /// forced here — they come solely from $(FLUTTER_BUILD_NAME) /
  /// $(FLUTTER_BUILD_NUMBER) substitution so that xcconfig and --build-name
  /// values are respected. (FlutterPacker.swift ~L717-723)
  static String _applyIosRequiredKeys(
    String plistXml, {
    required String bundleId,
  }) {
    var xml = plistXml;
    xml = _setPlistKey(xml, 'CFBundleExecutable', PlistDefaults.executable);
    xml = _setPlistKey(xml, 'CFBundleIdentifier', bundleId);
    xml = _setPlistKey(xml, 'CFBundlePackageType', 'APPL');
    if (!xml.contains(IosDeploymentConstants.minimumOsVersionKey)) {
      xml = _setPlistKey(
        xml,
        IosDeploymentConstants.minimumOsVersionKey,
        IosDeploymentConstants.minDeploymentTarget,
      );
    }
    xml = _ensureKey(
      xml,
      'LSRequiresIPhoneOS',
      '\t<key>LSRequiresIPhoneOS</key>\n\t<true/>\n',
    );
    xml = _ensureKey(
      xml,
      'CFBundleSupportedPlatforms',
      '\t<key>CFBundleSupportedPlatforms</key>\n'
          '\t<array><string>iPhoneOS</string></array>\n',
    );
    xml = _ensureKey(
      xml,
      'UIRequiredDeviceCapabilities',
      '\t<key>UIRequiredDeviceCapabilities</key>\n'
          '\t<array><string>arm64</string></array>\n',
    );
    // Xcode injects these at build time; without them newer iOS (26+) refuses
    // to register the app with SpringBoard/LaunchServices (installs but won't
    // launch — FBSApplicationLibrary returns nil).
    xml = _ensureKey(
      xml,
      'UIDeviceFamily',
      '\t<key>UIDeviceFamily</key>\n'
          '\t<array><integer>1</integer></array>\n',
    );
    xml = _ensureKey(
      xml,
      'DTPlatformName',
      '\t<key>DTPlatformName</key>\n\t<string>iphoneos</string>\n',
    );
    xml = _ensureKey(
      xml,
      'DTSDKName',
      '\t<key>DTSDKName</key>\n'
          '\t<string>${IosDeploymentConstants.sdkTriple}</string>\n',
    );
    xml = _ensureKey(
      xml,
      'DTPlatformVersion',
      '\t<key>DTPlatformVersion</key>\n'
          '\t<string>${IosDeploymentConstants.sdkVersion}</string>\n',
    );
    return xml;
  }

  /// Insert [fragment] before `</dict>` if [needle] is absent from [xml].
  static String _ensureKey(String xml, String needle, String fragment) {
    if (xml.contains(needle)) {
      return xml;
    }
    return _insertBeforeEnd(xml, fragment);
  }

  // ---------------------------------------------------------------------------
  // Plist / xcconfig text helpers
  // ---------------------------------------------------------------------------

  /// Expand `$(KEY)` and `${KEY}` in [text] using [subs].
  /// (FlutterPacker.swift: expand(_:with:) ~L854-861)
  static String _expandVars(String text, Map<String, String> subs) {
    var result = text;
    for (final entry in subs.entries) {
      result = result
          .replaceAll('\$(${entry.key})', entry.value)
          .replaceAll('\${${entry.key}}', entry.value);
    }
    return result;
  }

  /// Parse `KEY = VALUE` lines from an Xcode `.xcconfig` file.
  /// Strips `[config]` suffixes (e.g. `KEY[debug] = VALUE`).
  /// (FlutterPacker.swift: readXcconfig ~L863-878)
  static Map<String, String> _parseXcconfig(String text) {
    final result = <String, String>{};
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('//') || line.startsWith('#')) {
        continue;
      }
      final eq = line.indexOf('=');
      if (eq < 0) continue;
      var key = line.substring(0, eq).trim();
      final bracket = key.indexOf('[');
      if (bracket >= 0) key = key.substring(0, bracket).trim();
      final value = line.substring(eq + 1).trim();
      result[key] = value;
    }
    return result;
  }

  /// Overwrite an existing `<key>K</key><string>…</string>` pair, or insert a
  /// new one before `</dict>` if the key is absent.
  static String _setPlistKey(String xml, String key, String value) {
    final pattern =
        RegExp('<key>$key</key>\\s*<string>[^<]*</string>', dotAll: true);
    final replacement = '<key>$key</key>\n\t<string>$value</string>';
    if (xml.contains('<key>$key</key>')) {
      return xml.replaceFirst(pattern, replacement);
    }
    return _insertBeforeEnd(xml, '\t$replacement\n');
  }

  /// Insert [fragment] before the closing `</dict>` of the root plist dict.
  /// Tries `</dict>\n</plist>` first (canonical), then falls back to the last
  /// bare `</dict>` to handle compact plist serialisations.
  static String _insertBeforeEnd(String xml, String fragment) {
    const sentinel = '</dict>\n</plist>';
    final idx = xml.lastIndexOf(sentinel);
    if (idx >= 0) {
      return xml.substring(0, idx) + fragment + xml.substring(idx);
    }
    const dictEnd = '</dict>';
    final dictIdx = xml.lastIndexOf(dictEnd);
    if (dictIdx >= 0) {
      return xml.substring(0, dictIdx) + fragment + xml.substring(dictIdx);
    }
    return xml + fragment;
  }

  /// Remove references to storyboards not present (compiled) in [bundleDir].
  /// xtool doesn't run `ibtool`, so missing storyboards would crash at launch.
  /// (FlutterPacker.swift: stripUnsatisfiableStoryboards ~L769-800)
  static String _stripUnsatisfiableStoryboards(String xml, String bundleDir) {
    bool hasCompiled(String name) =>
        Directory(p.join(bundleDir, '$name.storyboardc')).existsSync();

    // Named local reused by Main and Scene patterns (identical predicate).
    String keepIfCompiled(Match m) =>
        hasCompiled(m.group(1)!) ? m.group(0)! : '';

    var result = xml.replaceAllMapped(
      _uiMainStoryboardPattern,
      keepIfCompiled,
    );

    result = result.replaceAllMapped(
      _uiLaunchStoryboardPattern,
      (m) {
        if (hasCompiled(m.group(1)!)) {
          return m.group(0)!;
        }
        // Replace with UILaunchScreen programmatic launch screen if absent.
        if (!result.contains('UILaunchScreen')) {
          return '<key>UILaunchScreen</key>\n\t<dict/>';
        }
        return '';
      },
    );

    // Strip UISceneStoryboardFile entries. (FlutterPacker.swift ~L786-800)
    result = result.replaceAllMapped(
      _uiSceneStoryboardPattern,
      keepIfCompiled,
    );

    return result;
  }

  /// Drop Swift module prefix from ObjC class names in the plist.
  /// The Runner shim registers `AppDelegate` / `SceneDelegate` without a module
  /// prefix, so `Runner.SceneDelegate` from the stock template would fail
  /// `NSClassFromString`. (FlutterPacker.swift: normalizeObjCClassNames ~L807-837)
  static String _normalizeObjCClassNames(String xml) {
    return xml.replaceAllMapped(
      _objcClassNamePattern,
      (m) {
        final name = m.group(2)!;
        final dot = name.lastIndexOf('.');
        final unqualified = dot >= 0 ? name.substring(dot + 1) : name;
        return '${m.group(1)}$unqualified${m.group(3)}';
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Static helpers
  // ---------------------------------------------------------------------------

  /// Parse `name:` from `pubspec.yaml` synchronously.
  /// (FlutterPacker.swift: parsePubspecName ~L911-921)
  static String _parsePubspecNameSync(String projectRoot) {
    final file = File(p.join(projectRoot, 'pubspec.yaml'));
    final pubspecExists = file.existsSync();
    if (!pubspecExists) {
      throw XcrossError(
          'FlutterPacker: pubspec.yaml not found at ${file.path}');
    }
    for (final line in file.readAsLinesSync()) {
      if (line.startsWith('name:')) {
        return line
            .substring('name:'.length)
            .trim()
            .replaceAll(_pubspecQuotesPattern, '');
      }
    }
    throw XcrossError('FlutterPacker: pubspec.yaml has no `name:` key');
  }

  /// Recursively copy [src] to [dst], preserving symlinks.
  static Future<void> _copyDirectory(String src, String dst) async {
    await Directory(dst).create(recursive: true);
    await for (final entity in Directory(src).list()) {
      final name = p.basename(entity.path);
      final destPath = p.join(dst, name);
      if (entity is Directory) {
        await _copyDirectory(entity.path, destPath);
      } else if (entity is File) {
        await entity.copy(destPath);
      } else if (entity is Link) {
        final link = Link(destPath);
        final linkExists = link.existsSync();
        if (linkExists) await link.delete();
        await link.create(await entity.target());
      }
    }
  }

  // Matches `<key>UIMainStoryboardFile</key><string>…</string>`.
  static final _uiMainStoryboardPattern = RegExp(
    r'<key>UIMainStoryboardFile</key>\s*<string>([^<]*)</string>',
  );

  // Matches `<key>UILaunchStoryboardName</key><string>…</string>`.
  static final _uiLaunchStoryboardPattern = RegExp(
    r'<key>UILaunchStoryboardName</key>\s*<string>([^<]*)</string>',
  );

  // Matches `<key>UISceneStoryboardFile</key><string>…</string>`.
  static final _uiSceneStoryboardPattern = RegExp(
    r'<key>UISceneStoryboardFile</key>\s*<string>([^<]*)</string>',
  );

  // Matches ObjC delegate/principal class plist entries for name normalisation.
  static final _objcClassNamePattern = RegExp(
    r'(<key>(?:UISceneDelegateClassName|NSPrincipalClass)</key>\s*<string>)'
    '([^<]*)'
    '(</string>)',
  );

  // Matches one or more single or double quote characters in pubspec name.
  static final _pubspecQuotesPattern = RegExp("""['"]+""");

  static const _fallbackPlist = '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"'
      ' "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
      '<plist version="1.0">\n'
      '<dict>\n'
      '\t<key>UILaunchScreen</key>\n'
      '\t<dict/>\n'
      '\t<key>UISupportedInterfaceOrientations</key>\n'
      '\t<array>\n'
      '\t\t<string>UIInterfaceOrientationPortrait</string>\n'
      '\t</array>\n'
      '</dict>\n'
      '</plist>\n';
}
