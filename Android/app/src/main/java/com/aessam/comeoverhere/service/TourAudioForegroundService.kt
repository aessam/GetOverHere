package com.aessam.comeoverhere.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.content.ContextCompat
import com.aessam.comeoverhere.MainActivity
import com.aessam.comeoverhere.R

/** Keeps active guide capture or guest playback in an OS-declared foreground audio session. */
class TourAudioForegroundService : Service() {
    override fun onCreate() {
        super.onCreate()
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Active tour audio",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Shows while broadcasting or listening to a local tour"
                setSound(null, null)
            },
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val mode = intent?.getStringExtra(EXTRA_MODE)
        if (mode != MODE_GUIDE && mode != MODE_GUEST) {
            stopSelf(startId)
            return START_NOT_STICKY
        }

        val isGuide = mode == MODE_GUIDE
        val notification = notification(isGuide)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val type = if (isGuide) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            } else {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            }
            startForeground(NOTIFICATION_ID, notification, type)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun notification(isGuide: Boolean): Notification {
        val launchIntent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val title = if (isGuide) "Broadcasting tour audio" else "Listening to tour audio"
        val body = if (isGuide) {
            "Your microphone is live on the local tour."
        } else {
            "Tour audio continues while the screen is locked."
        }
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "active-tour-audio"
        private const val NOTIFICATION_ID = 1001
        private const val EXTRA_MODE = "mode"
        private const val MODE_GUIDE = "guide"
        private const val MODE_GUEST = "guest"

        fun startGuide(context: Context) = start(context, MODE_GUIDE)

        fun startGuest(context: Context) = start(context, MODE_GUEST)

        fun stop(context: Context) {
            context.stopService(Intent(context, TourAudioForegroundService::class.java))
        }

        private fun start(context: Context, mode: String) {
            val intent = Intent(context, TourAudioForegroundService::class.java)
                .putExtra(EXTRA_MODE, mode)
            ContextCompat.startForegroundService(context, intent)
        }
    }
}
