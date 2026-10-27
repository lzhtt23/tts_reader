package com.example.tts_reader

import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * 只回答一个问题：**这台机器的 ROM 是不是 ColorOS 系**（一加 / OPPO / realme）。
 *
 * ## 为什么需要它
 *
 * `TtsAudioHandler.play()` 里有一段「正在播时按播放键就当暂停」的 ROM 兼容逻辑
 * （见 `tts_audio_handler.dart` 的说明）。那是 **ColorOS 实测**得出的行为：
 * 它把媒体键统一发成 `KEYCODE_MEDIA_PLAY`，不发标准的 `MEDIA_PLAY_PAUSE`。
 *
 * 但这段逻辑原先**没有任何设备判断**，所有设备都执行 —— 在非 ColorOS 的设备上
 * （例如联想平板的 ZUI），按「播放」会被当成「暂停」，表现为**恢复播放没反应**。
 * 所以 Dart 侧需要一个可靠的厂商判据。
 *
 * ## 为什么不用 Dart 侧的 Platform
 *
 * `dart:io` 的 `Platform` 只区分 android/ios，拿不到厂商。
 * 引 `device_info_plus` 会动依赖（本项目红线），所以用这 20 行原生代码。
 *
 * ## 判据
 *
 * `Build.BRAND` / `Build.MANUFACTURER` 里出现 oppo / oneplus / realme 即算。
 * ColorOS 覆盖 OPPO、一加、realme 三家（同一套系统）。
 * 取不到时**返回 false**（宁可少走兼容分支，也不要误伤别的设备）。
 */
object DeviceChannel {

    private const val CHANNEL = "tts_reader/device"

    fun attach(messenger: BinaryMessenger) {
        val channel = MethodChannel(messenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isColorOs" -> result.success(isColorOs())
                else -> result.notImplemented()
            }
        }
    }

    /** 当前 ROM 是否属于 ColorOS 系 */
    private fun isColorOs(): Boolean {
        val marks = listOf(
            (Build.BRAND ?: "").lowercase(),
            (Build.MANUFACTURER ?: "").lowercase(),
        )
        return marks.any { it.contains("oppo") || it.contains("oneplus") || it.contains("realme") }
    }
}
