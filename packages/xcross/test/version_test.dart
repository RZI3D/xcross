import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';
import 'package:xcross/src/update/semver.dart';
import 'package:xcross/src/version.dart';

final String _packageRoot = File.fromUri(
  Isolate.resolvePackageUriSync(Uri.parse('package:xcross/xcross.dart'))!,
).parent.parent.path;

String _pubspecVersion() {
  final pubspec = File('$_packageRoot/pubspec.yaml').readAsStringSync();
  final match = RegExp(
    r'^version:\s*(\S+)\s*$',
    multiLine: true,
  ).firstMatch(pubspec);
  expect(match, isNotNull, reason: 'pubspec.yaml has no version: entry');
  return match![1]!;
}

void main() {
  test('the committed version is a well-formed semver', () {
    expect(XcrossSemver.tryParse(XcrossVersion.current), isNotNull);
  });

  // CI stamps this constant from the git tag right before `dart build cli`.
  // A stamped file reaching the repository would make every later dev build
  // claim to be a release, so the committed value must stay a pre-release.
  test('the committed version is never a stamped release', () {
    expect(XcrossVersion.current, endsWith('-dev'));
    expect(XcrossVersion.isDev, isTrue);
  });

  test('the committed version tracks pubspec.yaml', () {
    final declared = XcrossSemver.tryParse(_pubspecVersion());
    final current = XcrossSemver.tryParse(XcrossVersion.current);
    expect(declared, isNotNull);
    expect(current, isNotNull);
    expect(
      [current!.major, current.minor, current.patch],
      [declared!.major, declared.minor, declared.patch],
      reason: 'bump lib/src/version.dart alongside pubspec.yaml',
    );
  });

  test('describe() marks an unreleased build', () {
    expect(XcrossVersion.describe(), contains(XcrossVersion.current));
    expect(XcrossVersion.describe(), contains('unreleased build'));
  });
}
