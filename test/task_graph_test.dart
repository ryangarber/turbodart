import 'package:test/test.dart';
import 'package:turbodart/turbodart.dart';

import 'fixture.dart';

void main() {
  List<String> ids(TaskGraph graph) => graph.nodes.map((n) => n.id).toList();

  test('^task runs dependencies first; task runs in the same package', () {
    final ws = standardWorkspace(
      tasks: '''
    build:
      run: echo build
      dependsOn: [^build]
    test:
      run: echo test
      dependsOn: [build]
    "//#build": false
    "//#test": false
''',
    ).load();
    final graph = TaskGraph.build(
      ws,
      packages: [ws.lookup('app')!],
      tasks: ['test'],
    );
    expect(ids(graph), ['util#build', 'core#build', 'app#build', 'app#test']);
    expect(graph.nodes.where((n) => n.isEntry).map((n) => n.id), ['app#test']);
  });

  test('package#task depends on a specific package', () {
    final ws = standardWorkspace(
      tasks: '''
    gen: echo gen
    build:
      run: echo build
      dependsOn: ["util#gen"]
''',
    ).load();
    final graph = TaskGraph.build(
      ws,
      packages: [ws.lookup('app')!],
      tasks: ['build'],
    );
    expect(ids(graph), ['util#gen', 'app#build']);
  });

  test('package#task on the command line ignores the selection', () {
    final ws = standardWorkspace(tasks: '    gen: echo gen\n').load();
    final graph = TaskGraph.build(ws, packages: [], tasks: ['core#gen']);
    expect(ids(graph), ['core#gen']);
  });

  test('skips packages where a task is disabled', () {
    final ws = standardWorkspace(
      tasks:
          '    test: echo test\n    "//#test": false\n    core#test: false\n',
    ).load();
    final graph = TaskGraph.build(ws, packages: ws.packages, tasks: ['test']);
    expect(ids(graph), ['app#test', 'tool#test', 'util#test']);
  });

  test('rejects unknown tasks', () {
    final ws = standardWorkspace(tasks: '    test: echo test\n').load();
    expect(
      () => TaskGraph.build(ws, packages: ws.packages, tasks: ['nope']),
      throwsA(isA<UsageException>()),
    );
    final bad = standardWorkspace(
      tasks: '    test:\n      run: x\n      dependsOn: [nope]\n',
    ).load();
    expect(
      () => TaskGraph.build(bad, packages: bad.packages, tasks: ['test']),
      throwsA(isA<ConfigException>()),
    );
  });

  test('rejects cycles', () {
    final ws = standardWorkspace(
      tasks: '''
    a:
      run: echo a
      dependsOn: [b]
    b:
      run: echo b
      dependsOn: [a]
''',
    ).load();
    expect(
      () => TaskGraph.build(ws, packages: [ws.lookup('util')!], tasks: ['a']),
      throwsA(
        isA<ConfigException>().having(
          (e) => e.message,
          'message',
          contains('util#a -> util#b -> util#a'),
        ),
      ),
    );
  });
}
