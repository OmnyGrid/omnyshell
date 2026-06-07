import '../../shared/utils/clock.dart';

/// A single audit entry recording a security-relevant Hub event.
class AuditRecord {
  /// When the event occurred.
  final DateTime at;

  /// The action (e.g. `auth.ok`, `auth.fail`, `session.open`,
  /// `session.rejected`, `session.close`).
  final String action;

  /// The acting principal id, if known.
  final String? principal;

  /// Free-form structured detail.
  final Map<String, dynamic> detail;

  /// Creates an audit record.
  AuditRecord({
    required this.at,
    required this.action,
    this.principal,
    this.detail = const {},
  });

  /// Serializes to a JSON map.
  Map<String, dynamic> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'action': action,
    if (principal != null) 'principal': principal,
    if (detail.isNotEmpty) 'detail': detail,
  };
}

/// A bounded, in-memory audit log of Hub security events.
///
/// Stage 1 keeps the most recent [capacity] records in memory; later stages can
/// add pluggable sinks (file, syslog, SIEM) behind the same append API.
class AuditLog {
  final Clock _clock;
  final int capacity;
  final List<AuditRecord> _records = [];

  /// Creates an audit log retaining up to [capacity] records.
  AuditLog({Clock clock = const SystemClock(), this.capacity = 1000})
    : _clock = clock;

  /// The retained records, oldest first.
  List<AuditRecord> get records => List.unmodifiable(_records);

  /// Appends an event.
  void record(
    String action, {
    String? principal,
    Map<String, dynamic> detail = const {},
  }) {
    _records.add(
      AuditRecord(
        at: _clock.now(),
        action: action,
        principal: principal,
        detail: detail,
      ),
    );
    if (_records.length > capacity) {
      _records.removeRange(0, _records.length - capacity);
    }
  }
}
