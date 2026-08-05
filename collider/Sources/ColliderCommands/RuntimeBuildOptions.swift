struct RuntimeBuildOptions: Equatable {
    var optimization: OptimizationMode = .debug
    var tracy = false
    var sanitizer: SanitizerKind?

    var identity: String {
        [
            optimization.rawValue,
            tracy ? "tracy" : "plain",
            sanitizer?.rawValue ?? "unsanitized",
        ].joined(separator: "-")
    }

    var metadata: String {
        """
        configuration=\(optimization.rawValue)
        tracy=\(tracy)
        sanitizer=\(sanitizer?.rawValue ?? "none")
        """ + "\n"
    }
}
