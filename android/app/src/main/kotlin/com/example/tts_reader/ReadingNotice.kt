package com.example.tts_reader

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat

/**
 * 朗读控制通知（**自定义样式，不是 MediaStyle**）
 *
 * ## 为什么不走 MediaStyle / 媒体会话
 *
 * 真机教训（平板 TB335FC / ZUX OS，2026-10-19~20）：这台设备上蓝牙耳机键的
 * AVRCP 指令只在「系统认为有活跃媒体会话」时才派发，被打断就 `a2dp suspend`，
 * 按键在蓝牙栈就被丢掉；试过重申请焦点、保持 PLAYING、音频锚点都不稳定。
 *
 * 参考同类应用 T2S（hesoft.T2S）的做法：**根本不做耳机键**，
 * 用一条 `NotificationCompat` 自定义通知 + 按钮当主控制入口。
 * 通知按钮是 PendingIntent 直投广播，**完全不依赖媒体会话与耳机** ——
 * 所以不会有「被打断后失效」「刚进页面不能启停」这些问题。
 *
 * ## 与朗读的关系
 *
 * 只负责「显示 + 把点击转成动作名」，动作由 Dart 侧执行（`MediaKeyChannel`
 * 已有 play_pause / next / previous / stop 的处理分支，这里不新增语义）。
 */
object ReadingNotice {
    private const val CHANNEL_ID = "tts_reader_reading_control_v2"
    private const val NOTICE_ID = 4711

    /** 广播里携带动作名的 key */
    const val EXTRA_ACTION = "tts_reader.notice.action"

    private fun manager(context: Context): NotificationManager? =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = manager(context) ?: return
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "朗读控制",
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = "朗读时提供上一句 / 播放暂停 / 下一句"
            setShowBadge(false)
        }
        nm.createNotificationChannel(channel)
    }

    private fun actionIntent(context: Context, action: String): PendingIntent {
        val intent = Intent(context, ReadingNoticeReceiver::class.java).apply {
            this.action = ReadingNoticeReceiver.ACTION_NOTICE
            putExtra(EXTRA_ACTION, action)
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        // requestCode 用动作名 hash：四个按钮各自的 PendingIntent 必须不同，
        // 否则系统会复用同一个（点哪个都变成第一个动作）
        return PendingIntent.getBroadcast(context, action.hashCode(), intent, flags)
    }

    /**
     * 显示 / 更新通知
     *
     * @param title 书名
     * @param detail 例如「第 25/432 页 · 第 15 句」
     * @param playing true = 显示「暂停」按钮，false = 显示「播放」
     */
    fun show(
        context: Context,
        title: String,
        detail: String,
        playing: Boolean,
    ) {
        ensureChannel(context)
        val nm = manager(context) ?: return

        val openIntent = context.packageManager
            .getLaunchIntentForPackage(context.packageName)
            ?.let {
                PendingIntent.getActivity(
                    context,
                    1,
                    it,
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                    } else {
                        PendingIntent.FLAG_UPDATE_CURRENT
                    },
                )
            }

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(title.take(60))
            .setContentText(detail)
            .setOnlyAlertOnce(true)
            .setOngoing(playing)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .addAction(
                android.R.drawable.ic_media_previous,
                "上一句",
                actionIntent(context, "previous"),
            )
            .addAction(
                if (playing) android.R.drawable.ic_media_pause
                else android.R.drawable.ic_media_play,
                if (playing) "暂停" else "播放",
                actionIntent(context, "play_pause"),
            )
            .addAction(
                android.R.drawable.ic_media_next,
                "下一句",
                actionIntent(context, "next"),
            )
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "停止",
                actionIntent(context, "stop"),
            )
        if (openIntent != null) builder.setContentIntent(openIntent)

        val notice: Notification = builder.build()
        // NOTICE_ID 固定：每次更新同一条，不会在通知栏堆一串
        nm.notify(NOTICE_ID, notice)
        android.util.Log.i("ReadingNotice", "notify id=$NOTICE_ID playing=$playing detail=$detail")
    }

    /** 收起通知（停止朗读 / 读完 / 退出阅读页时调用） */
    fun hide(context: Context) {
        android.util.Log.i("ReadingNotice", "hide id=$NOTICE_ID")
        manager(context)?.cancel(NOTICE_ID)
    }
}
