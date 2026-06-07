import '../shared/errors/omnyshell_exception.dart';

/// The stream a binary data frame belongs to, encoded as the `msgType` byte of
/// the data-frame header.
enum DataOpcode {
  /// Client → node: standard input bytes (`0x01`).
  stdin(0x01),

  /// Node → client: standard output bytes (`0x02`).
  stdout(0x02),

  /// Node → client: standard error bytes (`0x03`).
  stderr(0x03);

  /// The on-wire byte value.
  final int wire;

  const DataOpcode(this.wire);

  /// Resolves a [DataOpcode] from its on-wire byte [value].
  ///
  /// Throws [ProtocolException] if [value] is not a known data opcode.
  static DataOpcode fromWire(int value) => switch (value) {
    0x01 => DataOpcode.stdin,
    0x02 => DataOpcode.stdout,
    0x03 => DataOpcode.stderr,
    _ => throw ProtocolException(
      'Unknown data opcode: 0x${value.toRadixString(16)}',
    ),
  };
}
