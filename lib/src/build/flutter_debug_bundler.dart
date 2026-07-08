// Port of Sources/PackLib/FlutterDebugBundler.swift
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:xcross/src/build/ios_engine_cache.dart';
import 'package:xcross/src/constants/ios_deployment_constants.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';
import 'package:xcross/src/util/process.dart';
import 'package:xcross/src/xtool/darwin_sdk.dart';

/// Assembles `App.framework` (debug/JIT mode) for a Flutter iOS app without
/// invoking `xcrun` or `flutter_tools.snapshot assemble`.
///
/// Cross-platform path used on Linux where `xcrun` is unavailable.
///
/// Pipeline:
///   1. Download iOS engine artifacts via [IosEngineCache] if missing.
///   2. Run `frontend_server` → `app.dill` (Dart kernel for JIT).
///   3. Bundle `flutter_assets/` (kernel blob, snapshot data, manifests).
///   4. Build App stub Mach-O dylib via clang + xtool's ld64.lld.
///   5. Write `App.framework/Info.plist`.
///
class FlutterDebugBundler {
  final String projectRoot;
  final String flutterRoot;
  final String outputDir;

  /// Dart entrypoint to compile (default: `lib/main.dart`).
  final String entrypoint;

  /// `KEY=VALUE` dart-define strings forwarded to frontend_server as
  /// `-D<KEY=VALUE>` flags alongside the built-in vm.profile/vm.product flags.
  final List<String> dartDefines;

  FlutterDebugBundler({
    required this.projectRoot,
    required this.flutterRoot,
    required this.outputDir,
    this.entrypoint = 'lib/main.dart',
    this.dartDefines = const [],
  });

  // ---------------------------------------------------------------------------
  // Manifest byte constants (FlutterDebugBundler.swift ~L214, ~L244)
  // ---------------------------------------------------------------------------

  /// StandardMessageCodec empty map: tag 0x0d (Map) + 4-byte LE length 0.
  static const _emptyAssetManifestBytes = [0x0d, 0x00, 0x00, 0x00, 0x00];

  /// Empty zlib stream: `zlib.compress(b'')` in Python.
  /// CMF=0x78 FLG=0x9c, empty deflate block (BFINAL=1 BTYPE=0, zero length),
  /// Adler-32 of empty input = 0x00000001 big-endian.
  static const _emptyZlibBytes = [
    0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01, //
  ];

  // ---------------------------------------------------------------------------
  // FlutterDebugBundler.swift: build()
  // ---------------------------------------------------------------------------

  /// Build `App.framework` inside [outputDir]. Returns the framework path.
  /// (FlutterDebugBundler.swift: build())
  Future<String> build() async {
    final engineCache = IosEngineCache(flutterRoot: flutterRoot);
    logStatus('[xcross] ensuring Flutter iOS debug artifacts...');
    await engineCache.ensureArtifactsAvailable();

    logStatus('[xcross] resolving iOS debug toolchain...');
    final toolchain = await _resolveToolchain();

    logStatus('[xcross] preparing App.framework output...');
    await Directory(outputDir).create(recursive: true);

    final appFramework = p.join(outputDir, 'App.framework');
    final assetsDir = p.join(appFramework, 'flutter_assets');

    // Clean any previous build artifact.
    final appDir = Directory(appFramework);
    final appDirExists = appDir.existsSync();
    if (appDirExists) await appDir.delete(recursive: true);
    await Directory(assetsDir).create(recursive: true);

    // Step 1: Dart kernel snapshot (JIT — no AOT flags).
    final appDill = await _runKernelSnapshot(engineCache);

    // Step 2: Bundle flutter_assets/.
    logStatus('[xcross] bundling Flutter debug assets...');
    await _copyDataAssets(assetsDir, engineCache, appDill);
    await _copyMaterialFonts(assetsDir);
    _writeManifests(assetsDir);

    // Step 3: App stub Mach-O dylib.
    await _buildAppStub(appFramework, toolchain);

    // Step 4: App.framework/Info.plist.
    logStatus('[xcross] writing App.framework Info.plist...');
    _writeAppFrameworkInfoPlist(appFramework);

    return appFramework;
  }

  // ---------------------------------------------------------------------------
  // FlutterDebugBundler.swift: runKernelSnapshot()
  // ---------------------------------------------------------------------------

  Future<String> _runKernelSnapshot(IosEngineCache engineCache) async {
    final snapshot = engineCache.frontendServer;
    final dartSdkBin = p.join(flutterRoot, 'bin', 'cache', 'dart-sdk', 'bin');

    // AOT snapshots run via `dartaotruntime`; non-AOT via `dart`.
    final isAot = p.basename(snapshot).contains('_aot');
    final runtimeName = isAot ? 'dartaotruntime' : 'dart';
    final runtime = p.join(dartSdkBin, runtimeName);

    _validateKernelDependencies(snapshot, runtime, runtimeName, engineCache);

    final scratch =
        p.join(projectRoot, 'build', 'xtool-flutter-debug', '.kernel');
    final scratchDir = Directory(scratch);
    final scratchDirExists = scratchDir.existsSync();
    if (scratchDirExists) await scratchDir.delete(recursive: true);
    await scratchDir.create(recursive: true);

    final outputDill = p.join(scratch, 'app.dill');
    final packageConfig =
        p.join(projectRoot, '.dart_tool', 'package_config.json');
    final packageConfigExists = File(packageConfig).existsSync();
    if (!packageConfigExists) {
      throw XcrossError(
        'FlutterDebugBundler: package_config.json missing at $packageConfig; '
        'run `dart pub get` first.',
      );
    }

    // Resolve entrypoint — join with projectRoot when relative.
    final resolvedEntrypoint =
        p.isAbsolute(entrypoint) ? entrypoint : p.join(projectRoot, entrypoint);

    // Build args — dartaotruntime takes <snapshot> as first arg;
    // `dart` needs --disable-dart-dev first.
    // (FlutterDebugBundler.swift: runKernelSnapshot() ~L143-162)
    final args = <String>[
      if (!isAot) '--disable-dart-dev',
      snapshot,
      '--sdk-root', '${engineCache.patchedSdkRoot}/',
      '--target=flutter',
      '--no-print-incremental-dependencies',
      '-Ddart.developer.serviceExtensionStream.enabled=true',
      '-Ddart.vm.profile=false',
      '-Ddart.vm.product=false',
      '--track-widget-creation',
      '--packages', packageConfig,
      '--output-dill', outputDill,
      // User-supplied dart-defines forwarded as -D<KEY=VALUE>.
      for (final define in dartDefines) '-D$define',
      resolvedEntrypoint,
    ];

    logStatus('[frontend_server] kernel snapshot (debug/JIT)...');
    await ProcessRunner.runChecked(
      runtime,
      args,
      workingDirectory: projectRoot,
      inheritStdio: true,
      label: 'frontend_server',
    );

    final outputDillExists = File(outputDill).existsSync();
    if (!outputDillExists) {
      throw XcrossError(
          'FlutterDebugBundler: kernel snapshot did not produce $outputDill');
    }
    return outputDill;
  }

  /// Guard that all prerequisites for the kernel snapshot step exist.
  void _validateKernelDependencies(
    String snapshot,
    String runtime,
    String runtimeName,
    IosEngineCache engineCache,
  ) {
    final snapshotExists = File(snapshot).existsSync();
    if (!snapshotExists) {
      throw XcrossError(
        'FlutterDebugBundler: frontend_server snapshot missing at $snapshot.\n'
        'Run `<FLUTTER_ROOT>/bin/dart --version` once to materialize.',
      );
    }
    final runtimeExists = File(runtime).existsSync();
    if (!runtimeExists) {
      throw XcrossError('FlutterDebugBundler: $runtimeName not at $runtime');
    }
    final platformDillExists =
        File(p.join(engineCache.patchedSdkRoot, 'platform_strong.dill'))
            .existsSync();
    if (!platformDillExists) {
      throw XcrossError(
        'FlutterDebugBundler: ${engineCache.patchedSdkRoot} is missing\n'
        'platform_strong.dill. Try deleting '
        '`bin/cache/artifacts/engine/common/` and rerunning.',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // FlutterDebugBundler.swift: copyDataAssets(), copyFonts(), writeManifests()
  // ---------------------------------------------------------------------------

  Future<void> _copyDataAssets(
    String assetsDir,
    IosEngineCache engineCache,
    String appDill,
  ) async {
    // kernel_blob.bin — Dart kernel for JIT execution.
    await File(appDill).copy(p.join(assetsDir, 'kernel_blob.bin'));
    // Snapshot data files (name remap: .bin suffix dropped, stem changed).
    await File(engineCache.vmSnapshotData)
        .copy(p.join(assetsDir, 'vm_snapshot_data'));
    await File(engineCache.isolateSnapshotData)
        .copy(p.join(assetsDir, 'isolate_snapshot_data'));
  }

  /// Copy `MaterialIcons-Regular.otf` when the project uses material design.
  Future<void> _copyMaterialFonts(String assetsDir) async {
    final pubspec = File(p.join(projectRoot, 'pubspec.yaml'));
    final pubspecExists = pubspec.existsSync();
    if (!pubspecExists) return;
    final usesMaterial =
        (await pubspec.readAsString()).contains('uses-material-design: true');
    if (!usesMaterial) return;

    final fontsDir = p.join(assetsDir, 'fonts');
    await Directory(fontsDir).create(recursive: true);

    final src = p.join(flutterRoot, 'bin', 'cache', 'artifacts',
        'material_fonts', 'MaterialIcons-Regular.otf');
    final srcFontExists = File(src).existsSync();
    if (!srcFontExists) return;

    final dst = p.join(fontsDir, 'MaterialIcons-Regular.otf');
    final dstFontExists = File(dst).existsSync();
    if (dstFontExists) await File(dst).delete();
    await File(src).copy(dst);
  }

  void _writeManifests(String assetsDir) {
    // AssetManifest.bin — StandardMessageCodec empty map (5 bytes).
    File(p.join(assetsDir, 'AssetManifest.bin'))
        .writeAsBytesSync(_emptyAssetManifestBytes);

    // AssetManifest.json — legacy JSON variant still read by some plugins.
    File(p.join(assetsDir, 'AssetManifest.json')).writeAsStringSync('{}');

    // FontManifest.json — empty array (no custom fonts registered).
    File(p.join(assetsDir, 'FontManifest.json')).writeAsStringSync('[]');

    // NativeAssetsManifest.json — minimal valid shape expected by the engine.
    File(p.join(assetsDir, 'NativeAssetsManifest.json'))
        .writeAsStringSync('{"format-version":[1,0,0],"native-assets":{}}');

    // NOTICES.Z — empty zlib stream (LicensePage handles empty content fine).
    File(p.join(assetsDir, 'NOTICES.Z')).writeAsBytesSync(_emptyZlibBytes);
  }

  // ---------------------------------------------------------------------------
  // FlutterDebugBundler.swift: resolveToolchain() + Toolchain struct
  // ---------------------------------------------------------------------------

  Future<_Toolchain> _resolveToolchain() async {
    final darwin = DarwinSdk.current();
    if (darwin != null) {
      return _Toolchain(
        clang: await locateTool('clang'),
        iosSDK: darwin.iPhoneOSSdk(),
        lldToolsetBin: p.join(darwin.bundle, 'toolset', 'bin'),
      );
    }
    // Linux without xtool Darwin SDK — cannot proceed.
    throw XcrossError(
      'FlutterDebugBundler: no usable toolchain. xtool Darwin SDK not found.\n'
      'Install with `xtool sdk install <Xcode.xip|Xcode.app>` first.',
    );
  }

  // ---------------------------------------------------------------------------
  // FlutterDebugBundler.swift: buildAppStub()
  // ---------------------------------------------------------------------------

  Future<void> _buildAppStub(String appFramework, _Toolchain toolchain) async {
    logStatus('[clang] building App stub dylib...');

    final tmp = await Directory.systemTemp.createTemp('xtool-flutter-stub-');
    final stubSource = p.join(tmp.path, 'debug_app.c');
    // Exact stub content emitted by flutter_tools. (FlutterDebugBundler.swift ~L308)
    await File(stubSource).writeAsString('static const int Moo = 88;\n');

    await Directory(appFramework).create(recursive: true);
    final outputBinary = p.join(appFramework, 'App');

    // Flags mirror flutter_tools `_createStubAppFramework`.
    // (FlutterDebugBundler.swift ~L314-334)
    final args = _appStubClangArgs(
      toolchain: toolchain,
      stubSource: stubSource,
      outputBinary: outputBinary,
    );

    await ProcessRunner.runChecked(
      toolchain.clang,
      args,
      inheritStdio: true,
      label: 'clang',
    );

    final outputBinaryExists = File(outputBinary).existsSync();
    if (!outputBinaryExists) {
      throw XcrossError(
          'FlutterDebugBundler: clang did not produce $outputBinary');
    }

    await tmp.delete(recursive: true);
  }

  /// Build the clang argument list for the App stub dylib.
  /// (FlutterDebugBundler.swift ~L314-334)
  static List<String> _appStubClangArgs({
    required _Toolchain toolchain,
    required String stubSource,
    required String outputBinary,
  }) {
    return <String>[
      if (toolchain.lldToolsetBin != null) ...[
        '-fuse-ld=lld',
        '-B',
        toolchain.lldToolsetBin!,
      ],
      '--target=${IosDeploymentConstants.buildTriple}',
      '-arch',
      'arm64',
      '-miphoneos-version-min=${IosDeploymentConstants.minDeploymentTarget}',
      '-isysroot',
      toolchain.iosSDK,
      '-x',
      'c',
      stubSource,
      '-dynamiclib',
      '-Xlinker',
      '-rpath',
      '-Xlinker',
      '@executable_path/Frameworks',
      '-Xlinker',
      '-rpath',
      '-Xlinker',
      '@loader_path/Frameworks',
      '-fapplication-extension',
      '-install_name',
      '@rpath/App.framework/App',
      '-o',
      outputBinary,
    ];
  }

  // ---------------------------------------------------------------------------
  // FlutterDebugBundler.swift: writeAppFrameworkInfoPlist()
  // ---------------------------------------------------------------------------

  void _writeAppFrameworkInfoPlist(String appFramework) {
    // (FlutterDebugBundler.swift ~L349-368)
    const plist = '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"'
        ' "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0">\n'
        '<dict>\n'
        '\t<key>CFBundleDevelopmentRegion</key>\n'
        '\t<string>en</string>\n'
        '\t<key>CFBundleExecutable</key>\n'
        '\t<string>App</string>\n'
        '\t<key>CFBundleIdentifier</key>\n'
        '\t<string>io.flutter.flutter.app</string>\n'
        '\t<key>CFBundleInfoDictionaryVersion</key>\n'
        '\t<string>6.0</string>\n'
        '\t<key>CFBundleName</key>\n'
        '\t<string>App</string>\n'
        '\t<key>CFBundlePackageType</key>\n'
        '\t<string>FMWK</string>\n'
        '\t<key>CFBundleShortVersionString</key>\n'
        '\t<string>1.0</string>\n'
        '\t<key>CFBundleSignature</key>\n'
        '\t<string>????</string>\n'
        '\t<key>CFBundleVersion</key>\n'
        '\t<string>1.0</string>\n'
        '\t<key>${IosDeploymentConstants.minimumOsVersionKey}</key>\n'
        '\t<string>${IosDeploymentConstants.minDeploymentTarget}</string>\n'
        '</dict>\n'
        '</plist>\n'; // (FlutterDebugBundler.swift ~L349-368)
    File(p.join(appFramework, 'Info.plist')).writeAsStringSync(plist);
  }
}

/// Resolved toolchain for the App.framework stub build.
/// (FlutterDebugBundler.swift: Toolchain struct)
class _Toolchain {
  const _Toolchain({
    required this.clang,
    required this.iosSDK,
    this.lldToolsetBin,
  });

  final String clang;
  final String iosSDK;

  /// Path to `toolset/bin/` containing `ld64.lld`. Null on macOS where the
  /// host clang's default linker handles Mach-O.
  final String? lldToolsetBin;
}
