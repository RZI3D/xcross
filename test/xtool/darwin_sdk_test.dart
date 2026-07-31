import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/xtool/darwin_sdk.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xcross_darwin_sdk-');
  });

  tearDown(() => tmp.delete(recursive: true));

  String sdksDir(String bundle) => p.join(
    bundle,
    'Developer',
    'Platforms',
    'iPhoneOS.platform',
    'Developer',
    'SDKs',
  );

  group('ld64lld', () {
    test('joins bundle with toolset/bin/ld64.lld', () {
      final sdk = DarwinSdk(tmp.path);
      expect(sdk.ld64lld, p.join(tmp.path, 'toolset', 'bin', 'ld64.lld'));
    });

    test('follows a different bundle root', () {
      final otherBundle = p.join(tmp.path, 'darwin.artifactbundle');
      final sdk = DarwinSdk(otherBundle);
      expect(sdk.ld64lld, p.join(otherBundle, 'toolset', 'bin', 'ld64.lld'));
    });
  });

  group('iPhoneOSSdk', () {
    // Regression check: a plain unversioned symlink/dir and a versioned SDK
    // can coexist (xtool installs both); the versioned one must win so the
    // linker gets the concrete SDK contents rather than a symlink target.
    test('prefers a versioned SDK over an unversioned one', () async {
      final dir = sdksDir(tmp.path);
      await Directory(p.join(dir, 'iPhoneOS.sdk')).create(recursive: true);
      await Directory(p.join(dir, 'iPhoneOS17.5.sdk')).create(recursive: true);

      final sdk = DarwinSdk(tmp.path);
      expect(sdk.iPhoneOSSdk(), p.join(dir, 'iPhoneOS17.5.sdk'));
    });

    test(
      'returns the only versioned SDK when no unversioned one exists',
      () async {
        final dir = sdksDir(tmp.path);
        await Directory(p.join(dir, 'iPhoneOS26.sdk')).create(recursive: true);

        final sdk = DarwinSdk(tmp.path);
        expect(sdk.iPhoneOSSdk(), p.join(dir, 'iPhoneOS26.sdk'));
      },
    );

    test('falls back to the unversioned SDK when it is the only one', () async {
      final dir = sdksDir(tmp.path);
      await Directory(p.join(dir, 'iPhoneOS.sdk')).create(recursive: true);

      final sdk = DarwinSdk(tmp.path);
      expect(sdk.iPhoneOSSdk(), p.join(dir, 'iPhoneOS.sdk'));
    });

    test(
      'throws XcrossError when the SDKs dir exists but has no matches',
      () async {
        await Directory(sdksDir(tmp.path)).create(recursive: true);

        final sdk = DarwinSdk(tmp.path);
        expect(
          sdk.iPhoneOSSdk,
          throwsA(
            isA<XcrossError>().having(
              (e) => e.message,
              'message',
              contains('Could not find iPhoneOS SDK'),
            ),
          ),
        );
      },
    );

    test('throws XcrossError when the SDKs dir does not exist', () {
      final sdk = DarwinSdk(tmp.path);
      expect(
        sdk.iPhoneOSSdk,
        throwsA(
          isA<XcrossError>().having(
            (e) => e.message,
            'message',
            contains('Could not find iPhoneOS SDK'),
          ),
        ),
      );
    });
  });
}
