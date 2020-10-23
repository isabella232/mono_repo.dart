import 'package:collection/collection.dart' hide stronglyConnectedComponents;
import 'package:io/ansi.dart';

import '../../ci_shared.dart';
import '../../package_config.dart';
import '../../root_config.dart';
import '../../yaml.dart';
import '../travis.dart';

String generateGitHubYml(
  RootConfig rootConfig,
  Map<String, String> commandsToKeys,
) {
  for (var config in rootConfig) {
    final sdkConstraint = config.pubspec.environment['sdk'];

    if (sdkConstraint == null) {
      continue;
    }

    final disallowedExplicitVersions = config.jobs
        .map((tj) => tj.explicitSdkVersion)
        .where((v) => v != null)
        .toSet()
        .where((v) => !sdkConstraint.allows(v))
        .toList()
          ..sort();

    if (disallowedExplicitVersions.isNotEmpty) {
      final disallowedString =
          disallowedExplicitVersions.map((v) => '`$v`').join(', ');
      print(
        yellow.wrap(
          '  There are jobs defined that are not compatible with '
          'the package SDK constraint ($sdkConstraint): $disallowedString.',
        ),
      );
    }
  }

  final jobs = rootConfig.expand((config) => config.jobs);

  final jobList = Map<String, dynamic>.fromEntries(
      _listJobs(jobs, commandsToKeys, rootConfig.monoConfig.mergeStages)
          .map((e) => e.entries.single));

  return '''
${createdWith()}${toYaml({'name': 'Dart CI'})}

on:
  push:
    branches: [ master ]
  pull_request:
    branches: [ master ]

defaults:
  run:
    shell: bash

${toYaml({'jobs': jobList})}
''';
}

/// Lists all the jobs, setting their stage, environment, and script.
Iterable<Map<String, dynamic>> _listJobs(
  Iterable<TravisJob> jobs,
  Map<String, String> commandsToKeys,
  Set<String> mergeStages,
) sync* {
  final jobEntries = <_TravisJobEntry>[];

  for (var job in jobs) {
    final commands =
        job.tasks.map((task) => commandsToKeys[task.command]).toList();

    jobEntries.add(
        _TravisJobEntry(job, commands, mergeStages.contains(job.stageName)));
  }

  final groupedItems =
      groupBy<_TravisJobEntry, _TravisJobEntry>(jobEntries, (e) => e);

  for (var entry in groupedItems.entries) {
    if (entry.key.job.sdk == 'be/raw/latest') {
      print(red.wrap('SKIPPING OS `be/raw/latest` TODO GET SUPPORT!'));
      continue;
    }

    if (entry.key.merge) {
      final packages = entry.value.map((t) => t.job.package).toList();
      yield entry.key.jobYaml(packages);
    } else {
      yield* entry.value.map(
        (jobEntry) => jobEntry.jobYaml([jobEntry.job.package]),
      );
    }
  }
}

class _TravisJobEntry {
  static final _jobNameCache = <String>{};

  static String _replace(String input) {
    _jobNameCache.add(input);
    return 'job_${_jobNameCache.length.toString().padLeft(3, '0')}';
  }

  final TravisJob job;
  final List<String> commands;
  final bool merge;

  _TravisJobEntry(this.job, this.commands, this.merge);

  String _jobName(List<String> packages) {
    final pkgLabel = packages.length == 1 ? 'PKG' : 'PKGS';

    return 'OS: ${job.os}; SDK: ${job.sdk}; $pkgLabel: ${packages.join(', ')}; '
        'TASKS: ${job.name}';
  }

  String get _githubJobOs {
    switch (job.os) {
      case 'linux':
        return 'ubuntu-latest';
      case 'windows':
        return 'windows-latest';
      case 'macos':
        return 'macos-latest';
    }
    throw UnsupportedError('Not sure how to map `${job.os}` to GitHub!');
  }

  Map<String, dynamic> get _dartSetup {
    Map<String, String> withMap;

    final realVersion = job.explicitSdkVersion;

    if (realVersion != null) {
      if (realVersion.isPreRelease) {
        throw UnsupportedError('Not sure how to party on `${job.sdk}`.');
      }
      withMap = {
        'release-channel': 'stable',
        'version': job.sdk,
      };
    } else if (job.sdk == 'dev') {
      withMap = {'release-channel': 'dev'};
    } else {
      throw UnsupportedError('Not sure how to party on `${job.sdk}`.');
    }

    final map = {
      'uses': 'cedx/setup-dart@v2',
      'with': withMap,
    };

    return map;
  }

  Map<String, dynamic> jobYaml(List<String> packages) {
    assert(packages.isNotEmpty);
    assert(packages.contains(job.package));

    return {
      _replace(_jobName(packages)): {
        'name': _jobName(packages),
        'runs-on': _githubJobOs,
        'steps': [
          _dartSetup,
          {'uses': 'actions/checkout@v2'},
          {
            'env': {
              'PKGS': packages.join(' '),
              'TRAVIS_OS_NAME': job.os,
            },
            'run': '$travisShPath ${commands.join(' ')}',
          },
        ],
      }
    };
  }

  @override
  bool operator ==(Object other) =>
      other is _TravisJobEntry &&
      _equality.equals(_identityItems, other._identityItems);

  @override
  int get hashCode => _equality.hash(_identityItems);

  List get _identityItems => [job.os, job.stageName, job.sdk, commands, merge];
}

const _equality = DeepCollectionEquality();
