package com.example.tts_reader

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import android.view.KeyEvent

/**
 * 耳机 / 蓝牙 / 车机的媒体键接收器（`ACTION_MEDIA_BUTTON` 广播）
 *
 * ## 设计原则：无条件转发，不做任何判断
 *
 * 旧实现要求「先由 Dart 通知原生 `active=true`，才转发按键」。这个设计有两个
 * 致命缺陷，都表现为**静默失败**（按键完全没反应，日志里一行都没有）：
 *
 * 1. **单次异步通知会丢**：通道未就绪 / Dart 侧以为"状态没变"就不再发，
 *    原生就会永远停在 `active=false`，此后所有按键被直接丢弃；
 * 2. **状态有滞回**：Dart 用 60 秒滞回判断"是否在朗读"，与用户实际
 *    按下按键的时刻并不同步。
 *
 * 新实现里，**原生不做任何判断**：只要收到媒体键就转发给 Dart，
 * 由 Dart 根据当前真实的播放状态决定做什么（不需要就忽略）。
 *
 * 代价只是"空闲时多一次无用的通道调用"，换来的是**永远不会因为状态不同步
 * 而静默丢键**。这类问题排查成本极高，不值得为省一次调用去赌。
 *
 * ## 为什么必须显式打 Log
 *
 * 排查时首先要回答的问题是「按键到底有没有到接收器」。用 `Log.i` 打一行，
 * `adb logcat` 立刻能分辨：
 * * 有这一行 → 按键到了，问题在 Dart 侧；
 * * 没这一行 → 系统压根没广播，问题在系统/ROM 层。
 *
 * 不要用 CrashLog（只写应用私有文件，logcat 里看不到）。
 */
class TtsMediaButtonReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context?, intent: Intent?) {
        if (intent == null) return
        if (intent.action != Intent.ACTION_MEDIA_BUTTON) return

        val event: KeyEvent? = intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT)
        if (event == null) {
            Log.i(TAG, "收到 MEDIA_BUTTON 但没有 KeyEvent")
            return
        }

        // 只处理按下，抬起忽略（否则一次按键会触发两次动作）
        val down = event.action == KeyEvent.ACTION_DOWN
        Log.i(TAG, "广播按键 key=${event.keyCode} action=${event.action} down=$down")

        if (!down) return

        // 无条件转发：判断权交给 Dart（它才知道真实的播放状态）
        MediaKeyChannel.onBroadcastKey(event.keyCode)
    }

    private companion object {
        const val TAG = "TtsMediaKey"
    }
}
