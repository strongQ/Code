import 'dart:io';

import 'package:path/path.dart' as p;

/// 在系统文件管理器中打开指定文件所在的目录。
///
/// 纯 `dart:io` 实现，跨 Windows / macOS / Linux 桌面端，无原生插件依赖：
///  - Windows: `explorer.exe <dir>`
///  - macOS:   `open <dir>`
///  - Linux:   `xdg-open <dir>`
class OpenDirService {
  /// 在系统文件管理器中打开目录 [dir]；[dir] 为空时静默忽略。
  Future<void> openDirectory(String dir) async {
    if (dir.isEmpty) return;
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', [dir]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [dir]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [dir]);
      } else {
        // 移动端没有"目录管理器"这一概念，忽略
        print('[OpenDir] 当前平台（移动端）暂不支持打开目录: $dir');
      }
    } catch (e) {
      print('[OpenDir] 打开目录失败: $e');
    }
  }

  /// 打开 [filePath] 所在的目录；[filePath] 为空时静默忽略。
  Future<void> openDirectoryContaining(String filePath) async {
    if (filePath.isEmpty) return;
    await openDirectory(p.dirname(filePath));
  }
}