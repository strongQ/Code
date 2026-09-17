import 'dart:async';

import 'package:flutter/material.dart';

import '../providers/transfer_state.dart';

/// Android「选择外部同步文件夹」底部弹窗。
///
/// 选择共享存储目录（Download/Documents 等）需要先授予「所有文件访问」权限；
/// 授予后 dart:io 可直接读写任意真实路径，同步引擎无需改造。
class AndroidFolderSheet extends StatefulWidget {
  const AndroidFolderSheet({super.key, required this.state});

  final TransferState state;

  static const List<({String label, String path})> presets = [
    (label: 'Download', path: '/storage/emulated/0/Download'),
    (label: 'Documents', path: '/storage/emulated/0/Documents'),
    (label: 'Pictures', path: '/storage/emulated/0/Pictures'),
  ];

  @override
  State<AndroidFolderSheet> createState() => _AndroidFolderSheetState();
}

class _AndroidFolderSheetState extends State<AndroidFolderSheet>
    with WidgetsBindingObserver {
  final _controller = TextEditingController();
  bool _hasPermission = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 授予权限需到系统设置页手动开启；用户返回 App（resumed）时
    // 重新检测并反馈结果，避免「点了没反应」的错觉。
    WidgetsBinding.instance.addObserver(this);
    _loadPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_onResumed());
    }
  }

  Future<void> _onResumed() async {
    final messenger = ScaffoldMessenger.of(context);
    final before = _hasPermission;
    final ok = await widget.state.hasAllFilesAccess();
    if (!mounted) return;
    setState(() => _hasPermission = ok);
    if (ok != before) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? '「所有文件访问」已授予 ✓ 请重新点击上方外部目录'
                : '「所有文件访问」仍未授予：请在设置页打开开关后返回',
          ),
        ),
      );
    }
  }

  Future<void> _requestPermission(ScaffoldMessengerState messenger) async {
    await widget.state.requestAllFilesAccess();
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(
        content: Text(
            '已打开系统设置页：请在页面中打开「所有文件访问」开关，'
                '返回 App 后会自动检测并提示'),
      ),
    );
  }

  Future<void> _loadPermission() async {
    final ok = await widget.state.hasAllFilesAccess();
    if (mounted) setState(() => _hasPermission = ok);
  }

  Future<void> _choose(String path) async {
    if (!TransferState.isWritable(path)) {
      setState(() => _error =
          'App 尚无该目录（$path）的读写权限。请先点「授予」，在系统设置页'
              '打开「所有文件访问」开关，返回 App 后再点该目录。');
      return;
    }
    await widget.state.setWorkingFolder(path);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '选择外部同步文件夹',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            '选择外部目录需要「所有文件访问」权限（系统设置项）。',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          if (!_hasPermission)
            ElevatedButton.icon(
              onPressed: () {
                _requestPermission(ScaffoldMessenger.of(context));
              },
              icon: const Icon(Icons.lock_open, size: 16),
              label: const Text('授予「所有文件访问」'),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: AndroidFolderSheet.presets
                .map((preset) => OutlinedButton(
                      onPressed: () => _choose(preset.path),
                      child: Text(preset.label,
                          style: const TextStyle(fontSize: 13)),
                    ))
                .toList(),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            decoration: const InputDecoration(
              labelText: '自定义目录绝对路径',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(fontSize: 12, color: Colors.red)),
          ],
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: () {
              final t = _controller.text.trim();
              if (t.isEmpty) {
                setState(() => _error = '请输入路径或点击上方快捷目录');
                return;
              }
              _choose(t);
            },
            child: const Text('以此目录同步', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }
}