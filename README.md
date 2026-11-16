# turbodart

A task runner for Dart [pub workspaces](https://dart.dev/tools/pub/workspaces), modeled on [Turborepo](https://turborepo.com): define scripts once, run them across packages in dependency order and in parallel, and skip any whose inputs haven't changed since they last succeeded.

It's deliberately narrow: running scripts and caching their results. No remote cache, watch mode or code generation.

```console
$ turbodart test
turbodart 0.1.0 · 4 tasks in 2 package(s)

core:build: cache hit, replaying logs 2d34c5cec504b7bf
core:build: building core
app:build: cache miss, executing e026dbca9f52c96c
app:build: building app
core:test: cache hit, replaying logs ad201c55c9a33500
app:test: cache miss, executing c461d80b3262376d
...

   Tasks:  4 successful, 4 total
  Cached:  2 cached, 4 total
    Time:  3.12s
```

## Install

```sh
dart pub global activate turbodart
```

Or add it to the workspace root's `dev_dependencies` and use `dart run turbodart`, or download a binary from the [releases](../../releases).

## Packages

turbodart reads the workspace from the root `pubspec.yaml`: the root package itself (which pub doesn't let you list in `workspace`), then every member, including globbed entries (`packages/*`) and nested workspaces. A package's workspace dependencies are the members named in its `dependencies` and `dev_dependencies`.

Run from anywhere inside the workspace. Without `--filter`, running inside a member's directory scopes to that member, as Turborepo does.

## Tasks

Tasks go under a `turbodart` key in pubspecs, which pub ignores.

```yaml
# pubspec.yaml (workspace root)
name: my_workspace
workspace:
  - packages/*

turbodart:
  tasks:
    analyze: dart analyze --fatal-infos
    test:
      run: dart test
      dependsOn: [build]
    build:
      run: dart run build_runner build -d
      dependsOn: [^build]
      outputs: [lib/**/*.g.dart]
    check:
      dependsOn: [analyze, test] # no commands: runs its dependencies only

    # package#task configures one package; // is the root.
    "//#test": false
    "//#build": false
    api#test:
      env: [DATABASE_URL]
```

```yaml
# packages/api/pubspec.yaml
turbodart:
  tasks:
    build:
      run: [dart run build_runner build -d, dart run tool/openapi.dart]
    format: false # not in this package
```

A task in the root's `tasks` applies to **every** package, including the root. Each package can override it, field by field, with a `package#task` entry in the root or `tasks` in its own pubspec, in that order of precedence, or disable it with `false`. A package can also define tasks of its own.

| Field | Default | |
|---|---|---|
| `run` | none | A command, or a list run in order, in the package's directory. Shorthand: `task: command`. |
| `dependsOn` | `[]` | `task` in the same package, `^task` in each workspace dependency first, `package#task` in one package. |
| `inputs` | `[$DEFAULT]` | Globs of files hashed, relative to the package. `$DEFAULT` is the default set below, `!glob` excludes, `$ROOT/glob` is relative to the workspace root. |
| `outputs` | `[]` | Globs of files cached and restored on a hit. They're never inputs of their own task. |
| `env` | `[]` | Environment variables whose values are hashed. |
| `cache` | `true` | `false` always runs the task. |
| `hashDependencies` | `true` | Hash the `pubspec.yaml`, `lib/**` and `hook/**` of the package's workspace dependencies, transitively. |
| `outputLogs` | `full` | `full`, `new-only`, `hash-only`, `errors-only` or `none`. |

The root's `turbodart` section also takes:

| Key | Default | |
|---|---|---|
| `globalInputs` | `[pubspec.lock, analysis_options.yaml]` | Workspace-root files hashed for every task. |
| `globalEnv` | `[]` | Environment variables hashed for every task. |
| `cacheEntries` | `5` | Results kept per package and task, least recently used dropped first. |

Commands run in `sh` on Linux and macOS and `cmd` on Windows, so stick to what works in both (`dart …`, `flutter …`, `echo`, `&&`), or put anything more in a Dart script under `tool/`. They get `TURBODART_PACKAGE`, `TURBODART_TASK`, `TURBODART_HASH` and `TURBODART_ROOT` in their environment.

## Running

```sh
turbodart run test                     # test in every package that has it
turbodart test build                   # `run` is optional
turbodart test --filter app...         # app and its dependencies
turbodart run api#build                # one package's task
turbodart test -- --name parser        # arguments for the tasks asked for
turbodart test --dry-run [--json]      # what would run, and what's cached
turbodart ls                           # packages and their tasks
turbodart clean                        # delete every .turbodart
```

| Option | |
|---|---|
| `-F`, `--filter` | Select packages; repeatable, see below. |
| `--force` | Run tasks even when cached; results are still saved. |
| `--no-cache` | Don't save results. |
| `--concurrency` | Tasks at once: a number (default 10) or a percentage of CPUs. |
| `--continue` | After a failure, keep running tasks that don't depend on it. |
| `--output-logs` | Override every task's `outputLogs`. |
| `--log-prefix` | `prefix` (default) or `none`. |
| `--cwd` | Run as if in another directory (before the command). |

Arguments after `--` are appended to the last command of the tasks named on the command line, not their dependencies, and are part of their hash.

### Filters

Turborepo's syntax:

| Filter | Selects |
|---|---|
| `app`, `app_*` | By name, `*` matching anything. `//` is the root. |
| `./packages/app`, `{packages/*}` | By directory, relative to the current one. |
| `[main]`, `[main...HEAD]` | Packages with files changed since a git ref (including uncommitted and untracked ones), or between two. Combines with the others, e.g. `{packages/*}[main]`. |
| `app...` / `app^...` | Also / only its dependencies. |
| `...app` / `...^app` | Also / only its dependents. |
| `!app` | Excludes. |

Packages matching any filter are selected, less those matching a `!` filter.

## Caching

Before running a task, turbodart hashes:

- its definition (commands, arguments, `inputs`, `outputs`) and the Dart SDK version;
- the contents of its `inputs`, by default `$DEFAULT`: `pubspec.yaml`, `pubspec_overrides.yaml`, `analysis_options.yaml`, `build.yaml`, `dart_test.yaml`, `lib/`, `bin/`, `test/`, `tool/`, `hook/`, `web/`, `assets/` and `integration_test/`;
- the `globalInputs`, and the values of `globalEnv` and `env`;
- the hashes of the tasks it depends on;
- with `hashDependencies`, the public sources of its workspace dependencies.

`.dart_tool`, `.git` and `.turbodart` directories, and member packages nested in another's directory, are never part of a package's inputs.

If a successful run with that hash is cached, its outputs are restored and its log replayed instead of running it. Failed runs aren't cached.

Each package keeps its cache in `<package>/.turbodart/`, which ignores itself in git:

```
.turbodart/
  .gitignore
  test.log                     # the latest log of each task
  cache/test/<hash>/
    meta.json
    output.log
    outputs/…
```

### Across machines

Hashes are the same on every OS and architecture, so a `.turbodart` cached on one runner (say, with `actions/cache`) hits on another: paths are `/`-separated and sorted, `\r\n` hashes as `\n` (git's `autocrlf` doesn't matter), file modes aren't hashed, and only the SDK's version is, not its platform. Your commands' outputs are, of course, only as portable as the commands.

## Releasing

`.github/workflows/check.yml` formats, analyzes and tests on Linux, macOS and Windows for every push, pull request and manual run. `.github/workflows/release.yml` uses [rylease](https://github.com/ryangarber/rylease):

- After `check` passes on a push to `main` or `dev`, it does a dry run, reporting the version and notes conventional commits would release, and building the binaries as workflow artifacts.
- Run by hand (`workflow_dispatch`), it releases: bumps `pubspec.yaml` and `lib/src/version.dart`, writes `CHANGELOG.md`, commits, tags `vX.Y.Z`, creates the GitHub release, publishes to pub.dev, and attaches binaries for Linux, macOS and Windows on x64 and arm64.

Publishing needs a Google Cloud service account [set up for pub.dev](https://dart.dev/tools/pub/automated-publishing#publishing-with-google-cloud-service-account), with its workload identity provider and email in the repository variables `PUB_WORKLOAD_IDENTITY_PROVIDER` and `PUB_SERVICE_ACCOUNT`.
