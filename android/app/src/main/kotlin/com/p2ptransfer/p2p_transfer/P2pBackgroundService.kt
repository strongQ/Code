package com.p2ptransfer.p2p_transfer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * 前台服务：应用退到后台后保活设备发现 / 文件传输 / 文件夹同步。
 *
 * - startForeground 显示低重要性持久通知（Android 14+ 需 manifest 声明
 *   foregroundServiceType="dataSync" + FOREGROUND_SERVICE_DATA_SYNC 权限）；
 * - START_STICKY：服务被系统杀死后尝试重建。
 */
class P2pBackgroundService : Service() {

    companion object {
        private const val NOTIFICATION_CHANNEL_ID = "p2p_background"
        private const val NOTIFICATION_ID = 1
    }

    override fun onCreate() {
        super.onCreate()
        startForeground(NOTIFICATION_ID, buildNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, id: Int): Int = START_STICKY

    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildNotification(): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(
                    NOTIFICATION_CHANNEL_ID,
                    "后台传输服务",
                    NotificationManager.IMPORTANCE_LOW
                )
            )
        }
        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("局域网文件传输")
            .setContentText("后台服务运行中（设备发现 / 文件传输 / 文件夹同步）")
            .setOngoing(true)
            .build()
    }
}