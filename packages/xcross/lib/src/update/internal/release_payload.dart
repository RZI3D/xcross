import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/update/internal/archive_entry_path.dart';

/// The `bin/` + `lib/` payload unpacked from a release archive.
///
/// A downloaded archive is untrusted input, so every entry is validated before
/// it becomes a path and anything outside the two payload directories is
/// ignored rather than written.
abstract final class ReleasePayload {
  /// Directories an update replaces. The Windows zip also ships `LICENSE` and
  /// `THIRD_PARTY_LICENSES/`, which the installers place but updates leave
  /// alone.
  static const payloadDirs = {'bin', 'lib'};

  /// Unpacks [bytes] into [destination] and checks the result is a usable
  /// bundle.
  ///
  /// [asset] selects the container format and names the archive in errors.
  /// [executableName] is the binary the bundle must contain.
  static Future<void> extract({
    required List<int> bytes,
    required String asset,
    required Directory destination,
    required String executableName,
  }) async {
    final archive = asset.endsWith('.zip')
        ? ZipDecoder().decodeBytes(bytes)
        : TarDecoder().decodeBytes(const GZipDecoder().decodeBytes(bytes));

    await destination.create(recursive: true);
    for (final entry in archive) {
      // `isFile` stays true for a tar symlink entry, whose payload is a target
      // path rather than content; writing it would produce a plausible-looking
      // but empty binary.
      if (entry.isSymbolicLink) {
        throw XcrossError(
          'refusing to extract $asset: link entry "${entry.name}"',
        );
      }
      if (!entry.isFile) continue;
      final target = ArchiveEntryPath.resolve(destination.path, entry.name);
      if (target == null) {
        throw XcrossError(
          'refusing to extract $asset: unsafe entry "${entry.name}"',
        );
      }
      final relative = p.split(p.relative(target, from: destination.path));
      if (relative.length < 2 || !payloadDirs.contains(relative.first)) {
        continue;
      }
      await Directory(p.dirname(target)).create(recursive: true);
      await File(target).writeAsBytes(entry.content);
    }

    _assertComplete(
      destination: destination,
      asset: asset,
      executableName: executableName,
    );
  }

  /// A half-populated payload must be caught here, before anything installed
  /// is touched.
  static void _assertComplete({
    required Directory destination,
    required String asset,
    required String executableName,
  }) {
    final binary = File(p.join(destination.path, 'bin', executableName));
    if (!binary.existsSync() || binary.lengthSync() == 0) {
      throw XcrossError('$asset is missing bin/$executableName');
    }
    final libDir = Directory(p.join(destination.path, 'lib'));
    if (!libDir.existsSync() || libDir.listSync().isEmpty) {
      throw XcrossError('$asset is missing its lib/ payload');
    }
  }
}
