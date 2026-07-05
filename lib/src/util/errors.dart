/// A user-facing error. Its [message] is printed without a Dart stack trace.
class XcrossError implements Exception {
  XcrossError(this.message);

  final String message;

  @override
  String toString() => message;
}
