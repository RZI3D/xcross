import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/build/ios_plugins.dart';
import 'package:xcross/src/constants.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';
import 'package:xcross/src/util/process.dart';

/// Name of the synthetic package/product/binary-target that wraps the real
/// `Flutter.xcframework` as a SwiftPM binary target (SwiftPM binary-target
/// paths must be relative to their own package, so the framework can't be
/// referenced directly from the aggregate plugins package). Mirrors
/// flutter_tools' own `kFlutterGeneratedFrameworkSwiftPackageTargetName`.
const String _flutterFrameworkPackageName = 'FlutterFramework';

/// Name of our aggregate package/product/target that pulls in every SPM
/// plugin's native code.
const String _pluginsProductName = 'FlutterPluginsGenerated';

/// Result of building the aggregate Flutter-plugins Swift package.
class GeneratedPluginsBuildResult {
  /// Creates a result wrapping the built dylib's path.
  const GeneratedPluginsBuildResult({required this.libraryPath});

  /// Absolute path to the built `libFlutterPluginsGenerated.dylib`.
  final String libraryPath;
}

/// Synthesizes and builds a Swift Package Manager package that aggregates
/// every Flutter plugin's iOS SPM native code into one dynamic library,
/// cross-compiled on Linux via the same Darwin-SDK-backed `swift build
/// --swift-sdk` mechanism xtool itself uses.
///
/// Mirrors Flutter's own SPM plugin integration: a generated wrapper package
/// depending on every plugin package plus a `FlutterFramework` binary-target
/// wrapper around `Flutter.xcframework`. Two deliberate differences from
/// Flutter's tool: `.package(path:)` entries use absolute paths (there is no
/// committed Xcode project here to keep portable), and the aggregate is a
/// *dynamic* library, so it can be embedded as one extra `Frameworks/*.dylib`
/// and linked with a single flag instead of hand-deriving Swift-runtime
/// autolink flags for a static library.
abstract final class GeneratedPluginsPackage {
  /// Builds the aggregate dylib for the subset of [plugins] that use Swift
  /// Package Manager. Returns null if there is nothing to build.
  ///
  /// [projectRoot]        — Flutter project root (logging context only).
  /// [flutterXcframework] — Path to the real `Flutter.xcframework` (from
  ///                         `IosEngineCache.flutterXcframework`).
  /// [outputDir]           — Stable directory to synthesize the wrapper
  ///                         packages and run `swift build` in. Not deleted
  ///                         between calls, so SwiftPM's `.build` cache
  ///                         persists; only the generated `.swift` files are
  ///                         overwritten each call.
  static Future<GeneratedPluginsBuildResult?> build({
    required String projectRoot,
    required List<IosPlugin> plugins,
    required String flutterXcframework,
    required String outputDir,
  }) => Log.logStep(
    'Building Flutter plugins (Swift Package Manager)',
    () async {
      final spmPlugins = plugins
          .where((plugin) => plugin.usesSwiftPackageManager)
          .toList();
      if (spmPlugins.isEmpty) return null;

      Log.logTrace(
        'projectRoot=$projectRoot '
        'spmPlugins=${[for (final plugin in spmPlugins) plugin.name]}',
      );

      await writeGeneratedPackages(
        outputDir: outputDir,
        plugins: spmPlugins,
        flutterXcframework: flutterXcframework,
      );

      final swift = await ProcessRunner.locateTool('swift');
      final pluginsDir = p.join(outputDir, 'Plugins');
      final scratchPath = p.join(pluginsDir, '.build');
      // Real `Flutter.framework` (not our FlutterFramework binary-target
      // wrapper). Our own aggregate target resolves `import Flutter` via
      // that wrapper's declared package dependency, but individual
      // third-party plugin targets often don't declare any such dependency
      // in their own Package.swift at all — they rely on Xcode's implicit,
      // project-wide framework search paths to make `import Flutter` resolve
      // (verified against a real published plugin: its manifest lists zero
      // dependencies, yet its Swift source does `import Flutter`). A plain
      // `swift build` has no such implicit project-wide behaviour, so we
      // reproduce it ourselves with a build-wide `-Xswiftc -F` flag, applied
      // uniformly to every target's compile step regardless of what that
      // target's own manifest declares.
      final flutterFrameworkSlice = p.join(flutterXcframework, 'ios-arm64');
      await ProcessRunner.runChecked(
        swift,
        [
          'build',
          '--package-path',
          pluginsDir,
          '--configuration',
          'debug',
          '--swift-sdk',
          'arm64-apple-ios',
          '--scratch-path',
          scratchPath,
          '-Xswiftc',
          '-F',
          '-Xswiftc',
          flutterFrameworkSlice,
          // A plugin class can be marked `@available(iOS 16.0, *)` (etc.)
          // while its Package.swift's own `platforms:` floor stays lower —
          // real-world example: flutter_file_manager_ios declares iOS 12 at
          // the package level but gates its actual plugin class at iOS 16,
          // since only the underlying feature (not registration itself)
          // needs the newer OS. Our generated registrant has no per-plugin
          // `@available`/`#available` annotations (we don't parse Swift
          // source to learn each plugin's true floor), so without this flag
          // the call to `PluginClass.register(with:)` fails to compile.
          // Registration itself is lightweight glue — trusting the plugin
          // author's own availability gating for the actual feature code is
          // the right tradeoff here, same as disabling this check is a
          // common pattern for generated interop shims.
          //
          // `-disable-availability-checking` is a frontend-only flag, so it
          // must go through `-Xfrontend` — passing it as a bare `-Xswiftc`
          // argument crashes this SwiftPM version outright (a `try!` in its
          // own arg validation) instead of a normal compiler error.
          '-Xswiftc',
          '-Xfrontend',
          '-Xswiftc',
          '-disable-availability-checking',
          // Without this, the produced dylib's LC_ID_DYLIB defaults to an
          // absolute build-machine path. The final Runner binary, linked
          // against this dylib in a later pipeline step, would then embed that
          // same unusable absolute path in its own LC_LOAD_DYLIB and fail to
          // load at runtime on a real device with a `dyld: Library not loaded`
          // crash. Setting the install name to `@rpath/...` up front makes it
          // resolve via the `-rpath @executable_path/Frameworks` RunnerShim
          // already sets when linking Runner.
          '-Xlinker',
          '-install_name',
          '-Xlinker',
          '@rpath/lib$_pluginsProductName.dylib',
        ],
        inheritStdio: Log.isVerbose,
        label: 'swift build',
      );

      final libraryPath = p.join(
        scratchPath,
        'arm64-apple-ios',
        'debug',
        'lib$_pluginsProductName.dylib',
      );
      if (!File(libraryPath).existsSync()) {
        throw XcrossError(
          'GeneratedPluginsPackage: swift build did not produce the plugins '
          'library at $libraryPath',
        );
      }

      return GeneratedPluginsBuildResult(libraryPath: libraryPath);
    },
  );

  /// Writes the `FlutterFramework` and `Plugins` wrapper packages (manifests,
  /// registrant source, and the `Flutter.xcframework` symlink) under
  /// [outputDir], without invoking `swift build`. Split out from [build] so
  /// the file-synthesis logic is testable without a Swift toolchain.
  @visibleForTesting
  static Future<void> writeGeneratedPackages({
    required String outputDir,
    required List<IosPlugin> plugins,
    required String flutterXcframework,
  }) async {
    final frameworkDir = p.join(outputDir, _flutterFrameworkPackageName);
    final pluginsDir = p.join(outputDir, 'Plugins');

    await _writeFlutterFrameworkPackage(
      frameworkDir: frameworkDir,
      flutterXcframework: flutterXcframework,
    );
    await _writePluginsPackage(
      pluginsDir: pluginsDir,
      frameworkDir: frameworkDir,
      plugins: plugins,
    );
  }

  /// Writes `FlutterFramework/Package.swift` and the `Flutter.xcframework`
  /// symlink pointing at the real [flutterXcframework].
  static Future<void> _writeFlutterFrameworkPackage({
    required String frameworkDir,
    required String flutterXcframework,
  }) async {
    await Directory(frameworkDir).create(recursive: true);
    await File(
      p.join(frameworkDir, 'Package.swift'),
    ).writeAsString(flutterFrameworkManifest());

    final linkPath = p.join(frameworkDir, 'Flutter.xcframework');
    final existingLink = Link(linkPath);
    final existingDir = Directory(linkPath);
    if (existingLink.existsSync()) {
      await existingLink.delete();
    } else if (existingDir.existsSync()) {
      // Defensive: normal case is either nothing or a stale symlink from a
      // prior run, but guard against a real directory somehow landing here.
      await existingDir.delete(recursive: true);
    }
    await existingLink.create(flutterXcframework);
  }

  /// Writes `Plugins/Package.swift` and the generated registrant source.
  static Future<void> _writePluginsPackage({
    required String pluginsDir,
    required String frameworkDir,
    required List<IosPlugin> plugins,
  }) async {
    final sourcesDir = p.join(pluginsDir, 'Sources', _pluginsProductName);
    await Directory(sourcesDir).create(recursive: true);

    await File(
      p.join(pluginsDir, 'Package.swift'),
    ).writeAsString(pluginsManifest(plugins, frameworkDir));

    await File(
      p.join(sourcesDir, 'GeneratedPluginRegistrant.swift'),
    ).writeAsString(registrantSource(plugins));
  }

  /// `FlutterFramework/Package.swift` contents — wraps `Flutter.xcframework`
  /// as a SwiftPM binary target.
  @visibleForTesting
  static String flutterFrameworkManifest() =>
      '''
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "$_flutterFrameworkPackageName",
    products: [
        .library(name: "$_flutterFrameworkPackageName", targets: ["$_flutterFrameworkPackageName"])
    ],
    targets: [
        .binaryTarget(name: "$_flutterFrameworkPackageName", path: "Flutter.xcframework")
    ]
)
''';

  /// `Plugins/Package.swift` contents — aggregates every plugin's SPM package
  /// into one dynamic library product depending on [frameworkDir]'s
  /// `FlutterFramework` package plus every entry in [plugins].
  @visibleForTesting
  static String pluginsManifest(List<IosPlugin> plugins, String frameworkDir) {
    final dependencies = StringBuffer()
      ..writeln(
        '        .package(name: "$_flutterFrameworkPackageName", '
        'path: "${_swiftPath(frameworkDir)}"),',
      );
    for (final plugin in plugins) {
      dependencies.writeln(
        '        .package(name: "${plugin.name}", '
        'path: "${_swiftPath(plugin.swiftPackageDir)}"),',
      );
    }

    final targetDependencies = StringBuffer()
      ..writeln(
        '                .product(name: "$_flutterFrameworkPackageName", '
        'package: "$_flutterFrameworkPackageName"),',
      );
    for (final plugin in plugins) {
      targetDependencies.writeln(
        '                .product(name: "${_hyphenate(plugin.name)}", '
        'package: "${plugin.name}"),',
      );
    }

    return '''
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "$_pluginsProductName",
    platforms: [
        .iOS("${IosDeploymentConstants.minDeploymentTarget}")
    ],
    products: [
        .library(name: "$_pluginsProductName", type: .dynamic, targets: ["$_pluginsProductName"])
    ],
    dependencies: [
$dependencies    ],
    targets: [
        .target(
            name: "$_pluginsProductName",
            dependencies: [
$targetDependencies            ]
        )
    ]
)
''';
  }

  /// `GeneratedPluginRegistrant.swift` contents — imports every plugin and
  /// registers each one that has a non-null `pluginClassIos`. Plugins with no
  /// `pluginClassIos` (facade/pure-Dart/FFI-only packages) are imported but
  /// silently skipped in the registration body, since they have nothing to
  /// register.
  @visibleForTesting
  static String registrantSource(List<IosPlugin> plugins) {
    final imports = StringBuffer();
    for (final plugin in plugins) {
      imports.writeln('import ${plugin.name}');
    }

    final registrations = StringBuffer();
    for (final plugin in plugins) {
      final pluginClass = plugin.pluginClassIos;
      if (pluginClass == null) continue;
      registrations.writeln('''
    if let registrar = registry.registrar(forPlugin: "$pluginClass") {
        $pluginClass.register(with: registrar)
    }''');
    }

    return '''
//
// Generated file. Do not edit.
//
import Flutter
import UIKit
$imports
@_cdecl("${GeneratedPluginsConstants.registrantSymbol}")
public func xcrossRegisterGeneratedPlugins(_ registry: FlutterPluginRegistry) {
$registrations}
''';
  }

  /// Forward-slash-safe absolute path for interpolation into a Swift string
  /// literal. Production only runs on Linux, but this guards the test suite
  /// running on a non-POSIX path separator.
  static String _swiftPath(String path) =>
      p.absolute(path).replaceAll(r'\', '/');

  /// A pub package name with underscores replaced by hyphens — SwiftPM's own
  /// convention for a plugin's SPM library product name (used as the
  /// CFBundleIdentifier for dynamic products, which can't contain
  /// underscores). The `package:` argument stays underscored, matching the
  /// plugin's own unmodified `Package(name: ...)`.
  static String _hyphenate(String name) => name.replaceAll('_', '-');
}
