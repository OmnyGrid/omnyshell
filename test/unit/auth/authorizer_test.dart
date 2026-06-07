import 'package:omnyshell/omnyshell.dart';
import 'package:test/test.dart';

void main() {
  NodeDescriptor node({Map<String, String> labels = const {}}) =>
      NodeDescriptor(
        id: NodeId('n1'),
        displayName: 'n1',
        platform: const PlatformInfo(
          os: 'linux',
          arch: 'x64',
          agentVersion: '0.1.0',
          hostname: 'host',
        ),
        online: true,
        labels: labels,
      );

  Principal principal(Set<String> roles) =>
      Principal(id: PrincipalId('p'), displayName: 'p', roles: roles);

  const authorizer = RoleBasedAuthorizer();

  test('admins may open sessions on any node', () async {
    final allowed = await authorizer.canOpenSession(
      principal: principal({'admin'}),
      node: node(),
      mode: SessionMode.exec,
    );
    expect(allowed, isTrue);
  });

  test('non-admins need a matching allow-roles label', () async {
    final n = node(labels: {'allow-roles': 'developer,ci'});
    expect(
      await authorizer.canOpenSession(
        principal: principal({'developer'}),
        node: n,
        mode: SessionMode.shell,
      ),
      isTrue,
    );
    expect(
      await authorizer.canOpenSession(
        principal: principal({'guest'}),
        node: n,
        mode: SessionMode.shell,
      ),
      isFalse,
    );
  });

  test('a node without allow-roles is admin-only (fails closed)', () async {
    expect(
      await authorizer.canOpenSession(
        principal: principal({'developer'}),
        node: node(),
        mode: SessionMode.exec,
      ),
      isFalse,
    );
  });
}
