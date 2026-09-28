package com.zy.player

import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.net.Uri
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {

    private val channelName = "com.zy.player/system"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getBrightness" -> result.success(getScreenBrightness())
                    "setBrightness" -> {
                        setScreenBrightness((call.argument<Double>("value") ?: 0.5).toFloat())
                        result.success(null)
                    }
                    "getVolume" -> result.success(getMusicVolume())
                    "setVolume" -> {
                        setMusicVolume((call.argument<Double>("value") ?: 0.5).toFloat())
                        result.success(null)
                    }
                    "getSdkInt" -> result.success(android.os.Build.VERSION.SDK_INT)
                    "openWithExternalPlayer" -> result.success(
                        openWithExternalPlayer(
                            call.argument<String>("url").orEmpty(),
                            call.argument<String>("title").orEmpty()
                        )
                    )
                    "setKeepScreenOn" -> {
                        setKeepScreenOn(call.argument<Boolean>("value") ?: false)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 调起第三方播放器打开视频地址，返回状态字符串给 Dart 侧提示用：
     * `ok` / `no_url` / `no_app` / `error`。
     *
     * 为什么不用现成的 url_launcher：它走的是「浏览器式」ACTION_VIEW，
     * 遇到 m3u8 直链多半只会弹浏览器，用户要的是「选播放器」。
     *
     * ⚠️ 注释里千万别写「斜杠+星号」或「星号+斜杠」的字面量。
     *    Kotlin 的块注释是**可嵌套**的：多写一个「斜杠+星号」就多开一层，
     *    后面的「星号+斜杠」只关掉内层，外层一直不闭合，
     *    整个文件后半段被当成注释吞掉，报一堆假的 unresolved reference
     *    外加结尾一句 Unclosed comment。这次就是这么翻车的。
     *
     * m3u8 直链没有能识别的文件扩展名，各家播放器的 intent-filter 写法不一
     * （有的按 video 通配（video 斜杠星号）收，有的按 application/x-mpegURL 收，
     * MX Player 这类还要求 mime 非空），所以这里按「最可能被接住」的顺序挑第一个
     * 能解析到的组合，再交给系统选择器，避免出现「一无匹配直接闪退/无反应」。
     */
    private fun openWithExternalPlayer(url: String, title: String): String {
        if (url.isBlank()) return "no_url"

        val uri = Uri.parse(url)
        val mimeCandidates = listOf(
            "video/*",
            "application/x-mpegURL",
            "application/vnd.apple.mpegurl",
            "*/*"
        )

        for (mime in mimeCandidates) {
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime)
                if (title.isNotEmpty()) putExtra("title", title)
            }
            @Suppress("DEPRECATION")
            val matches = packageManager.queryIntentActivities(intent, 0)
            if (matches.isEmpty()) continue
            return try {
                startActivity(Intent.createChooser(intent, "选择播放器"))
                "ok"
            } catch (e: Exception) {
                "error"
            }
        }

        // 候选都没解析到：再试一次不带 mime 的纯 data 形式（浏览器之类只认 scheme）
        val plain = Intent(Intent.ACTION_VIEW).apply {
            setData(uri)
            if (title.isNotEmpty()) putExtra("title", title)
        }
        @Suppress("DEPRECATION")
        val plainMatches = packageManager.queryIntentActivities(plain, 0)
        if (plainMatches.isEmpty()) {
            // 一个都接不住：设备上确实没有能处理这个地址的应用
            return "no_app"
        }
        return try {
            startActivity(Intent.createChooser(plain, "选择播放器"))
            "ok"
        } catch (e: Exception) {
            "error"
        }
    }

    /**
     * 窗口亮度，0.0 ~ 1.0。从未覆盖过时读一次系统亮度作为起点
     * （BRIGHTNESS_OVERRIDE_NONE 为 -1f）。
     */
    private fun getScreenBrightness(): Double {
        val overridden = window.attributes.screenBrightness
        if (overridden >= 0f) {
            return overridden.toDouble().coerceIn(0.01, 1.0)
        }
        return try {
            val system = Settings.System.getInt(
                contentResolver,
                Settings.System.SCREEN_BRIGHTNESS,
                128
            )
            (system / 255.0).coerceIn(0.01, 1.0)
        } catch (e: Exception) {
            0.5
        }
    }

    /** 只改当前窗口的亮度，不写系统设置，退出播放页即恢复 */
    private fun setScreenBrightness(value: Float) {
        val attrs = window.attributes
        attrs.screenBrightness = value.coerceIn(0.01f, 1f)
        window.attributes = attrs
    }

    private fun getMusicVolume(): Double {
        val manager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return 0.5
        val max = manager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        if (max <= 0) return 0.5
        val current = manager.getStreamVolume(AudioManager.STREAM_MUSIC)
        return (current.toDouble() / max.toDouble()).coerceIn(0.0, 1.0)
    }

    private fun setMusicVolume(value: Float) {
        val manager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        val max = manager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        if (max <= 0) return
        val index = (value.coerceIn(0f, 1f) * max).roundToInt().coerceIn(0, max)
        manager.setStreamVolume(AudioManager.STREAM_MUSIC, index, 0)
    }

    /**
     * 播放时保持屏幕常亮：加/清当前窗口的 FLAG_KEEP_SCREEN_ON。
     * 这是播放器通行做法，只影响本窗口，退出播放页后由 Dart 侧主动关闭。
     */
    private fun setKeepScreenOn(on: Boolean) {
        if (on) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }
}
