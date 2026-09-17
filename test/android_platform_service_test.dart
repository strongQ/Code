// Android 平台桥的非 Android 行为测试：
// - 后台服务启动/停止在非 Android 平台上为 no-op（不触碰 MethodChannel、不抛异常）；
// - 空目录路径打开调用被静默忽略（不触碰 MethodChannel / 不启动进程）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:p2p_transfer/services/android_platform_service.dart';

void main() {
  test('非 Android 平台：后台服务 start/stop 为 no-op 且不抛异常',
      skip: Platform.isAndroid, () async {
    final svc = AndroidPlatformService();
    await expectLater(svc.startBackgroundService(), completes);
    await expectLater(svc.stopBackgroundService(), completes);
  });

  test('空目录路径：打开调用被静默忽略（不触碰通道/进程）', () async {
    final svc = AndroidPlatformService();
    await expectLater(svc.openDirectory(''), completes);
  });

  test('hasAllFilesAccess 在非 Android 平台返回 true', skip: Platform.isAndroid,
      () async {
    expect(await AndroidPlatformService().hasAllFilesAccess(), isTrue);
  });

  test('requestAllFilesAccess 在非 Android 平台为 no-op 且不抛异常',
      skip: Platform.isAndroid, () async {
    await expectLater(AndroidPlatformService().requestAllFilesAccess(), completes);
  });

  test('hasBatteryOptExempted 在非 Android 平台返回 true',
      skip: Platform.isAndroid, () async {
    expect(await AndroidPlatformService().hasBatteryOptExempted(), isTrue);
  });

  test('requestBatteryOptExemption 在非 Android 平台为 no-op 且不抛异常',
      skip: Platform.isAndroid, () async {
    await expectLater(AndroidPlatformService().requestBatteryOptExemption(), completes);
  });
}
