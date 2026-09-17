// 集成测试：驱动真实 FileTransferService + FolderSyncService 生产代码路径，
// 验证工作文件夹双向完全同步：
//   - A/B 两端各自新增文件后，通过 reconcile 双向收敛为并集；
//   - 接收端保留源端 mtime；
//   - 无回环死循环（多次 reconcile 后文件集合稳定、无副本膨胀）；
//   - 同名不同内容冲突：收敛到单一版本（mtime 新者胜）且终止。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:p2p_transfer/services/file_transfer_service.dart';
import 'package:p2p_transfer/services/folder_sync_service.dart';

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

Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

Set<String> _fileNames(Directory dir) =>
    dir.listSync(recursive: true).map((e) => p.basename(e.path)).toSet();

void main() {
  test('工作文件夹双向同步：新增文件两端收敛 + mtime 保留 + 无回环 (任务5)',
      () async {
    final baseDir = await Directory.systemTemp.createTemp('p2p_sync_test_');
    _FakePathProviderPlatform(baseDir.path);

    final portA = await _freePort();
    final portB = await _freePort();
    final svcA = FileTransferService(port: portA);
    final svcB = FileTransferService(port: portB);
    await svcA.start();
    await svcB.start();

    final dirA = Directory(p.join(baseDir.path, 'A'));
    final dirB = Directory(p.join(baseDir.path, 'B'));
    await dirA.create(recursive: true);
    await dirB.create(recursive: true);

    final syncA = FolderSyncService(fileService: svcA, selfId: 'device-A');
    final syncB = FolderSyncService(fileService: svcB, selfId: 'device-B');
    svcA.onSyncReceive =
        (rel, bytes, mtime) => syncA.handleRemoteFile(rel, bytes, mtime);
    svcB.onSyncReceive =
        (rel, bytes, mtime) => syncB.handleRemoteFile(rel, bytes, mtime);
    svcA.onSyncManifestProvider = () => syncA.manifest();
    svcB.onSyncManifestProvider = () => syncB.manifest();

    await syncA.setFolder(dirA.path);
    await syncB.setFolder(dirB.path);
    syncA.updatePeers({SyncEndpoint('127.0.0.1', portB)});
    syncB.updatePeers({SyncEndpoint('127.0.0.1', portA)});

    try {
      // A 新增文件 → A reconcile → B 收到
      final fa = File(p.join(dirA.path, '季度报告 终版.txt'));
      await fa.writeAsString('A 的内容 ABC');
      await syncA.reconcileNow();

      final fb = File(p.join(dirB.path, '季度报告 终版.txt'));
      expect(fb.existsSync(), isTrue, reason: 'B 应收到 A 的新增文件');
      expect(await fb.readAsString(), 'A 的内容 ABC');

      // mtime 保留（1.5s 容差）
      final srcMtime = fa.statSync().modified.millisecondsSinceEpoch;
      final gotMtime = fb.statSync().modified.millisecondsSinceEpoch;
      expect((srcMtime - gotMtime).abs(), lessThan(1500),
          reason: '应保留源端 mtime');

      // B 新增文件 → B reconcile → A 收到
      final gb = File(p.join(dirB.path, 'fromB.txt'));
      await gb.writeAsString('B 的内容');
      await syncB.reconcileNow();
      final ga = File(p.join(dirA.path, 'fromB.txt'));
      expect(ga.existsSync(), isTrue, reason: 'A 应收到 B 的新增文件');
      expect(await ga.readAsString(), 'B 的内容');

      // 再各 reconcile 两轮，验证收敛且无回环/无副本膨胀
      await syncA.reconcileNow();
      await syncB.reconcileNow();
      await syncA.reconcileNow();
      await syncB.reconcileNow();

      expect(_fileNames(dirA), {'季度报告 终版.txt', 'fromB.txt'},
          reason: 'A 端应恰好拥有两个文件');
      expect(_fileNames(dirB), {'季度报告 终版.txt', 'fromB.txt'},
          reason: 'B 端应恰好拥有两个文件');

      // 内容仍一致
      expect(await ga.readAsString(), 'B 的内容');
      expect(await fb.readAsString(), 'A 的内容 ABC');
    } finally {
      await syncA.dispose();
      await syncB.dispose();
      await svcA.stop();
      await svcB.stop();
      try {
        if (baseDir.existsSync()) {
          await baseDir.delete(recursive: true);
        }
      } catch (_) {
        // 忽略：系统临时目录由 OS 回收（Windows 下 watch 句柄释放可能滞后）
      }
    }
  });
  test('同名不同内容冲突：收敛到单一版本（新 mtime 胜）且终止 (任务5)', () async {
    final baseDir =
        await Directory.systemTemp.createTemp('p2p_sync_conflict_');
    _FakePathProviderPlatform(baseDir.path);

    final portA = await _freePort();
    final portB = await _freePort();
    final svcA = FileTransferService(port: portA);
    final svcB = FileTransferService(port: portB);
    await svcA.start();
    await svcB.start();

    final dirA = Directory(p.join(baseDir.path, 'A'));
    final dirB = Directory(p.join(baseDir.path, 'B'));
    await dirA.create(recursive: true);
    await dirB.create(recursive: true);

    final syncA = FolderSyncService(fileService: svcA, selfId: 'device-A');
    final syncB = FolderSyncService(fileService: svcB, selfId: 'device-B');
    svcA.onSyncReceive =
        (rel, bytes, mtime) => syncA.handleRemoteFile(rel, bytes, mtime);
    svcB.onSyncReceive =
        (rel, bytes, mtime) => syncB.handleRemoteFile(rel, bytes, mtime);
    svcA.onSyncManifestProvider = () => syncA.manifest();
    svcB.onSyncManifestProvider = () => syncB.manifest();

    await syncA.setFolder(dirA.path);
    await syncB.setFolder(dirB.path);
    syncA.updatePeers({SyncEndpoint('127.0.0.1', portB)});
    syncB.updatePeers({SyncEndpoint('127.0.0.1', portA)});

    try {
      // 两端各自先放同名、不同大小、不同 mtime 的文件 → 触发冲突
      final oldMtime = DateTime(2020, 1, 1);
      final newMtime = DateTime(2023, 6, 1);
      final fa = File(p.join(dirA.path, 'c.txt'));
      await fa.writeAsString('AAAAA');
      fa.setLastModifiedSync(oldMtime);
      final fb = File(p.join(dirB.path, 'c.txt'));
      await fb.writeAsString('BBBBBBBB');
      fb.setLastModifiedSync(newMtime);

      // 多轮 reconcile 直到稳定
      for (int i = 0; i < 3; i++) {
        await syncA.reconcileNow();
        await syncB.reconcileNow();
      }

      final contentA = await File(p.join(dirA.path, 'c.txt')).readAsString();
      final contentB = await File(p.join(dirB.path, 'c.txt')).readAsString();
      expect(contentA, contentB, reason: '冲突必须收敛到单一版本');
      expect(contentA, 'BBBBBBBB', reason: 'mtime 更新的版本应胜出');
      expect(_fileNames(dirA), {'c.txt'}, reason: '无副本膨胀');
      expect(_fileNames(dirB), {'c.txt'}, reason: '无副本膨胀');
    } finally {
      await syncA.dispose();
      await syncB.dispose();
      await svcA.stop();
      await svcB.stop();
      try {
        if (baseDir.existsSync()) {
          await baseDir.delete(recursive: true);
        }
      } catch (_) {
        // 忽略：系统临时目录由 OS 回收（Windows 下 watch 句柄释放可能滞后）
      }
    }
  });
}