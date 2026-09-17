// 集成测试：驱动真实 FileTransferService 生产代码路径，
// 验证含中文/特殊字符的文件名（如 PDF）能端到端传输，不再触发
// "Invalid HTTP header field value"，且接收端文件名正确还原。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:p2p_transfer/services/file_transfer_service.dart';

/// 测试用 path_provider 平台实现：把文档/临时目录指向临时目录，
/// 避免 flutter test 环境下缺少平台通道导致 start() 抛 MissingPluginException。
class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.baseDir) {
    PathProviderPlatform.instance = this;
  }

  final String baseDir;

  @override
  Future<String?> getApplicationDocumentsPath() async => baseDir;

  @override
  Future<String?> getTemporaryPath() async => baseDir;
}

void main() {
  test('含中文/特殊字符的文件名可端到端传输且正确还原 (回归: Invalid HTTP header field value)',
      () async {
    final baseDir = await Directory.systemTemp.createTemp('p2p_transfer_test_');
    _FakePathProviderPlatform(baseDir.path);

    const fileName = '季度报告(终版) + 副本.pdf';
    final srcDir = Directory(p.join(baseDir.path, 'src'));
    await srcDir.create(recursive: true);
    final srcFile = File(p.join(srcDir.path, fileName));
    const content = '%PDF-1.4 fake pdf payload 12345';
    await srcFile.writeAsString(content);

    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final testPort = probe.port;
    await probe.close();

    final service = FileTransferService(port: testPort);
    await service.start();

    final received = Completer<String>();
    service.onFileReceived = (path, _) => received.complete(path);
    String? errMsg;
    service.onError = (m) => errMsg = m;

    try {
      await service.sendFile(srcFile.path, '127.0.0.1');
      final gotPath =
          await received.future.timeout(const Duration(seconds: 15));

      // 发送端不应出现任何错误
      expect(errMsg, isNull, reason: '发送不应报错，实际: $errMsg');
      // 接收端文件名应与发送端完全一致（中文 + 空格 + + + 括号）
      expect(p.basename(gotPath), fileName,
          reason: '接收端文件名必须与发送端一致');
      // 文件内容必须完整
      expect(await File(gotPath).readAsString(), content,
          reason: '接收端文件内容必须与源文件一致');
    } finally {
      await service.stop();
      if (baseDir.existsSync()) {
        await baseDir.delete(recursive: true);
      }
    }
  });
}
