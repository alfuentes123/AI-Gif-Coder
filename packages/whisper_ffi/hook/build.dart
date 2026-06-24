import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:path/path.dart' as p;

const _assetId = 'src/whisper_bindings.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final config = input.config.code;
    final supported = {OS.windows, OS.linux, OS.macOS};
    if (!supported.contains(config.targetOS)) {
      throw UnsupportedError(
        'whisper_ffi supports Windows, Linux, and macOS only.',
      );
    }

    final buildDirectory = input.outputDirectory.resolve('cmake/').toFilePath();
    final outputDirectory = input.outputDirectory.toFilePath();
    final packageRoot = input.packageRoot.toFilePath();
    final configureArgs = <String>[
      '-S',
      packageRoot,
      '-B',
      buildDirectory,
      '-DCMAKE_BUILD_TYPE=Release',
      '-DWHISPER_FFI_OUTPUT_DIR=$outputDirectory',
    ];

    if (config.targetOS == OS.macOS) {
      configureArgs.add(
        '-DCMAKE_OSX_ARCHITECTURES='
        '${config.targetArchitecture == Architecture.arm64 ? 'arm64' : 'x86_64'}',
      );
    } else if (config.targetOS == OS.windows) {
      configureArgs.addAll([
        '-A',
        config.targetArchitecture == Architecture.arm64 ? 'ARM64' : 'x64',
      ]);
    }

    final cmake = await _findCmake();
    await _run(cmake, configureArgs);
    await _run(cmake, [
      '--build',
      buildDirectory,
      '--config',
      'Release',
      '--target',
      'whisper_ffi',
    ]);

    final library = input.outputDirectory.resolve(
      config.targetOS.dylibFileName('whisper_ffi'),
    );
    if (!await File.fromUri(library).exists()) {
      throw StateError('whisper_ffi build did not produce $library');
    }

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: _assetId,
        file: library,
        linkMode: DynamicLoadingBundled(),
      ),
    );
    output.dependencies.addAll(
      Directory(
        input.packageRoot.resolve('native/').toFilePath(),
      ).listSync(recursive: true).whereType<File>().map((file) => file.uri),
    );
    output.dependencies.addAll(
      Directory(
        input.packageRoot.resolve('vendor/whisper.cpp/').toFilePath(),
      ).listSync(recursive: true).whereType<File>().map((file) => file.uri),
    );
  });
}

Future<String> _findCmake() async {
  try {
    final result = await Process.run('cmake', ['--version']);
    if (result.exitCode == 0) return 'cmake';
  } on ProcessException {
    // Fall through to Windows Visual Studio discovery.
  }

  if (Platform.isWindows) {
    final roots = <String>[
      r'C:\Program Files\Microsoft Visual Studio',
      r'C:\Program Files (x86)\Microsoft Visual Studio',
    ];
    for (final root in roots) {
      final directory = Directory(root);
      if (!directory.existsSync()) continue;
      for (final entry in directory.listSync(recursive: true)) {
        if (entry is File &&
            p.basename(entry.path).toLowerCase() == 'cmake.exe' &&
            entry.path.contains('${p.separator}Microsoft${p.separator}CMake')) {
          return entry.path;
        }
      }
    }
  }
  throw StateError(
    'CMake is required to compile the bundled whisper.cpp runtime.',
  );
}

Future<void> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      'Command failed with exit code ${result.exitCode}',
      result.exitCode,
    );
  }
}
