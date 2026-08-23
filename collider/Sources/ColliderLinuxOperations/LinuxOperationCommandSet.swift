import ArgumentParser

package enum LinuxOperationCommandSet {
    package static let root: [ParsableCommand.Type] = [Run.self]
    package static let install: [ParsableCommand.Type] = [
        InstallSession.self
    ]
}
