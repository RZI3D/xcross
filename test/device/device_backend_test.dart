import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';
import 'package:xcross/src/device/device_backend.dart';

void main() {
  test('always resolves the native backend', () async {
    expect(await DeviceBackend.resolve(), isA<NativeBackend>());
  });

  test('rejects non-app inputs before provisioning mutates Apple state', () {
    final uri = Isolate.resolvePackageUriSync(
      Uri.parse('package:xcross/src/device/device_backend.dart'),
    )!;
    final source = File.fromUri(uri).readAsStringSync();
    final guard = source.indexOf(
      'in-process signer currently supports xcross-generated .app',
    );
    final provision = source.indexOf(
      'await AscProvisioning.provisionDevelopmentIdentity(',
    );

    expect(guard, greaterThanOrEqualTo(0));
    expect(provision, greaterThan(guard));
    expect(source, isNot(contains('ZsignCli')));
  });
}
