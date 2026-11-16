import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'cache.dart';
import 'config.dart';
import 'console.dart';
import 'errors.dart';
import 'filter.dart';
import 'runner.dart';
import 'task_graph.dart';
import 'version.dart';
import 'workspace.dart';

const _commands = {
  'run': 'Run tasks across the workspace.',
  'ls': 'List the workspace\'s packages and their tasks.',
  'clean': 'Delete the .turbodart cache of each package.',
};

ArgParser _globalParser() => ArgParser()
  ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.')
  ..addFlag('version', negatable: false, help: 'Show the version.')
  ..addOption(
    'cwd',
    help: 'Run as if started in this directory.',
    valueHelp: 'dir',
  )
  ..addFlag(
    'color',
    defaultsTo: null,
    help: 'Color the output; by default, when the terminal supports it.',
  );

void _addFilter(ArgParser parser) => parser.addMultiOption(
  'filter',
  abbr: 'F',
  splitCommas: false,
  valueHelp: 'selector',
  help:
      'Select packages: name, name*, ./path, {path}, //, [git-ref], with '
      'name... (and dependencies), ...name (and dependents), ^ to leave out '
      'the match itself, and ! to exclude. Repeatable.',
);

ArgParser _runParser() {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.');
  _addFilter(parser);
  parser
    ..addFlag(
      'force',
      negatable: false,
      help: 'Run tasks even when their result is cached.',
    )
    ..addFlag(
      'cache',
      defaultsTo: true,
      help: 'Save results to the cache (--no-cache doesn\'t).',
    )
    ..addOption(
      'concurrency',
      defaultsTo: '10',
      valueHelp: 'n|n%',
      help: 'How many tasks run at once, or a percentage of CPUs.',
    )
    ..addFlag(
      'continue',
      negatable: false,
      help: 'Keep running tasks that don\'t depend on a failed one.',
    )
    ..addOption(
      'output-logs',
      allowed: OutputLogs.values.map((m) => m.value),
      help: 'How much task output to show; overrides each task\'s outputLogs.',
    )
    ..addOption(
      'log-prefix',
      allowed: ['prefix', 'none'],
      defaultsTo: 'prefix',
      help: 'Prefix each line with package:task.',
    )
    ..addFlag(
      'dry-run',
      negatable: false,
      help: 'Show what would run, with hashes and cache status.',
    )
    ..addFlag('json', negatable: false, help: 'With --dry-run, print JSON.');
  return parser;
}

ArgParser _lsParser() {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.');
  _addFilter(parser);
  return parser..addFlag('json', negatable: false, help: 'Print JSON.');
}

ArgParser _cleanParser() {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.');
  _addFilter(parser);
  return parser;
}

/// Runs the `turbodart` command line, returning the exit code.
///
/// Arguments after `--` are passed to the tasks asked for. A first argument
/// that isn't a command is taken as a task, so `turbodart test` is
/// `turbodart run test`.
Future<int> runTurbodart(
  List<String> arguments, {
  String? cwd,
  Console? console,
}) async {
  final separator = arguments.indexOf('--');
  final ours = separator == -1 ? arguments : arguments.sublist(0, separator);
  final passed = separator == -1
      ? const <String>[]
      : arguments.sublist(separator + 1);

  final global = _globalParser();
  ArgResults globalResults;
  try {
    globalResults = global.parse(_splitGlobal(ours, global));
  } on FormatException catch (e) {
    (console ?? Console()).err.writeln('${e.message}\n\n${_usage(global)}');
    return 64;
  }
  console ??= Console(color: globalResults['color'] as bool?);
  if (globalResults['version'] as bool) {
    console.out.writeln(packageVersion);
    return 0;
  }
  var rest = globalResults.rest;
  if (rest.isEmpty || globalResults['help'] as bool) {
    console.out.writeln(_usage(global));
    return rest.isEmpty && !(globalResults['help'] as bool) ? 64 : 0;
  }
  if (!_commands.containsKey(rest.first)) rest = ['run', ...rest];
  final command = rest.first;
  final parser = switch (command) {
    'run' => _runParser(),
    'ls' => _lsParser(),
    _ => _cleanParser(),
  };

  try {
    final ArgResults results;
    try {
      results = parser.parse(rest.skip(1));
    } on FormatException catch (e) {
      throw UsageException(e.message);
    }
    if (results['help'] as bool) {
      console.out.writeln(_commandUsage(command, parser));
      return 0;
    }
    final dir = p.normalize(
      p.absolute(
        globalResults['cwd'] as String? ?? cwd ?? Directory.current.path,
      ),
    );
    final workspace = Workspace.load(dir);
    final packages = _selectPackages(
      workspace,
      results['filter'] as List<String>,
      dir,
    );
    return switch (command) {
      'run' => await _run(workspace, packages, results, passed, console),
      'ls' => _ls(workspace, packages, results, console),
      _ => _clean(packages, console),
    };
  } on UsageException catch (e) {
    console.err.writeln(
      '${console.red('error')} ${e.message}\n\n${_commandUsage(command, parser)}',
    );
    return 64;
  } on TurbodartException catch (e) {
    console.err.writeln('${console.red('error')} ${e.message}');
    return 1;
  }
}

/// The global options before the command, and the command with its
/// arguments as the rest.
List<String> _splitGlobal(List<String> args, ArgParser global) {
  final out = <String>[];
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('-')) return [...out, '--', ...args.sublist(i)];
    out.add(arg);
    if (arg == '--cwd') {
      if (i + 1 < args.length) out.add(args[++i]);
    } else if (!global.options.values.any(
      (o) =>
          arg == '--${o.name}' ||
          arg.startsWith('--${o.name}=') ||
          arg == '--no-${o.name}' ||
          (o.abbr != null && arg == '-${o.abbr}'),
    )) {
      // A command's option before any command: treat it as for `run`.
      return [...out..removeLast(), '--', 'run', ...args.sublist(i)];
    }
  }
  return out;
}

/// Packages selected by [filters]; without any, those under [dir] when it's
/// inside a member package, otherwise all of them.
List<Package> _selectPackages(
  Workspace workspace,
  List<String> filters,
  String dir,
) {
  if (filters.isNotEmpty) {
    return filterPackages(workspace, filters, cwd: dir);
  }
  final owner = workspace.owner(dir);
  return owner.isRoot ? workspace.packages : [owner];
}

Future<int> _run(
  Workspace workspace,
  List<Package> packages,
  ArgResults results,
  List<String> passed,
  Console console,
) async {
  final tasks = results.rest;
  if (tasks.isEmpty) {
    throw UsageException(
      'No tasks given. Tasks: ${(workspace.taskNames.toList()..sort()).join(', ')}.',
    );
  }
  final graph = TaskGraph.build(workspace, packages: packages, tasks: tasks);
  final runner = Runner(
    workspace,
    graph,
    console: console,
    options: RunOptions(
      concurrency: _concurrency(results['concurrency'] as String),
      force: results['force'] as bool,
      writeCache: results['cache'] as bool,
      continueOnError: results['continue'] as bool,
      outputLogs: switch (results['output-logs']) {
        final String value => OutputLogs.parse(value, '--output-logs'),
        _ => null,
      },
      logPrefix: results['log-prefix'] == 'prefix',
      args: passed,
    ),
  );

  if (results['dry-run'] as bool) {
    _printPlan(workspace, runner.plan(), results['json'] as bool, console);
    return 0;
  }
  final runnable = graph.nodes.where((n) => !n.def.isNoop).toList();
  if (runnable.isEmpty) {
    console.out.writeln('No tasks to run in the selected packages.');
    return 0;
  }
  console.out.writeln(
    '${console.bold('turbodart $packageVersion')} '
    '${console.dim('· ${runnable.length} task${runnable.length == 1 ? '' : 's'} '
    'in ${runnable.map((n) => n.package).toSet().length} package(s)')}\n',
  );
  final summary = await runner.run();
  _printSummary(summary, console);
  return summary.succeeded ? 0 : 1;
}

int _concurrency(String value) {
  final percent = value.endsWith('%');
  final number = num.tryParse(
    percent ? value.substring(0, value.length - 1) : value,
  );
  if (number == null || number <= 0 || (!percent && number is! int)) {
    throw UsageException(
      '--concurrency must be a positive integer or a percentage, not "$value".',
    );
  }
  if (!percent) return number.toInt();
  return (Platform.numberOfProcessors * number / 100).floor().clamp(1, 1 << 16);
}

void _printPlan(
  Workspace workspace,
  List<PlannedTask> plan,
  bool json,
  Console console,
) {
  if (json) {
    console.out.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'packages': [for (final p in workspace.packages) p.name],
        'tasks': [
          for (final t in plan)
            {
              'id': t.node.id,
              'package': t.node.package.name,
              'directory': t.node.package.path,
              'task': t.node.task,
              'hash': t.hash,
              'cached': t.cached,
              'cache': t.node.def.cache,
              'commands': t.node.def.run,
              'inputs': t.node.def.inputs,
              'outputs': t.node.def.outputs,
              'dependencies': [for (final d in t.node.dependencies) d.id],
            },
        ],
      }),
    );
    return;
  }
  console.out.writeln(console.bold('Tasks to run'));
  for (final t in plan) {
    final def = t.node.def;
    final status = def.isNoop
        ? console.dim('no commands')
        : !def.cache
        ? console.yellow('not cached')
        : t.cached
        ? console.green('cached')
        : console.cyan('will run');
    console.out
      ..writeln('\n${console.bold(t.node.id)}  $status')
      ..writeln('  ${console.dim('Directory')}     ${t.node.package.path}')
      ..writeln('  ${console.dim('Hash')}          ${t.hash}');
    for (final command in def.run) {
      console.out.writeln('  ${console.dim('Command')}       $command');
    }
    if (def.outputs.isNotEmpty) {
      console.out.writeln(
        '  ${console.dim('Outputs')}       ${def.outputs.join(', ')}',
      );
    }
    if (t.node.dependencies.isNotEmpty) {
      console.out.writeln(
        '  ${console.dim('Dependencies')}  '
        '${t.node.dependencies.map((d) => d.id).join(', ')}',
      );
    }
  }
}

void _printSummary(RunSummary summary, Console console) {
  final total = summary.results.length;
  final successful =
      summary.count(TaskStatus.success) + summary.count(TaskStatus.cached);
  final cached = summary.count(TaskStatus.cached);
  final failed = summary.results.where((r) => r.status == TaskStatus.failed);
  final skipped = summary.count(TaskStatus.skipped);
  final seconds = summary.duration.inMilliseconds / 1000;
  String label(String text) => console.dim(text.padLeft(8));
  console.out
    ..writeln()
    ..writeln(
      '${label('Tasks:')}  ${console.bold(console.green('$successful successful'))}, '
      '$total total',
    )
    ..writeln(
      '${label('Cached:')}  ${console.bold('$cached cached')}, $total total',
    )
    ..writeln(
      '${label('Time:')}  ${console.bold('${seconds.toStringAsFixed(2)}s')}'
      '${cached == total && total > 0 ? ' ${console.green('>>> ALL CACHED')}' : ''}',
    );
  if (failed.isNotEmpty) {
    console.out.writeln(
      '${label('Failed:')}  ${console.red(failed.map((r) => r.node.id).join(', '))}',
    );
  }
  if (skipped > 0) {
    console.out.writeln('${label('Skipped:')}  $skipped');
  }
  console.out.writeln();
}

int _ls(
  Workspace workspace,
  List<Package> packages,
  ArgResults results,
  Console console,
) {
  final names = workspace.taskNames.toList()..sort();
  List<String> tasksOf(Package package) => [
    for (final task in names)
      if (workspace.taskFor(package, task) case final def? when !def.isNoop)
        task,
  ];
  if (results['json'] as bool) {
    console.out.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'root': workspace.rootDir,
        'packages': [
          for (final package in packages)
            {
              'name': package.name,
              'directory': package.path,
              'root': package.isRoot,
              'dependencies': [
                for (final dep in workspace.directDependencies(package))
                  dep.name,
              ],
              'tasks': tasksOf(package),
            },
        ],
      }),
    );
    return 0;
  }
  console.out.writeln(
    console.bold(
      '${packages.length} package${packages.length == 1 ? '' : 's'}',
    ),
  );
  final width = packages.fold(
    0,
    (w, p) => w > p.name.length ? w : p.name.length,
  );
  for (final package in packages) {
    final tasks = tasksOf(package);
    console.out.writeln(
      '  ${package.name.padRight(width)}  '
      '${console.dim(package.isRoot ? '. (root)' : package.path)}'
      '${tasks.isEmpty ? '' : '  ${console.cyan(tasks.join(' '))}'}',
    );
  }
  return 0;
}

int _clean(List<Package> packages, Console console) {
  var cleaned = 0;
  for (final package in packages) {
    if (TaskCache.clean(package)) {
      cleaned++;
      console.out.writeln(
        'Deleted ${p.posix.normalize(p.posix.join(package.path, stateDirName))}',
      );
    }
  }
  if (cleaned == 0) console.out.writeln('Nothing to clean.');
  return 0;
}

String _usage(ArgParser global) =>
    '''
turbodart: run tasks across a Dart pub workspace, with caching.

Usage: turbodart [options] <command> [arguments]
       turbodart [options] <task>... [run options] [-- args]

Commands:
${_commands.entries.map((e) => '  ${e.key.padRight(8)}${e.value}').join('\n')}

Options:
${global.usage}

Run "turbodart <command> --help" for a command's options.''';

String _commandUsage(String command, ArgParser parser) => switch (command) {
  'run' =>
    'Usage: turbodart run <task|package#task>... [options] [-- args]\n\n'
        '${_commands[command]} Arguments after -- are passed to the tasks '
        'asked for.\n\n${parser.usage}',
  _ =>
    'Usage: turbodart $command [options]\n\n${_commands[command]}\n\n'
        '${parser.usage}',
};
