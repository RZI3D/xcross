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
}
