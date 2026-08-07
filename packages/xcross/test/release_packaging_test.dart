import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

final String _repoRoot = File.fromUri(
  Isolate.resolvePackageUriSync(Uri.parse('package:xcross/xcross.dart'))!,
).parent.parent.parent.parent.path;

void main() {
  test('release publishes only xcross artifacts and keeps attribution', () {
    final workflow = File(
      '$_repoRoot/.github/workflows/release.yml',
    ).readAsStringSync();

    for (final expected in [
      'native/signing/ZSIGN_LICENSE.txt',
      'dist/THIRD_PARTY_LICENSES/zsign.txt',
      "'THIRD_PARTY_LICENSES/zsign.txt'",
      'packages/apple_developer_kit/ADI_LICENSE',
      'dist/THIRD_PARTY_LICENSES/provision-dart.txt',
      "'THIRD_PARTY_LICENSES/provision-dart.txt'",
      'dart analyze',
      'dart test packages/cli_kit',
      'dart test packages/apple_developer_kit',
      'dart test packages/darwin_sdk_kit',
      'dart test packages/dart_mobile_device',
      'dart test packages/frontend_server_kit',
      'dart pub publish --dry-run',
      'dart build cli',
      r'dart run tool/stamp_version.dart "$RELEASE_TAG"',
      r'dart run tool/stamp_version.dart $env:RELEASE_TAG',
      "if: startsWith(github.ref, 'refs/tags/')",
      r'gh release create "$tag"',
      'dist/xcross-linux-x64.tar.gz',
      'dist/xcross-linux-arm64.tar.gz',
      'dist/xcross-windows-x64.zip',
      'native/signing/ZSIGN_LICENSE.txt',
      'bin/xcross.exe',
      'lib/sysv_abi_bridge.dll',
      'smoke/bin/xcross.exe --help',
    ]) {
      expect(workflow, contains(expected));
    }
    expect(
      workflow
          .split('\n')
          .where((line) => line.toLowerCase().contains('zsign'))
          .map((line) => line.trim()),
      orderedEquals([
        'native/signing/ZSIGN_LICENSE.txt `',
        'dist/THIRD_PARTY_LICENSES/zsign.txt',
        "'THIRD_PARTY_LICENSES/zsign.txt'",
        r'native/signing/ZSIGN_LICENSE.txt \',
      ]),
    );
    // Both build jobs must stamp, and only on a tag: an unstamped release
    // would ship a binary that reports itself as an unreleased dev build.
    expect(
      'dart run tool/stamp_version.dart'.allMatches(workflow).length,
      2,
      reason: 'the Linux and Windows jobs must both stamp the version',
    );
    expect(
      RegExp(
        r'- name: Stamp release version\n\s+if: '
        r"startsWith\(github\.ref, 'refs/tags/'\)",
      ).allMatches(workflow).length,
      2,
      reason: 'stamping must be gated on a tag ref in both jobs',
    );

    // Stamping before the validation steps would publish-validate a dirty
    // tree; stamping after the build would ship an unstamped binary.
    final stamps = 'dart run tool/stamp_version.dart'
        .allMatches(workflow)
        .map((m) => m.start)
        .toList();
    expect(workflow.indexOf('dart pub publish --dry-run'), lessThan(stamps[0]));
    expect(stamps[0], lessThan(workflow.indexOf('- name: Compile binary')));
    expect(
      workflow.indexOf('dart test packages/frontend_server_kit', stamps[0]),
      lessThan(stamps[1]),
    );
    expect(stamps[1], lessThan(workflow.indexOf('- name: Build xcross')));

    for (final removed in [
      'libssl-dev',
      'microsoft/setup-msbuild',
      'make -C',
      'msbuild ',
    ]) {
      expect(workflow, isNot(contains(removed)));
    }
  });

  test('installer installs xcross plus its required license notice', () {
    final installer = File('$_repoRoot/install.sh').readAsStringSync();

    for (final expected in [
      'xcross-linux-x64.tar.gz',
      'xcross-linux-arm64.tar.gz',
      'NOTICE="ZSIGN_LICENSE.txt"',
      r'tmp="$(mktemp -d)"',
      r'''trap 'rm -rf "$tmp"' EXIT HUP INT TERM''',
      r'download "$url" "$tmp/$asset"',
      r'download "$notice_url" "$tmp/$NOTICE"',
      r'tar -C "$tmp" -xzf "$tmp/$asset"',
      r'install -m 0755 "$tmp/bin/xcross" "$target"',
      r'install -m 0644 "$tmp/$NOTICE" "$notice_target"',
      r'"$target" --help',
    ]) {
      expect(installer, contains(expected));
    }
    for (final removed in ['zsign-linux', 'zsign.exe', 'XCROSS_ZSIGN_PATH']) {
      expect(installer, isNot(contains(removed)));
    }
  });

  test('Windows installer installs release zip under LOCALAPPDATA', () {
    final installer = File('$_repoRoot/install.ps1').readAsStringSync();

    for (final expected in [
      'xcross-windows-x64.zip',
      'LOCALAPPDATA',
      'sysv_abi_bridge.dll',
      r'bin\xcross.exe',
      '--help',
      r"Join-Path $env:LOCALAPPDATA 'xcross'",
      'SetEnvironmentVariable',
    ]) {
      expect(installer, contains(expected));
    }
    for (final removed in ['zsign.exe', 'XCROSS_ZSIGN_PATH']) {
      expect(installer, isNot(contains(removed)));
    }
  });
}
