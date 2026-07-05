/// Constants for device connectivity and interactive keypress handling.
abstract final class DeviceConstants {
  /// VM service port used when launching the app on device.
  static const int vmServicePort = 12345;

  /// RSD service name for the Apple remote debug proxy.
  static const String debugproxyService =
      'com.apple.internal.dt.remote.debugproxy';

  /// Default tunneld REST API base URL.
  static const String tunneldUrl = 'http://127.0.0.1:49151/';

  /// Name of the DevFS filesystem registered with the Dart VM.
  static const String devFsName = 'xtool';

  /// Keycode for 'q' — quits the running session.
  static const int keyQ = 0x71;

  /// Keycode for 'r' — triggers a hot reload.
  static const int keyR = 0x72;

  /// Keycode for 'R' — triggers a hot restart.
  static const int keyBigR = 0x52;

  /// Keycode for Ctrl-C — terminates the session.
  static const int keyCtrlC = 0x03;

  /// Keycode for Ctrl-D — terminates the session.
  static const int keyCtrlD = 0x04;
}
