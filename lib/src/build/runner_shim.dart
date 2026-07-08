// Port of Sources/PackLib/FlutterPacker.swift (compileRunnerViaObjC section ~L304-421)
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;
import 'package:xcross/src/build/ios_engine_cache.dart' show locateTool;
import 'package:xcross/src/constants/ios_deployment_constants.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';
import 'package:xcross/src/util/process.dart';
import 'package:xcross/src/xtool/darwin_sdk.dart';

/// Embeds the ObjC Runner.m source, compiles it with clang, and links it with
/// ld64.lld to produce the `Runner` executable for an iOS `.app` bundle.
///
/// This is the cross-platform (Linux) equivalent of the Xcode-built Runner.
class RunnerShim {
  /// Compile and link the Runner binary.
  ///
  /// [projectRoot]        — Flutter project root (used for output staging).
  /// [sdk]                — Resolved [DarwinSdk] (provides sysroot + ld64.lld).
  /// [flutterXcframework] — Path to `Flutter.xcframework`.
  /// [outputDir]          — Directory where `Runner` binary is written.
  ///
  /// Returns path to the linked `Runner` executable.
  /// (FlutterPacker.swift: compileRunnerViaObjC() ~L304)
  static Future<String> buildRunnerBinary({
    required String projectRoot,
    required DarwinSdk sdk,
    required String flutterXcframework,
    required String outputDir,
  }) async {
    logStatus(
        '[xcross] compiling Runner via clang/ld64.lld Objective-C shim...');

    final clang = await locateTool('clang');
    final iosSdk = _resolveIPhoneOsSDK(sdk);
    final flutterSlice = _flutterDeviceSlice(flutterXcframework);
    final subframeworks = p.join(iosSdk, 'System', 'Library', 'SubFrameworks');

    await Directory(outputDir).create(recursive: true);
    final sourcePath = p.join(outputDir, 'Runner.m');
    final objectPath = p.join(outputDir, 'Runner.o');
    final outputPath = p.join(outputDir, 'Runner');

    await File(sourcePath).writeAsString(_runnerObjcSource);

    // Compile: Runner.m → Runner.o (FlutterPacker.swift: compileArgs ~L370-380)
    await _compileObject(
      clang: clang,
      sourcePath: sourcePath,
      objectPath: objectPath,
      iosSdk: iosSdk,
      subframeworks: subframeworks,
      flutterSlice: flutterSlice,
    );

    // Link: Runner.o → Runner via ld64.lld (FlutterPacker.swift: linkArgs ~L389-404)
    final sdkVersion =
        _sdkVersion(iosSdk) ?? '26.5'; // fallback iOS SDK version
    await _linkBinary(
      ld64lld: sdk.ld64lld,
      objectPath: objectPath,
      outputPath: outputPath,
      iosSdk: iosSdk,
      flutterSlice: flutterSlice,
      subframeworks: subframeworks,
      sdkVersion: sdkVersion,
    );

    final outputExists = File(outputPath).existsSync();
    if (!outputExists) {
      throw XcrossError(
          'RunnerShim: clang/ld64.lld did not produce Runner at $outputPath');
    }

    // Make the Runner executable via libc chmod (FFI) — no subprocess.
    if (posix.isPosixSupported) {
      posix.chmod(outputPath, '0755');
    } // (FlutterPacker.swift ~L416)
    final size = await File(outputPath).length();
    logStatus(
        '[xcross] Runner binary produced: $outputPath (${size ~/ 1024} KB)');

    return outputPath;
  }

  // ---------------------------------------------------------------------------
  // Private step helpers
  // ---------------------------------------------------------------------------

  /// Compile [sourcePath] to [objectPath] via clang.
  /// (FlutterPacker.swift: compileArgs ~L370-380)
  static Future<void> _compileObject({
    required String clang,
    required String sourcePath,
    required String objectPath,
    required String iosSdk,
    required String subframeworks,
    required String flutterSlice,
  }) async {
    logStatus('[clang] compile Runner.m → Runner.o');
    await ProcessRunner.runChecked(
      clang,
      [
        '-target',
        IosDeploymentConstants.buildTriple,
        '-isysroot',
        iosSdk,
        '-F',
        subframeworks,
        '-F',
        flutterSlice,
        '-I',
        p.join(flutterSlice, 'Flutter.framework', 'Headers'),
        '-fobjc-arc',
        '-miphoneos-version-min=${IosDeploymentConstants.minDeploymentTarget}',
        '-c',
        sourcePath,
        '-o',
        objectPath,
      ],
      inheritStdio: true,
      label: 'clang',
    );
  }

  /// Link [objectPath] to [outputPath] via ld64.lld.
  /// (FlutterPacker.swift: linkArgs ~L389-404)
  static Future<void> _linkBinary({
    required String ld64lld,
    required String objectPath,
    required String outputPath,
    required String iosSdk,
    required String flutterSlice,
    required String subframeworks,
    required String sdkVersion,
  }) async {
    logStatus('[ld64.lld] link Runner.o → Runner');
    await ProcessRunner.runChecked(
      ld64lld,
      [
        '-arch',
        'arm64',
        '-platform_version',
        'ios',
        IosDeploymentConstants.minDeploymentTarget,
        sdkVersion,
        '-syslibroot',
        iosSdk,
        '-o',
        outputPath,
        objectPath,
        '-F',
        flutterSlice,
        '-F',
        p.join(iosSdk, 'System', 'Library', 'Frameworks'),
        '-F',
        subframeworks,
        '-framework',
        'Flutter',
        '-framework',
        'UIKit',
        '-framework',
        'Foundation',
        '-lobjc',
        '-lc',
        '-rpath',
        '@executable_path/Frameworks',
      ],
      inheritStdio: true,
      label: 'ld64.lld',
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Prefer the generic `iPhoneOS.sdk` symlink; fall back to the versioned SDK.
  /// (FlutterPacker.swift: clangIPhoneOSSDK ~L423-430)
  static String _resolveIPhoneOsSDK(DarwinSdk sdk) {
    final generic = p.join(
      sdk.bundle,
      'Developer',
      'Platforms',
      'iPhoneOS.platform',
      'Developer',
      'SDKs',
      'iPhoneOS.sdk',
    );
    final genericSdkExists = Directory(generic).existsSync();
    if (genericSdkExists) return generic;
    return sdk.iPhoneOSSdk();
  }

  /// Returns the `ios-arm64` slice directory inside [xcframework].
  /// (FlutterPacker.swift: flutterDeviceSlice ~L432-439)
  static String _flutterDeviceSlice(String xcframework) {
    final slice = p.join(xcframework, 'ios-arm64');
    final framework = p.join(slice, 'Flutter.framework');
    final frameworkExists = Directory(framework).existsSync();
    if (!frameworkExists) {
      throw XcrossError(
          'RunnerShim: Flutter device slice not found at $framework');
    }
    return slice;
  }

  /// Extract version number from SDK dir name, e.g. `iPhoneOS17.5.sdk` → `17.5`.
  /// (FlutterPacker.swift: sdkVersion ~L441-446)
  static String? _sdkVersion(String sdkPath) {
    final name = p.basenameWithoutExtension(sdkPath);
    if (!name.startsWith('iPhoneOS')) return null;
    final version = name.substring('iPhoneOS'.length);
    return version.isEmpty ? null : version;
  }

  // ---------------------------------------------------------------------------
  // Runner.m source (FlutterPacker.swift ~L331-366)
  // ---------------------------------------------------------------------------

  /// Minimal ObjC Runner that boots Flutter via FlutterAppDelegate.
  /// Mirrors the synthesized source in the Swift port of compileRunnerViaObjC.
  static const _runnerObjcSource = '''
#import <UIKit/UIKit.h>
#import <Flutter/Flutter.h>

@interface GeneratedPluginRegistrant : NSObject
+ (void)registerWithRegistry:(NSObject<FlutterPluginRegistry>*)registry;
@end
@implementation GeneratedPluginRegistrant
+ (void)registerWithRegistry:(NSObject<FlutterPluginRegistry>*)registry {}
@end

@interface AppDelegate : FlutterAppDelegate <FlutterImplicitEngineDelegate>
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
  FlutterViewController* flutterViewController = [[FlutterViewController alloc] initWithProject:nil nibName:nil bundle:nil];
  UIWindow* window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
  window.rootViewController = flutterViewController;
  [window makeKeyAndVisible];
  self.window = window;
  return [super application:application didFinishLaunchingWithOptions:launchOptions];
}
- (void)didInitializeImplicitFlutterEngine:(NSObject<FlutterImplicitEngineBridge>*)engineBridge {
  [GeneratedPluginRegistrant registerWithRegistry:engineBridge.pluginRegistry];
}
@end

@interface SceneDelegate : FlutterSceneDelegate
@end
@implementation SceneDelegate
@end

int main(int argc, char * argv[]) {
  @autoreleasepool { return UIApplicationMain(argc, argv, nil, @"AppDelegate"); }
}
''';
}
