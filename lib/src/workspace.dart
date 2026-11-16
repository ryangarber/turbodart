import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'config.dart';
import 'errors.dart';
import 'files.dart';

/// A package in the workspace: the root, or a `workspace` member.
class Package {
  Package({
    required this.name,
    required this.dir,
    required this.path,
    required this.isRoot,
    required this.dependencies,
    required this.devDependencies,
    required this.tasks,
  });

  final String name;

  /// The absolute, normalized directory.
  final String dir;

  /// The directory relative to the workspace root, `/`-separated; `.` for
  /// the root.
  final String path;

  final bool isRoot;

  /// Names of everything in `dependencies`.
  final Set<String> dependencies;

  /// Names of everything in `dev_dependencies`.
  final Set<String> devDependencies;

  /// The `turbodart.tasks` of a member's own pubspec.
  final TaskTable tasks;

  /// How `package#task` refers to it.
  String get ref => isRoot ? '//' : name;

  @override
  String toString() => name;
}

/// A pub workspace: the root package and its members, recursively.
class Workspace {
  Workspace._(this.rootDir, this.config, this.packages)
    : _byName = {for (final package in packages) package.name: package};

  /// The absolute, normalized root directory.
  final String rootDir;

  final RootConfig config;

  /// The root first, then the members by path.
  final List<Package> packages;

  final Map<String, Package> _byName;

  final _transitiveDeps = <Package, Set<Package>>{};

  Package get root => packages.first;

  /// Loads the workspace containing [startDir].
  static Workspace load(String startDir) {
    final rootDir = findRoot(startDir);
    final rootPubspec = _readPubspec(rootDir);
    final config = RootConfig.parse(
      rootPubspec['turbodart'],
      '${_pubspecPath(rootDir, rootDir)}: turbodart',
    );
    final packages = [_package(rootDir, rootDir, rootPubspec, isRoot: true)];
    final memberDirs = <String>[];
    _collectMembers(rootDir, rootDir, rootPubspec, memberDirs);
    packages.addAll(
      [
          for (final dir in memberDirs)
            _package(rootDir, dir, _readPubspec(dir), isRoot: false),
        ]
        // By the `/`-separated path, so the order is the same on every OS.
        ..sort((a, b) => a.path.compareTo(b.path)),
    );

    final seen = <String, Package>{};
    for (final package in packages) {
      final other = seen[package.name];
      if (other != null) {
        throw ConfigException(
          'Packages "${other.path}" and "${package.path}" are both named '
          '"${package.name}".',
        );
      }
      seen[package.name] = package;
    }
    for (final ref in config.packageTasks.keys) {
      if (ref != '//' && !seen.containsKey(ref)) {
        throw ConfigException(
          '${_pubspecPath(rootDir, rootDir)}: turbodart.tasks: there\'s no '
          'package "$ref" in the workspace.',
        );
      }
    }
    return Workspace._(rootDir, config, packages);
  }

  /// The directory of the outermost pubspec that [startDir] belongs to:
  /// the nearest one, or while that one has `resolution: workspace`, its
  /// enclosing workspace's.
  static String findRoot(String startDir) {
    var dir = p.normalize(p.absolute(startDir));
    String? member;
    while (true) {
      final pubspec = File(p.join(dir, 'pubspec.yaml'));
      if (pubspec.existsSync()) {
        final yaml = _readPubspec(dir);
        final isMember = yaml['resolution'] == 'workspace';
        if (member == null || yaml['workspace'] is List) {
          if (!isMember) return dir;
          member = dir;
        }
      }
      final parent = p.dirname(dir);
      if (parent == dir) break;
      dir = parent;
    }
    if (member != null) {
      throw ConfigException(
        '${p.join(member, 'pubspec.yaml')} has "resolution: workspace", but no '
        'enclosing pubspec.yaml lists it in its workspace.',
      );
    }
    throw ConfigException(
      'No pubspec.yaml found in ${p.normalize(p.absolute(startDir))} or its '
      'parents.',
    );
  }

  /// The package `//` or a name refers to.
  Package? lookup(String ref) => ref == '//' ? root : _byName[ref];

  /// The workspace packages [package] depends on directly; with [dev], also
  /// through `dev_dependencies`.
  List<Package> directDependencies(Package package, {bool dev = true}) => [
    for (final other in packages)
      if (other != package &&
          (package.dependencies.contains(other.name) ||
              (dev && package.devDependencies.contains(other.name))))
        other,
  ];

  /// The workspace packages [package] depends on, directly (including
  /// `dev_dependencies`) or through their `dependencies`.
  Set<Package> transitiveDependencies(Package package) =>
      _transitiveDeps[package] ??= () {
        final found = <Package>{};
        final pending = directDependencies(package);
        while (pending.isNotEmpty) {
          final next = pending.removeLast();
          if (next == package || !found.add(next)) continue;
          pending.addAll(directDependencies(next, dev: false));
        }
        return found;
      }();

  /// The workspace packages that depend on [package], directly or not.
  Set<Package> transitiveDependents(Package package) => {
    for (final other in packages)
      if (transitiveDependencies(other).contains(package)) other,
  };

  /// The package whose directory most closely contains [absolutePath].
  Package owner(String absolutePath) {
    final path = p.normalize(absolutePath);
    Package? best;
    for (final package in packages) {
      if ((p.equals(package.dir, path) || p.isWithin(package.dir, path)) &&
          (best == null || package.dir.length > best.dir.length)) {
        best = package;
      }
    }
    return best ?? root;
  }

  /// Whether [dir] is another package's directory, nested inside
  /// [package]'s: its files belong to that package, not [package].
  bool isNestedPackage(Package package, String dir) {
    final normalized = p.normalize(dir);
    return normalized != package.dir &&
        packages.any((other) => other.dir == normalized);
  }

  /// Every task name defined anywhere, enabled or not.
  Set<String> get taskNames => {
    ...config.tasks.keys,
    for (final table in config.packageTasks.values) ...table.keys,
    for (final package in packages) ...package.tasks.keys,
  };

  /// [task] as it applies to [package], with the shared definition, then the
  /// root's `package#task`, then the package's own merged in order; `null` if
  /// it's not defined there or disabled with `false`.
  ResolvedTask? taskFor(Package package, String task) {
    final layers = [
      config.tasks,
      ?config.packageTasks[package.ref],
      if (package.isRoot) ?config.packageTasks[package.name],
      package.tasks,
    ];
    TaskDef? def;
    for (final layer in layers) {
      if (!layer.containsKey(task)) continue;
      final value = layer[task];
      def = value == null ? null : (def ?? const TaskDef()).merge(value);
    }
    return def == null ? null : ResolvedTask(def);
  }

  static Package _package(
    String rootDir,
    String dir,
    Map<Object?, Object?> pubspec, {
    required bool isRoot,
  }) {
    final where = _pubspecPath(rootDir, dir);
    final name = pubspec['name'];
    if (name is! String || name.isEmpty) {
      throw ConfigException('$where: missing "name".');
    }
    final turbodart = pubspec['turbodart'];
    TaskTable tasks = const {};
    if (!isRoot && turbodart != null) {
      if (turbodart is! Map) {
        throw ConfigException('$where: turbodart: expected a map.');
      }
      for (final key in turbodart.keys) {
        if (key != 'tasks') {
          throw ConfigException(
            '$where: turbodart: "$key" is only allowed in the workspace '
            'root\'s pubspec; a package\'s can only have "tasks".',
          );
        }
      }
      tasks = parseTasks(turbodart['tasks'], '$where: turbodart.tasks');
    }
    Set<String> names(Object? deps) =>
        deps is Map ? deps.keys.whereType<String>().toSet() : {};
    final rel = p.relative(dir, from: rootDir);
    return Package(
      name: name,
      dir: dir,
      path: p.split(rel).join('/'),
      isRoot: isRoot,
      dependencies: names(pubspec['dependencies']),
      devDependencies: names(pubspec['dev_dependencies']),
      tasks: tasks,
    );
  }

  static void _collectMembers(
    String rootDir,
    String dir,
    Map<Object?, Object?> pubspec,
    List<String> out,
  ) {
    final entries = pubspec['workspace'];
    if (entries == null) return;
    final where = '${_pubspecPath(rootDir, dir)}: workspace';
    if (entries is! List) throw ConfigException('$where: expected a list.');
    for (final entry in entries) {
      if (entry is! String) {
        throw ConfigException('$where: "$entry" isn\'t a path.');
      }
      final pattern = normalizePattern(entry, where);
      final List<String> memberDirs;
      if (isGlob(pattern)) {
        final glob = Glob(pattern, context: p.posix);
        final segments = pattern.split('/');
        final prefix = segments.take(segments.indexWhere(isGlob)).join('/');
        memberDirs = [
          for (final rel in walk(dir, prefix, null, directories: true))
            if (glob.matches(rel) &&
                File(p.join(dir, rel, 'pubspec.yaml')).existsSync())
              p.normalize(p.join(dir, rel)),
        ]..sort();
      } else {
        final memberDir = p.normalize(p.join(dir, pattern));
        if (!File(p.join(memberDir, 'pubspec.yaml')).existsSync()) {
          throw ConfigException('$where: "$entry" has no pubspec.yaml.');
        }
        memberDirs = [memberDir];
      }
      for (final memberDir in memberDirs) {
        if (out.contains(memberDir) || memberDir == rootDir) continue;
        out.add(memberDir);
        _collectMembers(rootDir, memberDir, _readPubspec(memberDir), out);
      }
    }
  }

  static String _pubspecPath(String rootDir, String dir) =>
      p.split(p.relative(p.join(dir, 'pubspec.yaml'), from: rootDir)).join('/');

  static Map<Object?, Object?> _readPubspec(String dir) {
    final path = p.join(dir, 'pubspec.yaml');
    try {
      final yaml = loadYaml(
        File(path).readAsStringSync(),
        sourceUrl: Uri.file(path),
      );
      if (yaml is! Map) throw ConfigException('$path: expected a map.');
      return yaml;
    } on YamlException catch (e) {
      throw ConfigException('$path: ${e.message}');
    } on FileSystemException catch (e) {
      throw ConfigException('$path: ${e.message}');
    }
  }
}
