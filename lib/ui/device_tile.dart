import 'package:flutter/material.dart';
import '../models/device_info.dart';

/// 单台设备的列表项
Widget deviceTile({
  required DeviceInfo device,
  required VoidCallback onSend,
}) {
  return Card(
    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
    elevation: 1,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    ),
    child: ListTile(
      leading: const CircleAvatar(
        radius: 18,
        backgroundColor: Color(0xFF4A90D9),
        child: Icon(Icons.desktop_windows, color: Colors.white, size: 20),
      ),
      title: Text(
        device.name,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(device.ip,
          style: const TextStyle(fontSize: 12, color: Colors.grey)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.wifi, size: 16, color: Colors.green[600]),
          const SizedBox(width: 10),
          ElevatedButton.icon(
            onPressed: onSend,
            icon: const Icon(Icons.send, size: 16),
            label: const Text('发送', style: TextStyle(fontSize: 13)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF4A90D9),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
