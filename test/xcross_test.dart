import 'package:test/test.dart';
import 'package:xcross/src/xtool/xtool_cli.dart';

void main() {
  group('xtool devices parsing', () {
    test('parses name, connection type, and udid', () {
      final devices = XtoolCli.parseDevices(
        'iPhone 15 Pro [usb]: 00008130-001234ABCDEF1234\n',
      );
      expect(devices, hasLength(1));
      expect(devices.single.name, 'iPhone 15 Pro');
      expect(devices.single.udid, '00008130-001234ABCDEF1234');
    });

    test('ignores blank/unmatched lines', () {
      final devices = XtoolCli.parseDevices('\nno devices found\n');
      expect(devices, isEmpty);
    });
  });

  group('DeviceSearchMode.flag', () {
    test('usb maps to --usb', () {
      expect(DeviceSearchMode.usb.flag, '--usb');
    });

    // Regression check: upstream xtool's SearchMode flag is `--network`,
    // not `--wifi` — passing the wrong flag would silently fall through to
    // xtool's default (all) search mode.
    test('wifi maps to --network, not --wifi', () {
      expect(DeviceSearchMode.wifi.flag, '--network');
    });

    test('all has no flag', () {
      expect(DeviceSearchMode.all.flag, isNull);
    });
  });
}
