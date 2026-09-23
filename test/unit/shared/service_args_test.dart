import 'package:omnyshell/src/shared/utils/service_args.dart';
import 'package:test/test.dart';

void main() {
  group('serviceCommandArgs', () {
    test('keeps a vector that already starts with the role command', () {
      expect(serviceCommandArgs('hub', ['hub', 'start', '--port', '8080']), [
        'hub',
        'start',
        '--port',
        '8080',
      ]);
    });

    test('drops the snapshot a Dart VM install recorded ahead of it', () {
      expect(
        serviceCommandArgs('hub', [
          '/home/u/.pub-cache/global_packages/omnyshell/bin/'
              'omnyshell.dart-3.12.1.snapshot',
          'hub',
          'start',
          '--host',
          '0.0.0.0',
        ]),
        ['hub', 'start', '--host', '0.0.0.0'],
      );
    });

    test('drops every runtime prefix already doubled by a past reinstall', () {
      expect(
        serviceCommandArgs('node', [
          '/cache/omnyshell.dart-3.12.1.snapshot',
          '/cache/omnyshell.dart-3.11.0.snapshot',
          'node',
          'start',
          '--id',
          'web-01',
        ]),
        ['node', 'start', '--id', 'web-01'],
      );
    });

    test('does not match a later option value equal to the role', () {
      expect(serviceCommandArgs('node', ['node', 'start', '--name', 'node']), [
        'node',
        'start',
        '--name',
        'node',
      ]);
    });

    test('returns an unrecognised vector unchanged', () {
      expect(serviceCommandArgs('hub', ['serve', '--port', '1']), [
        'serve',
        '--port',
        '1',
      ]);
    });
  });
}
