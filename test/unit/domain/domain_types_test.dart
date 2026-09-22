@TestOn('vm')
library;

import 'package:omnyshell/omnyshell.dart';
import 'package:omnyshell/src/shared/utils/bytes.dart';
import 'package:test/test.dart';

void main() {
  group('SessionId', () {
    test('carries its value, in equality, hash and toString', () {
      final id = SessionId('s-1');

      expect(id.value, 's-1');
      expect(id, SessionId('s-1'));
      expect(id.hashCode, SessionId('s-1').hashCode);
      expect('$id', 's-1');
      expect(id, isNot(SessionId('s-2')));
      expect(id == Object(), isFalse);
    });

    test('refuses an empty id', () {
      expect(() => SessionId(''), throwsA(isA<ProtocolException>()));
      expect(() => SessionId('   '), throwsA(isA<ProtocolException>()));
    });

    test('generates unique ids', () {
      final ids = {for (var i = 0; i < 50; i++) SessionId.generate().value};

      expect(ids, hasLength(50));
      expect(ids.every((v) => v.isNotEmpty), isTrue);
    });
  });

  group('ChannelId', () {
    test('carries its value, in equality, hash and toString', () {
      final id = ChannelId(7);

      expect(id.value, 7);
      expect(id, ChannelId(7));
      expect(id.hashCode, ChannelId(7).hashCode);
      expect('$id', 'channel#7');
      expect(id, isNot(ChannelId(8)));
      expect(id == Object(), isFalse);
    });

    test('reserves channel 0 for connection control', () {
      expect(ChannelId.control.value, 0);
      expect(ChannelId.control.isControl, isTrue);
      expect(ChannelId(1).isControl, isFalse);
    });

    test('accepts the whole uint32 range and nothing outside it', () {
      expect(ChannelId(0).value, 0);
      expect(ChannelId(Bytes.maxUint32).value, Bytes.maxUint32);
      expect(() => ChannelId(-1), throwsA(isA<ProtocolException>()));
      expect(
        () => ChannelId(Bytes.maxUint32 + 1),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.message,
            'message',
            contains('out of range'),
          ),
        ),
      );
    });
  });

  group('PrincipalId', () {
    test('trims, and carries its value in equality and toString', () {
      final id = PrincipalId('  alice  ');

      expect(id.value, 'alice');
      expect(id, PrincipalId('alice'));
      expect(id.hashCode, PrincipalId('alice').hashCode);
      expect('$id', 'alice');
      expect(id, isNot(PrincipalId('bob')));
      expect(id == Object(), isFalse);
    });

    test('refuses an empty id', () {
      expect(() => PrincipalId('  '), throwsA(isA<ProtocolException>()));
    });
  });

  group('Principal', () {
    final principal = Principal(
      id: PrincipalId('alice'),
      displayName: 'Alice',
      roles: const {'developer', 'admin'},
    );

    test('answers role questions', () {
      expect(principal.hasRole('admin'), isTrue);
      expect(principal.hasRole('node'), isFalse);
      expect(
        Principal(id: PrincipalId('bob'), displayName: 'Bob').roles,
        isEmpty,
      );
    });

    test('serializes with sorted roles, as whoami and the audit log use', () {
      expect(principal.toJson(), {
        'id': 'alice',
        'displayName': 'Alice',
        'roles': ['admin', 'developer'],
      });
    });
  });

  group('SessionMode.parse', () {
    test('reads every wire value', () {
      expect(SessionMode.parse('shell'), SessionMode.shell);
      expect(SessionMode.parse('exec'), SessionMode.exec);
      expect(SessionMode.parse('transfer'), SessionMode.transfer);
      expect(SessionMode.parse('drive'), SessionMode.drive);
      expect(SessionMode.parse('tunnel'), SessionMode.tunnel);
    });

    test('falls back to exec for anything unknown', () {
      expect(SessionMode.parse('nonsense'), SessionMode.exec);
      expect(SessionMode.parse(''), SessionMode.exec);
    });
  });

  group('SessionState.parse', () {
    test('reads every wire value', () {
      expect(SessionState.parse('opening'), SessionState.opening);
      expect(SessionState.parse('open'), SessionState.open);
      expect(SessionState.parse('closing'), SessionState.closing);
      expect(SessionState.parse('closed'), SessionState.closed);
      expect(SessionState.parse('attached'), SessionState.attached);
      expect(SessionState.parse('detached'), SessionState.detached);
    });

    test('falls back to detached, the only state it serializes', () {
      expect(SessionState.parse('nonsense'), SessionState.detached);
    });
  });

  group('Session.copyWith', () {
    final openedAt = DateTime.utc(2026, 1, 1);
    final session = Session(
      id: SessionId('s-1'),
      nodeId: NodeId('n-1'),
      principal: PrincipalId('alice'),
      mode: SessionMode.shell,
      state: SessionState.open,
      openedAt: openedAt,
    );

    test('replaces the state and keeps everything else', () {
      final closed = session.copyWith(state: SessionState.closed);

      expect(closed.state, SessionState.closed);
      expect(closed.id, session.id);
      expect(closed.nodeId, session.nodeId);
      expect(closed.principal, session.principal);
      expect(closed.mode, session.mode);
      expect(closed.openedAt, openedAt);
      expect(closed.exitCode, isNull);
    });

    test('records an exit code', () {
      expect(session.copyWith(exitCode: 3).exitCode, 3);
    });

    test('keeps the current values when given nothing', () {
      final same = session
          .copyWith(state: SessionState.closed, exitCode: 0)
          .copyWith();

      expect(same.state, SessionState.closed);
      expect(same.exitCode, 0);
    });
  });

  group('OmnyShellException', () {
    test('each kind carries its stable wire code', () {
      expect(
        const ProtocolException('bad frame').code,
        ErrorCodes.protocolError,
      );
      expect(const AuthException('nope').code, ErrorCodes.authFailed);
      expect(
        const AuthorizationException('nope').code,
        ErrorCodes.notAuthorized,
      );
      expect(
        const NodeUnavailableException(ErrorCodes.nodeOffline, 'gone').code,
        ErrorCodes.nodeOffline,
      );
      expect(
        const SessionRejectedException('no').code,
        ErrorCodes.sessionRejected,
      );
      expect(const TunnelRejectedException('no').code, 'tunnel_rejected');
      expect(const ChannelException('closed').code, ErrorCodes.unknownChannel);
      expect(const TransportException('down').code, ErrorCodes.transportError);
      expect(const OmnyShellTimeoutException('late').code, ErrorCodes.timeout);
    });

    test('an explicit code overrides the default', () {
      expect(
        const ProtocolException(
          'too big',
          code: ErrorCodes.malformedFrame,
        ).code,
        ErrorCodes.malformedFrame,
      );
      expect(
        const SessionRejectedException('denied', code: 'policy').code,
        'policy',
      );
      expect(
        const ChannelException('gone', code: 'channel_gone').code,
        'channel_gone',
      );
      expect(
        const TunnelRejectedException('taken', code: 'port_in_use').code,
        'port_in_use',
      );
    });

    test('toString names the type, the code and the message', () {
      expect(
        const AuthException('bad token').toString(),
        'AuthException(auth_failed): bad token',
      );
    });

    test('is an Exception, so it survives a generic catch', () {
      expect(const TransportException('down'), isA<Exception>());
    });
  });
}
