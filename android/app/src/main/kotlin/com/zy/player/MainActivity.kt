package com.zy.player

import android.app.PictureInPictureParams
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.media.AudioManager
import android.net.Uri
import android.provider.Settings
import android.util.Rational
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.videoplayer.PlaybackConfig
import java.io.File
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {

    private val channelName = "com.zy.player/system"
    private val pipChannelName = "com.zy.player/pip"

    /// 画中画通道引用：configureFlutterEngine 里创建，onPictureInPictureModeChanged
    /// 用它向 Dart 侧回传「进入/退出 PiP」事件。
    private var pipChannel: MethodChannel? = null

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
                            call.argument<String>("title").orEmpty(),
                            call.argument<String>("package").orEmpty()
                        )
                    )
                    "listExternalPlayers" -> result.success(listExternalPlayers())
                    "setKeepScreenOn" -> {
                        setKeepScreenOn(call.argument<Boolean>("value") ?: false)
                        result.success(null)
                    }
                    // 强制软件解码开关：写到 video_player 插件的静态配置，
                    // 下次构建 ExoPlayer 时按它选择「软件优先」解码器。
                    "setForceSoftwareDecode" -> {
                        PlaybackConfig.forceSoftwareDecode =
                            call.argument<Boolean>("value") ?: false
                        result.success(null)
                    }
                    // 版本更新：读已安装包的版本号做比较基准
                    "getAppVersionName" -> result.success(getAppVersionName())
                    "getAppVersionCode" -> result.success(getAppVersionCode())
                    "canInstallPackages" -> result.success(canInstallPackages())
                    "openInstallPermissionSettings" -> {
                        openInstallPermissionSettings()
                        result.success(null)
                    }
                    "installApk" -> result.success(
                        installApk(call.argument<String>("path").orEmpty())
                    )
                    "openUrl" -> result.success(
                        openUrl(call.argument<String>("url").orEmpty())
                    )
                    else -> result.notImplemented()
                }
            }

        // 系统级画中画（PiP）入口 + 状态回传。同一个通道既接收 Dart 侧「enterPip」
        // 请求，也向 Dart 侧回传「onPipModeChanged」事件（Activity 进入 / 退出 PiP）。
        // 仅 Android 8.0（API 26）及以上支持；进入失败（如设备不支持、调用时机不对）
        // 时返回 false，由 Dart 侧提示用户，不抛异常。
        pipChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, pipChannelName)
        pipChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "enterPip" -> {
                    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                        try {
                            // 按视频实际显示比例设置 PiP 窗口形状（Dart 侧传 aspect 双精度，
                            // 已含用户手动设置的比例 + 交换宽高），让小窗贴合画面、少黑边；
                            // 拿不到时退回 16:9。
                            val aspect = call.argument<Double>("aspect") ?: (16.0 / 9.0)
                            val num = (aspect * 1000.0).roundToInt().coerceAtLeast(1)
                            val params = PictureInPictureParams.Builder()
                                .setAspectRatio(Rational(num, 1000))
                                .build()
                            enterPictureInPictureMode(params)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    } else {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    // 调起第三方播放器打开视频地址，返回状态字符串给 Dart 侧提示用：
    // ok / no_url / no_app / no_player / error。
    //
    // 不用 url_launcher：它走「浏览器式」ACTION_VIEW，m3u8 直链多半只会弹浏览器。
    // targetPackage 非空时直接调起用户指定的应用，不再弹系统选择器。
    //
    // m3u8 直链没有能识别的文件扩展名，各家播放器的 intent-filter 写法不一
    // （有的按 video 通配收，有的按 application/x-mpegURL 收，MX Player 这类还
    // 要求 mime 非空），所以按最可能被接住的顺序逐个试，最后再试不带 mime 的
    // 纯 data 形式（浏览器之类只认 scheme）。

    private fun videoViewIntents(url: String, title: String): List<Intent> {
        val uri = Uri.parse(url)
        val mimes = listOf(
            "video/*",
            "application/x-mpegURL",
            "application/vnd.apple.mpegurl",
            "*/*"
        )
        val intents = mimes.map { mime ->
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime)
                if (title.isNotBlank()) putExtra("title", title)
            }
        }.toMutableList()
        intents.add(Intent(Intent.ACTION_VIEW).apply {
            setData(uri)
            if (title.isNotBlank()) putExtra("title", title)
        })
        return intents
    }

    private fun openWithExternalPlayer(
        url: String,
        title: String,
        targetPackage: String
    ): String {
        if (url.isBlank()) return "no_url"

        val intents = videoViewIntents(url, title)

        if (targetPackage.isNotBlank()) {
            if (targetPackage == packageName) return "no_player"
            for (intent in intents) {
                @Suppress("DEPRECATION")
                val matched = packageManager.queryIntentActivities(intent, 0)
                    .any { it.activityInfo.packageName == targetPackage }
                if (!matched) continue
                return try {
                    startActivity(Intent(intent).apply { setPackage(targetPackage) })
                    "ok"
                } catch (e: Exception) {
                    "no_player"
                }
            }
            // 指定了但接不住地址：明确告诉用户去设置里重选，不静默退回选择器
            return "no_player"
        }

        for (intent in intents) {
            @Suppress("DEPRECATION")
            val matched = packageManager.queryIntentActivities(intent, 0).isNotEmpty()
            if (!matched) continue
            return try {
                startActivity(Intent.createChooser(intent, "选择播放器"))
                "ok"
            } catch (e: Exception) {
                "error"
            }
        }
        return "no_app"
    }

    // 设置页列出能接住视频地址的应用。Android 11+ 的包可见性靠 manifest 的
    // queries 声明放行；这里按同一组 mime / scheme 查询并去重，按应用名排序。
    private fun listExternalPlayers(): List<Map<String, String>> {
        val found = LinkedHashMap<String, String>()
        val sample = "http://example.com/video.m3u8"
        for (intent in videoViewIntents(sample, "")) {
            @Suppress("DEPRECATION")
            val matches = packageManager.queryIntentActivities(intent, 0)
            for (info in matches) {
                val pkg = info.activityInfo.packageName
                if (pkg.isBlank() || pkg == packageName || found.containsKey(pkg)) continue
                val label = try {
                    info.loadLabel(packageManager).toString()
                } catch (e: Exception) {
                    ""
                }
                found[pkg] = label.ifBlank { pkg }
            }
        }
        return found.entries
            .sortedBy { it.value.lowercase() }
            .map { mapOf("package" to it.key, "label" to it.value) }
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

    /** 已安装包的版本名（如 1.17.0），读不到返回空串 */
    private fun getAppVersionName(): String = try {
        packageManager.getPackageInfo(packageName, 0).versionName ?: ""
    } catch (e: Exception) {
        ""
    }

    /**
     * 已安装包的 versionCode。
     * API 28 起改用 longVersionCode（versionCode 是它的低 32 位），
     * 避免高版本号被截断后比较出错。
     */
    private fun getAppVersionCode(): Int = try {
        val info = packageManager.getPackageInfo(packageName, 0)
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
            info.longVersionCode.toInt()
        } else {
            @Suppress("DEPRECATION")
            info.versionCode
        }
    } catch (e: Exception) {
        0
    }

    /** 是否允许「安装未知来源应用」；Android 8.0 以下没有这个限制，恒为 true */
    private fun canInstallPackages(): Boolean =
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else {
            true
        }

    /** 跳到本应用的「安装未知来源应用」授权页 */
    private fun openInstallPermissionSettings() {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.O) return
        try {
            startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                    .setData(Uri.parse("package:$packageName"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        } catch (e: Exception) {
            // 部分定制 ROM 没有这个页面，忽略
        }
    }

    /**
     * 用系统安装器打开已下载的 APK，返回状态字符串：
     * `ok` / `no_file` / `no_permission` / `error`。
     *
     * 必须走 FileProvider 生成 content 协议的 URI：Android 7.0 起直接传
     * file 协议的路径会抛 FileUriExposedException，安装界面根本不会出现。
     * authority 与 AndroidManifest 里声明的保持一致：包名 + .fileprovider。
     */
    private fun installApk(path: String): String {
        if (path.isBlank()) return "no_file"
        val file = File(path)
        if (!file.exists() || file.length() == 0L) return "no_file"
        if (!canInstallPackages()) return "no_permission"
        return try {
            val uri = FileProvider.getUriForFile(
                this,
                "${packageName}.fileprovider",
                file
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            "ok"
        } catch (e: Exception) {
            "error"
        }
    }

    /** 用系统浏览器打开链接；没有可用浏览器时返回 false */
    private fun openUrl(url: String): Boolean {
        if (url.isBlank()) return false
        return try {
            startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse(url))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        } catch (e: Exception) {
            false
        }
    }

    /**
     * 系统画中画状态变化：进入 / 退出时回传 Dart 侧，驱动 Flutter 隐藏 / 恢复全部 UI，
     * 让 PiP 窗口里只剩纯播放画面（详见 PlayPage._inPip）。
     */
    override fun onPictureInPictureModeChanged(        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pipChannel?.invokeMethod("onPipModeChanged", isInPictureInPictureMode)
    }
}
