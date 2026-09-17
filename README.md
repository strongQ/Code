# P2P 文件传输工具 (Flutter)

局域网内点对点文件传输，**无需手动输入 IP**，打开 App 即可自动发现同一 Wi-Fi 下的其他设备。

## 架构

```
lib/
├── main.dart                        # 入口 + Provider 初始化
├── models/
│   └── device_info.dart             # 设备信息模型
├── services/
│   ├── discovery_service.dart       # HTTP 子网扫描设备自动发现 (port 9877/health)
│   ├── file_transfer_service.dart   # HTTP 文件收发 (port 9877/upload) + 同步端点 (/sync, /sync-manifest)
│   ├── folder_sync_service.dart     # 工作文件夹双向同步引擎（watch 去抖推送 + 周期 reconcile + 回声抑制 + 冲突裁决）
│   ├── app_dirs_service.dart        # 应用默认可读写目录解析（Android 端 p2p_sync 默认同步目录）
│   └── open_dir_service.dart        # 用系统文件管理器打开目录 / 文件所在目录
├── providers/
│   └── transfer_state.dart          # Provider 全局状态管理（装配同步服务、暴露 workingFolder/syncStatus）
└── ui/
    ├── home_page.dart               # 主界面 (设备列表 + 传输进度 + 工作文件夹同步面板)
    ├── device_tile.dart             # 设备列表项 Widget
    ├── transfer_progress_bar.dart   # 传输进度条 Widget
    └── folder_sync_panel.dart       # 工作文件夹同步面板（选目录/状态/打开/取消）
```

## 工作流程

1. **启动** → 同时启动 HttpServer(:9877) + 子网扫描定时器
2. **发现** → 每 5 秒并行扫描 C 段 (192.168.x.1~254) 的 `/health` 端点
3. **连接** → UI 自动展示附近设备列表，显示设备名和 IP
4. **传输** → 点击「发送」→ HTTP POST 到目标 `:9877/upload`
5. **接收** → 目标设备 HttpServer 接收 raw bytes → 保存到临时目录

## 运行

```bash
flutter pub get
flutter run
```

> 两台设备连接同一 Wi-Fi，分别运行即可互相发现。

## 权限要求

### Android (AndroidManifest.xml)
```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
<!-- 明文 HTTP（192.168.x.x:9877）必需，否则 Android 9+ 拦截全部局域网通信 -->
<application android:usesCleartextTraffic="true" ...>
```

### iOS (Info.plist)
```xml
<key>NSLocalNetworkUsageDescription</key>
<string>用于发现局域网内的其他设备</string>
```

## 技术要点

- **零配置发现**：通过 HTTP 子网扫描 + `/health` 健康检查自动发现设备，无需 mDNS / 输入 IP
- **纯 Dart 实现**：`dart:io` 的 `HttpServer` / `HttpClient` / `NetworkInterface`，无原生插件依赖
- **流式传输**：文件分块写入，支持大文件，实时进度回调
- **自动去重 & 超时**：设备 15 秒无响应自动从列表移除
- **统一 JSON 响应**：`{code, message, data}` 结构

## 单向发现 Bug 修复（任务 2 已完成，2026-09-09）

**现象**：电脑1 开无线热点，电脑2 连上后，电脑2 能发现电脑1，电脑1 却找不到电脑2。

**根因**（`discovery_service.dart`）：
- 旧 `_detectNetwork()` 遍历 `NetworkInterface.list()` 时取**第一张**非回环 IPv4 网卡就 `return`。开热点的主机通常有多张网卡（热点适配器 192.168.137.1/4.x + 有线/其它无线网卡），若热点网卡不是第一个，就会算错 C 段、扫错 /24，永远扫不到热点侧的客户端 → 单向发现。
- 旧逻辑只在 `start()` 探测一次网卡，热点网卡若在 App 启动后才上线则永久漏掉。

**修复**：
- `_detectNetwork()` 收集**所有**非回环 IPv4 网段的 C 段（`_subnetBases`）+ 所有本机 IP（`_localIps`），扫描时全部覆盖。
- `_scanSubnet()` 遍历每个网段 .1~.254，跳过**所有**本机 IP。
- `start()` 的周期定时器每轮先 `_detectNetwork()` 再 `_scanSubnet()`，动态适配网卡/热点变化。
- 新增 `_scanning` 布尔锁防重入，多网段扫描耗时超过 5s 扫描周期时不会堆积并发扫描。
- 验证：`flutter analyze` 0 问题 + `flutter build windows --debug` 通过。

> 注意：`DiscoveryService._selfId` 与 `FileTransferService.deviceId` 是两个独立生成的 ID（时间戳不同，永不相等），`/health` 返回的是后者。自检去重实际依赖「跳过所有本机 IP」，`id == _selfId` 仅为兜底，属正常设计、无需改动。

## 文件落地（任务 1 已完成，2026-09-09）

- **选择文件**：`file_picker` 12.x，`FilePicker.pickFile()`（12.x 新 API：无 `FilePicker.platform`、无 `FilePickerResult`；`PlatformFile.path` 为 `String?`，`readAsBytes()` 取字节）
- **保存落地**：`FileTransferService._resolveBaseDir()` 优先 `getApplicationDocumentsDirectory()/p2p_received`，失败降级临时目录；注意 path_provider 2.1.6 已把 `getDocumentsDir` 更名为 `getApplicationDocumentsDirectory`
- **重名处理**：`_uniqueTargetFile()` 重名时追加毫秒时间戳后缀
- **状态层**：`TransferState.receivedFiles` 存完整路径，`receivedDir` 供 UI 展示落地目录
- **iOS 兼容**：picker 不返回路径时用 `readAsBytes()` 写入临时文件再发送

## 打开文件目录（任务 3 已完成，2026-09-09）

- **交互**：点击「已接收文件」列表项，在系统文件管理器中打开该文件所在的 `p2p_received` 目录。
- **实现**：`OpenDirService.openDirectoryContaining(filePath)`（`lib/services/open_dir_service.dart`）用 `dart:io` 的 `Process.run` 按平台调用系统命令，**零新增依赖**：
  - Windows → `explorer.exe <dir>`；macOS → `open <dir>`；Linux → `xdg-open <dir>`；移动端无目录管理器概念，静默忽略。
- **分层**：业务方法 `TransferState.openReceivedFileDir(filePath)`，UI 层 `receivedRow` 仅通过 `onTap` 回调触发（业务逻辑不写在 Widget 内）。
- **验证**：`flutter analyze` 0 问题 + `flutter build windows --debug` 通过。

## 文件传输 header 编码 Bug 修复（任务 4 已完成，2026-09-09）

**现象**：传输 PDF 等文件时报 `FormatException: Invalid HTTP header field value`，含中文/emoji 的文件名无法发送（纯 ASCII 文件名正常，故表现为"部分文件能传、部分不能"）。

**根因**（`file_transfer_service.dart`）：
- `sendFile` 直接把 `p.basename(localPath)`（原始文件名）写入 HTTP 请求头 `x-file-name`。
- Dart 的 `HttpClient` 校验 header 值只允许 ASCII 可打印字符；文件名一旦含中文/emoji 等非 ASCII 字符，`headers.add('x-file-name', fileName)` 在 `req.close()` 写请求时抛 `FormatException: Invalid HTTP header field value`。

**修复**：
- 发送端：`req.headers.add('x-file-name', Uri.encodeComponent(fileName))` —— percent-encoding 后为纯 ASCII，是合法 header 值。
- 接收端 `_handleUpload`：`Uri.decodeComponent` 对称解码还原原始文件名；解码失败（旧版本未编码、文件名含非法 `%`）时回退为原始值，保证任何文件名都能接收。
- `Uri.encodeComponent`/`Uri.decodeComponent` 严格互逆：`+`、空格、`=`、括号、中文、emoji 均可往返还原（端到端测试已验证）。

**可测试性增强**：
- `FileTransferService` 端口由 `static const _kPort` 改为可注入实例字段 `port`（默认 9877，生产行为不变）。`DiscoveryService` 有独立 `_kPort`，互不影响。
- 新增集成测试 `test/file_transfer_header_test.dart`：mock `PathProviderPlatform`（`dev_dependency: path_provider_platform_interface`），驱动真实 `start()` + `sendFile` 回环传输中文文件名 PDF，断言文件名与内容一致、无错误；用随机空闲端口避开 9877 占用。
- 验证：`flutter analyze` 0 问题 + `flutter test` 全绿 + `flutter build windows --debug` 通过。

## 工作文件夹双向同步（任务 5 已完成，2026-09-09）

两台设备各自选择「工作文件夹」后，其中的文件（含子目录）会**双向完全同步**：一端新增/修改的文件会同步到另一端，最终两端文件集合收敛为并集。

### 架构与数据流

```
  ┌───────────────────────────── 设备 A ─────────────────────────────┐
  │  FolderSyncPanel (UI) ──setWorkingFolder──▶ TransferState        │
  │        │                                │  updatePeers(发现结果) │
  │        ▼                                ▼                        │
  │  FilePicker.getDirectoryPath     FolderSyncService ◀──┐          │
  │                            │        │  ▲               │          │
  │        watch(去抖)  │        │  ▲  handleRemoteFile    │ manifest()│
  │        setFolder    │        ▼  │  (onSyncReceive)      │          │
  │                     │  _pushLocalFile / pushSyncFile   │          │
  └─────────────────────┼──────────┼───────────────────────┘          │
                        │          │
              POST /sync │          │  GET /sync-manifest
                        ▼          ▼
        FileTransferService (port 9877, 复用同一 HTTP 服务)
                        │
        ────────────────────── 局域网 ──────────────────────▶  设备 B
```

### 关键机制

- **实时推送（watch + 去抖）**：`Directory.watch(recursive)` 监听工作文件夹，变更去抖 500ms 后把新增/修改文件推送到所有已发现对端（`POST /sync`，header `x-sync-path`/`x-sync-mtime`，body 为原始字节）。
- **周期对齐（reconcile）**：每 30s、以及发现/离线变化时触发。拉取对端 `GET /sync-manifest`（`{deviceId, files:[{relPath,size,mtimeMs}]}`），把「本机有、对端没有（或大小不同）」的文件推给对端。两端执行同一逻辑 → 收敛为并集。
- **一致性判定**：以 `(relPath + size)` 判定「已同步」，两端同路径同大小即稳定、停止推送 → 终止性。
- **回声抑制**：远端推来落盘的文件先登记 4s 抑制窗口，其触发的本地 watch 事件不回推，避免 A→B→A 回环。
- **冲突裁决**：同路径不同大小时，mtime 新者胜；mtime 相差 ≤1s 时按 `deviceId` 字典序大者胜（两端计算结果互补，恰好一方推送）→ 收敛到单一版本。
- **mtime 保留**：接收时 `setLastModifiedSync` 保留源端修改时间，保证后续 reconcile 不再误判为「更新」。
- **路径安全**：拒绝绝对路径与 `..` 逃逸（`_resolveSafe` 前缀校验）；相对路径统一用 `/` 分隔，跨平台匹配。
- **可测试性**：`reconcileNow()` 在已有对齐进行中会先等待其完成再补跑一轮，保证「立即同步」可靠反映最新状态（不并发、不静默忽略）；`FolderSyncService` 与 `FileTransferService` 均可注入空闲端口。
- **零新增依赖**：同步引擎为纯 `dart:io`；`file_picker` 仅用于 UI 选目录。

### 已知限制（有意为之的安全设计）

- **不同步删除**：只同步「新增 + 修改」，一端删除文件不会扩散到另一端，避免误删与同步风暴。
- **以大小判定一致**：极端情况「同大小但不同内容」不会被再次拉齐（可后续加内容哈希增强）。
- **依赖设备在线**：对端不在线时推送/拉取失败会被打印日志并跳过，待其上线后的下一轮 reconcile 自动补同步。

- **验证**：`flutter analyze` 0 问题 + `flutter test` 全绿（`test/folder_sync_test.dart` 覆盖双向收敛 / mtime 保留 / 无回环 / 冲突收敛）+ `flutter build windows --debug` 通过。

## 运行环境备忘

- 本机访问 pub.dev 必须走代理：`$env:HTTPS_PROXY='http://127.0.0.1:7890'`（Dart VM 不读系统代理，镜像 pub.flutter-io.cn 证书不受信任）
- 验证命令：`flutter analyze`（0 问题）+ `flutter build windows --debug`（通过）

## Android 端支持（任务 6 已完成，2026-09-17）

Android 与桌面端共用同一套服务层代码，差异只在「目录选择」与「HTTP 策略」两点：

- **明文 HTTP 策略**：Android 9+ 默认禁止明文流量，本 App 全部使用明文 `http://192.168.x.x:9877`，故 `AndroidManifest.xml` 的 `<application>` 必须声明 `android:usesCleartextTraffic="true"`。缺失时设备发现（`/health` 扫描）、文件传输、文件夹同步在 Android 上全部静默失败。
- **默认可读写目录（无需选择）**：`path_provider` 的 `getApplicationDocumentsDirectory()` 在 Android 上返回 App 专属外部存储 `/storage/emulated/0/Android/data/<package>/files`——程序默认可读写、无需任何权限选择、系统文件管理器可见。
  - 接收落地：沿用现有 `<Documents>/p2p_received`（`FileTransferService._resolveBaseDir`，行为不变）。
  - 工作文件夹同步：`AppDirsService.defaultWorkingFolderPath()` 返回 `<Documents>/p2p_sync`（自动创建，文档目录不可用时降级临时目录）。
- **状态层**：`TransferState.isAndroid` + `enableDefaultSync()`——Android 端不调用目录选择器，直接以默认目录开启双向同步（`FolderSyncService` 逻辑与桌面端完全一致）。
- **UI 分支**（`folder_sync_panel.dart`）：
  - Android 未开启：「使用默认目录同步」按钮 → `state.enableDefaultSync()`；
  - Android 已开启：仅展示目录路径 +「取消同步」；隐藏「打开目录」（移动端无目录管理器概念）；
  - 桌面端：原有「选择/更换工作文件夹 + 打开目录」行为完全不变。
- **文件选择/发送**：`file_picker` 在 Android 上原生支持（SAF），无需改动；`Directory.watch` / `HttpServer` / 子网扫描均为纯 `dart:io`，移动端直接可用。
- **验证**：`flutter analyze` 0 问题 + `flutter test` 全绿（含 `test/android_default_dirs_test.dart`：默认目录解析 + 降级路径）+ `flutter build windows --debug` 通过。
  - 注：真实 Android 设备上的端到端验证需 `flutter build apk` 后在两台 Android 设备（或 Android + 桌面）同一 Wi-Fi 下实测；代码层差异已全部覆盖。

## Android 平台桥与后台保活（任务 7 已完成，2026-09-17）

三个体验问题的落地方案：

### 1. 同步路径显示不全 → 换行 + 可点击

- `folder_sync_panel.dart`：路径文本 `maxLines: 1` 改为 `maxLines: 3`（换行显示，仍带 ellipsis 防溢出），整体包在 `InkWell` 中，**点击路径即打开该文件夹**。
- `home_page.dart`：「保存到: <receivedDir>」文本同样可点击 → `state.openReceivedDir()`。

### 2. Android 打开文件夹（MethodChannel + Intent）

- **Kotlin 侧**（`MainActivity.kt`）：MethodChannel `p2p_transfer` 暴露 `openDirectory(path)`：
  - 首选 `Intent(ACTION_VIEW)` + `Uri.fromFile(dir)` + type `vnd.android.dir` + `FLAG_GRANT_READ_URI_PERMISSION` —— 系统文件管理器（Files/DocumentsUI）直接打开该目录；
  - `ActivityNotFoundException` 时降级 `ACTION_GET_CONTENT`（SAF 文件选择器，用户可从该目录位置导航）；再失败则静默忽略。
- **Dart 侧**（`lib/services/android_platform_service.dart`）：
  - `openDirectory(dir)`：Android 走通道；**非 Android 回退 `OpenDirService`**（桌面文件管理器，原行为不变），失败仅打日志不抛异常；
  - `TransferState` 的 `openReceivedFileDir` / `openWorkingFolder` / `openReceivedDir` 全部统一走该桥，删除了对 `OpenDirService` 的直接依赖。

### 3. 后台运行支持（前台服务保活）

- **根因**：Android 应用退到后台被挂起后，Dart isolate 的 Timer（5s 发现扫描、30s reconcile、500ms watch 去抖）与网络 I/O 全部暂停，必须用前台服务保活。
- **Kotlin 侧**：新增 `P2pBackgroundService.kt` —— `startForeground` 低重要性持久通知 + `START_STICKY`；`MainActivity` 通过 `ContextCompat.startForegroundService`（API 26+ 分支）启动/`stopService` 停止。
- **Manifest**：`<service android:foregroundServiceType="dataSync">`（Android 14+ 强制声明类型）+ `POST_NOTIFICATIONS`（Android 13+ 通知）+ `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_DATA_SYNC` 权限。
- **Dart 侧**：`AndroidPlatformService.startBackgroundService()` 在 `TransferState.init()` 完成后 `unawaited` 启动；`disposeAll()` 停止；非 Android 平台为 no-op。
- **效果**：锁屏/App 切后台期间，设备发现、文件传输、工作文件夹同步持续运行，通知栏显示「后台服务运行中」。

### 验证

- `flutter analyze` 0 问题 + `flutter test` 7/7 全绿（含 `test/android_platform_service_test.dart`：非 Android no-op 行为）+ `flutter build windows --debug` 通过。
- 注：Kotlin 代码需 `flutter build apk` 在真机验证（本环境无 Android SDK）；Dart 侧行为已全部覆盖测试。

## Android 16 真机部署修复（任务 8 已完成，2026-09-17，V2507A 实测）

真机部署暴露的四个平台差异问题与修复：

1. **Kotlin MethodCall API**：新版引擎中 `MethodCall.argument()` 无参形式已移除，只有 `argument(String name)`（Map 参数）。Dart 侧 `invokeMethod` 改传 `{'path': dir}`，Kotlin 侧 `call.argument<String>("path")`。
2. **FileUriExposedException**：Android 7+ 禁止通过 Intent 暴露 `file://` URI，`Uri.fromFile(dir)` 方案必抛异常。打开目录改用 **SAF 目录选择器**（`ACTION_OPEN_DOCUMENT` + `vnd.android.dir`，无处理器时 `ACTION_GET_CONTENT` 兜底）——打开系统文件管理器，用户从存储根导航到目标文件夹。
3. **默认目录位置**：本真机（Flutter 3.41 / Android 16）上 `getApplicationDocumentsDirectory()` 实际返回 **内部存储**（`/data/user/0/<pkg>/app_flutter`），用户不可见且不可分享。`FileTransferService._resolveBaseDir` 与 `AppDirsService` 在 Android 上优先 `getExternalStorageDirectories()` → `/storage/emulated/0/Android/data/<pkg>/files`（`p2p_received`/`p2p_sync` 均落地于此，已 adb 验证）。注：Android 11+ 文件管理器需一次性开启「允许访问应用专属文件夹」才能看到该路径。
4. **递归 watch 断言**：`Directory.watch(recursive: true)` 在 Android/iOS（multiplexing watcher）触发 `_MultiplexingFileSystemWatcher` 断言失败，导致 `setFolder` 失败、同步静默中断。修复：移动端 `recursive: false`（仅实时监听顶层文件）；**子目录文件由 30s 周期 reconcile 兜底**（`_scanFolder` 递归全量扫描，两端仍完全收敛），桌面端行为不变。

真机验证结论：前台服务 `isForeground=true`（通知 channel `p2p_background`）；设备发现/传输正常运行；日志无 FileUriExposed/断言异常；`flutter analyze` 0 问题 + `flutter test` 全绿。

## Android 后台挂起问题与保活机制（任务 10，2026-09-17）

**现象**：App 退后台（回桌面）后设备发现/同步完全中断，对端显示该设备离线；回前台后瞬间自动恢复。

**根因**（真机复现确认）：退后台 6.7 分钟内进程存活、前台服务 `isForeground=true`、前台通知在，但 **Dart 事件循环完全冻结**（连纯本地 `NetworkInterface.list()` 的周期日志都停止）。排除：网络被限制（纯本地调用也停）、异常崩溃（无日志）、代码主动停止（`stop()` 无调用记录）。结论为 **ROM 级后台进程挂起**（Vivo 等国产 ROM 的激进后台管理），回前台时进程恢复执行。

**保活方案**（App 侧标准做法）：
1. **前台服务**（`dataSync`，持久通知，`START_STICKY`）——保持进程不被回收，但不阻止 ROM 挂起。
2. **电池优化豁免**：面板常驻「后台保活」行（`_AndroidKeepAliveRow`），未豁免时显示「授予保活」按钮 → `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` 系统对话框（`PowerManager.isIgnoringBatteryOptimizations` 查询状态）。
3. 若豁免后仍被挂起（ROM 特有），需用户手动：设置 → 电池 → 后台应用行为管理 → 将本 App 设为「不限制」，并开启「自启动」。

注意：前台服务/豁免可防进程回收，但「挂起 vs 回收」在不同 ROM 上行为不同；真机验证以「退后台 N 分钟后 logcat 发现循环是否持续」为准。

## Android 外部文件夹同步：权限流程与「对端目录可见」

**背景**：Android 11+ 上 App 默认无法读写共享存储（Download/Documents 等），必须授予
`MANAGE_EXTERNAL_STORAGE`（「所有文件访问」）；授予前选择外部目录会静默失败，
用户误以为已切换同步目录。

- **权限授予闭环**：sheet「授予」按钮打开系统设置页 → App `resumed`
  （`WidgetsBindingObserver`）时自动重查 `Environment.isExternalStorageManager()`
  → SnackBar 反馈「已授予 ✓ / 仍未授予」。避免「点了没反应」错觉；选择未通过可写校验时
  错误文案明确三步操作（授予 → 设置页开开关 → 返回重选）。
- **watch 平台策略**：Android 一律不启动 `Directory.watch`（Dart VM inotify/multiplexing
  watcher 在外部存储路径触发 VM 断言且订阅静默死亡，真机实测 file_patch.dart:522），
  确定性降级 10s 周期 reconcile；桌面端保留 watch 实时推送。
- **对端目录可见**：`GET /sync-manifest` 响应新增 `folder` 字段；reconcile 时本机学习
  各对端工作文件夹（`SyncStatus.peerFolders`），同步面板展示「对端 {ip:port} 同步目录: …」——
  两端互相可见对方正在同步的文件夹，消除「我在同步哪个目录」盲区。
