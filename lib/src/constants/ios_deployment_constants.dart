/// Constants describing the iOS deployment target and SDK versions.
abstract final class IosDeploymentConstants {
  /// Minimum iOS deployment target version.
  static const String minDeploymentTarget = '13.0';

  /// Clang build triple for the arm64 iOS 13 deployment target.
  static const String buildTriple = 'arm64-apple-ios13.0';

  /// iOS SDK version bundled with the active Xcode.
  static const String sdkVersion = '18.0';

  /// iOS SDK triple used for linking and plist metadata.
  static const String sdkTriple = 'iphoneos18.0';

  /// Info.plist key for the minimum OS version.
  static const String minimumOsVersionKey = 'MinimumOSVersion';
}
