import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'file_transfer_service.dart';

/// 工作文件夹同步状态（供 UI 渲染，业务层维护，非每帧扫描）。
class SyncStatus {
  /// 当前工作文件夹绝对路径；null 表示未设置
  final String? folder;
  /// 工作文件夹内参与同步的文件数量
  final int fileCount;
  /// 已连接的对端数量
  final int peerCount;
  /// 供 UI 展示的一句话状态
  final String message;
  /// 已连接对端的工作文件夹（对端端点 "ip:port" → 文件夹路径），
  /// reconcile 时从对端 /sync-manifest 学习，供 UI 展示「对端在同步哪个文件夹」。
  final Map<String, String> peerFolders;

  const SyncStatus({
    required this.folder,
    required this.fileCount,
    required this.peerCount,
    required this.message,
    this.peerFolders = const {},
  });
}

/// 同步对端端点（host:port）。生产环境 port 恒为 9877，测试可注入空闲端口。
class SyncEndpoint {
  final String host;
  final int port;

  const SyncEndpoint(this.host, this.port);

  @override
  bool operator ==(Object other) =>
      other is SyncEndpoint && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => '$host:$port';
}

class _FileMeta {
  final int size;
  final int mtimeMs;
  const _FileMeta({required this.size, required this.mtimeMs});
}

class _PeerManifest {
  final String deviceId;
  final Map<String, _FileMeta> files;
  _PeerManifest({required this.deviceId, required this.files});
}

/// 工作文件夹双向同步引擎。
///
/// 每台设备可设置一个「工作文件夹」。设置后：
///  1. 本地文件新增/修改 → 通过 `Directory.watch` 去抖后实时推送到所有对端工作文件夹；
///  2. 周期性 + 对端变化时触发 reconcile：把「本机有、对端没有（或大小不同）」的文件推给对端。
///     由于双方都会执行同样的 reconcile，两端最终收敛为文件并集；
///  3. 收到对端推送的文件 → 写入本机工作文件夹（同相对路径），保留源端 mtime，并做「回声抑制」避免回推死循环。
///
/// 收敛与终止性：
///  - 以 (relPath + size) 判定「已同步」：两端同路径同大小即视为一致，停止推送 → 稳定态；
///  - 内容冲突（同路径不同大小）：mtime 新者胜，mtime 接近时按 deviceId 字典序大者胜（两端计算一致，恰好一方推送）；
///  - 回声抑制：刚由远端写入的文件，其本地 watch 事件被抑制，不会回推。
///
/// 已知限制（安全设计）：
///  - 仅同步「新增 + 修改」，不同步「删除」，避免误删扩散与同步风暴；
///  - 以大小判定一致性，「同大小不同内容」的极端情况不会被再次拉齐（后续可加内容哈希增强）。
class FolderSyncService {
  FolderSyncService({
    required FileTransferService fileService,
    required String selfId,
  })  : _fileService = fileService,
        _selfId = selfId;

  final FileTransferService _fileService;
  final String _selfId;

  static const Duration _reconcileInterval = Duration(seconds: 30);
  /// watch 不可用时的降级同步周期（Android 部分 ROM 上 Directory.watch 会
  /// 触发 Dart VM 断言，此时靠更短的周期 reconcile 保证收敛）。
  static const Duration _reconcileFallbackInterval = Duration(seconds: 10);
  static const Duration _watchDebounce = Duration(milliseconds: 500);
  static const Duration _echoWindow = Duration(seconds: 4);
  static const int _mtimeToleranceMs = 1000;

  /// 可同步的单个文件上限（字节）。超限文件跳过不推送：
  /// readAsBytes 会把整个文件载入堆，超大文件会导致 Dart VM OOM——
  /// 在 Android 上是进程级致命崩溃（真机实测「选 Download 后闪退」）。
  static int get maxSyncFileSize =>
      Platform.isAndroid ? 100 * 1024 * 1024 : 1024 * 1024 * 1024;

  /// 因超限被跳过的文件（relPath 集合），供状态文案展示
  final Set<String> _skippedOversize = <String>{};

  String? _folder;
  StreamSubscription<FileSystemEvent>? _watchSub;
  bool _watchActive = false;
  Timer? _debounceTimer;
  Timer? _reconcileTimer;
  final Set<SyncEndpoint> _peers = <SyncEndpoint>{};
  /// 对端工作文件夹（peer.toString() → 路径），reconcile 时从对端 manifest 学习
  final Map<String, String> _peerFolders = <String, String>{};
  final Map<String, DateTime> _echoSuppress = <String, DateTime>{};
  final Set<String> _pendingChanges = <String>{};
  bool _reconciling = false;
  Completer<void>? _reconcileDone;
  bool _flushing = false;
  SyncStatus _status = const SyncStatus(
    folder: null,
    fileCount: 0,
    peerCount: 0,
    message: '未设置工作文件夹',
  );

  /// 同步写入/推送错误（非致命，供 UI 展示状态文案）
  void Function(String msg)? onError;
  /// 同步状态变化
  void Function(SyncStatus)? onStatus;

  bool get isWatching => _watchActive;
  String? get folder => _folder;
  int get peerCount => _peers.length;
  /// 已连接对端的工作文件夹（供 UI 展示对端同步目录）
  Map<String, String> get peerFolders => Map.unmodifiable(_peerFolders);

  /// 当前同步状态（业务层已缓存，UI 直接读取，不重复扫描）。
  SyncStatus get currentStatus => _status;

  /// 设置/更换工作文件夹；传 null 关闭同步。
  Future<void> setFolder(String? path) async {
    await _stopWatch();
    _echoSuppress.clear();
    _pendingChanges.clear();
    _skippedOversize.clear();
    if (path == null) {
      _folder = null;
      _reconcileTimer?.cancel();
      _reconcileTimer = null;
      _emitStatus();
      return;
    }
    final dir = Directory(path);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    _folder = p.normalize(p.absolute(path));
    _watchActive = false;
    try {
      await _startWatch();
    } catch (e) {
      // 部分平台（Android inotify watcher）watch 会抛断言/文件系统异常。
      // 非致命：降级为纯周期 reconcile，同步仍能收敛，仅实时性降低。
      print('[Sync] 目录监听启动失败，降级为周期同步: $e');
      await _stopWatch();
    }
    _reconcileTimer?.cancel();
    final interval = _watchActive
        ? _reconcileInterval
        : _reconcileFallbackInterval;
    _reconcileTimer = Timer.periodic(interval, (_) {
      unawaited(_reconcileAll());
    });
    _emitStatus();
    unawaited(_reconcileAll());
  }

  /// 对端端点变化（发现/离线）。仅在集合变化时触发一次 reconcile。
  void updatePeers(Set<SyncEndpoint> endpoints) {
    final changed =
        _peers.length != endpoints.length || !_peers.containsAll(endpoints);
    if (!changed) return;
    _peers
      ..clear()
      ..addAll(endpoints);
    final keep = endpoints.map((e) => e.toString()).toSet();
    _peerFolders.removeWhere((key, _) => !keep.contains(key));
    _emitStatus();
    if (_folder != null) unawaited(_reconcileAll());
  }

  Future<void> dispose() async {
    await _stopWatch();
    _reconcileTimer?.cancel();
    _reconcileTimer = null;
  }

  /// 手动触发一次全量 reconcile（供测试与「立即同步」使用）。
  ///
  /// 若已有对齐在进行，先等待其完成，再执行一轮「反映当前状态」的对齐，
  /// 保证本方法返回时一定已按最新状态完成一次对齐（不会因并发而被静默忽略）。
  Future<void> reconcileNow() {
    final pending = _reconcileDone;
    if (pending != null) {
      return pending.future.then((_) => _reconcileAll());
    }
    return _reconcileAll();
  }

  /// 返回本机工作文件夹清单（供 FileTransferService 的 GET /sync-manifest 使用）。
  Future<Map<String, dynamic>> manifest() async {
    final files = <Map<String, dynamic>>[];
    if (_folder != null) {
      for (final e in _scanFolder().entries) {
        files.add({
          'relPath': e.key,
          'size': e.value.size,
          'mtimeMs': e.value.mtimeMs,
        });
      }
    }
    return {'deviceId': _selfId, 'folder': _folder, 'files': files};
  }

  /// 收到对端推送的同步文件：写入本机工作文件夹（同相对路径），保留源端 mtime。
  Future<void> handleRemoteFile(
    String relPath,
    List<int> bytes,
    int mtimeMs,
  ) async {
    final root = _folder;
    if (root == null || relPath.isEmpty) return;
    final target = _resolveSafe(root, relPath);
    if (target == null) return;
    final cleanRel = relPath.replaceAll('\\', '/');
    // 先登记回声抑制，再写文件：保证随后触发的 watch 事件被抑制，不会回推。
    _markEcho(cleanRel);
    try {
      final file = File(target);
      final parent = file.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      if (mtimeMs > 0) {
        try {
          file.setLastModifiedSync(
              DateTime.fromMillisecondsSinceEpoch(mtimeMs));
        } catch (_) {
          // 个别文件系统不支持精确设置 mtime，忽略（不影响大小判定的一致性）
        }
      }
      _emitStatus();
    } catch (e) {
      onError?.call('同步写入失败: $e');
    }
  }

  void _emitStatus() {
    final root = _folder;
    if (root == null) {
      _status = SyncStatus(
        folder: null,
        fileCount: 0,
        peerCount: _peers.length,
        message: '未设置工作文件夹',
        peerFolders: Map.of(_peerFolders),
      );
    } else {
      final n = _scanFolder().length;
      final skipped = _skippedOversize.length;
      _status = SyncStatus(
        folder: root,
        fileCount: n,
        peerCount: _peers.length,
        message: _watchActive
            ? '已同步 $n 个文件 · ${_peers.length} 台设备'
            : '已同步 $n 个文件 · ${_peers.length} 台设备 · 周期同步(监听不可用)'
                '${skipped > 0 ? ' · 跳过 $skipped 个超大文件' : ''}',
        peerFolders: Map.of(_peerFolders),
      );
    }
    onStatus?.call(_status);
  }

  Future<void> _startWatch() async {
    // Android：Dart VM inotify watcher（multiplexing）在外部存储路径上会触发
    // VM 断言（真机实测，file_patch.dart:522），且订阅会静默死亡、状态不可信。
    // 因此 Android 一律不启动 watch，直接依赖 10s 周期 reconcile 保证收敛
    //（_scanFolder 递归全量扫描，最终仍完全同步，仅实时性为秒级）。
    // 桌面端（Windows/Linux/macOS）保留 watch 实时推送。
    if (Platform.isAndroid) return;
    final dir = Directory(_folder!);
    final recursive = !Platform.isIOS;
    final stream = dir.watch(recursive: recursive);
    _watchSub = stream.asBroadcastStream().listen(
      (e) => _onWatchEvent(e),
      onError: (e) {
        print('[Sync] watch 异常: $e');
      },
      cancelOnError: false,
    );
    _watchActive = true;
  }

  Future<void> _stopWatch() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    await _watchSub?.cancel();
    _watchSub = null;
    _watchActive = false;
  }

  void _onWatchEvent(FileSystemEvent e) {
    final root = _folder;
    if (root == null) return;
    final rel = _relPath(root, e.path);
    if (rel.isEmpty) return;
    _pendingChanges.add(rel);
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_watchDebounce, () {
      unawaited(_flushChanges());
    });
  }

  /// 去抖后把本地变更推送到所有对端。
  Future<void> _flushChanges() async {
    if (_folder == null || _flushing) return;
    _flushing = true;
    try {
      if (_pendingChanges.isEmpty) return;
      final changes = Set<String>.from(_pendingChanges);
      _pendingChanges.clear();
      for (final rel in changes) {
        if (_isEcho(rel)) continue; // 回声：远端写入，不回推
        final fullPath = p.join(_folder!, rel.split('/').join(p.separator));
        final f = File(fullPath);
        if (FileSystemEntity.typeSync(fullPath) != FileSystemEntityType.file) {
          continue;
        }
        final st = f.statSync();
        if (st.size > maxSyncFileSize) {
          _skippedOversize.add(rel);
          continue;
        }
        for (final peer in List<SyncEndpoint>.from(_peers)) {
          try {
            await _fileService.pushSyncFile(
              host: peer.host,
              port: peer.port,
              relPath: rel,
              bytes: await f.readAsBytes(),
              mtimeMs: st.modified.millisecondsSinceEpoch,
            );
          } catch (err) {
            print('[Sync] 推送失败 $rel → $peer: $err');
          }
        }
      }
      _emitStatus();
    } finally {
      _flushing = false;
    }
  }

  Future<void> _reconcileAll() async {
    if (_folder == null || _peers.isEmpty) return;
    if (_reconciling) {
      // 已有对齐在进行：等待其结束后再补跑一轮，覆盖等待期间的新变更
      final pending = _reconcileDone;
      if (pending == null) return;
      await pending.future;
    }
    _reconciling = true;
    final done = Completer<void>();
    _reconcileDone = done;
    try {
      for (final peer in List<SyncEndpoint>.from(_peers)) {
        await _reconcileWithPeer(peer);
      }
      _emitStatus();
    } catch (e) {
      print('[Sync] reconcile 异常: $e');
    } finally {
      _reconciling = false;
      _reconcileDone = null;
      done.complete();
    }
  }

  /// 与单个对端对齐：把本机「对端没有 / 内容更新」的文件推给对端。
  Future<void> _reconcileWithPeer(SyncEndpoint peer) async {
    final root = _folder;
    if (root == null) return;
    final data =
        await _fileService.fetchSyncManifest(host: peer.host, port: peer.port);
    if (data == null) return;
    // 学习对端工作文件夹（供 UI 展示「对端在同步哪个文件夹」）
    final peerFolder = (data['folder'] as String?) ?? '';
    if (peerFolder.isNotEmpty) {
      _peerFolders[peer.toString()] = peerFolder;
    }
    final peerManifest = _parseManifest(data);
    final local = _scanFolder();
    for (final entry in local.entries) {
      final rel = entry.key;
      final mine = entry.value;
      final theirs = peerManifest.files[rel];
      if (theirs == null) {
        await _pushLocalFile(peer, rel, mine);
      } else if (mine.size != theirs.size) {
        // 冲突：mtime 新者胜；mtime 接近时按 deviceId 字典序大者胜（两端计算一致，恰好一方推送）
        bool iWin;
        if (mine.mtimeMs > theirs.mtimeMs + _mtimeToleranceMs) {
          iWin = true;
        } else if (mine.mtimeMs < theirs.mtimeMs - _mtimeToleranceMs) {
          iWin = false;
        } else {
          iWin = _selfId.compareTo(peerManifest.deviceId) > 0;
        }
        if (iWin) {
          await _pushLocalFile(peer, rel, mine);
        }
      }
    }
  }

  Future<void> _pushLocalFile(
      SyncEndpoint peer, String rel, _FileMeta meta) async {
    final root = _folder;
    if (root == null) return;
    if (meta.size > maxSyncFileSize) {
      _skippedOversize.add(rel);
      return;
    }
    final f = File(p.join(root, rel.split('/').join(p.separator)));
    if (FileSystemEntity.typeSync(f.path) != FileSystemEntityType.file) return;
    try {
      await _fileService.pushSyncFile(
        host: peer.host,
        port: peer.port,
        relPath: rel,
        bytes: await f.readAsBytes(),
        mtimeMs: meta.mtimeMs,
      );
    } catch (e) {
      print('[Sync] reconcile 推送失败 $rel → $peer: $e');
    }
  }

  Map<String, _FileMeta> _scanFolder() {
    final result = <String, _FileMeta>{};
    final root = _folder;
    if (root == null) return result;
    final dir = Directory(root);
    if (!dir.existsSync()) return result;
    try {
      for (final ent in dir.listSync(recursive: true, followLinks: false)) {
        if (ent is File) {
          final rel = _relPath(root, ent.path);
          if (rel.isEmpty) continue;
          final st = ent.statSync();
          result[rel] = _FileMeta(
              size: st.size, mtimeMs: st.modified.millisecondsSinceEpoch);
        }
      }
    } catch (e) {
      print('[Sync] 扫描文件夹失败: $e');
    }
    return result;
  }

  _PeerManifest _parseManifest(Map<String, dynamic> data) {
    final deviceId = (data['deviceId'] as String?) ?? '';
    final list = (data['files'] as List?) ?? const [];
    final files = <String, _FileMeta>{};
    for (final e in list) {
      final em = e as Map<String, dynamic>;
      final rel = (em['relPath'] as String? ?? '').replaceAll('\\', '/');
      if (rel.isEmpty) continue;
      files[rel] = _FileMeta(
        size: (em['size'] as int?) ?? 0,
        mtimeMs: (em['mtimeMs'] as int?) ?? 0,
      );
    }
    return _PeerManifest(deviceId: deviceId, files: files);
  }

  /// 计算文件相对根目录的路径，统一使用 '/' 分隔（便于跨平台传输与匹配）。
  String _relPath(String root, String fullPath) {
    final rel = p.relative(fullPath, from: root);
    return rel.split(p.separator).join('/');
  }

  /// 校验远端传来的相对路径安全（拒绝绝对路径与 `..` 逃逸），返回绝对目标路径。
  String? _resolveSafe(String root, String relPath) {
    final cleaned = relPath.replaceAll('\\', '/');
    if (cleaned.isEmpty) return null;
    final parts = cleaned.split('/');
    if (parts.contains('..') || parts.contains('')) return null;
    final target = p.join(root, cleaned.split('/').join(p.separator));
    final normRoot = p.normalize(p.absolute(root));
    final normTarget = p.normalize(p.absolute(target));
    final prefix =
        normRoot.endsWith(p.separator) ? normRoot : '$normRoot${p.separator}';
    if (normTarget != normRoot && !normTarget.startsWith(prefix)) return null;
    return normTarget;
  }

  void _markEcho(String relPath) {
    _purgeEcho();
    _echoSuppress[relPath] = DateTime.now().add(_echoWindow);
  }

  bool _isEcho(String relPath) {
    final exp = _echoSuppress[relPath];
    if (exp == null) return false;
    if (DateTime.now().isBefore(exp)) return true;
    _echoSuppress.remove(relPath);
    return false;
  }

  void _purgeEcho() {
    final now = DateTime.now();
    _echoSuppress.removeWhere((_, exp) => !now.isBefore(exp));
  }
}