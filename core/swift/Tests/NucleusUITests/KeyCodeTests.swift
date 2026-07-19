import Testing
@testable import NucleusUI

/// Key codes, and the platform mapping that produces them.
///
/// The framework's key vocabulary must be a *closed* space. It used to be open —
/// unmapped platform codes were passed through as raw values — and because the
/// named constants were numbered from 1, ordinary evdev codes landed on them:
/// the "1" key (evdev 2) *was* `.return`, "q" (evdev 16) *was* `.pageUp`. Any
/// view switching on `keyCode` before inserting text, which is every text view,
/// acted on a keystroke the user never made.
@Suite struct KeyCodeTests {
    // MARK: - The vocabulary is closed

    /// The defect, stated directly: no key on a keyboard may arrive as a
    /// framework code it does not mean.
    @Test func noEvdevCodeCollidesWithAnUnrelatedNamedKey() {
        // Every evdev code a PC keyboard produces, mapped, must either be the
        // key it actually is or `.unknown` — never something else.
        let expectations: [(UInt32, KeyCode)] = [
            (2, .digit1), (3, .digit2), (4, .digit3), (10, .digit9), (11, .digit0),
            (16, .letterQ), (17, .letterW), (30, .letterA), (44, .letterZ),
            (12, .minus), (13, .equal),
        ]
        for (code, expected) in expectations {
            #expect(KeyCode(linuxEvdevCode: code) == expected,
                    "evdev \(code) must not resolve to anything else")
        }
    }

    /// The specific historical failures, kept as named cases because each one
    /// was a key a user could not type.
    @Test func digitsAreNotControlKeys() {
        #expect(KeyCode(linuxEvdevCode: 2) != .return, "the 1 key is not Return")
        #expect(KeyCode(linuxEvdevCode: 3) != .tab, "the 2 key is not Tab")
        #expect(KeyCode(linuxEvdevCode: 4) != .space, "the 3 key is not Space")
        #expect(KeyCode(linuxEvdevCode: 10) != .leftArrow, "the 9 key is not Left")
        #expect(KeyCode(linuxEvdevCode: 11) != .rightArrow, "the 0 key is not Right")
    }

    @Test func lettersAreNotNavigationKeys() {
        #expect(KeyCode(linuxEvdevCode: 16) != .pageUp, "q is not Page Up")
        #expect(KeyCode(linuxEvdevCode: 17) != .pageDown, "w is not Page Down")
    }

    /// An unmapped code resolves to nothing rather than to whatever constant
    /// happens to share its number. `characters` still carries the text.
    @Test func anUnmappedCodeIsUnknown() {
        #expect(KeyCode(linuxEvdevCode: 60000) == .unknown)
    }

    @Test func namedConstantsAreDistinct() {
        let named: [KeyCode] = [
            .escape, .return, .tab, .space, .delete, .forwardDelete, .insert,
            .leftArrow, .rightArrow, .upArrow, .downArrow,
            .home, .end, .pageUp, .pageDown,
            .letterA, .letterQ, .letterW, .letterZ,
            .digit0, .digit1, .digit9,
            .f1, .f12, .minus, .equal,
        ]
        #expect(Set(named).count == named.count, "two names must never share a value")
        #expect(!named.contains(.unknown))
    }

    // MARK: - Control keys still map

    @Test func controlKeysMapAsBefore() {
        #expect(KeyCode(linuxEvdevCode: 1) == .escape)
        #expect(KeyCode(linuxEvdevCode: 14) == .delete, "backspace is delete")
        #expect(KeyCode(linuxEvdevCode: 15) == .tab)
        #expect(KeyCode(linuxEvdevCode: 28) == .return)
        #expect(KeyCode(linuxEvdevCode: 96) == .return, "keypad enter")
        #expect(KeyCode(linuxEvdevCode: 57) == .space)
        #expect(KeyCode(linuxEvdevCode: 111) == .forwardDelete)
    }

    @Test func navigationKeysMap() {
        #expect(KeyCode(linuxEvdevCode: 102) == .home)
        #expect(KeyCode(linuxEvdevCode: 103) == .upArrow)
        #expect(KeyCode(linuxEvdevCode: 104) == .pageUp)
        #expect(KeyCode(linuxEvdevCode: 105) == .leftArrow)
        #expect(KeyCode(linuxEvdevCode: 106) == .rightArrow)
        #expect(KeyCode(linuxEvdevCode: 107) == .end)
        #expect(KeyCode(linuxEvdevCode: 108) == .downArrow)
        #expect(KeyCode(linuxEvdevCode: 109) == .pageDown)
        #expect(KeyCode(linuxEvdevCode: 110) == .insert)
    }

    // MARK: - Letters, digits, function keys

    @Test func everyLetterMaps() {
        // evdev letter rows are not alphabetical, which is why the mapping is a
        // table rather than arithmetic.
        let rows: [(UInt32, KeyCode)] = [
            (16, .letterQ), (18, .letterE), (25, .letterP),
            (30, .letterA), (38, .letterL),
            (44, .letterZ), (50, .letterM),
        ]
        for (code, key) in rows {
            #expect(KeyCode(linuxEvdevCode: code) == key)
        }
    }

    @Test func everyDigitMaps() {
        for (index, code) in (UInt32(2)...UInt32(10)).enumerated() {
            #expect(KeyCode(linuxEvdevCode: code) == KeyCode.digit(index + 1))
        }
        #expect(KeyCode(linuxEvdevCode: 11) == .digit0, "0 sits after 9 on the row")
    }

    @Test func functionKeysMap() {
        #expect(KeyCode(linuxEvdevCode: 59) == .f1)
        #expect(KeyCode(linuxEvdevCode: 68) == .f10)
        // F11 and F12 are not contiguous with F1–F10 in evdev.
        #expect(KeyCode(linuxEvdevCode: 87) == .f11)
        #expect(KeyCode(linuxEvdevCode: 88) == .f12)
    }

    @Test func digitHelperRejectsOutOfRange() {
        #expect(KeyCode.digit(0) == .digit0)
        #expect(KeyCode.digit(9) == .digit9)
        #expect(KeyCode.digit(10) == .unknown)
        #expect(KeyCode.digit(-1) == .unknown)
    }
}

/// A text field must insert the character a key produced, not act on a control
/// key that happened to share its platform code.
@MainActor
@Suite struct TextFieldDigitEntryTests {
    private func makeField() -> TextField {
        let field = TextField()
        field.frame = Rect(x: 0, y: 0, width: 200, height: 24)
        return field
    }

    private func type(_ field: TextField, evdev: UInt32, characters: String) {
        var event = Event(type: .keyDown, location: .zero, timestampNanoseconds: 0)
        event.keyCode = KeyCode(linuxEvdevCode: evdev)
        event.characters = characters
        _ = field.handleEvent(event)
    }

    /// Typing a digit used to submit the field, move the caret, or insert a tab,
    /// depending on the digit — because the digit row resolved to control keys.
    @Test func digitsAreTypedRatherThanActedOn() {
        let field = makeField()
        var submitted = false
        field.onSubmit = { _ in submitted = true }

        // "1234567890" across the whole digit row.
        let row: [(UInt32, String)] = [
            (2, "1"), (3, "2"), (4, "3"), (5, "4"), (6, "5"),
            (7, "6"), (8, "7"), (9, "8"), (10, "9"), (11, "0"),
        ]
        for (code, character) in row { type(field, evdev: code, characters: character) }

        #expect(field.stringValue == "1234567890")
        #expect(!submitted, "no digit is Return")
    }

    @Test func lettersAreTypedRatherThanActedOn() {
        let field = makeField()
        type(field, evdev: 16, characters: "q")
        type(field, evdev: 17, characters: "w")
        #expect(field.stringValue == "qw")
    }

    /// The control keys must keep working, which is the other half of the
    /// contract.
    @Test func controlKeysStillAct() {
        let field = makeField()
        var submitted = false
        field.onSubmit = { _ in submitted = true }

        type(field, evdev: 2, characters: "1")
        type(field, evdev: 14, characters: "")   // backspace
        #expect(field.stringValue == "")

        type(field, evdev: 28, characters: "")   // return
        #expect(submitted)
    }
}
