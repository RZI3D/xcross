/// A user-facing error from device transport, tunnels, or pymobiledevice3.
base class TunnelError implements Exception {
  TunnelError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// tunneld answered, but refused to create an RSD tunnel for the device.
///
/// Distinct from every other [TunnelError] because it is *recoverable*:
/// mounting the Developer Disk Image and starting a lockdown tunnel — what
/// `xcross tunnel` does — is exactly what tunneld could not do for itself.
final class TunnelCreationError extends TunnelError {
  TunnelCreationError(super.message);
}
