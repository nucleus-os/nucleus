import Testing

@testable import NucleusAndroidRuntimeBridgeProtocol

@Test
func presentationControlRequestsCarryOneExactOperationShape() throws {
    let create = AndroidPresentationControlRequest.create(
        appID: "org.example.application",
        title: "Example",
        width: 1_280,
        height: 720,
        activationToken: "activation-token")
    let close = AndroidPresentationControlRequest.close(presentationID: 42)
    let activate = AndroidPresentationControlRequest.activate(
        presentationID: 42,
        token: "replacement-token")
    let observe = AndroidPresentationControlRequest.observe

    try create.validate()
    try close.validate()
    try activate.validate()
    try observe.validate()
    #expect(create.operation == .create)
    #expect(create.presentationID == nil)
    #expect(close.operation == .close)
    #expect(close.presentationID == 42)
    #expect(close.appID == nil)
    #expect(activate.operation == .activate)
    #expect(activate.activationToken == "replacement-token")
    #expect(observe.operation == .observe)
}

@Test
func presentationControlRoundTripsCreateAndReplyPackets() throws {
    let (client, server) = try AndroidPresentationControlConnection.socketPair()
    let request = AndroidPresentationControlRequest.create(
        appID: "org.example.application",
        title: "Example",
        width: 1_280,
        height: 720)

    try client.send(request)
    #expect(try server.receiveRequest() == request)

    let reply = AndroidPresentationControlReply(presentationID: 7)
    try server.send(reply)
    #expect(try client.receiveReply() == reply)
}

@Test
func presentationObserverCarriesReadinessAndHostClosure() throws {
    let (client, server) = try AndroidPresentationControlConnection.socketPair()
    try client.send(.observe)
    #expect(try server.receiveRequest() == .observe)

    try server.send(.ready)
    try server.send(.closed(presentationID: 9))
    #expect(try client.receiveEvent() == .ready)
    #expect(try client.receiveEvent() == .closed(presentationID: 9))
}
