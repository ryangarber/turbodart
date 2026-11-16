import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'cache.dart';
import 'config.dart';
import 'console.dart';
import 'hasher.dart';
import 'task_graph.dart';
import 'workspace.dart';

/// How a run behaves, from the command line.
class RunOptions {
  RunOptions({
    this.concurrency = 10,
    this.force = false,
    this.writeCache = true,
    this.continueOnError = false,
    this.outputLogs,
    this.logPrefix = true,
    this.args = const [],
  });

  /// How many tasks run at once.
  final int concurrency;

  /// Run tasks even when their result is cached.
  final bool force;

  /// Save results to the cache.
  final bool writeCache;

  /// Keep running tasks that don't depend on a failed one.
  final bool continueOnError;

  /// Overrides each task's `outputLogs`.
  final OutputLogs? outputLogs;

  /// Prefix each line of output with `package:task: `.
  final bool logPrefix;

  /// Appended to the last command of the tasks asked for.
  final List<String> args;
}

enum TaskStatus {
  /// It ran and succeeded.
  success,

  /// Its result came from the cache.
  cached,

  /// It ran and failed.
  failed,

  /// A task it depends on failed, or the run stopped first.
  skipped,
}

class TaskResult {
  TaskResult(this.node, this.status, {this.hash, this.duration, this.exitCode});

  final TaskNode node;
  final TaskStatus status;
  final String? hash;
  final Duration? duration;
  final int? exitCode;

  bool get succeeded =>
      status == TaskStatus.success || status == TaskStatus.cached;
}

class RunSummary {
  RunSummary(this.results, this.duration);

  /// The results of tasks with commands, in the graph's order.
  final List<TaskResult> results;
  final Duration duration;

  bool get succeeded => results.every((r) => r.succeeded);

  int count(TaskStatus status) =>
      results.where((r) => r.status == status).length;
}

/// A task as a dry run sees it.
class PlannedTask {
  PlannedTask(this.node, this.hash, this.cached);

  final TaskNode node;
  final String hash;
  final bool cached;
}

/// Runs a [TaskGraph], in dependency order and in parallel where it can,
/// using cached results where they exist.
class Runner {
  Runner(
    this.workspace,
    this.graph, {
    required this.console,
    required this.options,
    TaskHasher? hasher,
    TaskCache? cache,
  }) : hasher = hasher ?? TaskHasher(workspace),
       cache = cache ?? TaskCache(maxEntries: workspace.config.cacheEntries);

  final Workspace workspace;
  final TaskGraph graph;
  final Console console;
  final RunOptions options;
  final TaskHasher hasher;
  final TaskCache cache;

  late final _colors = {
    for (final (i, package) in workspace.packages.indexed) package: i,
  };

  /// Each task's hash and whether it's cached, without running anything.
  /// Inputs that tasks would generate aren't there yet, so hashes can
  /// differ from a real run's.
  List<PlannedTask> plan() {
    final hashes = <TaskNode, String>{};
    return [
      for (final node in graph.nodes)
        () {
          final hash = hashes[node] = _hash(node, hashes);
          return PlannedTask(
            node,
            hash,
            !node.def.isNoop &&
                node.def.cache &&
                cache.lookup(node.package, node.task, hash) != null,
          );
        }(),
    ];
  }

  Future<RunSummary> run() async {
    final stopwatch = Stopwatch()..start();
    final results = <TaskNode, TaskResult>{};
    final hashes = <TaskNode, String>{};
    final pending = [...graph.nodes];
    var running = 0;
    var stopped = false;
    final done = Completer<void>();

    void pump() {
      for (final node in [...pending]) {
        if (running >= options.concurrency) break;
        final depResults = node.dependencies.map((d) => results[d]);
        if (depResults.any((r) => r != null && !r.succeeded) || stopped) {
          pending.remove(node);
          results[node] = TaskResult(node, TaskStatus.skipped);
          continue;
        }
        if (depResults.any((r) => r == null)) continue;
        pending.remove(node);
        running++;
        _execute(node, hashes).then((result) {
          results[node] = result;
          if (result.hash != null) hashes[node] = result.hash!;
          if (!result.succeeded && !options.continueOnError) stopped = true;
          running--;
          pump();
        });
      }
      if (pending.isEmpty && running == 0 && !done.isCompleted) {
        done.complete();
      }
    }

    pump();
    await done.future;
    return RunSummary([
      for (final node in graph.nodes)
        if (!node.def.isNoop) results[node]!,
    ], stopwatch.elapsed);
  }

  String _hash(TaskNode node, Map<TaskNode, String> hashes) => hasher.hash(
    node,
    [for (final dep in node.dependencies) hashes[dep]!],
    args: node.isEntry ? options.args : const [],
  );

  Future<TaskResult> _execute(
    TaskNode node,
    Map<TaskNode, String> hashes,
  ) async {
    final String hash;
    try {
      hash = _hash(node, hashes);
    } on Object catch (e) {
      _line(node, console.red('could not hash inputs: $e'), error: true);
      return TaskResult(node, TaskStatus.failed);
    }
    final def = node.def;
    if (def.isNoop) return TaskResult(node, TaskStatus.success, hash: hash);
    final package = node.package;
    final mode = options.outputLogs ?? def.outputLogs ?? OutputLogs.full;
    final announce = mode != OutputLogs.errorsOnly && mode != OutputLogs.none;

    if (def.cache && !options.force) {
      final entry = cache.lookup(package, node.task, hash);
      if (entry != null) {
        try {
          cache.restore(package, entry);
          hasher.invalidate(package);
          if (mode == OutputLogs.full) {
            _line(node, 'cache hit, replaying logs ${console.dim(hash)}');
            for (final line in const LineSplitter().convert(entry.log)) {
              _line(node, line);
            }
          } else if (announce) {
            _line(node, 'cache hit, suppressing logs ${console.dim(hash)}');
          }
          cache.writeLog(package, node.task, entry.log);
          return TaskResult(
            node,
            TaskStatus.cached,
            hash: hash,
            duration: entry.duration,
          );
        } on FileSystemException catch (e) {
          _line(node, console.yellow('cache restore failed, running: $e'));
        }
      }
    }

    if (announce) {
      final reason = !def.cache
          ? 'cache bypass, executing'
          : options.force
          ? 'cache bypass, force executing'
          : 'cache miss, executing';
      _line(node, '$reason ${console.dim(hash)}');
    }
    final live = mode == OutputLogs.full || mode == OutputLogs.newOnly;
    final log = StringBuffer();
    final stopwatch = Stopwatch()..start();
    var exitCode = 0;
    String? failedCommand;
    for (final (i, command) in def.run.indexed) {
      final full = node.isEntry && i == def.run.length - 1
          ? [command, ...options.args.map(shellQuote)].join(' ')
          : command;
      exitCode = await _spawn(node, full, hash, (line, isError) {
        log.writeln(line);
        if (live) _line(node, line, error: isError);
      });
      if (exitCode != 0) {
        failedCommand = full;
        break;
      }
    }
    stopwatch.stop();
    hasher.invalidate(package);
    cache.writeLog(package, node.task, log.toString());

    if (exitCode != 0) {
      if (mode == OutputLogs.errorsOnly || mode == OutputLogs.hashOnly) {
        for (final line in const LineSplitter().convert(log.toString())) {
          _line(node, line, error: true);
        }
      }
      _line(
        node,
        console.red('command ($failedCommand) exited ($exitCode)'),
        error: true,
      );
      return TaskResult(
        node,
        TaskStatus.failed,
        hash: hash,
        duration: stopwatch.elapsed,
        exitCode: exitCode,
      );
    }
    if (def.cache && options.writeCache) {
      try {
        cache.save(
          package,
          node.task,
          hash,
          log: log.toString(),
          outputs: def.outputs,
          duration: stopwatch.elapsed,
          skipDir: (dir) => workspace.isNestedPackage(package, dir),
        );
      } on Object catch (e) {
        _line(node, console.yellow('could not save to the cache: $e'));
      }
    }
    return TaskResult(
      node,
      TaskStatus.success,
      hash: hash,
      duration: stopwatch.elapsed,
      exitCode: 0,
    );
  }

  /// Runs [command] in a shell: `sh` on Linux and macOS, `cmd` on Windows.
  Future<int> _spawn(
    TaskNode node,
    String command,
    String hash,
    void Function(String line, bool isError) onLine,
  ) async {
    final environment = {
      'TURBODART_PACKAGE': node.package.name,
      'TURBODART_TASK': node.task,
      'TURBODART_HASH': hash,
      'TURBODART_ROOT': workspace.rootDir,
    };
    final Process process;
    try {
      process = Platform.isWindows
          // cmd parses its own command line, which Dart would quote; passing
          // the command through a variable leaves it as written.
          ? await Process.start(
              'cmd.exe',
              ['/d', '/c', '%TURBODART_COMMAND%'],
              workingDirectory: node.package.dir,
              environment: {...environment, 'TURBODART_COMMAND': command},
            )
          : await Process.start(
              '/bin/sh',
              ['-c', command],
              workingDirectory: node.package.dir,
              environment: environment,
            );
    } on ProcessException catch (e) {
      onLine('could not start a shell: ${e.message}', true);
      return 127;
    }
    unawaited(process.stdin.close());
    Future<void> pipe(Stream<List<int>> stream, bool isError) => stream
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach((line) => onLine(line, isError));
    await Future.wait([
      pipe(process.stdout, false),
      pipe(process.stderr, true),
    ]);
    return process.exitCode;
  }

  void _line(TaskNode node, String line, {bool error = false}) {
    final prefix = options.logPrefix
        ? console.accent(
            '${node.package.name}:${node.task}: ',
            _colors[node.package]!,
          )
        : '';
    (error ? console.err : console.out).writeln('$prefix$line');
  }
}

final _plainArg = RegExp(r'^[A-Za-z0-9_\-+=.,/:@%]+$');

/// [arg] quoted for the platform's shell, if it needs to be.
String shellQuote(String arg) {
  if (_plainArg.hasMatch(arg)) return arg;
  if (Platform.isWindows) return '"${arg.replaceAll('"', r'\"')}"';
  return "'${arg.replaceAll("'", r"'\''")}'";
}
