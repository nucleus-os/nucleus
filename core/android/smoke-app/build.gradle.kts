import java.util.zip.ZipEntry
import java.util.zip.ZipFile

plugins {
    alias(libs.plugins.androidApplication)
}

val androidSdkRoot = providers.gradleProperty("nucleus.androidSdk")
    .orElse(providers.environmentVariable("ANDROID_HOME"))
    .orElse(providers.environmentVariable("ANDROID_SDK_ROOT"))
    .orElse("${System.getProperty("user.home")}/Android/Sdk")
val buildTools = providers.gradleProperty("nucleus.androidBuildTools")
    .orElse(androidSdkRoot.map { "$it/build-tools/${libs.versions.buildTools.get()}" })
val adbPath = providers.gradleProperty("nucleus.adb")
    .orElse(androidSdkRoot.map { "$it/platform-tools/adb" })
val minSdkVersion = providers.gradleProperty("nucleus.minSdk").orElse(libs.versions.minSdk)
val targetSdkVersion = providers.gradleProperty("nucleus.targetSdk").orElse(libs.versions.targetSdkApi)

extensions.configure<com.android.build.api.dsl.ApplicationExtension>("android") {
    namespace = "dev.nucleus.android.smoke"
    buildToolsVersion = libs.versions.buildTools.get()
    ndkVersion = libs.versions.ndk.get()

    compileSdk {
        version = release(libs.versions.compileSdkApi.get().toInt()) {
            minorApiLevel = libs.versions.compileSdkMinor.get().toInt()
        }
    }

    defaultConfig {
        applicationId = "dev.nucleus.android.smoke"
        minSdk = minSdkVersion.get().toInt()
        targetSdk {
            version = release(targetSdkVersion.get().toInt())
        }
        versionCode = 1
        versionName = "0.1"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

dependencies {
    implementation(project(":nucleus"))
}

val debugApk = layout.buildDirectory.file("outputs/apk/debug/smoke-app-debug.apk")

tasks.register("assembleDebugSigned") {
    group = "build"
    description = "Assemble a signed debug smoke APK."
    dependsOn("assembleDebug")
}

tasks.register("verifyDebugPackage") {
    group = "verification"
    description = "Verify the smoke APK contains Nucleus classes and native libraries."
    dependsOn("assembleDebug")
    inputs.file(debugApk)
    doLast {
        ZipFile(debugApk.get().asFile).use { apk ->
            val entries = apk.entries().asSequence().map { it.name }.toSet()
            require("classes.dex" in entries) {
                "classes.dex missing from smoke APK"
            }
            require("lib/arm64-v8a/libnucleus-android.so" in entries) {
                "libnucleus-android.so missing from smoke APK"
            }
            require("lib/arm64-v8a/libc++_shared.so" in entries) {
                "libc++_shared.so missing from smoke APK"
            }
            require("assets/nucleus-smoke.txt" in entries) {
                "nucleus-smoke.txt missing from smoke APK assets"
            }
            require("assets/nucleus-android.properties" in entries) {
                "nucleus-android.properties missing from smoke APK assets"
            }
        }
    }
}

val verifyDebugSignature = tasks.register<Exec>("verifyDebugSignature") {
    group = "verification"
    description = "Verify the signed debug smoke APK signature."
    dependsOn("assembleDebug")
    inputs.file(debugApk)
    doFirst {
        commandLine(
            "${buildTools.get()}/apksigner",
            "verify",
            "--verbose",
            debugApk.get().asFile.absolutePath,
        )
    }
}

val verifyDebugInstallPackage = tasks.register("verifyDebugInstallPackage") {
    group = "verification"
    description = "Verify install-time APK layout constraints for modern Android devices."
    dependsOn("assembleDebug")
    inputs.file(debugApk)
    doLast {
        ZipFile(debugApk.get().asFile).use { apk ->
            val resources = apk.getEntry("resources.arsc")
                ?: error("resources.arsc missing from signed smoke APK")
            require(resources.method == ZipEntry.STORED) {
                "resources.arsc must be stored uncompressed for Android R+ installs"
            }
        }
    }
}

val verifyDebugZipAlignment = tasks.register<Exec>("verifyDebugZipAlignment") {
    group = "verification"
    description = "Verify the signed debug smoke APK zip alignment."
    dependsOn("assembleDebug")
    inputs.file(debugApk)
    doFirst {
        commandLine(
            "${buildTools.get()}/zipalign",
            "-c",
            "-p",
            "4",
            debugApk.get().asFile.absolutePath,
        )
    }
}

tasks.register("verifyDebugSignedPackage") {
    group = "verification"
    description = "Verify the signed smoke APK contains expected Nucleus artifacts."
    dependsOn(
        "assembleDebug",
        verifyDebugSignature,
        verifyDebugInstallPackage,
        verifyDebugZipAlignment,
    )
    inputs.file(debugApk)
    doLast {
        ZipFile(debugApk.get().asFile).use { apk ->
            val entries = apk.entries().asSequence().map { it.name }.toSet()
            require("classes.dex" in entries) {
                "classes.dex missing from signed smoke APK"
            }
            require("lib/arm64-v8a/libnucleus-android.so" in entries) {
                "libnucleus-android.so missing from signed smoke APK"
            }
            require("lib/arm64-v8a/libc++_shared.so" in entries) {
                "libc++_shared.so missing from signed smoke APK"
            }
            require("assets/nucleus-smoke.txt" in entries) {
                "nucleus-smoke.txt missing from signed smoke APK assets"
            }
        }
    }
}

tasks.register("installDebugDevice") {
    group = "device"
    description = "Install the debug smoke APK on a connected Android device."
    dependsOn("installDebug")
}

tasks.register<Exec>("forceStopDebugDevice") {
    group = "device"
    description = "Force-stop the smoke app so native libraries reload on next launch."
    dependsOn("installDebugDevice")
    doFirst {
        commandLine(
            adbPath.get(),
            "shell",
            "am",
            "force-stop",
            "dev.nucleus.android.smoke",
        )
    }
}

tasks.register<Exec>("startDebugDevice") {
    group = "device"
    description = "Start the smoke activity on a connected Android device."
    dependsOn("forceStopDebugDevice")
    doFirst {
        commandLine(
            adbPath.get(),
            "shell",
            "am",
            "start",
            "-W",
            "-n",
            "dev.nucleus.android.smoke/.SmokeActivity",
        )
    }
}
