struct AndroidPresentationID: Hashable, Sendable, RawRepresentable {
    let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    static let desktop = AndroidPresentationID(rawValue: 0)
}

enum AndroidPresentationRole: Equatable, Sendable {
    case desktop
    case application
}

struct AndroidPresentation: Equatable, Sendable {
    let id: AndroidPresentationID
    let role: AndroidPresentationRole
    let appID: String
    let title: String
    var configurationGeneration: UInt64
    var mode: AndroidPresentationMode
}

struct AndroidPresentationRegistry {
    private(set) var presentations: [AndroidPresentationID: AndroidPresentation]
    private var nextApplicationID: UInt64 = 1

    init(
        desktopMode: AndroidPresentationMode = AndroidPresentationMode(
            width: initialAndroidPresentationWidth,
            height: initialAndroidPresentationHeight)
    ) {
        let desktop = AndroidPresentation(
            id: .desktop,
            role: .desktop,
            appID: "nucleus.android.desktop",
            title: "Android",
            configurationGeneration: 1,
            mode: desktopMode)
        presentations = [.desktop: desktop]
    }

    var desktop: AndroidPresentation {
        presentations[.desktop]!
    }

    func presentation(
        id: AndroidPresentationID
    ) -> AndroidPresentation? {
        presentations[id]
    }

    mutating func createApplication(
        appID: String,
        title: String,
        initialMode: AndroidPresentationMode
    ) throws -> AndroidPresentation {
        guard !appID.isEmpty,
            !title.isEmpty,
            initialMode.width > 0,
            initialMode.height > 0,
            nextApplicationID > 0
        else {
            throw DisplayHostError.invalidArguments(
                "invalid Android application presentation")
        }
        let id = AndroidPresentationID(rawValue: nextApplicationID)
        guard presentations[id] == nil else {
            throw DisplayHostError.invalidArguments(
                "Android presentation identity is exhausted")
        }
        nextApplicationID &+= 1
        let presentation = AndroidPresentation(
            id: id,
            role: .application,
            appID: appID,
            title: title,
            configurationGeneration: 1,
            mode: initialMode)
        presentations[id] = presentation
        return presentation
    }

    mutating func updateConfiguration(
        id: AndroidPresentationID,
        generation: UInt64,
        mode: AndroidPresentationMode
    ) throws {
        guard generation > 0,
            mode.width > 0,
            mode.height > 0,
            var presentation = presentations[id]
        else { throw DisplayHostError.invalidRequest }
        presentation.configurationGeneration = generation
        presentation.mode = mode
        presentations[id] = presentation
    }

    @discardableResult
    mutating func removeApplication(
        id: AndroidPresentationID
    ) -> AndroidPresentation? {
        guard id != .desktop,
            presentations[id]?.role == .application
        else { return nil }
        return presentations.removeValue(forKey: id)
    }
}
