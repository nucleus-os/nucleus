import Testing
@testable import NucleusUI

/// `SecureBytes` and the credential exit path. These exist because a Swift
/// `String` cannot be scrubbed, so the guarantee has to live somewhere that can.
@MainActor
@Suite(.uiContext) struct SecureBytesTests {
    @Test func bytesRoundTripFromAString() {
        let secret = SecureBytes(utf8: "hunter2")
        #expect(secret.count == 7)
        unsafe secret.withUnsafeBytes {
            #expect(String(decoding: $0, as: UTF8.self) == "hunter2")
        }
    }

    @Test func multibyteTextKeepsItsByteLength() {
        let secret = SecureBytes(utf8: "pä😀")
        #expect(secret.count == 7, "1 + 2 + 4 bytes")
    }

    @Test func anEmptySecretIsEmpty() {
        let textSecret = SecureBytes(utf8: "")
        let allocatedSecret = SecureBytes(count: 0)
        let textIsEmpty = textSecret.isEmpty
        let allocationIsEmpty = allocatedSecret.isEmpty
        #expect(textIsEmpty)
        #expect(allocationIsEmpty)
    }

    /// Scrubbing zeroes in place — the same buffer, not a fresh one, which is
    /// what makes it a guarantee rather than a hope.
    @Test func scrubbingZeroesTheBufferInPlace() {
        let secret = SecureBytes(utf8: "hunter2")
        secret.scrub()
        unsafe secret.withUnsafeBytes { bytes in
            #expect(bytes.allSatisfy { $0 == 0 })
        }
        #expect(secret.count == 7, "the buffer is still there, just empty of secret")
    }

    @Test func bytesCanBeMutatedInPlace() {
        var secret = SecureBytes(count: 4)
        unsafe secret.withUnsafeMutableBytes { $0.copyBytes(from: [1, 2, 3, 4]) }
        unsafe secret.withUnsafeBytes { #expect(Array($0) == [1, 2, 3, 4]) }
    }

    @Test func requestedCapacityIsAllocatedExactly() {
        var allocatedCounts: [Int] = []
        let observer = SecureBytesLifecycleObserver(
            didAllocate: { allocatedCounts.append($0) })

        let secret = SecureBytes(count: 37, lifecycleObserver: observer)

        #expect(secret.count == 37)
        #expect(allocatedCounts == [37])
    }

    @Test func emptyStorageOwnsNoAllocationAndNeedsNoScrub() {
        var allocatedCounts: [Int] = []
        var scrubbed: [[UInt8]] = []
        var deallocations = 0
        let observer = SecureBytesLifecycleObserver(
            didAllocate: { allocatedCounts.append($0) },
            didScrub: { scrubbed.append($0) },
            didDeallocate: { deallocations += 1 })

        consume(SecureBytes(count: 0, lifecycleObserver: observer))

        #expect(allocatedCounts == [0])
        #expect(scrubbed.isEmpty)
        #expect(deallocations == 0)
    }

    @Test func movingTransfersOneAllocationAndZeroesItBeforeRelease() {
        var scrubbed: [[UInt8]] = []
        var deallocations = 0
        let observer = SecureBytesLifecycleObserver(
            didScrub: { scrubbed.append($0) },
            didDeallocate: { deallocations += 1 })
        var original = SecureBytes(count: 4, lifecycleObserver: observer)
        unsafe original.withUnsafeMutableBytes { $0.copyBytes(from: [9, 8, 7, 6]) }

        consume(original)

        #expect(scrubbed == [[0, 0, 0, 0]])
        #expect(deallocations == 1)
    }

    private func consume(_ secret: consuming SecureBytes) {
        #expect(secret.count >= 0)
    }

    // MARK: - The credential exit path

    /// Taking the credential empties the model: the byte copy becomes the
    /// authoritative one and nothing is left to recover.
    @Test func takingTheBytesEmptiesTheModel() {
        var model = TextEditorModel(text: "hunter2", isSecure: true)
        let secret = model.takeSecureBytes()

        unsafe secret.withUnsafeBytes {
            #expect(String(decoding: $0, as: UTF8.self) == "hunter2")
        }
        #expect(model.text.isEmpty)
        #expect(model.selection == TextSelection(caretAt: 0))
    }

    /// Undo must not put a taken credential back.
    @Test func takingTheBytesDiscardsUndoHistory() {
        var model = TextEditorModel(text: "", isSecure: true)
        model.insert("hunter2")
        #expect(model.canUndo)

        _ = model.takeSecureBytes()
        #expect(!model.canUndo)
        let restored = model.undo()
        #expect(!restored)
        #expect(model.text.isEmpty)
    }

    @Test func takingFromAFieldEmptiesIt() {
        let field = TextField(string: "hunter2", isSecure: true)
        let secret = field.takeSecureCredential()

        unsafe secret.withUnsafeBytes {
            #expect(String(decoding: $0, as: UTF8.self) == "hunter2")
        }
        #expect(field.stringValue.isEmpty)
    }

    /// Taking from a field notifies observers, so a lock screen's status and any
    /// input-method state stay consistent with an emptied field.
    @Test func takingFromAFieldReportsTheChange() {
        let field = TextField(string: "hunter2", isSecure: true)
        var changes = 0
        field.onChange = { _ in changes += 1 }
        _ = field.takeSecureCredential()
        #expect(changes == 1)
    }

    @Test func takingFromAnEmptyFieldYieldsNothing() {
        let field = TextField(string: "", isSecure: true)
        let secret = field.takeSecureCredential()
        let isEmpty = secret.isEmpty
        #expect(isEmpty)
    }
}
