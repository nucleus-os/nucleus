import Foundation
import Glibc
import NucleusAndroidDisplayHostCore

do {
    var arguments = Array(CommandLine.arguments.dropFirst())
    func value(_ name: String) throws -> String {
        guard let index = arguments.firstIndex(of: name),
            arguments.indices.contains(index + 1)
        else { throw DisplayHostError.invalidArguments("missing \(name)") }
        let result = arguments[index + 1]
        arguments.removeSubrange(index...(index + 1))
        return result
    }

    let socket = try value("--socket")
    let expectedUserID = try UInt32(value("--expected-uid"))
    let renderDevice = try value("--render-device")
    let parentPID = try Int32(value("--parent-pid"))
    let wayland = try value("--wayland")
    let inputSocket = try value("--input-socket")
    let presentationSocket = try value("--presentation-socket")
    let displayControlSocket = try value("--display-control-socket")
    let presentationControlSocket =
        try value("--presentation-control-socket")
    let presentationUserID =
        try UInt32(value("--presentation-expected-uid"))
    guard let expectedUserID, let presentationUserID,
        let parentPID, arguments.isEmpty
    else {
        throw DisplayHostError.invalidArguments("invalid numeric argument or unknown option")
    }
    try await NucleusAndroidDisplayHost(
        socketPath: socket,
        expectedUserID: expectedUserID,
        renderDevice: renderDevice,
        parentProcessID: parentPID,
        waylandSocket: wayland,
        inputSocketPath: inputSocket,
        presentationSocketPath: presentationSocket,
        displayControlSocketPath: displayControlSocket,
        presentationExpectedUserID: presentationUserID,
        presentationControlSocketPath: presentationControlSocket,
        presentationControlExpectedUserID: getuid()
    ).run()
} catch {
    FileHandle.standardError.write(
        Data("nucleus-android-display-host: \(error)\n".utf8))
    exit(1)
}
