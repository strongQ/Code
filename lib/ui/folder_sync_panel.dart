import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../providers/transfer_state.dart';
import 'android_folder_sheet.dart';

/// 工作文件夹同步面板。
///
/// UI 层只负责渲染状态与触发交互：选择目录（桌面端）、默认目录同步（Android）、
/// 取消同步、打开目录（桌面端）。具体同步逻辑在 [TransferState] / [FolderSyncService] 中。
class FolderSyncPanel extends StatelessWidget {
  const FolderSyncPanel({super.key, required this.state});

  final TransferState state;

  Future<void> _pickFolder() async {
    String? dir;
    try {
      dir = await FilePicker.getDirectoryPath(
        dialogTitle: '选择要双向同步的工作文件夹',
      );
    } catch (_) {
      return;
    }
    if (dir == null) return; // 用户取消
    await state.setWorkingFolder(dir);
  }

  @override
  Widget build(BuildContext context) {
    final folder = state.workingFolder;
    final st = state.syncStatus;
    final active = folder != null;
    final isAndroid = Platform.isAndroid;
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.deepOrange.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.deepOrange.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.folder,
                size: 18,
                color: Colors.deepOrange,
              ),
              const SizedBox(width: 8),
              Text(
                '工作文件夹同步',
                style:
                    theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Text(
                active ? '已开启' : '未开启',
                style: TextStyle(
                  fontSize: 12,
                  color: active ? Colors.deepOrange : Colors.grey,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            active
                ? st.message
                : isAndroid
                    ? 'Android 端无需选择目录：启用后直接使用本 App 默认可读写目录（p2p_sync）与已发现设备双向同步'
                    : '选择文件夹后，其中的文件将与已发现设备双向同步（新增/修改自动同步，含子目录）',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: active ? Colors.grey : Colors.grey[600],
            ),
          ),
          if (active) ...[
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: InkWell(
                onTap: () => state.openWorkingFolder(),
                borderRadius: BorderRadius.circular(6),
                child: Text(
                  st.folder ?? '',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                ),
              ),
            ),
            for (final entry in st.peerFolders.entries)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Text(
                  '对端 ${entry.key} 同步目录: ${entry.value}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                ),
              ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              if (isAndroid) ...[
                ElevatedButton.icon(
                  onPressed: active ? null : () => state.enableDefaultSync(),
                  icon: const Icon(Icons.sync_alt, size: 16),
                  label: const Text(
                    '使用默认目录同步',
                    style: TextStyle(fontSize: 13),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4A90D9),
                    foregroundColor: Colors.white,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                ),
                if (!active) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () {
                      showModalBottomSheet<void>(
                        context: context,
                        builder: (_) => AndroidFolderSheet(state: state),
                      );
                    },
                    child:
                        const Text('选择外部文件夹', style: TextStyle(fontSize: 13)),
                  ),
                ],
              ]
              else
                ElevatedButton.icon(
                  onPressed: _pickFolder,
                  icon: Icon(
                    active ? Icons.folder_open : Icons.create_new_folder,
                    size: 16,
                  ),
                  label: Text(
                    active ? '更换工作文件夹' : '选择工作文件夹',
                    style: const TextStyle(fontSize: 13),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4A90D9),
                    foregroundColor: Colors.white,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              if (active) ...[
                const SizedBox(width: 8),
                if (!isAndroid)
                  TextButton(
                    onPressed: () => state.openWorkingFolder(),
                    child:
                        const Text('打开目录', style: TextStyle(fontSize: 13)),
                  ),
                TextButton(
                  onPressed: () => state.setWorkingFolder(null),
                  child:
                      const Text('取消同步', style: TextStyle(fontSize: 13)),
                ),
              ],
            ],
          ),
          if (isAndroid) ...[
            const SizedBox(height: 4),
            _AndroidKeepAliveRow(state),
          ],
        ],
      ),
    );
  }
}

/// Android 后台保活行：显示电池优化豁免状态，未豁免时提供一键请求入口。
class _AndroidKeepAliveRow extends StatefulWidget {
  const _AndroidKeepAliveRow(this.state);

  final TransferState state;

  @override
  State<_AndroidKeepAliveRow> createState() => _AndroidKeepAliveRowState();
}

class _AndroidKeepAliveRowState extends State<_AndroidKeepAliveRow> {
  bool? _exempted;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ok = await widget.state.hasBatteryOptExempted();
    if (mounted) setState(() => _exempted = ok);
  }

  @override
  Widget build(BuildContext context) {
    final exempted = _exempted ?? true;
    return Row(
      children: [
        Icon(
          exempted ? Icons.check_circle_outline : Icons.battery_alert,
          size: 14,
          color: exempted ? Colors.green : Colors.orange,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            exempted
                ? '后台保活：已豁免电池优化'
                : '后台保活：未豁免电池优化，退后台后系统可能挂起同步',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ),
        if (!exempted)
          TextButton(
            onPressed: () async {
              await widget.state.requestBatteryOptExemption();
              await _load();
            },
            child: const Text('授予保活', style: TextStyle(fontSize: 12)),
          ),
      ],
    );
  }
}