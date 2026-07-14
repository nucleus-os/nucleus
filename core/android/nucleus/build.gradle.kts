import org.gradle.api.DefaultTask
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.provider.Property
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.InputFile
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.PathSensitive
import org.gradle.api.tasks.PathSensitivity
import org.gradle.api.tasks.TaskAction
import java.util.zip.ZipFile

plugins {
    alias(libs.plugins.androidLibrary)
}

val repoRoot = layout.projectDirectory.dir("../..")
val repoRootFile = repoRoot.asFile
val androidSdkRoot = providers.gradleProperty("nucleus.androidSdk")
    .orElse(providers.environmentVariable("ANDROID_HOME"))
    .orElse(providers.environmentVariable("ANDROID_SDK_ROOT"))
    .orElse("${System.getProperty("user.home")}/Android/Sdk")
val ndkHome = providers.gradleProperty("nucleus.androidNdk")
    .orElse(providers.environmentVariable("NUCLEUS_ANDROID_NDK_HOME"))
    .orElse(providers.environmentVariable("ANDROID_NDK_HOME"))
    .orElse(androidSdkRoot.map { "$it/ndk/${libs.versions.ndk.get()}" })
val nucleusSourceId = providers.gradleProperty("nucleus.swiftSourceId").orElse("release-6.4.x")
// Cross-compile libnucleus-android.so via SwiftPM (the platform-android package)
// using the registered Swift Android SDK, then verify the JNI export contract.
// Replaces the deleted `zig build nucleus-android`. Override with -Pnucleus.nativeBuildCommand.
val nativeBuildCommand = providers.gradleProperty("nucleus.nativeBuildCommand")
    .orElse(nucleusSourceId.map { sourceId ->
        val inner = "swift build --package-path platform-android " +
            "--swift-sdk swift-${sourceId}_android --static-swift-stdlib -c release && " +
            "${shellQuote(repoRootFile.resolve("tools/nucleus").absolutePath)} android verify"
        "bash -c ${shellQuote("source ${shellQuote(repoRootFile.resolve("core/tools/host-env.sh").absolutePath)} && $inner")}"
    })
val nucleusMinSdkVersion = providers.gradleProperty("nucleus.minSdk").orElse(libs.versions.minSdk)
val nucleusTargetSdkVersion = providers.gradleProperty("nucleus.targetSdk").orElse(libs.versions.targetSdkApi)

fun shellQuote(value: String): String = "'" + value.replace("'", "'\\''") + "'"

fun String.capitalizedTaskName(): String =
    replaceFirstChar { if (it.isLowerCase()) it.titlecase() else it.toString() }

abstract class CopyNucleusJniLibs : DefaultTask() {
    @get:InputFile
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val nucleusLibrary: RegularFileProperty

    // The swift-java runtime support library — a NEEDED dependency of
    // libnucleus-android.so, built alongside it in the SwiftPM product directory.
    @get:InputFile
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val swiftJavaLibrary: RegularFileProperty

    @get:InputFile
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val cxxRuntime: RegularFileProperty

    @get:OutputDirectory
    abstract val outputDirectory: DirectoryProperty

    @TaskAction
    fun copyLibraries() {
        val output = outputDirectory.get().asFile
        output.deleteRecursively()
        val abiDirectory = output.resolve("arm64-v8a")
        abiDirectory.mkdirs()
        nucleusLibrary.get().asFile.copyTo(
            abiDirectory.resolve("libnucleus-android.so"),
            overwrite = true,
        )
        swiftJavaLibrary.get().asFile.copyTo(
            abiDirectory.resolve("libSwiftJava.so"),
            overwrite = true,
        )
        cxxRuntime.get().asFile.copyTo(
            abiDirectory.resolve("libc++_shared.so"),
            overwrite = true,
        )
    }
}

abstract class WriteNucleusAndroidMetadata : DefaultTask() {
    @get:Input
    abstract val variantName: Property<String>

    @get:Input
    abstract val minSdkVersion: Property<String>

    @get:Input
    abstract val targetSdkVersion: Property<String>

    @get:Input
    abstract val sourceId: Property<String>

    @get:OutputDirectory
    abstract val outputDirectory: DirectoryProperty

    @TaskAction
    fun writeMetadata() {
        val output = outputDirectory.get().asFile
        output.deleteRecursively()
        output.mkdirs()
        output.resolve("nucleus-android.properties").writeText(
            """
            schemaVersion=1
            artifact=dev.nucleus.android:nucleus
            variant=${variantName.get()}
            abi=arm64-v8a
            minSdk=${minSdkVersion.get()}
            targetSdk=${targetSdkVersion.get()}
            swiftSourceId=${sourceId.get()}
            nativeLibrary=libnucleus-android.so
            cxxRuntime=libc++_shared.so
            viewClass=dev.nucleus.android.NucleusView
            frameCallback=frame
            assetManager=AAssetManager_fromJava
            smokeAsset=assets/nucleus-smoke.txt
            eventQueue=eventQueueSmokeValue
            assetProvider=assetSmokeValue
            runtimeHost=runtimeAttach
            rendererBackend=AndroidRenderer
            runtimeVerification=runtimeVerificationValue
            renderSmoke=renderSmokeValue
            renderStatus=renderStatusCode
            diagnostics=diagnosticValue
            """.trimIndent() + "\n"
        )
    }
}

extensions.configure<com.android.build.api.dsl.LibraryExtension>("android") {
    namespace = "dev.nucleus.android"
    buildToolsVersion = libs.versions.buildTools.get()
    ndkVersion = libs.versions.ndk.get()

    compileSdk {
        version = release(libs.versions.compileSdkApi.get().toInt()) {
            minorApiLevel = libs.versions.compileSdkMinor.get().toInt()
        }
    }

    defaultConfig {
        minSdk = nucleusMinSdkVersion.get().toInt()
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    sourceSets {
        getByName("main") {
            // The swift-java Java runtime (SwiftKitCore) consumed as source, and the
            // jextract-generated bindings (AndroidHost.java) produced by the native
            // build. The generated directory is populated by buildNucleusAndroidNative,
            // which the compile tasks depend on (wired below).
            java.srcDir(repoRoot.dir("../third-party/swift-java/SwiftKitCore/src/main/java"))
            java.srcDir(
                repoRoot.dir(
                    "platform-android/.build/plugins/outputs/platform-android/" +
                        "NucleusAndroidJNI/destination/JExtractSwiftPlugin/src/generated/java"
                )
            )
        }
    }
}

val buildNucleusAndroidNative = tasks.register<Exec>("buildNucleusAndroidNative") {
    group = "build"
    description = "Build libnucleus-android.so through the SwiftPM platform-android package."
    workingDir(repoRootFile)
    doFirst {
        commandLine("sh", "-lc", nativeBuildCommand.get())
    }
}

val ndkCxxShared = ndkHome.map {
    "$it/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so"
}

// The jextract-generated AndroidHost.java is produced by the native build, so all
// Java/Kotlin compilation must run after it.
tasks.withType<JavaCompile>().configureEach { dependsOn(buildNucleusAndroidNative) }
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    dependsOn(buildNucleusAndroidNative)
}

extensions.configure<com.android.build.api.variant.LibraryAndroidComponentsExtension>("androidComponents") {
    onVariants { variant ->
        val variantTaskName = variant.name.capitalizedTaskName()
        val copyJniLibs = tasks.register<CopyNucleusJniLibs>("copy${variantTaskName}JniLibs") {
            dependsOn(buildNucleusAndroidNative)
            val productDir = "platform-android/.build/out/Products/Release-android-aarch64"
            nucleusLibrary.set(repoRoot.file("$productDir/libnucleus-android.so"))
            swiftJavaLibrary.set(repoRoot.file("$productDir/libSwiftJava.so"))
            cxxRuntime.set(layout.file(ndkCxxShared.map { file(it) }))
            outputDirectory.set(layout.buildDirectory.dir("generated/jniLibs/${variant.name}"))
        }
        val writeMetadata = tasks.register<WriteNucleusAndroidMetadata>("write${variantTaskName}Metadata") {
            variantName.set(variant.name)
            minSdkVersion.set(nucleusMinSdkVersion)
            targetSdkVersion.set(nucleusTargetSdkVersion)
            sourceId.set(nucleusSourceId)
            outputDirectory.set(layout.buildDirectory.dir("generated/assets/${variant.name}"))
        }
        variant.sources.jniLibs?.addGeneratedSourceDirectory(
            copyJniLibs,
            CopyNucleusJniLibs::outputDirectory,
        )
        variant.sources.assets?.addGeneratedSourceDirectory(
            writeMetadata,
            WriteNucleusAndroidMetadata::outputDirectory,
        )
    }
}

tasks.register("verifyDebugAar") {
    group = "verification"
    description = "Verify the debug AAR contains classes, metadata, and native libraries."
    dependsOn("assembleDebug")
    val aar = layout.buildDirectory.file("outputs/aar/nucleus-debug.aar")
    inputs.file(aar)
    doLast {
        ZipFile(aar.get().asFile).use { archive ->
            val entries = archive.entries().asSequence().map { it.name }.toSet()
            require("AndroidManifest.xml" in entries) {
                "AndroidManifest.xml missing from AAR"
            }
            require("classes.jar" in entries) {
                "classes.jar missing from AAR"
            }
            require("assets/nucleus-android.properties" in entries) {
                "nucleus-android.properties missing from AAR assets"
            }
            require("assets/nucleus-smoke.txt" in entries) {
                "nucleus-smoke.txt missing from AAR assets"
            }
            require("jni/arm64-v8a/libnucleus-android.so" in entries) {
                "libnucleus-android.so missing from AAR"
            }
            require("jni/arm64-v8a/libc++_shared.so" in entries) {
                "libc++_shared.so missing from AAR"
            }

            val classesEntry = archive.getEntry("classes.jar") ?: error("classes.jar missing from AAR")
            val classesJar = temporaryDir.resolve("classes.jar")
            archive.getInputStream(classesEntry).use { input ->
                classesJar.outputStream().use { output -> input.copyTo(output) }
            }
            ZipFile(classesJar).use { classes ->
                val classEntries = classes.entries().asSequence().map { it.name }.toSet()
                require("dev/nucleus/android/NucleusView.class" in classEntries) {
                    "NucleusView.class missing from classes.jar"
                }
            }
        }
    }
}
