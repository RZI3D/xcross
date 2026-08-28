import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/swiftpm_binary_artifact_store.dart';
import 'package:xcross/src/flutter/errors.dart';

void main() {
  late Directory temp;
  late SwiftPmBinaryArtifactStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('xcross_swiftpm_store-');
    store = SwiftPmBinaryArtifactStore(p.join(temp.path, 'store'));
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test('publishes and reuses a verified archive', () async {
    final bytes = utf8.encode('archive');
    final checksum = sha256.convert(bytes).toString();
    final first = File(p.join(temp.path, 'first.zip'))..writeAsBytesSync(bytes);

    final published = await store.publishArchive(first, checksum);
    final second = File(p.join(temp.path, 'second.zip'))
      ..writeAsBytesSync(bytes);
    final reused = await store.publishArchive(second, checksum);

    expect(published.path, store.archivePath(checksum));
    expect(await published.readAsBytes(), bytes);
    expect(reused.path, published.path);
  });

  test('canonicalizes archive and target checksum identity', () async {
    final bytes = utf8.encode('archive');
    final checksum = sha256.convert(bytes).toString();
    final archive = File(p.join(temp.path, 'archive.zip'))
      ..writeAsBytesSync(bytes);

    final published = await store.publishArchive(
      archive,
      checksum.toUpperCase(),
    );
    final target = await publishFixture(
      store,
      temp,
      checksum: 'ABC',
      target: 'A',
    );

    expect(published.path, store.archivePath(checksum));
    expect(
      store.archivePath(checksum.toUpperCase()),
      store.archivePath(checksum),
    );
    expect(store.targetRoot('ABC', 'A'), store.targetRoot('abc', 'A'));
    expect(target.archiveChecksum, 'abc');
    expect(await store.findCompleteTarget('abc', 'A'), isNotNull);
  });

  test('rejects an archive with a mismatched checksum', () async {
    final archive = File(p.join(temp.path, 'bad.zip'))
      ..writeAsStringSync('archive');

    await expectLater(
      store.publishArchive(archive, '0' * 64),
      throwsA(isA<FlutterBuildError>()),
    );
  });

  test('same archive supports distinct target entries', () async {
    final a = await publishFixture(store, temp, checksum: 'abc', target: 'A');
    final b = await publishFixture(store, temp, checksum: 'abc', target: 'B');

    expect(a.artifactPath, isNot(b.artifactPath));
    expect(store.archivePath('abc'), endsWith('abc.zip'));
    expect(await store.findCompleteTarget('abc', 'A'), isNotNull);
    expect(await store.findCompleteTarget('abc', 'B'), isNotNull);
  });

  test('separates target entries by checksum', () async {
    final a = await publishFixture(store, temp, checksum: 'abc', target: 'A');
    final b = await publishFixture(store, temp, checksum: 'def', target: 'A');

    expect(a.artifactPath, isNot(b.artifactPath));
  });

  test('does not reuse an entry without completion marker', () async {
    Directory(store.targetRoot('abc', 'A')).createSync(recursive: true);

    expect(await store.findCompleteTarget('abc', 'A'), isNull);
  });

  test('concurrent publication exposes one complete target', () async {
    final results = await Future.wait([
      publishFixture(store, temp, checksum: 'abc', target: 'A', value: 'one'),
      publishFixture(store, temp, checksum: 'abc', target: 'A', value: 'two'),
    ]);

    expect(results[0].artifactPath, results[1].artifactPath);
    final found = await store.findCompleteTarget('abc', 'A');
    expect(found, isNotNull);
    expect(
      File(p.join(found!.artifactPath, 'payload')).readAsStringSync(),
      anyOf('one', 'two'),
    );
    final metadata =
        jsonDecode(
              File(
                p.join(store.targetRoot('abc', 'A'), 'metadata.json'),
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    expect(metadata['archiveChecksum'], 'abc');
    expect(metadata['targetName'], 'A');
    expect(metadata['artifactDirectoryName'], 'A.artifactbundle');
  });

  test('recovers publication from an incomplete destination', () async {
    final poisoned = Directory(store.targetRoot('abc', 'A'))
      ..createSync(recursive: true);
    File(p.join(poisoned.path, 'partial')).writeAsStringSync('keep');

    final published = await publishFixture(
      store,
      temp,
      checksum: 'abc',
      target: 'A',
    );

    expect(Directory(published.artifactPath).existsSync(), isTrue);
    expect(await store.findCompleteTarget('abc', 'A'), isNotNull);
    final preserved = poisoned.parent
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .any(
          (entry) =>
              p.basename(entry.path) == 'partial' &&
              entry.readAsStringSync() == 'keep',
        );
    expect(preserved, isTrue);
  });

  test(
    'streams multi-chunk target files with stable mutation-sensitive digest',
    () async {
      Future<SwiftPmBinaryArtifactEntry> publishLarge(String checksum) {
        final staging = temp.createTempSync('large-$checksum-');
        final artifact = Directory(p.join(staging.path, 'A.artifactbundle'))
          ..createSync();
        final payload = File(
          p.join(artifact.path, 'payload'),
        ).openSync(mode: FileMode.write);
        final chunk = List<int>.generate(64 * 1024, (index) => index & 0xff);
        for (var index = 0; index < 48; index++) {
          payload.writeFromSync(chunk);
        }
        payload.closeSync();
        return store.publishTarget(
          checksum: checksum,
          targetName: 'A',
          stagingRoot: staging,
          artifactDirectoryName: 'A.artifactbundle',
          metadata: const {},
        );
      }

      String treeDigest(String checksum) {
        final metadata =
            jsonDecode(
                  File(
                    p.join(store.targetRoot(checksum, 'A'), 'metadata.json'),
                  ).readAsStringSync(),
                )
                as Map<String, Object?>;
        return metadata['treeDigest']! as String;
      }

      final first = await publishLarge('abc');
      final second = await publishLarge('def');

      expect(treeDigest('abc'), treeDigest('def'));
      final payload = File(p.join(first.artifactPath, 'payload'));
      final handle = payload.openSync(mode: FileMode.append);
      handle.writeByteSync(1);
      handle.closeSync();
      expect(await store.findCompleteTarget('abc', 'A'), isNull);
      expect(await store.findCompleteTarget('def', 'A'), isNotNull);
      expect(
        File(p.join(second.artifactPath, 'payload')).lengthSync(),
        3 * 1024 * 1024,
      );
    },
  );

  test('requires a real artifact directory root', () async {
    final staging = temp.createTempSync('file-artifact-');
    File(p.join(staging.path, 'A.artifactbundle')).writeAsStringSync('value');

    await expectLater(
      store.publishTarget(
        checksum: 'abc',
        targetName: 'A',
        stagingRoot: staging,
        artifactDirectoryName: 'A.artifactbundle',
        metadata: const {},
      ),
      throwsA(isA<FlutterBuildError>()),
    );
  });

  test('rejects symlinks anywhere in a staged target tree', () async {
    final staging = fixture(temp, 'linked', 'A.artifactbundle', 'value');
    final outside = File(p.join(temp.path, 'outside'))..writeAsStringSync('x');
    Link(
      p.join(staging.path, 'A.artifactbundle', 'link'),
    ).createSync(outside.path);

    await expectLater(
      store.publishTarget(
        checksum: 'abc',
        targetName: 'A',
        stagingRoot: staging,
        artifactDirectoryName: 'A.artifactbundle',
        metadata: const {},
      ),
      throwsA(isA<FlutterBuildError>()),
    );
    expect(await store.findCompleteTarget('abc', 'A'), isNull);
  });

  test('does not reuse a published tree containing a symlink', () async {
    final published = await publishFixture(
      store,
      temp,
      checksum: 'abc',
      target: 'A',
    );
    final outside = File(p.join(temp.path, 'outside'))..writeAsStringSync('x');
    Link(p.join(published.artifactPath, 'link')).createSync(outside.path);

    expect(await store.findCompleteTarget('abc', 'A'), isNull);
  });

  test('does not accept a symlink as the target root', () async {
    final elsewhere = temp.createTempSync('elsewhere-');
    File(p.join(elsewhere.path, '.complete')).writeAsStringSync('');
    final target = store.targetRoot('abc', 'A');
    Directory(target).parent.createSync(recursive: true);
    Link(target).createSync(elsewhere.path);

    expect(await store.findCompleteTarget('abc', 'A'), isNull);
  });

  test('rejects unsafe target and artifact names', () async {
    for (final target in ['.', '..', 'A/B', r'A\B']) {
      expect(() => store.targetRoot('abc', target), throwsArgumentError);
    }
    final staging = fixture(temp, 'unsafe', 'artifact', 'value');
    await expectLater(
      store.publishTarget(
        checksum: 'abc',
        targetName: 'A',
        stagingRoot: staging,
        artifactDirectoryName: '../artifact',
        metadata: const {},
      ),
      throwsArgumentError,
    );
  });
}

Future<SwiftPmBinaryArtifactEntry> publishFixture(
  SwiftPmBinaryArtifactStore store,
  Directory temp, {
  required String checksum,
  required String target,
  String value = 'artifact',
}) {
  return store.publishTarget(
    checksum: checksum,
    targetName: target,
    stagingRoot: fixture(
      temp,
      '$checksum-$target',
      '$target.artifactbundle',
      value,
    ),
    artifactDirectoryName: '$target.artifactbundle',
    metadata: {'fixture': value},
  );
}

Directory fixture(
  Directory temp,
  String name,
  String artifactName,
  String value,
) {
  final root = temp.createTempSync('$name-');
  final artifact = Directory(p.join(root.path, artifactName))
    ..createSync(recursive: true);
  File(p.join(artifact.path, 'payload')).writeAsStringSync(value);
  return root;
}
