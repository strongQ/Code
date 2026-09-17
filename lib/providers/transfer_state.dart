import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/device_info.dart';
import '../services/android_platform_service.dart';
import '../services/app_dirs_service.dart';
import '../services/discovery_service.dart';
import '../services/file_transfer_service.dart';
import '../services/folder_sync_service.dart';

enum TransferPhase { idle, receiving, sending, error }

class TransferState extends ChangeNotifier {
  final DiscoveryService _discovery = DiscoveryService();
  final FileTransferService _fileSvc = FileTransferService();
  final AppDirsService _appDirs = AppDirsService();
  final AndroidPlatformService _platformSvc = AndroidPlatformService();
  late FolderSyncService _sync;

  List<DeviceInfo> _devices = const [];
  TransferPhase _phase = TransferPhase.idle;
  String _status = '正在初始化…';
  String? _error;

  // 接收
  String? _recvFile;
  double _recvFrac = 0;

  // 发送
  String? _sendFile;
  double _sendFrac = 0;

  // 已接收文件列表（完整路径，文件已落地到持久化目录）
  final List<String> _received = [];

  /// 文件落地目录
  String get receivedDir => _fileSvc.receivedDir;

  // ── 只读 getter ──────────────────────────────────────
  List<DeviceInfo> get devices => List.unmodifiable(_devices);
  TransferPhase get phase => _phase;
  String get status => _status;
  String? get error => _error;

  String? get recvFile => _recvFile;
  double get recvFrac => _recvFrac;
  String? get sendFile => _sendFile;
  double get sendFrac => _sendFrac;
  List<String> get receivedFiles => List.unmodifiable(_received);

  /// 工作文件夹同步：当前工作文件夹路径（null = 未开启）
  String? get workingFolder => _sync.folder;
  /// 工作文件夹同步：当前同步状态
  SyncStatus get syncStatus => _sync.currentStatus;

  // ── 初始化 ───────────────────────────────────────────
  Future<void> init() async {
    try {
      // 文件传输服务回调
      _fileSvc.onReceiveProgress = (p) {
        _recvFile = p.fileName;
        _recvFrac = p.fraction;
        _phase = TransferPhase.receiving;
        _status = '接收中: ${p.fileName} ${(_recvFrac * 100).toStringAsFixed(0)}%';
        notifyListeners();
      };
      _fileSvc.onFileReceived = (path, size) {
        _received.add(path);
        _recvFile = null;
        _recvFrac = 0;
        if (_phase == TransferPhase.receiving) {
          _phase = TransferPhase.idle;
        }
        _status = '已接收: ${path.split(RegExp(r'[/\\]')).last}';
        notifyListeners();
      };
      _fileSvc.onSendProgress = (p) {
        _sendFile = p.fileName;
        _sendFrac = p.fraction;
        _phase = TransferPhase.sending;
        _status = '发送中: ${p.fileName} ${(_sendFrac * 100).toStringAsFixed(0)}%';
        notifyListeners();
      };
      _fileSvc.onSendComplete = () {
        _sendFile = null;
        _sendFrac = 0;
        if (_phase == TransferPhase.sending) {
          _phase = TransferPhase.idle;
        }
        _status = '发送完成 ✓';
        notifyListeners();
      };
      _fileSvc.onError = (msg) {
        _phase = TransferPhase.error;
        _error = msg;
        _status = msg;
        _sendFile = null;
        _sendFrac = 0;
        notifyListeners();
      };

      // 设备发现回调
      _discovery.onDevicesChanged = (list) {
        _devices = list;
        _sync.updatePeers(list.map((d) => SyncEndpoint(d.ip, d.port)).toSet());
        if (_phase == TransferPhase.idle) {
          _status = list.isEmpty
              ? '等待设备连接…'
              : '已发现 ${list.length} 台设备';
        }
        notifyListeners();
      };

      // 把本机身份信息传给 FileTransferService（/health 端点使用）
      try {
        _fileSvc.deviceName = Platform.localHostname;
      } catch (_) {
        _fileSvc.deviceName = 'Flutter-Device';
      }
      _fileSvc.deviceId = '${_fileSvc.deviceName}-${DateTime.now().microsecondsSinceEpoch}';

      // 工作文件夹同步服务（依赖 deviceId 作为本端身份，用于冲突裁决）
      _sync = FolderSyncService(fileService: _fileSvc, selfId: _fileSvc.deviceId);
      _sync.onError = (msg) {
        if (_phase == TransferPhase.idle) {
          _status = '同步提示: $msg';
        }
        notifyListeners();
      };
      _sync.onStatus = (_) {
        notifyListeners();
      };
      _fileSvc.onSyncReceive =
          (rel, bytes, mtime) => _sync.handleRemoteFile(rel, bytes, mtime);
      _fileSvc.onSyncManifestProvider = () => _sync.manifest();

      await _fileSvc.start();
      await _discovery.start();
      // Android：启动前台后台服务，App 退到后台后继续发现/传输/同步
      unawaited(_platformSvc.startBackgroundService());
      _phase = TransferPhase.idle;
      _status = '正在扫描局域网…';
      notifyListeners();
    } catch (e) {
      _phase = TransferPhase.error;
      _error = '初始化失败: $e';
      _status = _error!;
      notifyListeners();
    }
  }

  // ── 操作 ─────────────────────────────────────────────
  Future<void> sendFileTo(String localPath, DeviceInfo target) async {
    _error = null;
    notifyListeners();
    await _fileSvc.sendFile(localPath, target.ip);
  }

  void clearError() {
    _error = null;
    _phase = TransferPhase.idle;
    _status = '正在扫描局域网…';
    notifyListeners();
  }

  /// 是否已授予 Android「所有文件访问」权限（非 Android 恒为 true）
  Future<bool> hasAllFilesAccess() => _platformSvc.hasAllFilesAccess();

  /// 打开 Android「所有文件访问」设置页（由用户手动开启）
  Future<void> requestAllFilesAccess() => _platformSvc.requestAllFilesAccess();

  /// 是否已豁免 Android 电池优化（非 Android 恒为 true）
  Future<bool> hasBatteryOptExempted() => _platformSvc.hasBatteryOptExempted();

  /// 弹出 Android 电池优化豁免请求对话框（后台保活需要）
  Future<void> requestBatteryOptExemption() =>
      _platformSvc.requestBatteryOptExemption();

  /// 校验目录可写（Android 选择外部同步目录前使用）
  static bool isWritable(String path) => AppDirsService.isWritable(path);

  /// 在系统文件管理器中打开某个已接收文件所在的目录（Android 走平台通道）
  Future<void> openReceivedFileDir(String filePath) async {
    if (filePath.isEmpty) return;
    await _platformSvc.openDirectory(p.dirname(filePath));
  }

  /// 在系统文件管理器中打开已接收文件的保存目录
  Future<void> openReceivedDir() => _platformSvc.openDirectory(receivedDir);

  /// 在系统文件管理器中打开当前工作文件夹
  Future<void> openWorkingFolder() async {
    final f = _sync.folder;
    if (f == null) return;
    await _platformSvc.openDirectory(f);
  }

  /// 设置/更换工作文件夹以开启双向同步；传 null 关闭同步
  Future<void> setWorkingFolder(String? path) async {
    try {
      await _sync.setFolder(path);
      notifyListeners();
    } catch (e) {
      _error = '设置工作文件夹失败: $e';
      notifyListeners();
    }
  }

  /// 是否 Android 端（移动端使用「默认可读写目录」同步路径，无需选择目录）
  bool get isAndroid => Platform.isAndroid;

  /// Android 端：直接用程序默认可读写目录（`<Documents>/p2p_sync`）开启双向同步，
  /// 无需弹出目录选择器。
  Future<void> enableDefaultSync() async {
    try {
      final dir = await _appDirs.defaultWorkingFolderPath();
      await _sync.setFolder(dir);
      notifyListeners();
    } catch (e) {
      _error = '启用默认目录同步失败: $e';
      notifyListeners();
    }
  }

  Future<void> disposeAll() async {
    await _platformSvc.stopBackgroundService();
    await _discovery.stop();
    await _sync.dispose();
    await _fileSvc.stop();
  }
}
