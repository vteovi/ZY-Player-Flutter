// 环境健康探测：当前进程能不能派生出「需要 stdio 命名管道」的子进程。
//
// 背景：Dart 在 Windows 上用命名管道给子进程接 stdio。如果当前进程链被
// 注入了拦截型组件（例如 WorkBuddy 沙箱的 tsbx.dll），客户端以读取权限打开
// 管道会被恒定拒绝（CreateFile failed 231 / ERROR_PIPE_BUSY），于是 Dart、
// flutter、node 全都无法启动任何子进程 —— `flutter build apk` 必然失败。
//
// 这个脚本本身是单进程的，跑通就说明环境健康。
// 注意：Detached / inheritStdio 模式不创建管道，所以能成功，
// 不能用它来判断环境是否健康。

import 'dart:io';

void main() {
  try {
    final result = Process.runSync('cmd', ['/c', 'echo', 'ok']);
    final text = result.stdout.toString().trim();
    if (text == 'ok') {
      stdout.writeln('PIPE_PROBE_OK');
    } else {
      stdout.writeln('PIPE_PROBE_ODD: unexpected output "$text"');
    }
  } on ProcessException catch (e) {
    stdout.writeln('PIPE_PROBE_FAIL: ${e.message} (osError ${e.errorCode})');
  } catch (e) {
    stdout.writeln('PIPE_PROBE_FAIL: $e');
  }
}
