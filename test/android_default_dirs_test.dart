// Android 端「默认可读写目录」解析测试：
// 1. 文档目录可用时，默认工作文件夹 = <Documents>/p2p_sync 且自动创建；
// 2. 文档目录不可用时，降级到临时目录的 p2p_sync，保证任何平台都可用。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:p2p_transfer/services/app_dirs_service.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform({this.docsPath, this.tmpPath}) {
    PathProviderPlatform.instance = this;
  }

  final String? docsPath;
  final String? tmpPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;

  @override
  Future<String?> getTemporaryPath() async => tmpPath;
}

void main() {
  test('文档目录可用：默认工作文件夹为 <Documents>/p2p_sync 且自动创建',
      () async {
    final baseDir = await Directory.systemTemp.createTemp('p2p_android_test_');
    _FakePathProviderPlatform(docsPath: baseDir.path, tmpPath: baseDir.path);

    final svc = AppDirsService();
    final dir = await svc.defaultWorkingFolderPath();

    expect(
        dir,
        p.normalize(p.join(baseDir.path, AppDirsService.syncSubDirName)),
        reason: '默认工作文件夹应位于文档目录下的 p2p_sync');
    expect(
        Directory(dir).existsSync(), isTrue, reason: 'p2p_sync 目录应被自动创建');

    if (baseDir.existsSync()) {
      await baseDir.delete(recursive: true);
    }
  });

  test('文档目录不可用：降级到临时目录的 p2p_sync', () async {
    final baseDir = await Directory.systemTemp.createTemp('p2p_android_fallback_');
    // docsPath 返回 null → path_provider 抛 PathProviderException → 触发降级
    _FakePathProviderPlatform(tmpPath: baseDir.path);

    final svc = AppDirsService();
    final dir = await svc.defaultWorkingFolderPath();

    expect(
        dir,
        p.normalize(p.join(baseDir.path, AppDirsService.syncSubDirName)),
        reason: '降级路径应位于临时目录下的 p2p_sync');
    expect(Directory(dir).existsSync(), isTrue, reason: '降级目录应被自动创建');

    if (baseDir.existsSync()) {
      await baseDir.delete(recursive: true);
    }
  });
}
