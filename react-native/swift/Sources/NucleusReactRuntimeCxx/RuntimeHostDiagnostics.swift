public enum RuntimeHostDiagnostics {
    public static func canCreateRuntime() -> Bool {
        RuntimeHost.hermesCanCreateRuntime()
    }

    public static func bytecodeVersion() -> UInt32 {
        RuntimeHost.hermesBytecodeVersion()
    }

    public static func intlDateTimeFormatWorks() -> Bool {
        RuntimeHost.hermesIntlDateTimeFormatWorks()
    }
}
