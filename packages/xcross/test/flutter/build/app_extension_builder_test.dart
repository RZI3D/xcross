import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/app_extension_builder.dart';
import 'package:xcross/src/flutter/build/ios_app_extensions.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';

IosAppExtension _extension({
  String name = 'Share Extension',
  String bundleId = 'com.example.App.Share-Extension',
  List<String> sources = const [
    '/ios/Share Extension/ShareViewController.swift',
  ],
  List<String> resources = const [],
  List<String> appGroups = const [],
}) => IosAppExtension(
  name: name,
  bundleId: bundleId,
  infoPlistPath: null,
  sources: sources,
  resources: resources,
  entitlementsPath: null,
  swiftVersion: '5.0',
  deploymentTarget: null,
  appGroups: appGroups,
);

void main() {
  group('compileArguments', () {
    List<String> argumentsWith({
      String? pluginsLibrary,
      String? pluginModulesDir,
    }) => AppExtensionBuilder.compileArguments(
      iosSdk: '/sdk/iPhoneOS.sdk',
      resourceDir: '/sdk/toolchain/usr/lib/swift',
      sources: const ['/ios/Share Extension/ShareViewController.swift'],
      outputPath: '/out/Share Extension.appex/Share Extension',
      deploymentTarget: const IosDeploymentTarget('15.0'),
      flutterSlice: '/engine/Flutter.xcframework/ios-arm64',
      moduleCache: '/out/.module-cache',
      ld64lld: '/usr/bin/ld64.lld',
      sdkVersion: '26.5',
      pluginsLibrary: pluginsLibrary,
      pluginModulesDir: pluginModulesDir,
    );

    test('marks the binary as app-extension safe', () {
      final arguments = argumentsWith();

      expect(arguments, contains('-application-extension'));
      expect(
        arguments,
        containsAllInOrder(['-Xcc', '-fapplication-extension']),
      );
    });

    test('entry point is _NSExtensionMain, not main', () {
      expect(
        argumentsWith(),
        containsAllInOrder(['-e', '-Xlinker', '_NSExtensionMain']),
      );
    });

    test('rpath reaches the host app Frameworks two levels up', () {
      expect(
        argumentsWith(),
        containsAllInOrder([
          '-rpath',
          '-Xlinker',
          '@executable_path/../../Frameworks',
        ]),
      );
    });

    test('uses the Darwin SDK Swift resources, not the host toolchain', () {
      expect(
        argumentsWith(),
        containsAllInOrder(['-resource-dir', '/sdk/toolchain/usr/lib/swift']),
      );
    });

    test('links and imports the plugins library when present', () {
      final arguments = argumentsWith(
        pluginsLibrary: '/build/libFlutterPluginsGenerated.dylib',
        pluginModulesDir: '/build/Modules',
      );

      expect(arguments, containsAllInOrder(['-I', '/build/Modules']));
      expect(
        arguments,
        containsAllInOrder([
          '-Xlinker',
          '/build/libFlutterPluginsGenerated.dylib',
        ]),
      );
    });

    test('omits plugin flags for a project without plugins', () {
      final arguments = argumentsWith();

      expect(arguments, isNot(contains('-I')));
      expect(arguments.where((a) => a.endsWith('.dylib')), isEmpty);
    });

    test(
      'passes -arch and -platform_version explicitly for non-Apple clang',
      () {
        expect(
          argumentsWith(),
          containsAllInOrder([
            '-arch',
            '-Xlinker',
            'arm64',
            '-Xlinker',
            '-platform_version',
            '-Xlinker',
            'ios',
            '-Xlinker',
            '15.0',
            '-Xlinker',
            '26.5',
          ]),
        );
      },
    );
  });

  group('expandExtensionVars', () {
    test('substitutes the app group into CUSTOM_GROUP_ID', () {
      final xml = AppExtensionBuilder.expandExtensionVars(
        r'<key>AppGroupId</key><string>$(CUSTOM_GROUP_ID)</string>',
        extension: _extension(appGroups: const ['group.com.example.Shared']),
      );

      expect(xml, contains('<string>group.com.example.Shared</string>'));
    });

    test('substitutes the bundle identifier', () {
      final xml = AppExtensionBuilder.expandExtensionVars(
        r'<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>',
        extension: _extension(),
      );

      expect(xml, contains('com.example.App.Share-Extension'));
    });

    test('leaves CUSTOM_GROUP_ID alone when no app group is declared', () {
      const source = r'<string>$(CUSTOM_GROUP_ID)</string>';

      expect(
        AppExtensionBuilder.expandExtensionVars(
          source,
          extension: _extension(),
        ),
        source,
      );
    });
  });

  group('replaceStoryboardWithPrincipalClass', () {
    test('swaps the storyboard for the module-qualified principal class', () {
      final xml = AppExtensionBuilder.replaceStoryboardWithPrincipalClass(
        '<dict>\n'
        '\t\t<key>NSExtensionMainStoryboard</key>\n'
        '\t\t<string>MainInterface</string>\n'
        '</dict>',
        extension: _extension(),
      );

      expect(xml, isNot(contains('NSExtensionMainStoryboard')));
      expect(xml, contains('<key>NSExtensionPrincipalClass</key>'));
      expect(
        xml,
        contains('<string>Share_Extension.ShareViewController</string>'),
      );
    });

    test('leaves a plist that already names a principal class', () {
      const source =
          '<dict><key>NSExtensionPrincipalClass</key>'
          '<string>Custom.Controller</string></dict>';

      expect(
        AppExtensionBuilder.replaceStoryboardWithPrincipalClass(
          source,
          extension: _extension(),
        ),
        source,
      );
    });

    test('keeps the storyboard key when no controller class can be found', () {
      const source =
          '<dict><key>NSExtensionMainStoryboard</key>'
          '<string>MainInterface</string></dict>';

      expect(
        AppExtensionBuilder.replaceStoryboardWithPrincipalClass(
          source,
          extension: _extension(sources: const ['/ios/Helpers.swift']),
        ),
        source,
      );
    });
  });

  group('AppExtensionPlist.forceKeys', () {
    String forced(String xml) => AppExtensionPlist.forceKeys(
      xml,
      bundleId: 'com.example.App.Share-Extension',
      executableName: 'Share Extension',
      bundleName: 'Share Extension',
      minimumOsVersion: '15.0',
    );

    test('sets the identity keys installd validates', () {
      final xml = forced('<dict>\n</dict>');

      expect(xml, contains('<string>com.example.App.Share-Extension</string>'));
      expect(xml, contains('<key>CFBundleExecutable</key>'));
      // installd rejects an appex with no display name.
      expect(xml, contains('<key>CFBundleDisplayName</key>'));
      expect(xml, contains('<string>XPC!</string>'));
      expect(xml, contains('<key>MinimumOSVersion</key>'));
    });

    test('overwrites an existing value instead of duplicating the key', () {
      final xml = forced(
        '<dict><key>CFBundleIdentifier</key><string>stale</string></dict>',
      );

      expect(xml, isNot(contains('stale')));
      expect(RegExp('<key>CFBundleIdentifier</key>').allMatches(xml).length, 1);
    });
  });
}
