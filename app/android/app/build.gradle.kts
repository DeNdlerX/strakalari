plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

import java.io.FileInputStream
import java.util.Properties

android {
    namespace = "io.github.dendlerx.strakalari"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.github.dendlerx.strakalari"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Permanent identity: changing it makes a new app (no updates in place).
    // The release ("prod") flavor keeps the store identity
    // io.github.dendlerx.strakalari; the "phonetest" flavor installs beside
    // it as io.github.dendlerx.strakalari.test for the on-phone checks
    // (PLAN §4.8: never install over the owner's real app). ("test" itself
    // is banned as a flavor name by the Android Gradle plugin.)
    flavorDimensions += "dist"
    productFlavors {
        create("prod") {
            dimension = "dist"
        }
        create("phonetest") {
            dimension = "dist"
            applicationIdSuffix = ".test"
            versionNameSuffix = "-test"
        }
    }

    // Release signing reads the release key properties (the same folder the
    // Python build used: ~/.strakalari-signing/android-release.properties
    // with storeFile/storePassword/keyAlias/keyPassword; storeFile relative
    // to that file). Without it (or on CI without the env vars below) the
    // release build falls back to the debug key, which can never be updated
    // by a release build. Never generate or commit a key here; the env vars
    // win over the properties file, like tools/make_mobile.py.
    val signingPropsFile = File(
        System.getProperty("user.home"),
        ".strakalari-signing/android-release.properties",
    )
    if (signingPropsFile.isFile) {
        val props = Properties()
        FileInputStream(signingPropsFile).use { stream -> props.load(stream) }
        fun prop(name: String, env: String): String? =
            System.getenv(env)?.takeIf { it.isNotEmpty() } ?: props.getProperty(name)
        val releaseStoreFile = prop("storeFile", "STRAKALARI_SIGNING_KEY_STORE")
        val releaseStorePassword = prop("storePassword", "STRAKALARI_SIGNING_KEY_PASSWORD")
        val releaseKeyAlias = prop("keyAlias", "STRAKALARI_SIGNING_KEY_ALIAS")
        val releaseKeyPassword = prop("keyPassword", "STRAKALARI_SIGNING_KEY_KEY_PASSWORD")
            ?: releaseStorePassword // PKCS12: one password, like make_mobile.py
        if (releaseStoreFile != null && releaseStorePassword != null
            && releaseKeyAlias != null && releaseKeyPassword != null
        ) {
            val resolved = File(signingPropsFile.parentFile, releaseStoreFile)
                .let { if (it.isFile) it else File(releaseStoreFile) }
            if (resolved.isFile) {
                signingConfigs {
                    create("release") {
                        this.storeFile = resolved
                        this.storePassword = releaseStorePassword
                        this.keyAlias = releaseKeyAlias
                        this.keyPassword = releaseKeyPassword
                    }
                }
            }
        }
    }

    buildTypes {
        release {
            val releaseSigning = try {
                signingConfigs.getByName("release")
            } catch (_: Exception) {
                null
            }
            // Debug key fallback: fine for testing, never for release.
            signingConfig = releaseSigning ?: signingConfigs.getByName("debug")
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