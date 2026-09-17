/// 局域网内发现的设备信息
class DeviceInfo {
  final String id;
  final String name;
  final String ip;
  final int port;

  const DeviceInfo({
    required this.id,
    required this.name,
    required this.ip,
    required this.port,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceInfo &&
          other.id == id &&
          other.ip == ip &&
          other.port == port;

  @override
  int get hashCode => Object.hash(id, ip, port);

  @override
  String toString() => 'DeviceInfo($name, $ip:$port)';
}
