import 'dart:io';

import 'package:flutter/services.dart';

import 'open_dir_service.dart';

/// Android 平台桥服务：
/// - 用系统文件管理器打开目录（MethodChannel → Kotlin `ACTION_VIEW` intent）；
/// - 前台后台服务（Kotlin foreground service）：应用退到后台后继续保活
///   设备发现 / 文件传输 / 文件夹同步。
///
/// 非 Android 平台：打开目录回退 [OpenDirService]（桌面文件管理器），
/// 后台服务相关调用为 no-op。
class AndroidPlatformService {
  static const MethodChannel _channel = MethodChannel('p2p_transfer');

  /// 在系统文件管理器中打开目录 [dir]；[dir] 为空时静默忽略。
  Future<void> openDirectory(String dir) async {
    if (dir.isEmpty) return;
    if (!Platform.isAndroid) {
      await OpenDirService().openDirectory(dir);
      return;
    }
    try {
      await _channel.invokeMethod<void>('openDirectory', {'path': dir});
    } on PlatformException catch (e) {
      print('[AndroidPlatform] 打开目录失败: ${e.message}');
    } catch (e) {
      print('[AndroidPlatform] 调用打开目录通道失败: $e');
    }
  }

  /// 启动前台后台服务（App 退到后台后继续运行）。非 Android 为 no-op。
  Future<void> startBackgroundService() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('startBackgroundService');
    } catch (e) {
      print('[AndroidPlatform] 启动后台服务失败: $e');
    }
  }

  /// 停止前台后台服务。非 Android 为 no-op。
  Future<void> stopBackgroundService() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('stopBackgroundService');
    } catch (e) {
      print('[AndroidPlatform] 停止后台服务失败: $e');
    }
  }

  /// 是否已授予「所有文件访问」权限（MANAGE_EXTERNAL_STORAGE）。
  /// 非 Android 或 Android 10 及以下返回 true（无 scoped storage 限制）。
  Future<bool> hasAllFilesAccess() async {
    if (!Platform.isAndroid) return true;
    try {
      final r = await _channel.invokeMethod<bool>('hasAllFilesAccess');
      return r ?? true;
    } catch (e) {
      print('[AndroidPlatform] 查询所有文件访问权限失败: $e');
      return true;
    }
  }

  /// 打开系统「所有文件访问」设置页（由用户手动开启）。
  Future<void> requestAllFilesAccess() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('requestAllFilesAccess');
    } catch (e) {
      print('[AndroidPlatform] 打开权限设置页失败: $e');
    }
  }

  /// 是否已豁免电池优化（「不优化此应用」）。
  /// 非 Android 或 Android 5 及以下返回 true。
  Future<bool> hasBatteryOptExempted() async {
    if (!Platform.isAndroid) return true;
    try {
      final r = await _channel.invokeMethod<bool>('hasBatteryOptExempted');
      return r ?? true;
    } catch (e) {
      print('[AndroidPlatform] 查询电池优化豁免失败: $e');
      return true;
    }
  }

  /// 弹出系统对话框请求豁免电池优化（后台保活需要）。
  Future<void> requestBatteryOptExemption() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('requestBatteryOptExemption');
    } catch (e) {
      print('[AndroidPlatform] 打开豁免请求对话框失败: $e');
    }
  }
}
