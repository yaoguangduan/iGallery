plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dtdyq.igallery"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dtdyq.igallery"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // Point the debug config at a keystore committed to the repo instead of
        // the one the Android SDK auto-generates at ~/.android/debug.keystore.
        // That file is created per machine, so building on a new laptop yields a
        // brand-new key and every already-installed build rejects the update with
        // a signature mismatch — the only recovery is uninstall + reinstall on
        // every device, and the original key is gone with the old machine.
        //
        // The passwords below are Android's fixed, public debug credentials; the
        // keystore file is the only machine-specific part, which is precisely why
        // it is version-controlled (see the negated rule in android/.gitignore).
        getByName("debug") {
            storeFile = file("debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }

    buildTypes {
        release {
            // Deliberately the debug key, shared with the debug build type so both
            // produce update-compatible APKs. The app is sideloaded, never
            // published, so a separate release key would buy nothing and would
            // cost a forced reinstall on the day it was introduced.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
