package enum RuntimeOptimization: String, Equatable {
    case debug
    case release
}

package struct RuntimeBuildSelection: Equatable {
    package var optimization: RuntimeOptimization
    package var tracy: Bool
    package var sanitizer: SanitizerKind?

    package init(
        optimization: RuntimeOptimization = .debug,
        tracy: Bool = false,
        sanitizer: SanitizerKind? = nil
    ) {
        self.optimization = optimization
        self.tracy = tracy
        self.sanitizer = sanitizer
    }

    var identity: String {
        [
            optimization.rawValue,
            tracy ? "tracy" : "plain",
            sanitizer?.rawValue ?? "unsanitized",
        ].joined(separator: "-")
    }

    package var metadata: String {
        """
        configuration=\(optimization.rawValue)
        tracy=\(tracy)
        sanitizer=\(sanitizer?.rawValue ?? "none")
        """ + "\n"
    }
}
