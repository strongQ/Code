import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/device_info.dart';

/// 基于 HTTP 子网扫描的局域网设备自动发现服务。
///
/// 原理：
///  1. 获取本机 IP，推算所在 C 段（如 192.168.1.x）
///  2. 每隔 [scanInterval] 并行扫描 C 段内所有 IP 的 /health 端点
///  3. 响应的设备即为同一局域网内的 P2P 设备
///  4. 超过 [deviceTimeout] 未响应的设备自动移除
///
/// 无需 UDP / mDNS，仅使用标准 HTTP，兼容性最好。
class DiscoveryService {
  static const int _kPort = 9877;
  static const Duration _kScanInterval = Duration(seconds: 5);
  static const Duration _kRequestTimeout = Duration(milliseconds: 400);
  static const Duration _kDeviceTimeout = Duration(seconds: 15);
  static const int _kMaxParallel = 50;

  final String _selfId;
  final String _selfName;

  final Set<String> _localIps = <String>{};
  final List<String> _subnetBases = <String>[];
  bool _scanning = false;

  /// 设备列表变化回调
  void Function(List<DeviceInfo>)? onDevicesChanged;

  final Map<String, DeviceInfo> _devices = {};
  final Map<String, DateTime> _lastSeen = {};
  Timer? _scanTimer;
  bool _running = false;

  DiscoveryService()
      : _selfId = '${_hostname()}-${DateTime.now().microsecondsSinceEpoch}',
        _selfName = _hostname();

  static String _hostname() {
    try {
      final h = Platform.localHostname;
      return h.isNotEmpty ? h : 'Flutter-Device';
    } catch (_) {
      return 'Flutter-Device';
    }
  }

  /// 获取本机所有 IPv4 网卡及其子网前缀。
  ///
  /// 关键点：一台机器可能同时挂多张网卡（如「无线网卡开热点 + 有线/其它网卡」），
  /// 只取第一张网卡会漏掉热点网段，导致热点侧主机找不到连上来的客户端，
  /// 表现为"客户端能发现主机、主机却找不到客户端"的单向发现。
  /// 因此这里收集所有非回环 IPv4 网段的 C 段，扫描时全部覆盖。
  Future<void> _detectNetwork() async {
    final localIps = <String>{};
    final bases = <String>{};
    try {
      final interfaces = await NetworkInterface.list();
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            final ip = addr.address;
            localIps.add(ip);
            final parts = ip.split('.');
            if (parts.length == 4) {
              bases.add('${parts[0]}.${parts[1]}.${parts[2]}');
            }
          }
        }
      }
    } catch (e) {
      print('[Discovery] 检测网络失败: $e');
    }
    if (localIps.isEmpty) {
      // 回退：假设 192.168.0.x
      localIps.add('192.168.0.1');
      bases.add('192.168.0');
    }
    _localIps
      ..clear()
      ..addAll(localIps);
    _subnetBases
      ..clear()
      ..addAll(bases);
    print('[Discovery] 本机 IP: ${_localIps.join(', ')} | 子网: '
        '${_subnetBases.map((b) => '$b.x').join(', ')}');
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;
    await _detectNetwork();

    // 立即扫描一次
    await _scanSubnet();

    // 周期扫描（每次重新探测网卡，适配热点/网卡在启动后才上线的场景）
    _scanTimer = Timer.periodic(_kScanInterval, (_) {
      if (!_running) return;
      _detectNetwork().then((_) => _scanSubnet());
    });

    print('[Discovery] 启动: $_selfName ($_selfId)');
  }

  /// 并行扫描所有本机网段内所有 IP
  Future<void> _scanSubnet() async {
    if (_subnetBases.isEmpty || !_running || _scanning) return;
    _scanning = true;

    final client = HttpClient();
    client.connectionTimeout = _kRequestTimeout;

    final futures = <Future<void>>[];
    for (final base in _subnetBases) {
      for (int i = 1; i <= 254; i++) {
        final ip = '$base.$i';
        if (_localIps.contains(ip)) continue;
        futures.add(_checkDevice(client, ip));
        if (futures.length >= _kMaxParallel) {
          await Future.wait(futures);
          futures.clear();
        }
      }
    }
    if (futures.isNotEmpty) {
      await Future.wait(futures);
    }

    client.close(force: true);
    _scanning = false;
    _cleanup();
    _notify();
  }

  /// 检测单个 IP 是否是 P2P 设备
  Future<void> _checkDevice(HttpClient client, String ip) async {
    try {
      final req = await client
          .getUrl(Uri.parse('http://$ip:$_kPort/health'))
          .timeout(_kRequestTimeout);
      final resp = await req.close().timeout(_kRequestTimeout);
      final body = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(_kRequestTimeout);

      final json = jsonDecode(body) as Map<String, dynamic>;
      if (json['code'] != 0) return;

      final data = json['data'] as Map<String, dynamic>;
      final name = (data['name'] as String? ?? 'Device');
      final id = (data['id'] as String? ?? ip);

      // 忽略自己
      if (id == _selfId) return;

      final isNew = !_devices.containsKey(id);
      _devices[id] = DeviceInfo(
        id: id,
        name: name,
        ip: ip,
        port: _kPort,
      );
      _lastSeen[id] = DateTime.now();

      if (isNew) {
        print('[Discovery] 发现设备: $name ($ip)');
      }
    } catch (_) {
      // 无响应，忽略
    }
  }

  /// 移除超时的设备
  void _cleanup() {
    final now = DateTime.now();
    final toRemove = <String>[];
    _lastSeen.forEach((id, ts) {
      if (now.difference(ts) > _kDeviceTimeout) {
        toRemove.add(id);
      }
    });
    for (final id in toRemove) {
      final dev = _devices.remove(id);
      _lastSeen.remove(id);
      if (dev != null) {
        print('[Discovery] 设备离线: $dev');
      }
    }
  }

  void _notify() {
    onDevicesChanged?.call(List.unmodifiable(_devices.values));
  }

  Future<void> stop() async {
    _running = false;
    _scanTimer?.cancel();
    _devices.clear();
    _lastSeen.clear();
    print('[Discovery] 已停止');
  }
}
