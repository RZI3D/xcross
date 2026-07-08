// Port of Sources/PackLib/IOSEngineCache.swift
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'package:xcross/src/constants/flutter_artifact_constants.dart';
import 'package:xcross/src/util/download.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';

/// Resolves Flutter iOS engine artifacts needed for a debug iOS bundle.
///
/// On macOS, `flutter precache --ios` downloads these into
/// `bin/cache/artifacts/engine/ios/`. On Linux, Flutter skips iOS artifacts,
/// so we fetch them ourselves from `storage.googleapis.com`.
///
class IosEngineCache {
  final String flutterRoot;

  IosEngineCache({required this.flutterRoot});

  // ---------------------------------------------------------------------------
  // IOSEngineCache.swift: paths
  // ---------------------------------------------------------------------------

  /// `bin/cache/artifacts/engine/ios/` — debug/JIT artifacts only.
  /// (IOSEngineCache.swift: engineDir; hardcoded to debug `ios` dir)
  String get engineDir =>
      p.join(flutterRoot, 'bin', 'cache', 'artifacts', 'engine', 'ios');

  /// Flutter.xcframework inside [engineDir].
  /// (IOSEngineCache.swift: flutterXCFramework)
  String get flutterXcframework => p.join(engineDir, 'Flutter.xcframework');

  /// `vm_isolate_snapshot.bin` from the host engine cache.
  /// (IOSEngineCache.swift: vmSnapshotData)
  String get vmSnapshotData => p.join(hostEngineDir, 'vm_isolate_snapshot.bin');

  /// `isolate_snapshot.bin` from the host engine cache.
  /// (IOSEngineCache.swift: isolateSnapshotData)
  String get isolateSnapshotData =>
      p.join(hostEngineDir, 'isolate_snapshot.bin');

  /// Host engine cache dir — where Flutter caches the host Dart engine.
  /// (IOSEngineCache.swift: hostEngineDir)
  String get hostEngineDir => p.join(
      flutterRoot, 'bin', 'cache', 'artifacts', 'engine', _hostEngineCacheDir);

  /// Path to the Dart frontend_server snapshot. Prefers the AOT variant
  /// (`frontend_server_aot.dart.snapshot`) for speed; falls back to the JIT
  /// variant. (IOSEngineCache.swift: frontendServer)
  String get frontendServer {
    final snapshotsDir =
        p.join(flutterRoot, 'bin', 'cache', 'dart-sdk', 'bin', 'snapshots');
    for (final name in [
      'frontend_server_aot.dart.snapshot',
      'frontend_server.dart.snapshot',
    ]) {
      final candidate = p.join(snapshotsDir, name);
      final candidateExists = File(candidate).existsSync();
      if (candidateExists) return candidate;
    }
    // Canonical fallback — used in error messages even if the file is missing.
    return p.join(snapshotsDir, 'frontend_server.dart.snapshot');
  }

  /// Patched SDK platform .dill — debug uses `flutter_patched_sdk/`.
  /// (IOSEngineCache.swift: patchedSDKRoot; hardcoded to debug variant)
  String get patchedSdkRoot => p.join(
        flutterRoot,
        'bin',
        'cache',
        'artifacts',
        'engine',
        'common',
        'flutter_patched_sdk',
      );

  // ---------------------------------------------------------------------------
  // IOSEngineCache.swift: engineHash()
  // ---------------------------------------------------------------------------

  /// Engine hash that pins the artifact set. Read from
  /// `bin/internal/engine.version` (stable/beta) or `bin/cache/engine.stamp`
  /// (written by flutter_tools at runtime). (IOSEngineCache.swift: engineHash())
  Future<String> engineHash() async {
    for (final rel in [
      p.join('bin', 'internal', 'engine.version'),
      p.join('bin', 'cache', 'engine.stamp'),
    ]) {
      final file = File(p.join(flutterRoot, rel));
      final fileExists = file.existsSync();
      if (fileExists) {
        final text = (await file.readAsString()).trim();
        if (text.isNotEmpty) return text;
      }
    }
    throw XcrossError(
      'IosEngineCache: Could not determine engine hash. Neither\n'
      'bin/internal/engine.version nor bin/cache/engine.stamp present under\n'
      '$flutterRoot. Run `<FLUTTER_ROOT>/bin/flutter --version` once to '
      'materialize the stamp.',
    );
  }

  // ---------------------------------------------------------------------------
  // IOSEngineCache.swift: ensureArtifactsAvailable()
  // ---------------------------------------------------------------------------

  /// Verify required iOS engine artifacts are present, downloading each set
  /// from `storage.googleapis.com` if missing. Safe to call repeatedly.
  /// (IOSEngineCache.swift: ensureArtifactsAvailable())
  Future<void> ensureArtifactsAvailable() async {
    final xcframeworkExists = Directory(flutterXcframework).existsSync();
    if (!xcframeworkExists) {
      await _downloadIosArtifacts();
    }
    final vmSnapshotExists = File(vmSnapshotData).existsSync();
    final isolateSnapshotExists = File(isolateSnapshotData).existsSync();
    if (!vmSnapshotExists || !isolateSnapshotExists) {
      await _downloadHostArtifacts();
    }
    final patchedSdkExists = Directory(patchedSdkRoot).existsSync();
    if (!patchedSdkExists) {
      await _downloadPatchedSdk();
    }
  }

  // ---------------------------------------------------------------------------
  // IOSEngineCache.swift: download helpers
  // ---------------------------------------------------------------------------

  Future<void> _downloadHostArtifacts() async {
    final hash = await engineHash();
    final url =
        '${FlutterArtifactConstants.baseUrl}/$hash/$_hostEngineCacheDir/artifacts.zip';
    logStatus('[curl] downloading Flutter host engine artifacts from $url');
    await _fetchAndExtract(url, hostEngineDir, 'host-artifacts-');
  }

  Future<void> _downloadIosArtifacts() async {
    final hash = await engineHash();
    final url = '${FlutterArtifactConstants.baseUrl}/$hash/ios/artifacts.zip';
    logStatus('[curl] downloading Flutter iOS engine artifacts from $url');
    await _fetchAndExtract(url, engineDir, 'ios-artifacts-');
  }

  Future<void> _downloadPatchedSdk() async {
    final hash = await engineHash();
    final leaf = p.basename(patchedSdkRoot);
    final url = '${FlutterArtifactConstants.baseUrl}/$hash/$leaf.zip';
    logStatus('[curl] downloading Flutter patched SDK from $url');
    await _fetchAndExtract(url, p.dirname(patchedSdkRoot), 'patched-sdk-');
  }

  /// Download [url] into a temp directory, extract into [destDir], then
  /// delete the temp directory.
  static Future<void> _fetchAndExtract(
    String url,
    String destDir,
    String tmpPrefix,
  ) async {
    await Directory(destDir).create(recursive: true);
    final tmp = await Directory.systemTemp.createTemp(tmpPrefix);
    final zipPath = p.join(tmp.path, 'artifacts.zip');
    await _downloadFile(url, zipPath);
    await _unzip(zipPath, destDir);
    await tmp.delete(recursive: true);
  }

  /// Stream [url] to [destination] in pure Dart (no `curl` subprocess).
  /// Follows redirects and retries transient failures. (IOSEngineCache.swift:
  /// downloadFile)
  static Future<void> _downloadFile(String url, String destination) async {
    await downloadToFile(url, File(destination), maxAttempts: 5);
  }

  /// Unzip [archive] into [directory] in pure Dart (no `unzip` subprocess).
  /// Restores unix permissions (exec bits) and symlinks via the archive
  /// package's posix-aware extractor. (IOSEngineCache.swift: unzip)
  static Future<void> _unzip(String archive, String directory) async {
    await extractFileToDisk(archive, directory);
  }

  // ---------------------------------------------------------------------------
  // Helpers (IOSEngineCache.swift: hostEngineCacheDir)
  // ---------------------------------------------------------------------------

  /// Platform-specific engine cache directory name.
  /// Mirrors `_HostArtifacts` in flutter_tools.
  static String get _hostEngineCacheDir {
    // linux: PROCESSOR_ARCHITECTURE → HOSTTYPE env-var cascade for arm detect.
    if (Platform.isLinux) {
      // Dart doesn't expose CPU arch directly; fall back to env vars.
      final arch = Platform.environment['PROCESSOR_ARCHITECTURE'] ??
          Platform.environment['HOSTTYPE'] ??
          '';
      return (arch.contains('arm') || arch.contains('aarch64'))
          ? 'linux-arm64'
          : 'linux-x64';
    }
    // darwin: Platform.version string → HOSTTYPE env-var cascade for arm detect.
    if (Platform.isMacOS) {
      // Dart 3+ embeds "arm64" in Platform.version on Apple Silicon.
      final isArm = Platform.version.contains('arm64') ||
          (Platform.environment['HOSTTYPE'] ?? '').contains('arm64');
      return isArm ? 'darwin-arm64' : 'darwin-x64';
    }
    // windows: always x64 (no arm64 variant published).
    if (Platform.isWindows) {
      return 'windows-x64';
    }
    // fallback: treat unknown platforms as linux-x64.
    return 'linux-x64';
  }
}

/// Search PATH for [name]. Falls back to `command -v` via a shell.
/// Minimal port of ToolRegistry.locate (ToolRegistry.swift).
/// Exported so sibling build files can reuse without duplication.
Future<String> locateTool(String name) async {
  final pathEnv = Platform.environment['PATH'] ?? '';
  for (final dir in pathEnv.split(':')) {
    final candidate = p.join(dir, name);
    final candidateExists = File(candidate).existsSync();
    if (candidateExists) return candidate;
  }
  // Fallback: shell `command -v`.
  final result = await Process.run('/bin/sh', ['-c', "command -v '$name'"]);
  final out = (result.stdout as String).trim();
  if (out.isNotEmpty) return out;
  throw XcrossError("Could not find '$name' in PATH.");
}
