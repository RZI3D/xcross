import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

final String _repoRoot = File.fromUri(
  Isolate.resolvePackageUriSync(Uri.parse('package:xcross/xcross.dart'))!,
).parent.parent.parent.parent.path;

/// Workspace packages must not deep-import each other's `lib/src/`.
void main() {
  test('no cross-package package:*/src/ imports outside owning package', () {
    final packages = [
      'xcross',
      'cli_kit',
      'apple_developer_kit',
      'darwin_sdk_kit',
      'dart_mobile_device',
      'frontend_server_kit',
      'xcross_flutter',
      'xcross_dap',
    ];
    final roots = [
      for (final name in packages) Directory('$_repoRoot/packages/$name'),
    ];

    final violations = <String>[];
    for (final root in roots) {
      if (!root.existsSync()) continue;
      for (final file in root.listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        final text = file.readAsStringSync();
        for (final pkg in packages) {
          final needle = 'package:$pkg/src/';
          if (!text.contains(needle)) continue;
          // Allowed only inside the owning package.
          final normalized = file.path.replaceAll(r'\', '/');
          final ownerPrefix = 'packages/$pkg/';
          if (normalized.contains(ownerPrefix)) continue;
          violations.add('${file.path}: $needle');
        }
      }
    }

    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
