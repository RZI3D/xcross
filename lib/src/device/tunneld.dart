// Ported from Sources/XToolSupport/CoreDevice/Tunneld.swift
import 'dart:convert';
import 'dart:io';

import 'package:xcross/src/constants/device_constants.dart';
import 'package:xcross/src/models/device/tunnel.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';

export 'package:xcross/src/models/device/tunnel.dart';

/// Reads tunnel endpoint(s) from the locally-running tunneld REST API
/// (http://127.0.0.1:49151/). Polls until available.
/// Tunneld.swift:11
abstract final class Tunneld {
  /// Find the tunnel endpoint for [udid] (or the first tunneled device when
  /// [udid] is null). Retries up to ~60 seconds, 1.5s sleeps.
  /// Tunneld.swift:46
  static Future<Tunnel> discoverTunnel({required String? udid}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    var lastUnreachable = true;

    while (DateTime.now().isBefore(deadline)) {
      try {
        final data = await _fetch();
        lastUnreachable = false;
        final tunnel = _parseTunnel(data, udid);
        if (tunnel != null) return tunnel;
      } catch (_) {
        // Keep retrying until deadline.
      }
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    }

    if (lastUnreachable) {
      throw XcrossError(
        'Cannot reach the tunneld REST API on 127.0.0.1:49151.\n\n'
        'Start it (in another terminal, leave it running):\n\n'
        '    sudo pymobiledevice3 remote tunneld',
      );
    }
    final target = udid != null ? 'for device $udid' : 'for any device';
    throw XcrossError(
      'No RSD tunnel $target yet. Make sure the iPhone is connected, '
      'unlocked, and trusted; if it just connected, give tunneld a few '
      'seconds and re-run.',
    );
  }

  // Tunneld.swift:71
  static Future<Map<String, dynamic>> _fetch() async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 5);
    try {
      final request =
          await client.getUrl(Uri.parse(DeviceConstants.tunneldUrl));
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw XcrossError('tunneld returned HTTP ${response.statusCode}');
      }
      final body = await response.transform(utf8.decoder).join();
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  // Tunneld.swift:82 — accept multi-version JSON field names
  static Tunnel? _parseTunnel(Map<String, dynamic> root, String? udid) {
    final List<dynamic> candidates;
    if (udid != null && root.containsKey(udid)) {
      candidates = [root[udid]];
    } else {
      candidates = root.values.toList();
    }

    for (final value in candidates) {
      if (value is! List) continue;
      if (value.isEmpty) continue;
      final first = value.first;
      if (first is! Map) continue;

      // Tunneld.swift:95 — address field variants
      final addr = (first['tunnel-address'] as String?) ??
          (first['address'] as String?) ??
          (first['tunnel_address'] as String?);

      // Tunneld.swift:99 — port field variants (try tunnel-port before port,
      // int before String; switch expression preserves that precedence).
      final port = switch ((first['tunnel-port'], first['port'])) {
        (final int tp, _) => tp,
        (_, final int rp) => rp,
        (final String tp, _) => int.tryParse(tp),
        (_, final String rp) => int.tryParse(rp),
        _ => null,
      };

      if (addr != null && port != null) {
        logStatus('[xtool] found RSD tunnel: $addr:$port');
        return Tunnel(address: addr, port: port);
      }
    }
    return null;
  }
}
