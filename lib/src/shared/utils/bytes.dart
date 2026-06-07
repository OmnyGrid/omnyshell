import 'dart:typed_data';

/// Big-endian byte helpers used by the binary data-frame header.
///
/// The data-frame header packs a `uint32` channel id and a `uint32` payload
/// length, both big-endian (network byte order). These helpers keep the codec
/// free of inline bit-twiddling.
class Bytes {
  const Bytes._();

  /// The maximum value a `uint32` field can hold.
  static const int maxUint32 = 0xFFFFFFFF;

  /// Writes [value] as a big-endian `uint32` into [target] starting at
  /// [offset].
  ///
  /// Throws [ArgumentError] if [value] is negative or exceeds [maxUint32].
  static void writeUint32(Uint8List target, int offset, int value) {
    if (value < 0 || value > maxUint32) {
      throw ArgumentError.value(value, 'value', 'not a uint32');
    }
    target[offset] = (value >> 24) & 0xFF;
    target[offset + 1] = (value >> 16) & 0xFF;
    target[offset + 2] = (value >> 8) & 0xFF;
    target[offset + 3] = value & 0xFF;
  }

  /// Reads a big-endian `uint32` from [source] starting at [offset].
  static int readUint32(Uint8List source, int offset) {
    return (source[offset] << 24) |
        (source[offset + 1] << 16) |
        (source[offset + 2] << 8) |
        source[offset + 3];
  }
}
