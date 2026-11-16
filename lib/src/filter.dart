import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import 'errors.dart';
import 'files.dart';
import 'workspace.dart';

/// Lists files changed in a git range, relative to the workspace root.
typedef ChangedFiles = List<String> Function(String rootDir, String range);

/// A parsed `--filter` selector, in Turborepo's syntax:
///
/// - `name` or `name*`: packages by name; `//` is the root.
/// - `./path`, `{path}`: packages by directory, relative to the current one.
/// - `[ref]`, `[a...b]`: packages with files changed since `ref`, or between
///   two refs; combines with the above, e.g. `{./packages/*}[main]`.
/// - `name...`: also its dependencies; `name^...` only its dependencies.
/// - `...name`: also its dependents; `...^name` only its dependents.
/// - `!selector`: excludes what it matches.
class Selector {
  Selector({
    required this.raw,
    this.exclude = false,
    this.name,
    this.path,
    this.gitRange,
    this.dependencies = false,
    this.dependents = false,
    this.excludeSelf = false,
  });

  final String raw;
  final bool exclude;
  final String? name;
  final String? path;
  final String? gitRange;
  final bool dependencies;
  final bool dependents;
  final bool excludeSelf;

  static final _gitSuffix = RegExp(r'\[([^\]]+)\]$');

  static Selector parse(String raw) {
    var s = raw.trim();
    final exclude = s.startsWith('!');
    if (exclude) s = s.substring(1);
    var dependents = false, dependencies = false, excludeSelf = false;
    if (s.startsWith('...')) {
      dependents = true;
      s = s.substring(3);
      if (s.startsWith('^')) {
        excludeSelf = true;
        s = s.substring(1);
      }
    }
    if (s.endsWith('...')) {
      dependencies = true;
      s = s.substring(0, s.length - 3);
      if (s.endsWith('^')) {
        excludeSelf = true;
        s = s.substring(0, s.length - 1);
      }
    }
    String? gitRange, path, name;
    final git = _gitSuffix.firstMatch(s);
    if (git != null) {
      gitRange = git[1];
      s = s.substring(0, git.start);
    }
    if (s.startsWith('{') && s.endsWith('}')) {
      path = s.substring(1, s.length - 1);
    } else if (s != '//' && (s.startsWith('.') || s.startsWith('/'))) {
      path = s;
    } else if (s.isNotEmpty) {
      name = s;
    }
    if (name == null && path == null && gitRange == null) {
      throw UsageException('Invalid filter "$raw".');
    }
    return Selector(
      raw: raw,
      exclude: exclude,
      name: name,
      path: path,
      gitRange: gitRange,
      dependencies: dependencies,
      dependents: dependents,
      excludeSelf: excludeSelf,
    );
  }

  /// The packages this selects, before [exclude] is applied.
  Set<Package> select(
    Workspace workspace, {
    required String cwd,
    ChangedFiles changedFiles = gitChangedFiles,
  }) {
    Iterable<Package> matched = workspace.packages;
    if (name case final name?) {
      final pattern = RegExp(
        '^${name.split('*').map(RegExp.escape).join('.*')}\$',
      );
      matched = matched.where(
        (package) =>
            pattern.hasMatch(package.name) || (package.isRoot && name == '//'),
      );
    }
    if (path case final path?) {
      final absolute = p.normalize(p.join(cwd, path));
      final rel = p
          .split(p.relative(absolute, from: workspace.rootDir))
          .join('/');
      if (rel == '..' || rel.startsWith('../')) {
        throw UsageException('Filter "$raw" is outside the workspace.');
      }
      final match = isGlob(rel)
          ? Glob(rel, context: p.posix).matches
          : (String other) => other == rel;
      matched = matched.where((package) => match(package.path));
    }
    if (gitRange case final range?) {
      final changed = {
        for (final file in changedFiles(workspace.rootDir, range))
          workspace.owner(p.join(workspace.rootDir, file)),
      };
      matched = matched.where(changed.contains);
    }

    final base = matched.toSet();
    return {
      if (!excludeSelf) ...base,
      if (dependencies)
        for (final package in base)
          ...workspace.transitiveDependencies(package),
      if (dependents)
        for (final package in base) ...workspace.transitiveDependents(package),
    };
  }
}

/// The packages [filters] select: those any non-`!` selector matches (or all
/// of them, without one), less those any `!` selector matches.
List<Package> filterPackages(
  Workspace workspace,
  List<String> filters, {
  required String cwd,
  ChangedFiles changedFiles = gitChangedFiles,
}) {
  final selectors = filters.map(Selector.parse).toList();
  final included = <Package>{};
  final excluded = <Package>{};
  var anyIncludes = false;
  for (final selector in selectors) {
    final selected = selector.select(
      workspace,
      cwd: cwd,
      changedFiles: changedFiles,
    );
    if (selector.exclude) {
      excluded.addAll(selected);
    } else {
      anyIncludes = true;
      included.addAll(selected);
    }
  }
  return [
    for (final package in workspace.packages)
      if ((!anyIncludes || included.contains(package)) &&
          !excluded.contains(package))
        package,
  ];
}

/// Files changed in [range] (`a...b`, or since `ref`, including uncommitted
/// and untracked ones), relative to [rootDir].
List<String> gitChangedFiles(String rootDir, String range) {
  List<String> git(List<String> args) {
    final result = Process.runSync('git', args, workingDirectory: rootDir);
    if (result.exitCode != 0) {
      throw TurbodartException(
        'git ${args.join(' ')} failed: ${(result.stderr as String).trim()}',
      );
    }
    return [
      for (final line in (result.stdout as String).split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
  }

  return [
    ...git(['diff', '--name-only', '--relative', range]),
    if (!range.contains('...'))
      ...git(['ls-files', '--others', '--exclude-standard']),
  ];
}
