package enum RuntimeHostDiagnostics {
    package static func canCreateRuntime() -> Bool {
        RuntimeHost.hermesCanCreateRuntime()
    }

    package static func bytecodeVersion() -> UInt32 {
        RuntimeHost.hermesBytecodeVersion()
    }

    package static func intlDateTimeFormatWorks() -> Bool {
        RuntimeHost.hermesIntlDateTimeFormatWorks()
    }
}
