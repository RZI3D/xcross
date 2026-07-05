/// Default values written into an iOS app bundle's Info.plist.
abstract final class PlistDefaults {
  /// Default CFBundleShortVersionString (FLUTTER_BUILD_NAME).
  static const String shortVersion = '1.0.0';

  /// Default CFBundleVersion (FLUTTER_BUILD_NUMBER).
  static const String bundleVersion = '1';

  /// Default CFBundleExecutable and product name.
  static const String executable = 'Runner';

  /// Default bundle-id organisation prefix.
  static const String orgId = 'com.example';
}
