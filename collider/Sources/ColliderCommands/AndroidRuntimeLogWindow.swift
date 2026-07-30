import Foundation

struct AndroidRuntimeLogWindowInvocation: Equatable {
    let executable = "kitty"
    let arguments: [String]

    init(diagnosticsDirectory: URL) {
        arguments = [
            "--class",
            "nucleus.android.runtime-log",
            "--title",
            "Nucleus Android Runtime",
            "--",
            "tail",
            "--lines=200",
            "--follow=name",
            "--retry",
            diagnosticsDirectory.appendingPathComponent(
                "android-kmsg.log").path,
            diagnosticsDirectory.appendingPathComponent(
                "android-logcat.log").path,
            diagnosticsDirectory.appendingPathComponent(
                "android-gfxstream-broker.log").path,
            diagnosticsDirectory.appendingPathComponent(
                "android-display-host.log").path,
            diagnosticsDirectory.appendingPathComponent(
                "android-progress.jsonl").path,
        ]
    }
}
