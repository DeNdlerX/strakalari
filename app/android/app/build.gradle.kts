plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

import java.io.FileInputStream
import java.util.Properties

/** Set while configuring `android {}`: whether the real release key exists. */
var releaseSigningFound = false

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
    // to that file). The env vars win over the properties file, like
    // tools/make_mobile.py, and also work without it (CI). Never generate or
    // commit a key here.
    val signingPropsFile = File(
        System.getProperty("user.home"),
        ".strakalari-signing/android-release.properties",
    )
    val props = Properties()
    if (signingPropsFile.isFile) {
        FileInputStream(signingPropsFile).use { stream -> props.load(stream) }
    }
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
    val releaseSigning = signingConfigs.findByName("release")
    releaseSigningFound = releaseSigning != null

    buildTypes {
        release {
            // The debug key is only for the phonetest flavor (its release
            // build can never update a real install, which is fine there);
            // a prod release without the real key stops below.
            signingConfig = releaseSigning ?: signingConfigs.getByName("debug")
        }
    }
}

// A prod release (APK or AAB) signed with the debug key could never update
// the installed app, and the build would give no hint: refuse it.
tasks.matching { it.name == "preProdReleaseBuild" }.configureEach {
    doFirst {
        if (!releaseSigningFound) {
            throw GradleException(
                "No release signing key: put it in ~/.strakalari-signing/" +
                    "android-release.properties (storeFile, storePassword, keyAlias, " +
                    "keyPassword) or set STRAKALARI_SIGNING_KEY_STORE / _PASSWORD / " +
                    "_ALIAS. Only the phonetest flavor may use the debug key."
            )
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