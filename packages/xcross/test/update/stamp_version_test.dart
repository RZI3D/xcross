import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final String _packageRoot = File.fromUri(
  Isolate.resolvePackageUriSync(Uri.parse('package:xcross/xcross.dart'))!,
).parent.parent.path;

final String _toolPath = p.join(_packageRoot, 'tool', 'stamp_version.dart');

void main() {
  late Directory sandbox;

  /// A throwaway copy of the package layout the tool rewrites, so the test
  /// never touches the real lib/src/version.dart and never needs git.
  void seed({String pubspecVersion = '1.0.0', String? versionSource}) {
    File(
      p.join(sandbox.path, 'pubspec.yaml'),
    ).writeAsStringSync('name: xcross\nversion: $pubspecVersion\n');
    final lib = Directory(p.join(sandbox.path, 'lib', 'src'))
      ..createSync(recursive: true);
    File(p.join(lib.path, 'version.dart')).writeAsStringSync(
      versionSource ??
          File(
            p.join(_packageRoot, 'lib', 'src', 'version.dart'),
          ).readAsStringSync(),
    );
  }

  ProcessResult stamp(String tag) => Process.runSync(
    Platform.resolvedExecutable,
    ['run', _toolPath, tag],
    workingDirectory: sandbox.path,
  );

  String stampedConstant() =>
      RegExp("static const String current = '([^']*)';").firstMatch(
        File(
          p.join(sandbox.path, 'lib', 'src', 'version.dart'),
        ).readAsStringSync(),
      )![1]!;

  setUp(() => sandbox = Directory.systemTemp.createTempSync('xcross-stamp-'));
  tearDown(() => sandbox.deleteSync(recursive: true));

  test('stamps a bare tag', () {
    seed();
    final result = stamp('1.0.0');
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(stampedConstant(), '1.0.0');
    expect(result.stdout, contains('stamped'));
  });

  test('strips a leading v', () {
    seed();
    expect(stamp('v1.0.0').exitCode, 0);
    expect(stampedConstant(), '1.0.0');
  });

  test('the stamped file is still valid Dart', () {
    seed();
    expect(stamp('1.0.0').exitCode, 0);
    final probe = File(p.join(sandbox.path, 'probe.dart'))
      ..writeAsStringSync(
        "import 'lib/src/version.dart';\n"
        'void main() => print(XcrossVersion.describe());\n',
      );
    final run = Process.runSync(Platform.resolvedExecutable, [
      'run',
      probe.path,
    ], workingDirectory: sandbox.path);
    expect(run.exitCode, 0, reason: '${run.stderr}');
    expect(run.stdout, contains('xcross 1.0.0'));
    expect(run.stdout, isNot(contains('unreleased')));
  });

  test('refuses a tag that disagrees with pubspec.yaml', () {
    seed();
    final result = stamp('1.2.3');
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('does not match pubspec version'));
    expect(stampedConstant(), '1.0.0-dev', reason: 'must not have been edited');
  });

  test('refuses a malformed tag', () {
    seed();
    for (final bad in ['latest', '1.0', 'release-1.0.0', '']) {
      final result = stamp(bad);
      expect(result.exitCode, isNot(0), reason: 'accepted "$bad"');
      expect(stampedConstant(), '1.0.0-dev');
    }
  });

  test('refuses a version.dart whose constant moved', () {
    seed(versionSource: 'abstract final class XcrossVersion {}\n');
    final result = stamp('1.0.0');
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('could not find'));
  });

  test('rejects a wrong argument count', () {
    seed();
    final result = Process.runSync(Platform.resolvedExecutable, [
      'run',
      _toolPath,
    ], workingDirectory: sandbox.path);
    expect(result.exitCode, 64);
    expect(result.stderr, contains('usage:'));
  });
}
