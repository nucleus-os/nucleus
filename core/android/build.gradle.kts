plugins {
    base
    alias(libs.plugins.androidApplication) apply false
    alias(libs.plugins.androidLibrary) apply false
}

val repoRoot = layout.projectDirectory.dir("..")

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
    dependsOn(":nucleus:verifyDebugAar", ":smoke-app:verifyDebugPackage", ":smoke-app:verifyDebugSignedPackage")
}

allprojects {
    layout.buildDirectory.set(repoRoot.dir("zig-out/android-gradle/${project.path.replace(':', '/').trimStart('/')}"))
}
