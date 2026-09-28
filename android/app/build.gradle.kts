plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.zy.player"
    compileSdk = flutter.compileSdkVersion
    // 本机 SDK 中 flutter.ndkVersion 指向的 26.3.11579264 目录为空（安装损坏），
    // 这里固定使用已完整安装的 27.0.12077973
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.zy.player"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // 官方模板默认是 21，这里提到 24：部分插件（ExoPlayer / sqflite 等）
        // 在更低的 API 上会报 manifest merger 冲突
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    // 关闭 release 的 lint：lintVitalAnalyzeRelease 会生成体量很大的中间产物，
    // 本机 D 盘空间紧张，且应用本身不做上架校验，保留 lint 只有开销。
    lint {
        checkReleaseBuilds = false
        abortOnError = false
    }
}

flutter {
    source = "../.."
}
