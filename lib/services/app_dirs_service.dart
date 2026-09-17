import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 应用默认可读写的目录服务。
///
/// 在 Android 上优先使用 App 专属外部存储（`/storage/emulated/0/Android/data/<package>/files`），
/// 是「程序默认可读写、无需用户选择、系统文件管理器可见」的目录；
/// 其他平台返回用户文档目录，同样默认可读写。
///
/// 用于 Android 端「工作文件夹同步」：无需弹目录选择器，直接使用该默认目录。
class AppDirsService {
  /// 工作文件夹同步使用的默认子目录名（与接收目录 p2p_received 并列，互不干扰）。
  static const String syncSubDirName = 'p2p_sync';

  /// 默认工作文件夹路径：`<base>/p2p_sync`（不存在则自动创建）。
  /// Android 优先外部存储；文档目录不可用时降级临时目录，保证任何平台都可用。
  Future<String> defaultWorkingFolderPath() async {
    final base = await _resolveBase();
    final dir = Directory(p.join(base, syncSubDirName));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir.path;
  }

  Future<String> _resolveBase() async {
    if (Platform.isAndroid) {
      try {
        final external = await getExternalStorageDirectories();
        for (final e in external ?? <Directory>[]) {
          if (e.path.isNotEmpty) return e.path;
        }
      } catch (e) {
        print('[AppDirs] 外部存储不可用，降级到文档目录: $e');
      }
    }
    try {
      final docs = await getApplicationDocumentsDirectory();
      return docs.path;
    } catch (e) {
      print('[AppDirs] 文档目录不可用，降级到临时目录: $e');
      final tmp = await getTemporaryDirectory();
      return tmp.path;
    }
  }

  /// 校验目录是否可写（不存在则尝试创建，写入/删除探针文件）。
  /// 用于 Android 选择外部同步目录前的前置检查。
  static bool isWritable(String path) {
    try {
      final dir = Directory(path);
      if (!dir.existsSync()) {
        if (!dir.parent.existsSync()) return false;
        dir.createSync(recursive: true);
      }
      final probe = File(p.join(path, '.p2p_write_test'));
      probe.writeAsStringSync('');
      probe.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }
}
