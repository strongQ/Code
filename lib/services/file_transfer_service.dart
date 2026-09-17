import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 文件传输进度
class TransferProgress {
  final String fileName;
  final int totalBytes;
  final int doneBytes;
  final bool sending;

  const TransferProgress({
    required this.fileName,
    required this.totalBytes,
    required this.doneBytes,
    this.sending = false,
  });

  double get fraction =>
      totalBytes == 0 ? 0 : doneBytes / totalBytes;
}

/// 基于 HTTP 的点对点文件传输服务。
///
/// 每个设备启动一个本地 HttpServer（端口 9877），提供：
///   POST /upload  – 接收对方发来的文件（raw body + X-File-Name header）
///   GET  /health  – 健康检查
///
/// 发送时主动 POST 到目标设备的 /upload 端点。
class FileTransferService {
  /// 服务端口（发送/接收共用）。默认 9877，可注入以便测试绑定空闲端口。
  final int port;

  HttpServer? _server;
  late final Directory _recvDir;

  /// 本机设备名称（用于 /health 广播身份）
  String deviceName = '';
  /// 本机设备唯一 ID
  String deviceId = '';

  /// 接收文件落地目录（UI 可展示）
  String get receivedDir => _recvDir.path;

  /// 接收进度
  void Function(TransferProgress)? onReceiveProgress;
  /// 接收完成
  void Function(String filePath, int size)? onFileReceived;
  /// 发送进度
  void Function(TransferProgress)? onSendProgress;
  /// 发送完成
  void Function()? onSendComplete;
  /// 发送/接收错误
  void Function(String msg)? onError;

  /// 工作文件夹同步：收到对端推送的文件（相对路径, 字节, 源端 mtime 毫秒）。
  /// 声明为 Future 以便在响应前完成落盘。
  Future<void> Function(
      String relativePath, List<int> bytes, int mtimeMs)? onSyncReceive;

  /// 工作文件夹同步：提供本机清单（GET /sync-manifest 使用）。
  Future<Map<String, dynamic>> Function()? onSyncManifestProvider;

  FileTransferService({this.port = 9877});

  /// 启动本地 HTTP 服务
  ///
  /// 接收文件落地到持久化目录：`<Documents>/p2p_received`，
  /// 临时目录不可用时自动降级。
  Future<void> start() async {
    final baseDir = await _resolveBaseDir();
    _recvDir = Directory(p.join(baseDir, 'p2p_received'));
    if (!_recvDir.existsSync()) {
      _recvDir.createSync(recursive: true);
    }

    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server!.listen(_handle, onError: (e) {
      print('[FileTransfer] 服务异常: $e');
    });
    print('[FileTransfer] 本地服务 :$port');
  }

  /// 接收文件落地到用户可见的持久化目录：
  /// - Android：优先 App 专属外部存储 `<ExternalFiles>`（`/storage/emulated/0/Android/data/<pkg>/files`，
  ///   系统文件管理器可见、默认可读写）；
  /// - 其他平台：文档目录；均不可用时降级临时目录。
  Future<String> _resolveBaseDir() async {
    if (Platform.isAndroid) {
      try {
        final external = await getExternalStorageDirectories();
        for (final e in external ?? <Directory>[]) {
          if (e.path.isNotEmpty) return e.path;
        }
      } catch (e) {
        print('[FileTransfer] 外部存储不可用，降级到文档目录: $e');
      }
    }
    try {
      final docs = await getApplicationDocumentsDirectory();
      return docs.path;
    } catch (e) {
      print('[FileTransfer] 文档目录不可用，降级到临时目录: $e');
      final tmp = await getTemporaryDirectory();
      return tmp.path;
    }
  }

  /// 生成不冲突的目标文件：重名时追加时间戳后缀
  File _uniqueTargetFile(String fileName) {
    var target = File(p.join(_recvDir.path, fileName));
    if (!target.existsSync()) return target;
    final ext = p.extension(fileName);
    final root = p.withoutExtension(fileName);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    return File(p.join(_recvDir.path, '${root}_$stamp$ext'));
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    final method = req.method;

    if (method == 'POST' && path == '/upload') {
      await _handleUpload(req);
    } else if (method == 'POST' && path == '/sync') {
      await _handleSync(req);
    } else if (method == 'GET' && path == '/health') {
      req.response.statusCode = HttpStatus.ok;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'code': 0,
        'message': 'ok',
        'data': {
          'name': deviceName,
          'id': deviceId,
        },
      }));
      await req.response.close();
    } else if (method == 'GET' && path == '/sync-manifest') {
      req.response.statusCode = HttpStatus.ok;
      req.response.headers.contentType = ContentType.json;
      Map<String, dynamic> data;
      final provider = onSyncManifestProvider;
      if (provider != null) {
        try {
          data = await provider();
        } catch (_) {
          data = {'deviceId': deviceId, 'files': <Map<String, dynamic>>[]};
        }
      } else {
        data = {'deviceId': deviceId, 'files': <Map<String, dynamic>>[]};
      }
      req.response.write(
          jsonEncode({'code': 0, 'message': 'ok', 'data': data}));
      await req.response.close();
    } else {
      req.response.statusCode = HttpStatus.notFound;
      req.response.write(jsonEncode({'code': 404, 'message': 'not found'}));
      await req.response.close();
    }
  }

  Future<void> _handleUpload(HttpRequest req) async {
    // 发送端已对文件名做 Uri.encodeComponent（纯 ASCII 合法 header 值），此处对称解码还原。
    // 解码失败（如旧版本未编码、文件名含非法 % 转义）时回退为原始值，保证任何文件名都能接收。
    final rawName = req.headers.value('x-file-name');
    late String fileName;
    if (rawName != null && rawName.isNotEmpty) {
      try {
        fileName = Uri.decodeComponent(rawName);
      } catch (_) {
        fileName = rawName;
      }
    } else {
      fileName = 'unknown_${DateTime.now().millisecondsSinceEpoch}';
    }
    final safeName = fileName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    final target = _uniqueTargetFile(safeName);

    // 从 Content-Length 获取真实文件大小，用于进度计算
    final totalBytes = int.tryParse(req.headers.value('content-length') ?? '0') ?? 0;

    var received = 0;
    final sink = target.openWrite();

    onReceiveProgress?.call(TransferProgress(
      fileName: safeName,
      totalBytes: totalBytes,
      doneBytes: 0,
    ));

    await for (final chunk in req) {
      sink.add(chunk);
      received += chunk.length;
      onReceiveProgress?.call(TransferProgress(
        fileName: safeName,
        totalBytes: totalBytes,
        doneBytes: received,
      ));
    }

    await sink.close();

    req.response.statusCode = HttpStatus.ok;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode({
      'code': 0,
      'message': 'ok',
      'data': {'filePath': target.path, 'size': received},
    }));
    await req.response.close();

    onFileReceived?.call(target.path, received);
    print('[FileTransfer] 接收完成: $safeName ($received bytes)');
  }

  /// 发送文件到目标设备
  Future<void> sendFile(String localPath, String targetIp) async {
    final file = File(localPath);
    if (!await file.exists()) {
      onError?.call('文件不存在: $localPath');
      return;
    }

    final fileName = p.basename(localPath);
    final bytes = await file.readAsBytes();
    final total = bytes.length;

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 5);

    try {
      final req = await client
          .postUrl(Uri.parse('http://$targetIp:$port/upload'))
          .timeout(const Duration(seconds: 10));
      req.headers.add('x-file-name', Uri.encodeComponent(fileName));
      req.contentLength = total;

      var sent = 0;
      const chunkSize = 64 * 1024; // 64KB
      for (int i = 0; i < total; i += chunkSize) {
        final end = (i + chunkSize) > total ? total : i + chunkSize;
        req.add(bytes.sublist(i, end));
        sent = end;
        onSendProgress?.call(TransferProgress(
          fileName: fileName,
          totalBytes: total,
          doneBytes: sent,
          sending: true,
        ));
      }

      final respBytes = await req.close();
      final resp = await respBytes
          .transform(utf8.decoder)
          .join();
      print('[FileTransfer] 发送完成: $fileName → $targetIp  $resp');

      onSendProgress?.call(TransferProgress(
        fileName: fileName,
        totalBytes: total,
        doneBytes: total,
        sending: true,
      ));
      onSendComplete?.call();
    } catch (e) {
      onError?.call('发送失败: $e');
    } finally {
      client.close(force: true);
    }
  }

  /// 接收对端推送的同步文件（POST /sync）。
  /// body 为文件字节，header `x-sync-path`（Uri.encodeComponent 编码的相对路径）、
  /// `x-sync-mtime`（源端 mtime 毫秒）。解码后交给 onSyncReceive 落盘。
  Future<void> _handleSync(HttpRequest req) async {
    final rawRel = req.headers.value('x-sync-path');
    String relPath;
    if (rawRel != null && rawRel.isNotEmpty) {
      try {
        relPath = Uri.decodeComponent(rawRel);
      } catch (_) {
        relPath = rawRel;
      }
    } else {
      req.response.statusCode = HttpStatus.badRequest;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'code': 400, 'message': 'missing x-sync-path'}));
      await req.response.close();
      return;
    }
    final mtimeMs = int.tryParse(req.headers.value('x-sync-mtime') ?? '0') ?? 0;
    final totalBytes = int.tryParse(req.headers.value('content-length') ?? '0') ?? 0;

    // 接收端大小门禁：超限直接拒收（413），不把整个文件读进堆，
    // 防止对端推送超大文件导致本机 Dart VM OOM 崩溃。
    final maxBytes = Platform.isAndroid ? 100 * 1024 * 1024 : 1024 * 1024 * 1024;
    if (totalBytes > maxBytes) {
      req.response.statusCode = 413;
      req.response.headers.contentType = ContentType.json;
      req.response.write(
          jsonEncode({'code': 413, 'message': 'file too large for sync'}));
      await req.response.close();
      return;
    }

    final bytes = <int>[];
    await for (final chunk in req) {
      bytes.addAll(chunk);
    }

    final handler = onSyncReceive;
    if (handler != null) {
      try {
        await handler(relPath, bytes, mtimeMs);
      } catch (e) {
        print('[FileTransfer] 同步接收处理异常: $e');
      }
    }

    req.response.statusCode = HttpStatus.ok;
    req.response.headers.contentType = ContentType.json;
    req.response.write(
        jsonEncode({'code': 0, 'message': 'ok', 'data': {'size': totalBytes}}));
    await req.response.close();
  }

  /// 推送单个同步文件到目标端点（POST /sync）。失败时抛出异常，由调用方决定处理。
  Future<void> pushSyncFile({
    required String host,
    required int port,
    required String relPath,
    required List<int> bytes,
    required int mtimeMs,
  }) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client
          .postUrl(Uri.parse('http://$host:$port/sync'))
          .timeout(const Duration(seconds: 10));
      req.headers.add('x-sync-path', Uri.encodeComponent(relPath));
      req.headers.add('x-sync-mtime', '$mtimeMs');
      req.contentLength = bytes.length;
      req.add(bytes);
      final resp = await req.close();
      await resp.drain<void>();
    } finally {
      client.close(force: true);
    }
  }

  /// 拉取目标端点的工作文件夹清单（GET /sync-manifest），失败返回 null。
  Future<Map<String, dynamic>?> fetchSyncManifest({
    required String host,
    required int port,
  }) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client
          .getUrl(Uri.parse('http://$host:$port/sync-manifest'))
          .timeout(const Duration(seconds: 8));
      final resp = await req.close().timeout(const Duration(seconds: 8));
      final body = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 8));
      final json = jsonDecode(body) as Map<String, dynamic>;
      if (json['code'] != 0) return null;
      return json['data'] as Map<String, dynamic>?;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    print('[FileTransfer] 已停止');
  }
}
