// 在当前 Dart 进程内直接调用 analyzer 做静态检查。
// 本机的 flutter / dart CLI 无法派生子进程（CreateFile failed 231），
// 因此不能用 `flutter analyze`，改为单进程方式跑同样的分析。
//
// 运行：dart run tools/analyze.dart
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/error/error.dart';

Future<void> main(List<String> args) async {
  final root = Directory.current.path;
  final libDir = Directory('$root${Platform.pathSeparator}lib');
  if (!libDir.existsSync()) {
    stderr.writeln('lib 目录不存在: ${libDir.path}');
    exit(2);
  }

  final collection = AnalysisContextCollection(includedPaths: [libDir.path]);

  var errorCount = 0;
  var warningCount = 0;
  var lintCount = 0;
  var fileCount = 0;

  for (final AnalysisContext context in collection.contexts) {
    final files = context.contextRoot.analyzedFiles().where((f) => f.endsWith('.dart')).toList()
      ..sort();
    for (final path in files) {
      fileCount++;
      final relative = path.substring(root.length + 1);
      final SomeErrorsResult result = await context.currentSession.getErrors(path);
      if (result is! ErrorsResult) {
        stdout.writeln('SKIP $relative (${result.runtimeType})');
        continue;
      }
      for (final AnalysisError error in result.errors) {
        final severity = error.errorCode.errorSeverity;
        if (severity == ErrorSeverity.ERROR) {
          errorCount++;
        } else if (severity == ErrorSeverity.WARNING) {
          warningCount++;
        } else {
          lintCount++;
          if (args.contains('--no-lints')) continue;
        }
        stdout.writeln(
            '${severity.name.toUpperCase()} ${error.errorCode.name} $relative:${error.source.fullName}:${error.offset}:${error.offset + error.length} ${error.message}');
      }
    }
  }

  stdout.writeln('----');
  stdout.writeln('files: $fileCount  errors: $errorCount  warnings: $warningCount  lints: $lintCount');
  if (errorCount > 0) exit(1);
}
