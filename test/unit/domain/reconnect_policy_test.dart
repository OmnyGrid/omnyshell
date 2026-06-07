import 'dart:math';

import 'package:omnyshell/omnyshell_node.dart';
import 'package:test/test.dart';

void main() {
  test('grows exponentially and caps at maxDelay', () {
    final policy = ReconnectPolicy(
      initial: const Duration(seconds: 1),
      maxDelay: const Duration(seconds: 8),
      factor: 2,
      jitter: 0,
      random: Random(1),
    );
    expect(policy.nextDelay(), const Duration(seconds: 1));
    expect(policy.nextDelay(), const Duration(seconds: 2));
    expect(policy.nextDelay(), const Duration(seconds: 4));
    expect(policy.nextDelay(), const Duration(seconds: 8));
    expect(policy.nextDelay(), const Duration(seconds: 8)); // capped
  });

  test('reset returns to the initial delay', () {
    final policy = ReconnectPolicy(jitter: 0, random: Random(1));
    policy.nextDelay();
    policy.nextDelay();
    policy.reset();
    expect(policy.attempt, 0);
    expect(policy.nextDelay(), const Duration(seconds: 1));
  });

  test('jitter stays within the configured fraction', () {
    final policy = ReconnectPolicy(
      initial: const Duration(seconds: 10),
      maxDelay: const Duration(seconds: 10),
      jitter: 0.2,
      random: Random(7),
    );
    final delay = policy.nextDelay();
    expect(delay.inMilliseconds, greaterThanOrEqualTo(10000));
    expect(delay.inMilliseconds, lessThanOrEqualTo(12000));
  });
}
