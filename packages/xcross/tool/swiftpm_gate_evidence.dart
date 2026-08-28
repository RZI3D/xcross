import 'dart:convert';
import 'dart:io';

import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/cli/basic/sdk_install.dart';
import 'package:xcross/src/flutter/build/internal/swiftpm_gate_evidence.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';

Future<void> main(List<String> arguments) async {
  if (!Platform.isWindows ||
      arguments.length != 2 ||
      arguments.first != 'record') {
    throw ArgumentError('usage: swiftpm_gate_evidence record <mode>');
  }
  final mode = SwiftPmGateMode.values.singleWhere(
    (candidate) => candidate.name == arguments[1],
  );
  final cacheRoot = Platform.environment['XCROSS_CACHE_DIR'];
  if (cacheRoot == null || cacheRoot.isEmpty) {
    throw StateError('XCROSS_CACHE_DIR is required');
  }
  final sdk = DarwinSdk.current();
  if (sdk == null) throw StateError('Darwin SDK is required');
  final passed =
      await SwiftPmGateEvidence(
        p.join(cacheRoot, 'swiftpm', 'gate-evidence-v2'),
      ).verifies(
        mode: mode,
        platformIdentity:
            '${Platform.operatingSystem}-${Platform.operatingSystemVersion}',
        toolchainIdentity: jsonEncode(
          await GeneratedPluginsPackage.resolveBuildToolchainIdentity(sdk),
        ),
        sdkIdentity: jsonEncode(
          await SdkInstall.sdkBuildIdentity(sdk.swiftSdkPath),
        ),
      );
  if (!passed) throw StateError('${mode.name} feasibility probe failed');
}
