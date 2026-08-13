import Glibc
import NucleusConfig
import NucleusIPCTransport
import NucleusSessionProtocol
import Testing

@Suite struct ShellPolicyChannelTests {
    @Test func policyMessagesPreserveTypedConfigurationIdentity() throws {
        let (serverTransport, shellTransport) =
            try PacketConnection.socketPair()
        let server = ShellPolicyChannel(
            owning: serverTransport.takeFileDescriptor())
        let shell = ShellPolicyChannel(
            owning: shellTransport.takeFileDescriptor())
        let epoch = ConfigurationServiceEpoch(high: 12, low: 34)
        let generation = ConfigurationGeneration(rawValue: 56)
        let publication = ShellPolicyPublication(
            kind: .acceptedAction,
            action: .launch(appIDs: [], command: ["foot"]),
            configurationIndex: 7,
            configurationEpoch: epoch,
            configurationGeneration: generation)

        try server.send(publication)

        #expect(try shell.receivePublication() == publication)
    }

    @Test func policyChannelRejectsAnotherProtocolVersion() throws {
        let (serverTransport, shellTransport) =
            try PacketConnection.socketPair()
        let server = ShellPolicyChannel(
            owning: serverTransport.takeFileDescriptor())
        let shell = ShellPolicyChannel(
            owning: shellTransport.takeFileDescriptor())
        try server.send(
            ShellPolicyPublication(
                protocolVersion: SessionProtocolVersion.current + 1,
                kind: .ready))

        #expect(throws: ShellPolicyChannelFailure.self) {
            _ = try shell.receivePublication()
        }
    }

    @Test func attachmentTransfersOwnedPolicyAndWaylandEndpoints() throws {
        let (senderTransport, receiverTransport) =
            try PacketConnection.socketPair()
        let sender = ShellPolicyAttachmentChannel(
            owning: senderTransport.takeFileDescriptor())
        let receiver = ShellPolicyAttachmentChannel(
            owning: receiverTransport.takeFileDescriptor())
        var policy = [Int32](repeating: -1, count: 2)
        var wayland = [Int32](repeating: -1, count: 2)
        #expect(
            unsafe Glibc.socketpair(
                AF_UNIX, Int32(SOCK_SEQPACKET.rawValue), 0, &policy) == 0)
        #expect(
            unsafe Glibc.socketpair(
                AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &wayland) == 0)
        defer {
            for descriptor in policy + wayland where descriptor >= 0 {
                _ = Glibc.close(descriptor)
            }
        }

        try sender.send(
            policyDescriptor: policy[0],
            waylandDescriptor: wayland[0])
        let attachment = try receiver.receive()

        #expect(attachment.policy.rawValue >= 0)
        #expect(attachment.wayland.rawValue >= 0)
        #expect(Glibc.fcntl(attachment.policy.rawValue, F_GETFD) >= 0)
        #expect(Glibc.fcntl(attachment.wayland.rawValue, F_GETFD) >= 0)
    }

    @Test func inheritedDescriptorArgumentsRequireOneValidValue() throws {
        #expect(
            try ShellPolicyAttachmentChannel.inherited(
                arguments: ["shell"]) == nil)
        let inherited = try ShellPolicyAttachmentChannel.inherited(
            arguments: [
                "shell",
                ShellPolicyAttachmentChannel.descriptorArgument,
                "194",
            ])
        #expect(inherited?.fileDescriptor == 194)
        #expect(throws: ShellPolicyChannelFailure.self) {
            _ = try ShellPolicyAttachmentChannel.inherited(
                arguments: [
                    "shell",
                    ShellPolicyAttachmentChannel.descriptorArgument,
                    "194",
                    ShellPolicyAttachmentChannel.descriptorArgument,
                    "195",
                ])
        }
    }

    @Test func shellWaylandDescriptorRequiresOneValidValue() throws {
        #expect(try ShellWaylandConnection.inherited(arguments: ["shell"]) == nil)
        #expect(
            try ShellWaylandConnection.inherited(arguments: [
                "shell", ShellWaylandConnection.descriptorArgument, "194",
            ]) == 194)
        #expect(throws: ShellWaylandConnectionFailure.self) {
            _ = try ShellWaylandConnection.inherited(arguments: [
                "shell", ShellWaylandConnection.descriptorArgument, "194",
                ShellWaylandConnection.descriptorArgument, "195",
            ])
        }
    }
}
