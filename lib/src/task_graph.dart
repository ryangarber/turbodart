import 'config.dart';
import 'errors.dart';
import 'workspace.dart';

/// A task to run in one package.
class TaskNode {
  TaskNode(this.package, this.task, this.def);

  final Package package;
  final String task;
  final ResolvedTask def;

  /// The tasks that must succeed first.
  final List<TaskNode> dependencies = [];

  /// Whether it was asked for on the command line, rather than only as a
  /// dependency, so it gets the arguments after `--`.
  bool isEntry = false;

  String get id => '${package.name}#$task';

  @override
  String toString() => id;
}

/// The tasks to run, with their dependencies, in an order where each comes
/// after everything it depends on.
class TaskGraph {
  TaskGraph._(this.nodes);

  final List<TaskNode> nodes;

  /// The graph of [tasks] in [packages]. A `package#task` runs in that
  /// package regardless of [packages].
  static TaskGraph build(
    Workspace workspace, {
    required List<Package> packages,
    required List<String> tasks,
  }) {
    final known = workspace.taskNames;
    final created = <String, TaskNode?>{};

    late final TaskNode Function(Package, String, String) required;

    TaskNode? node(Package package, String task) {
      final key = '${package.name}#$task';
      if (created.containsKey(key)) return created[key];
      final def = workspace.taskFor(package, task);
      if (def == null) return created[key] = null;
      final self = created[key] = TaskNode(package, task, def);
      void add(TaskNode? dependency) {
        if (dependency != null && !self.dependencies.contains(dependency)) {
          self.dependencies.add(dependency);
        }
      }

      for (final dep in def.dependsOn) {
        final where = '${self.id}: dependsOn "$dep"';
        final hash = dep.indexOf('#');
        if (hash != -1) {
          final ref = dep.substring(0, hash);
          final target = workspace.lookup(ref);
          if (target == null) {
            throw ConfigException('$where: there\'s no package "$ref".');
          }
          add(required(target, dep.substring(hash + 1), where));
        } else if (dep.startsWith('^')) {
          final name = dep.substring(1);
          _checkKnown(name, known, where);
          for (final target in workspace.directDependencies(package)) {
            add(node(target, name));
          }
        } else {
          _checkKnown(dep, known, where);
          add(node(package, dep));
        }
      }
      return self;
    }

    required = (package, task, where) {
      _checkKnown(task, known, where);
      return node(package, task) ??
          (throw ConfigException(
            '$where: task "$task" is disabled in package "${package.name}".',
          ));
    };

    final entries = <TaskNode>[];
    for (final spec in tasks) {
      final hash = spec.indexOf('#');
      if (hash != -1) {
        final ref = spec.substring(0, hash);
        final name = spec.substring(hash + 1);
        final target = workspace.lookup(ref);
        if (target == null) {
          throw UsageException('There\'s no package "$ref" in the workspace.');
        }
        entries.add(required(target, name, '"$spec"'));
      } else {
        if (!known.contains(spec)) {
          throw UsageException(
            'There\'s no task "$spec" in the workspace.'
            '${known.isEmpty ? '' : ' Tasks: ${(known.toList()..sort()).join(', ')}.'}',
          );
        }
        for (final package in packages) {
          if (node(package, spec) case final entry?) entries.add(entry);
        }
      }
    }
    for (final entry in entries) {
      entry.isEntry = true;
    }
    return TaskGraph._(_sort(entries));
  }

  static void _checkKnown(String task, Set<String> known, String where) {
    if (!known.contains(task)) {
      throw ConfigException('$where: there\'s no task "$task".');
    }
  }

  static List<TaskNode> _sort(List<TaskNode> entries) {
    final order = <TaskNode>[];
    final state = <TaskNode, bool>{}; // false: visiting, true: done
    final stack = <TaskNode>[];

    void visit(TaskNode node) {
      switch (state[node]) {
        case true:
          return;
        case false:
          final cycle = [...stack.skip(stack.indexOf(node)), node];
          throw ConfigException(
            'Tasks depend on each other in a cycle: ${cycle.join(' -> ')}.',
          );
        case null:
          state[node] = false;
          stack.add(node);
          node.dependencies.forEach(visit);
          stack.removeLast();
          state[node] = true;
          order.add(node);
      }
    }

    entries.forEach(visit);
    return order;
  }
}
