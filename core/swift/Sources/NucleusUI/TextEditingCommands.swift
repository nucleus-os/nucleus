/// The retained editing state and lifecycle hooks shared by single-line and
/// multiline controls.
///
/// This seam is package-only and has exactly two consumers. It keeps
/// pasteboard commands, generation checks, undo/redo, and teardown ownership
/// identical without coupling `TextView` to `TextField`'s rendering model.
@MainActor
package protocol TextEditingCommandHost: AnyObject {
    var editorModel: TextEditorModel { get set }
    var editorAllowsMultilineText: Bool { get }
    var editorIsFocused: Bool { get }
    var editorPasteboard: Pasteboard { get }
    var editorSceneIsConnected: Bool { get }

    func editorDidEdit(cause: TextInputChangeCause)
    func editorDidChangeSelection()
}

/// Common semantic surface consumed by the neutral accessibility tree.
@MainActor
package protocol RetainedTextEditorAccessibility: AnyObject {
    var accessibilityEditorText: String { get set }
    var accessibilityEditorSelection: Range<Int> { get }
    var accessibilityEditorIsSecure: Bool { get }
    var accessibilityEditorIsMultiline: Bool { get }

    func setAccessibilityEditorSelection(_ range: Range<Int>)
}

/// Owns asynchronous editing commands for one retained text control.
///
/// The host owns this coordinator; the coordinator holds the host weakly.
/// Every suspended result is guarded by the exact editing generation captured
/// before suspension.
@MainActor
package final class TextEditingCommandCoordinator: ~Sendable {
    private weak var host: (any TextEditingCommandHost)?
    private var generation: UInt64 = 1
    private var commandTask: Task<Void, Never>?

    package init(host: any TextEditingCommandHost) {
        self.host = host
    }

    isolated deinit {
        commandTask?.cancel()
    }

    package func installStandardActions(on responder: Responder) {
        responder.setAction(.copy) { [weak self] _ in
            self?.startCopy()
        }
        responder.setAction(.cut) { [weak self] _ in
            self?.startCut()
        }
        responder.setAction(.paste) { [weak self] _ in
            self?.startPaste()
        }
        responder.setAction(.selectAll) { [weak self] _ in
            guard let host = self?.host else { return }
            host.editorModel.selectAll()
            host.editorDidChangeSelection()
        }
        responder.setAction(.undo) { [weak self] _ in
            guard let host = self?.host,
                  host.editorModel.undo()
            else { return }
            host.editorDidEdit(cause: .other)
        }
        responder.setAction(.redo) { [weak self] _ in
            guard let host = self?.host,
                  host.editorModel.redo()
            else { return }
            host.editorDidEdit(cause: .other)
        }
    }

    package func advanceGeneration() {
        generation &+= 1
        precondition(generation != 0, "text editing generation exhausted")
    }

    package func cancelAndAdvance() {
        commandTask?.cancel()
        commandTask = nil
        advanceGeneration()
    }

    package func copy(
        to pasteboard: Pasteboard
    ) async -> Bool {
        guard let host,
              host.editorIsFocused,
              let selected = host.editorModel.copyableSelection()
        else { return false }
        do {
            try await pasteboard.writeString(selected)
            return true
        } catch {
            return false
        }
    }

    package func cut(
        to pasteboard: Pasteboard
    ) async -> Bool {
        guard let host,
              host.editorIsFocused,
              let selected = host.editorModel.copyableSelection()
        else { return false }
        let generation = self.generation
        do {
            try await pasteboard.writeString(selected)
        } catch {
            return false
        }
        guard isCurrent(generation),
              let host = self.host,
              host.editorModel.deleteSelection()
        else { return false }
        host.editorDidEdit(cause: .other)
        return true
    }

    package func paste(
        from pasteboard: Pasteboard
    ) async -> Bool {
        guard let host, host.editorIsFocused else { return false }
        let generation = self.generation
        let value: String
        do {
            guard let string = try await pasteboard.readString(),
                  !string.isEmpty
            else { return false }
            value = string
        } catch {
            return false
        }
        guard isCurrent(generation), let host = self.host else {
            return false
        }
        host.editorModel.insert(normalized(value, for: host))
        host.editorDidEdit(cause: .other)
        return true
    }

    private func startCopy() {
        cancelCommand()
        guard let host,
              host.editorIsFocused,
              let selected = host.editorModel.copyableSelection()
        else { return }
        let pasteboard = host.editorPasteboard
        commandTask = Task {
            try? await pasteboard.writeString(selected)
        }
    }

    private func startCut() {
        cancelCommand()
        guard let host,
              host.editorIsFocused,
              let selected = host.editorModel.copyableSelection()
        else { return }
        let generation = self.generation
        let pasteboard = host.editorPasteboard
        commandTask = Task { @MainActor [weak self] in
            do {
                try await pasteboard.writeString(selected)
            } catch {
                return
            }
            guard let self,
                  self.isCurrent(generation),
                  let host = self.host,
                  host.editorModel.deleteSelection()
            else { return }
            host.editorDidEdit(cause: .other)
        }
    }

    private func startPaste() {
        cancelCommand()
        guard let host, host.editorIsFocused else { return }
        let generation = self.generation
        let pasteboard = host.editorPasteboard
        commandTask = Task { @MainActor [weak self] in
            let value: String
            do {
                guard let string = try await pasteboard.readString(),
                      !string.isEmpty
                else { return }
                value = string
            } catch {
                return
            }
            guard let self,
                  self.isCurrent(generation),
                  let host = self.host
            else { return }
            host.editorModel.insert(self.normalized(value, for: host))
            host.editorDidEdit(cause: .other)
        }
    }

    private func normalized(
        _ string: String,
        for host: any TextEditingCommandHost
    ) -> String {
        host.editorAllowsMultilineText
            ? string
            : string.replacing("\n", with: " ")
    }

    private func isCurrent(_ candidate: UInt64) -> Bool {
        guard candidate == generation,
              let host,
              host.editorIsFocused,
              host.editorSceneIsConnected
        else { return false }
        return true
    }

    private func cancelCommand() {
        commandTask?.cancel()
        commandTask = nil
    }
}
