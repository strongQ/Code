import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../models/device_info.dart';
import '../providers/transfer_state.dart';
import 'device_tile.dart';
import 'folder_sync_panel.dart';
import 'transfer_progress_bar.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<TransferState>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('局域网文件传输'),
        centerTitle: true,
        backgroundColor: const Color(0xFF1A73E8),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.laptop, size: 14, color: Colors.white70),
                  const SizedBox(width: 4),
                  Text(
                    _shortName(),
                    style: const TextStyle(fontSize: 11, color: Colors.white70),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),

      // 状态栏
      body: Column(
        children: [
          statusBar(state: state),

          // 错误条
          if (state.error != null) errorBar(msg: state.error!),

          // 接收进度
          if (state.recvFile != null)
            transferProgress(
              label: '接收: ${state.recvFile}',
              fraction: state.recvFrac,
              sending: false,
            ),

          // 发送进度
          if (state.sendFile != null)
            transferProgress(
              label: '发送: ${state.sendFile}',
              fraction: state.sendFrac,
              sending: true,
            ),

          // 工作文件夹双向同步
          FolderSyncPanel(state: state),

          const Divider(height: 1),

          // 已接收文件
          if (state.receivedFiles.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 10, bottom: 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '已接收文件 (${state.receivedFiles.length})',
                      style:
                          Theme.of(context).textTheme.titleSmall?.copyWith(color: const Color(0xFF1A73E8)),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: GestureDetector(
                        onTap: () => state.openReceivedDir(),
                        child: Text(
                          '保存到: ${state.receivedDir}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 10, color: Colors.grey[500]),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 48.0 * state.receivedFiles.length,
              child: ListView.builder(
                physics: const NeverScrollableScrollPhysics(),
                itemCount: state.receivedFiles.length,
                itemBuilder: (ctx, i) {
                  final fp = state.receivedFiles[i];
                  return receivedRow(
                    filePath: fp,
                    onTap: () => state.openReceivedFileDir(fp),
                  );
                },
              ),
            ),
          ],

          const Divider(height: 1),

          // 设备列表标题
          Padding(
            padding: const EdgeInsets.only(left: 16, top: 10, bottom: 4),
            child: Row(
              children: [
                Text(
                  '附近设备',
                  style:
                      Theme.of(context).textTheme.titleSmall?.copyWith(color: const Color(0xFF1A73E8)),
                ),
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${state.devices.length}',
                    style: const TextStyle(
                        fontSize: 12, color: Colors.blue, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),

          // 设备列表 / 空态
          Expanded(
            child: state.devices.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(
                          width: 44,
                          height: 44,
                          child: CircularProgressIndicator(
                              strokeWidth: 3,
                              color: Color(0xFF1A73E8)),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          '正在扫描局域网设备…',
                          style: TextStyle(color: Colors.grey, fontSize: 14),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '请确保设备连接同一 Wi-Fi',
                          style: TextStyle(color: Colors.grey[400], fontSize: 12),
                        ),
                      ],
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: () async {},
                    child: ListView.builder(
                      padding: const EdgeInsets.only(bottom: 16),
                      itemCount: state.devices.length,
                      itemBuilder: (ctx, i) {
                        final device = state.devices[i];
                        return deviceTile(
                          device: device,
                          onSend: () => _pickAndSend(ctx, device),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  static String _shortName() {
    try {
      final h = Platform.localHostname;
      if (h.length > 12) return '${h.substring(0, 12)}…';
      return h;
    } catch (_) {
      return 'This-Device';
    }
  }

  /// 打开系统文件选择器 → 选中文件后发送到目标设备
  Future<void> _pickAndSend(BuildContext context, DeviceInfo device) async {
    final state = context.read<TransferState>();
    if (state.phase == TransferPhase.sending) return; // 传输进行中不重复触发

    PlatformFile? picked;
    try {
      picked = await FilePicker.pickFile(
        dialogTitle: '选择要发送到 ${device.name} 的文件',
      );
    } catch (e) {
      state.clearError();
      return;
    }
    if (picked == null) return; // 用户取消

    var path = picked.path;
    if (path == null || path.isEmpty) {
      // iOS 等场景可能不直接返回路径，将文件字节写入临时文件后发送
      try {
        final bytes = await picked.readAsBytes();
        final tmp = File(p.join((await getTemporaryDirectory()).path, picked.name));
        await tmp.writeAsBytes(bytes);
        path = tmp.path;
      } catch (_) {
        return;
      }
    }
    await state.sendFileTo(path, device);
  }
}

// ── 子组件 ──────────────────────────────────────────────

Widget statusBar({required TransferState state}) {
  final phaseIcon = switch (state.phase) {
    TransferPhase.idle => Icons.check_circle_outline,
    TransferPhase.receiving => Icons.download,
    TransferPhase.sending => Icons.upload,
    TransferPhase.error => Icons.error_outline,
  };
  final phaseColor = switch (state.phase) {
    TransferPhase.idle => Colors.green,
    TransferPhase.receiving => Colors.green,
    TransferPhase.sending => Colors.blue,
    TransferPhase.error => Colors.red,
  };

  return Container(
    width: double.infinity,
    color: Colors.grey.shade50,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Row(
      children: [
        Icon(phaseIcon, size: 16, color: phaseColor),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            state.status,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          ),
        ),
      ],
    ),
  );
}

Widget errorBar({required String msg}) {
  return Container(
    width: double.infinity,
    color: Colors.red.shade50,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Row(
      children: [
        const Icon(Icons.error_outline, color: Colors.red, size: 16),
        const SizedBox(width: 8),
        Expanded(
          child: Text(msg,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Colors.red)),
        ),
      ],
    ),
  );
}

Widget receivedRow({
  required String filePath,
  required VoidCallback onTap,
}) {
  final name = filePath.split(RegExp(r'[/\\]')).last;
  final dir = p.dirname(filePath);
  return Material(
    type: MaterialType.transparency,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.green.shade50,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(Icons.folder_open, size: 16, color: Colors.green[700]),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                  Text(
                    dir,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, color: Colors.grey[600]),
                  ),
                ],
              ),
            ),
            Icon(Icons.check_circle, size: 14, color: Colors.green[600]),
          ],
        ),
      ),
    ),
  );
}
