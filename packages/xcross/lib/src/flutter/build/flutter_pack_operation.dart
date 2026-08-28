import 'dart:convert';
import 'dart:io';

import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/cli/basic/sdk_install.dart';
import 'package:xcross/src/flutter/build/flutter_packer.dart';
import 'package:xcross/src/flutter/build/internal/swiftpm_gate_evidence.dart';
import 'package:xcross/src/flutter/build/internal/swiftpm_workspace.dart';
import 'package:xcross/src/flutter/build/ios_bundle_id.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/flutter/models/flutter/flutter_build_options.dart';
import 'package:xcross/src/models/pack_result.dart';

/// Groups the Flutter iOS `.app` packing entrypoint.
abstract final class FlutterPackOperation {
  /// Build the Flutter iOS `.app` for the project in the current directory.
  ///
  /// Bundle id comes from `ios/Runner/Info.plist` / `project.pbxproj` (same
  /// sources Flutter tooling uses). Deletes any prior bundle, then packs.
  static Future<({bool swiftPmArtifact, bool packageLocalArtifact})>
  artifactJunctionCapabilities({
    required String evidenceRoot,
    required String platformIdentity,
    required String toolchainIdentity,
    required String sdkIdentity,
    Map<String, String> environment = const {},
    SwiftPmGateProbe probe = probeSwiftPmGate,
    SwiftPmGateRuntimeBinding? runtimeBinding,
  }) async {
    final evidence = SwiftPmGateEvidence(evidenceRoot);
    return (
      swiftPmArtifact: await evidence.verifies(
        mode: SwiftPmGateMode.swiftPmArtifact,
        platformIdentity: platformIdentity,
        toolchainIdentity: toolchainIdentity,
        sdkIdentity: sdkIdentity,
        probe: probe,
        runtimeBinding: runtimeBinding,
      ),
      packageLocalArtifact: await evidence.verifies(
        mode: SwiftPmGateMode.packageLocalArtifact,
        platformIdentity: platformIdentity,
        toolchainIdentity: toolchainIdentity,
        sdkIdentity: sdkIdentity,
        probe: probe,
        runtimeBinding: runtimeBinding,
      ),
    );
  }

  static Future<({bool swiftPmArtifact, bool packageLocalArtifact})>
  resolveArtifactJunctionCapabilities({
    required SwiftPmWorkspace workspace,
    DarwinSdk? Function() currentDarwinSdk = DarwinSdk.current,
    bool? windows,
  }) async {
    final sdk = currentDarwinSdk();
    final isWindows = windows ?? Platform.isWindows;
    if (isWindows && sdk == null) {
      throw FlutterBuildError(
        'Darwin Swift SDK not found. Run '
        '`xcross sdk install <Xcode.xip>` first.',
      );
    }
    final sdkIdentity = jsonEncode(
      sdk == null
          ? const <String, Object>{}
          : await SdkInstall.sdkBuildIdentity(sdk.swiftSdkPath),
    );
    final toolchainIdentity = jsonEncode(
      isWindows
          ? await GeneratedPluginsPackage.resolveBuildToolchainIdentity(sdk!)
          : await SdkInstall.hostToolchainIdentity(),
    );
    return artifactJunctionCapabilities(
      evidenceRoot: workspace.gateEvidence,
      platformIdentity:
          '${Platform.operatingSystem}-${Platform.operatingSystemVersion}',
      toolchainIdentity: toolchainIdentity,
      sdkIdentity: sdkIdentity,
    );
  }

  static Future<PackResult> pack({required FlutterBuildOptions options}) async {
    final projectRoot = Directory.current.path;
    final bundleId = IosBundleId.resolve(projectRoot);
    final workspace = SwiftPmWorkspace.forProject(projectRoot);

    final packer = FlutterPacker(
      projectRoot: projectRoot,
      bundleId: bundleId,
      options: options,
      artifactJunctionCapabilityResolver: () =>
          resolveArtifactJunctionCapabilities(workspace: workspace),
    );

    // Always delete any previous bundle BEFORE packing, otherwise stale
    // binaries from an earlier build get codesigned into the new one.
    final bundleDir = Directory(
      p.join(projectRoot, 'build', 'xcross-ios', '${packer.appName}.app'),
    );
    if (bundleDir.existsSync()) await bundleDir.delete(recursive: true);

    final appPath = await packer.pack();
    return PackResult(outputPath: appPath, bundleId: bundleId);
  }
}
