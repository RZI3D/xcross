import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/errors.dart';

/// Resolves the iOS product bundle identifier the way Flutter tooling does on
/// non-macOS hosts (no `xcodebuild -showBuildSettings`).
///
/// Order:
///   1. Literal `CFBundleIdentifier` from `ios/Runner/Info.plist` (no `$`).
///   2. `PRODUCT_BUNDLE_IDENTIFIER` of the *application* target in
///      `ios/*.xcodeproj/project.pbxproj` (never an app extension target).
///   3. First `PRODUCT_BUNDLE_IDENTIFIER` in the pbxproj (legacy fallback).
abstract final class IosBundleId {
  /// Flutter's `_productBundleIdPattern` from `xcode_project.dart`.
  static final _productBundleIdPattern = RegExp(
    r'''^\s*PRODUCT_BUNDLE_IDENTIFIER\s*=\s*(["']?)(.*?)\1;\s*$''',
    multiLine: true,
  );

  static final _cfBundleIdentifierPattern = RegExp(
    r'<key>CFBundleIdentifier</key>\s*<string>([^<]*)</string>',
  );

  /// One `PBXNativeTarget` object: name, build configuration list id and
  /// product type. `productType` closes the interesting part of the block.
  static final _nativeTargetPattern = RegExp(
    r'isa\s*=\s*PBXNativeTarget;(.*?)productType\s*=\s*"?([^";]+)"?\s*;',
    dotAll: true,
  );

  static final _buildConfigurationListRefPattern = RegExp(
    r'buildConfigurationList\s*=\s*([0-9A-Fa-f]{8,})\b',
  );

  static final _targetNamePattern = RegExp(
    r'''^\s*name\s*=\s*(["']?)(.*?)\1;\s*$''',
    multiLine: true,
  );

  static const _applicationProductType = 'com.apple.product-type.application';

  /// Resolve the bundle id for the Flutter project at [projectRoot].
  ///
  /// Throws [FlutterBuildError] when neither a literal plist value nor a
  /// pbxproj `PRODUCT_BUNDLE_IDENTIFIER` can be found.
  static String resolve(String projectRoot) {
    final fromPlist = _cfBundleIdentifierFromPlist(projectRoot);
    if (fromPlist != null && !fromPlist.contains(r'$')) {
      return fromPlist;
    }

    final fromPbxproj = _productBundleIdFromPbxproj(projectRoot);
    if (fromPbxproj != null && fromPbxproj.isNotEmpty) {
      return fromPbxproj;
    }

    throw FlutterBuildError(
      'Could not resolve iOS bundle identifier. Set CFBundleIdentifier in '
      'ios/Runner/Info.plist, or PRODUCT_BUNDLE_IDENTIFIER in '
      'ios/*.xcodeproj/project.pbxproj.',
    );
  }

  static String? _cfBundleIdentifierFromPlist(String projectRoot) {
    final file = File(p.join(projectRoot, 'ios', 'Runner', 'Info.plist'));
    if (!file.existsSync()) return null;
    final match = _cfBundleIdentifierPattern.firstMatch(
      file.readAsStringSync(),
    );
    final value = match?.group(1)?.trim();
    if (value == null || value.isEmpty) return null;
    return value;
  }

  static String? _productBundleIdFromPbxproj(String projectRoot) {
    final pbxproj = _findPbxproj(projectRoot);
    if (pbxproj == null) return null;
    final contents = pbxproj.readAsStringSync();

    // Projects with app extensions (share extensions, widgets, ...) declare
    // several PRODUCT_BUNDLE_IDENTIFIERs; the extension's often comes first.
    // Resolve through the application target when the project graph is
    // readable, and only then fall back to the first match in the file.
    final fromAppTarget = _appTargetBundleId(contents);
    if (fromAppTarget != null) return fromAppTarget;

    final match = _productBundleIdPattern.firstMatch(contents);
    return _clean(match?.group(2));
  }

  /// Bundle id declared by the `com.apple.product-type.application` target,
  /// preferring a target literally named `Runner`.
  static String? _appTargetBundleId(String contents) {
    String? fallback;

    for (final target in _nativeTargetPattern.allMatches(contents)) {
      final body = target.group(1) ?? '';
      if (target.group(2)?.trim() != _applicationProductType) continue;

      final listId = _buildConfigurationListRefPattern
          .firstMatch(body)
          ?.group(1);
      if (listId == null) continue;

      final bundleId = _bundleIdFromConfigurationList(contents, listId);
      if (bundleId == null) continue;

      final name = _targetNamePattern.firstMatch(body)?.group(2)?.trim();
      if (name == 'Runner') return bundleId;
      fallback ??= bundleId;
    }

    return fallback;
  }

  /// Walk `XCConfigurationList` -> `XCBuildConfiguration` objects and return
  /// the first literal `PRODUCT_BUNDLE_IDENTIFIER` found.
  static String? _bundleIdFromConfigurationList(
    String contents,
    String listId,
  ) {
    final list = _objectBody(contents, listId);
    if (list == null) return null;

    for (final ref in RegExp(r'\b([0-9A-Fa-f]{8,})\b').allMatches(list)) {
      final body = _objectBody(contents, ref.group(1)!);
      if (body == null) continue;
      if (!body.contains('isa = XCBuildConfiguration')) continue;
      final value = _clean(_productBundleIdPattern.firstMatch(body)?.group(2));
      if (value != null) return value;
    }
    return null;
  }

  /// The `{ ... }` body of the pbxproj object with [id], brace-balanced.
  static String? _objectBody(String contents, String id) {
    final header = RegExp(
      '(?<![0-9A-Fa-f])$id(?![0-9A-Fa-f])[^\\n]*?=\\s*\\{',
    ).firstMatch(contents);
    if (header == null) return null;

    var depth = 1;
    final start = header.end;
    for (var i = start; i < contents.length; i++) {
      final char = contents[i];
      if (char == '{') {
        depth++;
      } else if (char == '}') {
        depth--;
        if (depth == 0) return contents.substring(start, i);
      }
    }
    return null;
  }

  static String? _clean(String? raw) {
    final value = raw?.trim();
    if (value == null || value.isEmpty || value.contains(r'$')) return null;
    return value;
  }

  /// Prefer `Runner.xcodeproj`, otherwise the first `*.xcodeproj` under `ios/`.
  static File? _findPbxproj(String projectRoot) {
    final iosDir = Directory(p.join(projectRoot, 'ios'));
    if (!iosDir.existsSync()) return null;

    final runner = File(
      p.join(iosDir.path, 'Runner.xcodeproj', 'project.pbxproj'),
    );
    if (runner.existsSync()) return runner;

    for (final entity in iosDir.listSync()) {
      if (entity is! Directory) continue;
      if (!entity.path.endsWith('.xcodeproj')) continue;
      final candidate = File(p.join(entity.path, 'project.pbxproj'));
      if (candidate.existsSync()) return candidate;
    }
    return null;
  }
}
