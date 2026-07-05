import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/util/errors.dart';
import 'package:yaml/yaml.dart';

/// How the app's bundle identifier is derived. Mirrors xtool's `PackSchema`.
@immutable
sealed class IdSpecifier {
  const IdSpecifier();

  /// Compute the final bundle id given the resolved product name.
  String formBundleId(String product);
}

/// `orgID: com.example` → bundle id `com.example.<product>`.
@immutable
class OrgIdSpecifier extends IdSpecifier {
  const OrgIdSpecifier(this.orgId);

  /// The organization identifier prefix.
  final String orgId;

  @override
  String formBundleId(String product) => '$orgId.$product';
}

/// `bundleID: com.example.MyApp` → literal bundle id.
@immutable
class BundleIdSpecifier extends IdSpecifier {
  const BundleIdSpecifier(this.bundleId);

  /// The literal bundle identifier.
  final String bundleId;

  @override
  String formBundleId(String product) => bundleId;
}

/// Parsed `xtool.yml` (schema version 1). Mirrors xtool's `PackSchemaBase`.
@immutable
class PackSchema {
  const PackSchema({
    required this.version,
    required this.idSpecifier,
    this.product,
    this.infoPath,
    this.entitlementsPath,
    this.iconPath,
    this.resources = const [],
  });

  /// Schema version (must be 1).
  final int version;

  /// How the bundle identifier is derived.
  final IdSpecifier idSpecifier;

  /// Optional product name override.
  final String? product;

  /// Path to a custom `Info.plist`.
  final String? infoPath;

  /// Path to an entitlements `.plist` file.
  final String? entitlementsPath;

  /// Path to the app icon `.png`.
  final String? iconPath;

  /// Additional resource paths to embed in the bundle.
  final List<String> resources;

  /// Default used when no `xtool.yml` is present (`com.example` org).
  factory PackSchema.defaultSchema() =>
      const PackSchema(version: 1, idSpecifier: OrgIdSpecifier('com.example'));

  static Future<PackSchema> fromFile(String path) async {
    final doc = loadYaml(await File(path).readAsString());
    if (doc is! YamlMap) {
      throw XcrossError('xtool.yml: invalid document');
    }
    final version = doc['version'];
    if (version != 1) {
      throw XcrossError('xtool.yml: Unsupported schema version: $version');
    }
    final bundleId = doc['bundleID'] as String?;
    final orgId = doc['orgID'] as String?;
    final IdSpecifier spec;
    if (bundleId != null) {
      spec = BundleIdSpecifier(bundleId);
    } else if (orgId != null) {
      spec = OrgIdSpecifier(orgId);
    } else {
      throw XcrossError('xtool.yml: Must specify either orgID or bundleID');
    }
    final iconPath = doc['iconPath'] as String?;
    if (iconPath != null && p.extension(iconPath) != '.png') {
      throw XcrossError(
        "xtool.yml: iconPath should have a 'png' path extension. "
        "Got '${p.extension(iconPath)}'.",
      );
    }
    final resources =
        (doc['resources'] as YamlList?)?.map((e) => e.toString()).toList() ??
            const <String>[];
    return PackSchema(
      version: 1,
      idSpecifier: spec,
      product: doc['product'] as String?,
      infoPath: doc['infoPath'] as String?,
      entitlementsPath: doc['entitlementsPath'] as String?,
      iconPath: iconPath,
      resources: resources,
    );
  }
}
