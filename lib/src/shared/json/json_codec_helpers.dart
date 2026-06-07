import '../errors/omnyshell_exception.dart';

/// Manual JSON read helpers shared by control-message decoders.
///
/// OmnyShell follows the sibling packages' convention of hand-written
/// `toJson`/`fromJson` (no code generation). These helpers centralise the
/// type-checking and error reporting so each decoder stays terse and fails
/// with a [ProtocolException] (rather than a raw `TypeError`) on bad input.
class Json {
  const Json._();

  /// Casts an arbitrary [value] to a `Map<String, dynamic>`.
  ///
  /// Throws [ProtocolException] if [value] is not a JSON object.
  static Map<String, dynamic> asObject(Object? value, [String what = 'value']) {
    if (value is Map) return value.cast<String, dynamic>();
    throw ProtocolException('Expected $what to be a JSON object');
  }

  /// Reads a required string field [key] from [json].
  static String requireString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is String) return value;
    throw ProtocolException("Missing or invalid string field '$key'");
  }

  /// Reads an optional string field [key], returning `null` if absent.
  static String? optString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is String) return value;
    throw ProtocolException("Invalid string field '$key'");
  }

  /// Reads a required int field [key] from [json].
  static int requireInt(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is int) return value;
    throw ProtocolException("Missing or invalid int field '$key'");
  }

  /// Reads an optional int field [key], returning [fallback] if absent.
  static int? optInt(Map<String, dynamic> json, String key, [int? fallback]) {
    final value = json[key];
    if (value == null) return fallback;
    if (value is int) return value;
    throw ProtocolException("Invalid int field '$key'");
  }

  /// Reads an optional bool field [key], returning [fallback] if absent.
  static bool optBool(
    Map<String, dynamic> json,
    String key, {
    bool fallback = false,
  }) {
    final value = json[key];
    if (value == null) return fallback;
    if (value is bool) return value;
    throw ProtocolException("Invalid bool field '$key'");
  }

  /// Reads a required ISO-8601 timestamp field [key] as a UTC [DateTime].
  static DateTime requireTimestamp(Map<String, dynamic> json, String key) {
    final raw = requireString(json, key);
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) {
      throw ProtocolException("Invalid timestamp field '$key'");
    }
    return parsed.toUtc();
  }

  /// Reads an optional ISO-8601 timestamp field [key].
  static DateTime? optTimestamp(Map<String, dynamic> json, String key) {
    final raw = optString(json, key);
    if (raw == null) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) {
      throw ProtocolException("Invalid timestamp field '$key'");
    }
    return parsed.toUtc();
  }

  /// Reads an optional string→string map field [key], returning an empty map
  /// if absent.
  static Map<String, String> optStringMap(
    Map<String, dynamic> json,
    String key,
  ) {
    final value = json[key];
    if (value == null) return const {};
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), v.toString()));
    }
    throw ProtocolException("Invalid map field '$key'");
  }

  /// Reads an optional list of strings field [key], returning an empty list if
  /// absent.
  static List<String> optStringList(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value == null) return const [];
    if (value is List) return value.map((e) => e.toString()).toList();
    throw ProtocolException("Invalid list field '$key'");
  }
}
