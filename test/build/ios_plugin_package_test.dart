import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/build/ios_plugin_package.dart';
import 'package:xcross/src/build/ios_plugins.dart';
import 'package:xcross/src/constants.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xcross_ios_plugin_package-');
  });

  tearDown(() => tmp.delete(recursive: true));

  /// Creates a fake plugin pub package with an `ios/<name>/Package.swift` and
  /// a `pubspec.yaml` whose `pluginClass` is [pluginClass] (or omitted when
  /// null).
  IosPlugin makePlugin(String name, {String? pluginClass}) {
    final packageRoot = p.join(tmp.path, name);
    Directory(
      p.join(packageRoot, 'ios', name),
    ).createSync(recursive: true);
    File(
      p.join(packageRoot, 'ios', name, 'Package.swift'),
    ).writeAsStringSync('');

    final pluginSection = pluginClass == null
        ? ''
        : '''
flutter:
  plugin:
    platforms:
      ios:
        pluginClass: $pluginClass
''';
    File(
      p.join(packageRoot, 'pubspec.yaml'),
    ).writeAsStringSync('name: $name\n$pluginSection');

    return IosPlugin(name: name, packageRoot: packageRoot);
  }

  group('flutterFrameworkManifest', () {
    test('matches the exact wrapper manifest', () {
      expect(GeneratedPluginsPackage.flutterFrameworkManifest(), '''
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FlutterFramework",
    products: [
        .library(name: "FlutterFramework", targets: ["FlutterFramework"])
    ],
    targets: [
        .binaryTarget(name: "FlutterFramework", path: "Flutter.xcframework")
    ]
)
''');
    });
  });

  group('pluginsManifest', () {
    test('includes every plugin package dependency and hyphenated product', () {
      final pluginA = makePlugin('plugin_a', pluginClass: 'PluginA');
      final pluginB = makePlugin('plugin_b');
      final frameworkDir = p.join(tmp.path, 'FlutterFramework');

      final manifest = GeneratedPluginsPackage.pluginsManifest(
        [pluginA, pluginB],
        frameworkDir,
      );

      expect(manifest, contains('name: "FlutterPluginsGenerated"'));
      expect(
        manifest,
        contains('.iOS("${IosDeploymentConstants.minDeploymentTarget}")'),
      );
      expect(
        manifest,
        contains(
          '.library(name: "FlutterPluginsGenerated", type: .dynamic, '
          'targets: ["FlutterPluginsGenerated"])',
        ),
      );
      expect(
        manifest,
        contains('.package(name: "FlutterFramework", path:'),
      );
      expect(manifest, contains('.package(name: "plugin_a", path:'));
      expect(manifest, contains('.package(name: "plugin_b", path:'));
      expect(
        manifest,
        contains('.product(name: "plugin-a", package: "plugin_a")'),
      );
      expect(
        manifest,
        contains('.product(name: "plugin-b", package: "plugin_b")'),
      );
      expect(
        manifest,
        contains(
          '.product(name: "FlutterFramework", package: "FlutterFramework")',
        ),
      );
    });

    test('paths are forward-slash safe', () {
      final pluginA = makePlugin('plugin_a');
      final frameworkDir = p.join(tmp.path, 'FlutterFramework');

      final manifest = GeneratedPluginsPackage.pluginsManifest(
        [pluginA],
        frameworkDir,
      );

      expect(manifest, isNot(contains(r'\')));
    });
  });

  group('registrantSource', () {
    test(
      'imports both plugins but registers only the one with a pluginClass',
      () {
        final pluginA = makePlugin('plugin_a', pluginClass: 'PluginA');
        final pluginB = makePlugin('plugin_b');

        final source = GeneratedPluginsPackage.registrantSource([
          pluginA,
          pluginB,
        ]);

        expect(source, contains('import plugin_a'));
        expect(source, contains('import plugin_b'));
        expect(
          source,
          contains(
            'if let registrar = registry.registrar(forPlugin: "PluginA")',
          ),
        );
        expect(source, contains('PluginA.register(with: registrar)'));
        // Exactly one registration block: only plugin_a has a pluginClass.
        expect('if let registrar'.allMatches(source).length, 1);
        expect(
          source,
          contains('@_cdecl("XcrossRegisterGeneratedPlugins")'),
        );
      },
    );

    test('emits a function with an empty body when no plugin has a pluginClass', () {
      final pluginA = makePlugin('plugin_a');

      final source = GeneratedPluginsPackage.registrantSource([pluginA]);

      expect(source, contains('import plugin_a'));
      expect(source, isNot(contains('if let registrar')));
      expect(
        source,
        contains(
          'public func xcrossRegisterGeneratedPlugins(_ registry: '
          'FlutterPluginRegistry) {\n}',
        ),
      );
    });
  });

  group('writeGeneratedPackages', () {
    test(
      'writes FlutterFramework/Plugins packages and the xcframework symlink',
      () async {
        final pluginA = makePlugin('plugin_a', pluginClass: 'PluginA');
        final flutterXcframework = p.join(tmp.path, 'Flutter.xcframework');
        Directory(flutterXcframework).createSync(recursive: true);
        final outputDir = p.join(tmp.path, 'out');

        try {
          await GeneratedPluginsPackage.writeGeneratedPackages(
            outputDir: outputDir,
            plugins: [pluginA],
            flutterXcframework: flutterXcframework,
          );
        } on FileSystemException {
          markTestSkipped('symlink creation unsupported in this environment');
          return;
        }

        final frameworkManifest = File(
          p.join(outputDir, 'FlutterFramework', 'Package.swift'),
        );
        expect(frameworkManifest.existsSync(), isTrue);
        expect(
          frameworkManifest.readAsStringSync(),
          GeneratedPluginsPackage.flutterFrameworkManifest(),
        );

        final link = Link(
          p.join(outputDir, 'FlutterFramework', 'Flutter.xcframework'),
        );
        expect(link.existsSync(), isTrue);
        expect(
          p.equals(link.targetSync(), flutterXcframework),
          isTrue,
        );

        final pluginsManifestFile = File(
          p.join(outputDir, 'Plugins', 'Package.swift'),
        );
        expect(pluginsManifestFile.existsSync(), isTrue);
        expect(
          pluginsManifestFile.readAsStringSync(),
          contains('.package(name: "plugin_a", path:'),
        );

        final registrantFile = File(
          p.join(
            outputDir,
            'Plugins',
            'Sources',
            'FlutterPluginsGenerated',
            'GeneratedPluginRegistrant.swift',
          ),
        );
        expect(registrantFile.existsSync(), isTrue);
        expect(registrantFile.readAsStringSync(), contains('import plugin_a'));
      },
    );
  });

  group('build', () {
    test('returns null and writes nothing when there are no SPM plugins', () async {
      final outputDir = p.join(tmp.path, 'out');

      final result = await GeneratedPluginsPackage.build(
        projectRoot: tmp.path,
        plugins: const [],
        flutterXcframework: p.join(tmp.path, 'Flutter.xcframework'),
        outputDir: outputDir,
      );

      expect(result, isNull);
      expect(Directory(outputDir).existsSync(), isFalse);
    });

    test(
      'returns null when plugins exist but none use Swift Package Manager',
      () async {
        final podspecOnly = p.join(tmp.path, 'plugin_pod');
        Directory(
          p.join(podspecOnly, 'ios'),
        ).createSync(recursive: true);
        File(
          p.join(podspecOnly, 'ios', 'plugin_pod.podspec'),
        ).writeAsStringSync('');
        final plugin = IosPlugin(name: 'plugin_pod', packageRoot: podspecOnly);
        final outputDir = p.join(tmp.path, 'out');

        final result = await GeneratedPluginsPackage.build(
          projectRoot: tmp.path,
          plugins: [plugin],
          flutterXcframework: p.join(tmp.path, 'Flutter.xcframework'),
          outputDir: outputDir,
        );

        expect(result, isNull);
        expect(Directory(outputDir).existsSync(), isFalse);
      },
    );
  });
}
