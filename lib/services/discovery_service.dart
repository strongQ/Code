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
  static const int _kMaxParallel = 160;

  /// 常见局域网 C 段兜底表。
  ///
  /// 覆盖最典型的场景：家用/办公路由器（192.168.1、192.168.0）、
  /// Windows 热点（192.168.137）、Android 热点（192.168.43）、
  /// 常见内网/虚拟化网段（10.0.0、172.16.0）。
  /// 当无法从本机网卡可靠推断子网时（Android 常见），按这些网段扫描兜底。
  static const List<String> _kCommonLanBases = [
    '192.168.1',
    '192.168.0',
    '192.168.137', // Windows 热点
    '192.168.43', // Android 热点
    '10.0.0',
    '172.16.0',
  ];

  final String _selfId;
  final String _selfName;

  final Set<String> _localIps = <String>{};
  final List<String> _subnetBases = <String>[];
  bool _scanning = false;

  /// 连续「扫描后无在线设备」的轮数。
  /// 驱动常见网段兜底：本机上报的子网若连续扫不出任何设备，
  /// 说明该子网很可能不是真实局域网（Android 上 NetworkInterface.list()
  /// 误报/漏报时），下一轮起追加常见网段兜底。
  int _emptyCycles = 0;

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

  /// 获取本机所有非回环 IPv4 网卡及其子网前缀。
  ///
  /// 关键点 1：一台机器可能同时挂多张网卡（如「无线网卡开热点 + 有线/其它网卡」），
  /// 只取第一张网卡会漏掉热点网段，导致热点侧主机找不到连上来的客户端，
  /// 表现为"客户端能发现主机、主机却找不到客户端"的单向发现。
  /// 因此这里收集所有非回环 IPv4 网段的 C 段，扫描时全部覆盖。
  ///
  /// 关键点 2：Android 上 dart:io 的 NetworkInterface.list() 常常**不返回 Wi-Fi 的
  /// IPv4**（只返回 loopback，或返回错误/链路本地地址）。若此时仍只按"本机 IP 的 C 段"
  /// 扫描，就会扫错 /24，表现为「桌面端能找到 Android，Android 却找不到桌面端」的
  /// 单向发现（桌面端 Windows 网卡枚举可靠，故不受影响）。
  /// 处理：交由 [computeSubnetBases] 决策——取不到可信子网、或连续空扫描时，
  /// 追加 [_kCommonLanBases] 常见网段兜底。
  Future<void> _detectNetwork() async {
    final localIps = <String>{};
    try {
      final interfaces = await NetworkInterface.list();
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            localIps.add(addr.address);
          }
        }
      }
    } catch (e) {
      print('[Discovery] 检测网络失败: $e');
    }
    _localIps
      ..clear()
      ..addAll(localIps);
    _subnetBases
      ..clear()
      ..addAll(computeSubnetBases(localIps: localIps, emptyCycles: _emptyCycles));
    print('[Discovery] 本机 IP: ${localIps.isEmpty ? '(未检测到)' : localIps.join(', ')} | '
        '子网: ${_subnetBases.map((b) => '$b.x').join(', ')}');
  }

  /// 纯函数：根据「真实网卡 IP」与「连续空扫描轮数」决定本轮要扫描的 C 段子网。
  ///
  /// 抽成静态纯函数以便单元测试（不依赖 NetworkInterface / 真实网络）。
  ///
  /// 规则：
  ///  1. 收集所有非链路本地（169.254.x.x，Android 常见误报）IPv4 的 C 段作为首选子网；
  ///  2. 若取不到任何可信子网（[localIps] 为空/全链路本地），或连续 [emptyCycles] ≥ 1 轮
  ///     未扫出任何设备，则追加 [_kCommonLanBases] 常见局域网 C 段兜底。
  ///     （覆盖 Android 上报空/错误子网、或桌面端作为热点主机的场景。）
  static List<String> computeSubnetBases({
    required Iterable<String> localIps,
    int emptyCycles = 0,
  }) {
    final bases = <String>{};
    for (final ip in localIps) {
      final parts = ip.split('.');
      // 仅处理标准 IPv4；跳过链路本地 169.254.x.x（非真实局域网）。
      if (parts.length != 4) continue;
      if (parts[0] == '169' && parts[1] == '254') continue;
      bases.add('${parts[0]}.${parts[1]}.${parts[2]}');
    }
    final needFallback = bases.isEmpty || emptyCycles >= 1;
    if (needFallback) {
      for (final b in _kCommonLanBases) {
        bases.add(b);
      }
    }
    return bases.toList();
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
    // 记录连续空扫描轮数：驱动 [computeSubnetBases] 的常见网段兜底
    // （本机上报的子网连续扫不出任何在线设备时，下一轮起追加常见网段）。
    _emptyCycles = _devices.isEmpty ? _emptyCycles + 1 : 0;
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
