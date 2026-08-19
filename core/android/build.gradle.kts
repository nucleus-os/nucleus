import org.gradle.util.GradleVersion

plugins {
    base
    alias(libs.plugins.androidApplication) apply false
    alias(libs.plugins.androidLibrary) apply false
}

// Every Gradle output goes where the caller says, never into the checkout: the
// identity that runs builds has read-only access to the source it builds.
val nucleusBuildRoot =
    providers.gradleProperty("nucleus.buildRoot").map { File(it) }.orNull
        ?: layout.projectDirectory.dir("../.gradle-out").asFile
val requiredGradle = libs.versions.gradle.get()
check(GradleVersion.current() == GradleVersion.version(requiredGradle)) {
    "Nucleus Android requires Gradle $requiredGradle; the running version is "
        .plus(GradleVersion.current().version)
}
val requiredJava = JavaVersion.toVersion(libs.versions.jvm.get())
check(JavaVersion.current() == requiredJava) {
    "Nucleus Android requires Java $requiredJava; the running version is "
        .plus(JavaVersion.current())
}

tasks.register("assembleDebug") {
    group = "build"
    description = "Assemble all Android debug scaffold artifacts."
    dependsOn(":nucleus:assembleDebug", ":smoke-app:assembleDebug")
}

tasks.register("assembleDebugSigned") {
    group = "build"
    description = "Assemble all signed Android debug scaffold artifacts."
    dependsOn(":smoke-app:assembleDebug")
}

tasks.register("verifyDebug") {
    group = "verification"
    description = "Verify all Android debug scaffold artifacts."
    dependsOn(
        ":nucleus:testDebugUnitTest",
        ":nucleus:verifyDebugAar",
        ":smoke-app:verifyDebugPackage",
        ":smoke-app:verifyDebugSignedPackage",
    )
}

allprojects {
    layout.buildDirectory.set(
        File(nucleusBuildRoot, project.path.replace(':', '/').trimStart('/'))
    )
}
