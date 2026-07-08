// Port of Sources/PackLib/DarwinSDKLocator.swift
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:xcross/src/util/errors.dart';

/// Locates an installed xtool Darwin SDK on the local machine and exposes path
/// accessors for the parts needed to drive clang/ld invocations directly
/// (without `xcrun`).
///
class DarwinSdk {
  /// Bundle root, e.g. `~/.swiftpm/swift-sdks/darwin.artifactbundle`.
  final String bundle;

  static final RegExp _digitPattern = RegExp('[0-9]');

  DarwinSdk(this.bundle);

  // ---------------------------------------------------------------------------
  // DarwinSDKLocator.swift: searchRoots() + current()
  // ---------------------------------------------------------------------------

  /// All locations xtool may install the Darwin SDK into. First match wins.
  static List<String> _searchRoots() {
    final home = _homeDir();
    return [
      // SwiftPM canonical location (set by `swift sdk install`).
      p.join(home, '.swiftpm', 'swift-sdks', 'darwin.artifactbundle'),
      p.join(home, '.swiftpm', 'swift-sdks', 'darwin.xtoolsdk'),
      // macOS fallback path.
      p.join(home, 'Library', 'org.swift.swiftpm', 'swift-sdks',
          'darwin.artifactbundle'),
      p.join(home, 'Library', 'org.swift.swiftpm', 'swift-sdks',
          'darwin.xtoolsdk'),
    ];
  }

  /// Resolve the SDK installed by `xtool sdk install`. Returns null if not
  /// installed. (DarwinSDKLocator.swift: current())
  static DarwinSdk? current() {
    for (final candidate in _searchRoots()) {
      if (_isValidBundle(candidate)) return DarwinSdk(candidate);
    }
    return null;
  }

  /// Returns true if [candidate] looks like a valid installed Darwin SDK bundle.
  static bool _isValidBundle(String candidate) {
    // Accept if version marker exists.
    final versionFileExists =
        File(p.join(candidate, 'darwin-sdk-version.txt')).existsSync();
    if (versionFileExists) {
      return true;
    }
    // Or if the canonical SDK sub-tree exists.
    final sdksPath = p.join(
      candidate,
      'Developer',
      'Platforms',
      'iPhoneOS.platform',
      'Developer',
      'SDKs',
    );
    return Directory(sdksPath).existsSync();
  }

  // ---------------------------------------------------------------------------
  // DarwinSDKLocator.swift: toolset paths
  // ---------------------------------------------------------------------------

  /// `<bundle>/toolset/bin/ld64.lld` — Apple-compatible linker on Linux.
  String get ld64lld => p.join(bundle, 'toolset', 'bin', 'ld64.lld');

  /// `<bundle>/toolset/bin/dsymutil`.
  String get dsymutil => p.join(bundle, 'toolset', 'bin', 'dsymutil');

  /// `<bundle>/toolset/bin/libtool` (= llvm-libtool-darwin).
  String get libtool => p.join(bundle, 'toolset', 'bin', 'libtool');

  // ---------------------------------------------------------------------------
  // DarwinSDKLocator.swift: iPhoneOSSDK() + firstSDK(in:prefix:)
  // ---------------------------------------------------------------------------

  String _sdksDir(String platform) => p.join(
        bundle,
        'Developer',
        'Platforms',
        '$platform.platform',
        'Developer',
        'SDKs',
      );

  /// First versioned iPhoneOSXX.X.sdk found, else first .sdk under the
  /// platform. Throws [XcrossError] if missing.
  /// (DarwinSDKLocator.swift: iPhoneOSSDK())
  String iPhoneOSSdk() {
    final dir = _sdksDir('iPhoneOS');
    final pick = _firstSdk(dir, 'iPhoneOS');
    if (pick == null) {
      throw XcrossError(
        'DarwinSdk: Could not find iPhoneOS SDK under $dir.\n'
        "Install xtool's Darwin SDK with `xtool sdk install <Xcode.xip|Xcode.app>`.",
      );
    }
    return pick;
  }

  /// Returns the first matching `.sdk` directory under [dir] with the given
  /// [prefix], preferring versioned names (e.g. `iPhoneOS17.5.sdk`) over
  /// unversioned symlinks. (DarwinSDKLocator.swift: firstSDK(in:prefix:))
  static String? _firstSdk(String dir, String prefix) {
    final sdkDirExists = Directory(dir).existsSync();
    if (!sdkDirExists) return null;
    final entries =
        Directory(dir).listSync().map((e) => p.basename(e.path)).toList();

    // Prefer versioned (e.g. iPhoneOS17.5.sdk) over generic symlink.
    final versioned = entries
        .where(
          (e) =>
              e.startsWith(prefix) &&
              e.endsWith('.sdk') &&
              e.contains(_digitPattern),
        )
        .firstOrNull;

    final pick = versioned ??
        entries
            .where((e) => e.startsWith(prefix) && e.endsWith('.sdk'))
            .firstOrNull;

    return pick != null ? p.join(dir, pick) : null;
  }

  static String _homeDir() =>
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '/root';
}
