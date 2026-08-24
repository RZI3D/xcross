import 'package:test/test.dart';
import 'package:xcross/src/device/core_device_launcher.dart';
import 'package:xcross/src/device/device_log.dart';

void main() {
  test('device logs disable Python stdout buffering', () {
    expect(DeviceLog.processEnvironment(const {'EXISTING': 'value'}), {
      'EXISTING': 'value',
      'PYTHONUNBUFFERED': '1',
    });
  });

  test('device logs keep only the launched process', () {
    expect(
      DeviceLog.appLogMessage(
        '{"pid":13457,"message":"first Flutter frame rendered"}',
        13457,
      ),
      'first Flutter frame rendered',
    );
    expect(
      DeviceLog.appLogMessage(
        '{"pid":42,"message":"unrelated system log"}',
        13457,
      ),
      isNull,
    );
    expect(DeviceLog.appLogMessage('not json', 13457), isNull);
  });

  test('device logs stay disabled outside verbose mode', () async {
    expect(
      await DeviceLog.start(deviceArgs: const [], pid: 1, enabled: false),
      isNull,
    );
  });

  String pick(List<String> installed, String requested) =>
      CoreDeviceLauncher.pickInstalledBundleId(
        installed: installed,
        requested: requested,
      );

  test('prefers the XCR-qualified build over the production one', () {
    expect(
      pick([
        'com.production.app',
        'XCR-ABCD1234.com.production.app',
      ], 'com.production.app'),
      'XCR-ABCD1234.com.production.app',
    );
  });

  test('falls back to the requested id when no qualified build exists', () {
    expect(
      pick(['com.production.app'], 'com.production.app'),
      'com.production.app',
    );
  });

  test('does not match unrelated suffixes', () {
    expect(
      pick(['com.other.com.example.App'], 'com.example.App'),
      'com.example.App',
    );
  });

  test('shortest qualified match wins', () {
    expect(
      pick([
        'XCR-LONGERTEAMID.com.example.App',
        'XCR-ABCD.com.example.App',
      ], 'com.example.App'),
      'XCR-ABCD.com.example.App',
    );
  });

  test('does not match an extension of the app id', () {
    expect(
      pick(['XCR-ABCD.com.example.App.Share-Extension'], 'com.example.App'),
      'com.example.App',
    );
  });

  test('already-qualified request resolves to itself', () {
    expect(
      pick(['XCR-ABCD.com.example.App'], 'XCR-ABCD.com.example.App'),
      'XCR-ABCD.com.example.App',
    );
  });
}
