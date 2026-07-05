// Ported from the iOS version check pattern used in CoreDeviceLauncher.swift
// (gating iOS 17+ vs pre-17 based on ProductVersion from lockdown info).
import 'dart:convert';

import 'package:xcross/src/device/pymd.dart';
import 'package:xcross/src/util/logging.dart';

/// Return the major OS version for [udid] by running
/// `pymobiledevice3 lockdown info --udid <udid>` and parsing `ProductVersion`.
///
/// Returns null if pymobiledevice3 is not available or output cannot be parsed.
/// Callers use this to gate iOS 17+ (CoreDeviceLauncher) vs pre-17 (DebugLauncher).
Future<int?> deviceOSMajorVersion(String udid) async {
  try {
    final result = await Pymd.run(['lockdown', 'info', '--udid', udid]);
    final dynamic json = jsonDecode(result.stdout);
    if (json is! Map) return null;
    final version = json['ProductVersion'] as String?;
    if (version == null) return null;
    return int.tryParse(version.split('.').first);
  } catch (e) {
    logWarn('Could not determine device OS version: $e');
    return null;
  }
}
