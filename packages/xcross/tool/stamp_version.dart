import 'dart:io';

/// Rewrites `XcrossVersion.current` in `lib/src/version.dart` from a git tag.
///
/// Usage: `dart run tool/stamp_version.dart <tag>` from `packages/xcross`.
/// The tag may carry a leading `v`. Exits non-zero when the tag is malformed,
/// disagrees with `pubspec.yaml`, or the constant cannot be located.
void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/stamp_version.dart <tag>');
    exit(64);
  }

  final packageRoot = Directory.current.path;
  final version = _normalizeTag(args.single);
  _assertMatchesPubspec(packageRoot, version);
  _rewriteVersionFile(packageRoot, version);

  stdout.writeln('stamped lib/src/version.dart -> $version');
}

final _semver = RegExp(r'^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$');
final _pubspecVersion = RegExp(r'^version:\s*(\S+)\s*$', multiLine: true);
final _currentConstant = RegExp("(static const String current = ')[^']*(';)");

String _normalizeTag(String tag) {
  final trimmed = tag.trim();
  final version = trimmed.startsWith('v') ? trimmed.substring(1) : trimmed;
  if (!_semver.hasMatch(version)) {
    stderr.writeln(
      'error: tag "$tag" is not a semver release '
      '(expected 1.2.3, optionally prefixed with v)',
    );
    exit(2);
  }
  return version;
}

/// A tag that disagrees with `pubspec.yaml` would ship a binary claiming a
/// version the package never declared, so the release fails here instead.
void _assertMatchesPubspec(String packageRoot, String version) {
  final pubspec = File('$packageRoot/pubspec.yaml');
  if (!pubspec.existsSync()) {
    stderr.writeln(
      'error: ${pubspec.path} not found; run from packages/xcross',
    );
    exit(3);
  }
  final declared = _pubspecVersion.firstMatch(pubspec.readAsStringSync())?[1];
  if (declared == null) {
    stderr.writeln('error: no version: entry in ${pubspec.path}');
    exit(3);
  }
  if (_core(declared) != _core(version)) {
    stderr.writeln(
      'error: tag $version does not match pubspec version $declared; '
      'bump pubspec.yaml before tagging',
    );
    exit(2);
  }
}

String _core(String version) => version.split(RegExp('[-+]')).first;

void _rewriteVersionFile(String packageRoot, String version) {
  final file = File('$packageRoot/lib/src/version.dart');
  if (!file.existsSync()) {
    stderr.writeln('error: ${file.path} not found');
    exit(3);
  }
  final source = file.readAsStringSync();
  if (!_currentConstant.hasMatch(source)) {
    stderr.writeln(
      'error: could not find `static const String current = ...` in '
      '${file.path}',
    );
    exit(3);
  }
  file.writeAsStringSync(
    source.replaceFirstMapped(
      _currentConstant,
      (match) => '${match[1]}$version${match[2]}',
    ),
  );
}
