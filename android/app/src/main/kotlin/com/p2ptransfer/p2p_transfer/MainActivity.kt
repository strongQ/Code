package com.p2ptransfer.p2p_transfer

import android.content.ActivityNotFoundException
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "p2p_transfer"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openDirectory" -> {
                        openDirectory(call.argument<String>("path"))
                        result.success(null)
                    }
                    "startBackgroundService" -> {
                        startBackgroundService()
                        result.success(null)
                    }
                    "stopBackgroundService" -> {
                        stopBackgroundService()
                        result.success(null)
                    }
                    "hasAllFilesAccess" -> {
                        result.success(hasAllFilesAccess())
                    }
                    "requestAllFilesAccess" -> {
                        requestAllFilesAccess()
                        result.success(null)
                    }
                    "hasBatteryOptExempted" -> {
                        result.success(hasBatteryOptExempted())
                    }
                    "requestBatteryOptExemption" -> {
                        requestBatteryOptExemption()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 打开目录：Android 7+ 禁止通过 Intent 暴露 file:// URI（FileUriExposedException），
     * 目录也无法用 FileProvider 分享，故用 SAF 目录选择器打开系统文件管理器，
     * 用户可从存储根目录导航到目标文件夹（Android 11+ 需在文件管理器开启
     * 「允许访问应用专属文件夹」才能看到 Android/data 路径）。
     */
    private fun openDirectory(path: String?) {
        android.util.Log.d("p2p", "open directory: $path")
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            setDataAndType(null, "vnd.android.dir")
            addCategory(Intent.CATEGORY_DEFAULT)
        }
        try {
            startActivity(intent)
        } catch (e: ActivityNotFoundException) {
            // 无 ACTION_OPEN_DOCUMENT 目录处理器时，降级为 GET_CONTENT 目录选择器
            val fallback = Intent(Intent.ACTION_GET_CONTENT).apply {
                setDataAndType(null, "vnd.android.dir")
            }
            try {
                startActivity(fallback)
            } catch (ignored: Exception) {
                // 无任何可用文件管理器，忽略
            }
        }
    }

    /** 启动前台服务：应用退到后台后继续保活设备发现 / 文件传输 / 文件夹同步。 */
    private fun startBackgroundService() {
        val intent = Intent(this, P2pBackgroundService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ContextCompat.startForegroundService(this, intent)
        } else {
            startService(intent)
        }
    }

    private fun stopBackgroundService() {
        stopService(Intent(this, P2pBackgroundService::class.java))
    }

    /**
     * 是否已授予「所有文件访问」权限（MANAGE_EXTERNAL_STORAGE）。
     * Android 10 及以下无 scoped storage 限制，直接返回 true。
     */
    private fun hasAllFilesAccess(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return true
        return android.os.Environment.isExternalStorageManager()
    }

    /** 打开系统「所有文件访问」设置页，由用户手动开启。 */
    private fun requestAllFilesAccess() {
        val intent =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                Intent(android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                    .setData(android.net.Uri.parse("package:$packageName"))
            } else {
                Intent(android.provider.Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
            }
        try {
            startActivity(intent)
        } catch (e: ActivityNotFoundException) {
            try {
                startActivity(Intent(android.provider.Settings.ACTION_SETTINGS))
            } catch (ignored: Exception) {
                // 无可用设置页，忽略
            }
        }
    }

    /**
     * 是否已豁免电池优化（「不优化此应用」）。
     * 常驻后台同步类应用需要该豁免，否则部分 ROM（尤其国产机型）
     * 会在退后台后杀死进程，前台服务通知也会随之消失。
     */
    private fun hasBatteryOptExempted(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return getSystemService(PowerManager::class.java)
            .isIgnoringBatteryOptimizations(packageName)
    }

    /** 弹出系统对话框请求豁免电池优化（由用户确认）。 */
    private fun requestBatteryOptExemption() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        try {
            startActivity(
                Intent(android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                    .setData(android.net.Uri.parse("package:$packageName"))
            )
        } catch (e: ActivityNotFoundException) {
            // 部分 ROM 没有该设置页，忽略
        }
    }
}
