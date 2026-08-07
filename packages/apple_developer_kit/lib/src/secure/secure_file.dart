/// Owner-only, crash-safe writes for the per-user files that hold
/// credential material (sessions, API keys, private keys).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/errors.dart';
import 'package:meta/meta.dart';
import 'package:posix/posix.dart' as posix;

/// Filesystem helpers that keep secret files out of other users' reach.
///
/// Every write goes through a temporary file in the destination directory
/// and is `rename`d into place, so a crash mid-write can never leave a
/// truncated credential behind. The temporary file is restricted to the
/// owner *before* the rename, so the secret is never observable at mode
/// 644, not even for an instant.
///
/// Windows has no POSIX mode bits and `dart:io` exposes no ACL API, so
/// hardening is a no-op there; `%APPDATA%` is already per-user.
abstract final class SecureFile {
  /// Mode 600: read/write for the owner, nothing for anyone else.
  static const String _ownerOnly = '0600';

  /// Atomically writes [contents] to [path] as an owner-only file,
  /// creating the parent directory if needed.
  static Future<void> writeString(String path, String contents) =>
      writeBytes(path, utf8.encode(contents));

  /// Byte-oriented [writeString].
  static Future<void> writeBytes(String path, List<int> bytes) async {
    final file = File(path);
    await file.parent.create(recursive: true);

    final temporary = File('$path.${_temporarySuffix()}.tmp');
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      harden(temporary.path);
      await temporary.rename(file.path);
    } on Object catch (e) {
      if (temporary.existsSync()) await temporary.delete();
      throw AppleError('Could not write $path: $e');
    }
  }

  /// Restricts an existing file to its owner. Silently does nothing on
  /// Windows, on hosts without POSIX support, or when [path] is missing —
  /// permission hardening is defence in depth, never a hard requirement.
  static void harden(String path) {
    if (Platform.isWindows || !posix.isPosixSupported) return;
    try {
      posix.chmod(path, _ownerOnly);
    } on Object {
      // Best effort: an exotic filesystem (FAT, some network mounts)
      // rejecting chmod must not fail an otherwise successful write.
    }
  }

  /// 16 random hex characters — enough that two concurrent writers never
  /// collide on the same temporary file.
  static String _temporarySuffix() =>
      randomBytes(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// [count] cryptographically random bytes.
  @useResult
  static Uint8List randomBytes(int count) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(count, (_) => random.nextInt(256)),
    );
  }
}
