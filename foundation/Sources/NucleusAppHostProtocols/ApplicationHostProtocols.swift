public import NucleusTypes

@MainActor
public protocol ApplicationEventSink: AnyObject {
    func receive(_ event: ApplicationInputEvent)
}

@MainActor
public protocol WindowLifecycleSink: AnyObject {
    func receive(_ update: WindowLifecycleUpdate)
}

public protocol RenderUploadSink: AnyObject, Sendable {
    func upload(
        _ upload: RenderUpload,
        release: @escaping @Sendable () -> Void
    )
}

@MainActor
public protocol PasteboardHost: AnyObject {
    var availableTypes: [String] { get }
    func read(type: String) -> [UInt8]?
    func write(type: String, bytes: [UInt8])
    func clear()
}

public protocol OutputTopologyProvider: AnyObject, Sendable {
    var outputs: [OutputDescriptor] { get }
}
