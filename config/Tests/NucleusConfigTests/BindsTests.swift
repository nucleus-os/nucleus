import Testing
@testable import NucleusConfig
@testable import NucleusConfigIO

@Suite struct KeyChordTests {
    // MARK: parsing

    @Test func parsesAModifierAndKey() throws {
        let chord = try KeyChord.parse("Super+Q")
        #expect(chord.modifiers == .superKey)
        #expect(chord.keyCode == 16)
    }

    @Test func parsesMultipleModifiersInAnyOrder() throws {
        let a = try KeyChord.parse("Ctrl+Alt+Left")
        let b = try KeyChord.parse("Alt+Ctrl+Left")
        #expect(a == b)
        #expect(a.modifiers == [.control, .alt])
        #expect(a.keyCode == 105)
    }

    @Test func parsesABareKeyWithNoModifiers() throws {
        let chord = try KeyChord.parse("Escape")
        #expect(chord.modifiers.isEmpty)
        #expect(chord.keyCode == 1)
    }

    @Test func isCaseInsensitiveAndTolerantOfSpacing() throws {
        let expected = try KeyChord.parse("Super+Shift+M")
        #expect(try KeyChord.parse("super+shift+m") == expected)
        #expect(try KeyChord.parse("SUPER + SHIFT + M") == expected)
    }

    @Test func acceptsModifierAliases() throws {
        let expected = try KeyChord.parse("Super+Q")
        for alias in ["Mod", "Logo", "Meta", "Cmd", "Command", "Win"] {
            #expect(try KeyChord.parse("\(alias)+Q") == expected)
        }
        let control = try KeyChord.parse("Ctrl+Q")
        #expect(try KeyChord.parse("Control+Q") == control)
        let alt = try KeyChord.parse("Alt+Q")
        #expect(try KeyChord.parse("Option+Q") == alt)
        #expect(try KeyChord.parse("Mod1+Q") == alt)
    }

    @Test func acceptsKeyAliases() throws {
        #expect(try KeyChord.parse("Enter").keyCode
            == KeyChord.parse("Return").keyCode)
        #expect(try KeyChord.parse("Esc").keyCode
            == KeyChord.parse("Escape").keyCode)
        #expect(try KeyChord.parse("PgUp").keyCode
            == KeyChord.parse("PageUp").keyCode)
    }

    // MARK: the evdev mapping

    @Test func digitsFollowEvdevNumbering() throws {
        // KEY_1…KEY_9 are 2…10 and KEY_0 is 11 — not 1, and not contiguous
        // with the rest. Getting this wrong silently binds the wrong key.
        #expect(try KeyChord.parse("1").keyCode == 2)
        #expect(try KeyChord.parse("9").keyCode == 10)
        #expect(try KeyChord.parse("0").keyCode == 11)
    }

    @Test func functionKeysSpanTheirThreeSeparateRuns() throws {
        #expect(try KeyChord.parse("F1").keyCode == 59)
        #expect(try KeyChord.parse("F10").keyCode == 68)
        // F11/F12 sit apart from F1–F10.
        #expect(try KeyChord.parse("F11").keyCode == 87)
        #expect(try KeyChord.parse("F12").keyCode == 88)
        // F13+ start another run entirely.
        #expect(try KeyChord.parse("F13").keyCode == 183)
        #expect(try KeyChord.parse("F24").keyCode == 194)
    }

    @Test func printScreenMapsToSysRqNotToKeyPrint() throws {
        // The physical PrtSc key emits KEY_SYSRQ (99); KEY_PRINT (210) is a
        // different key that most keyboards do not have.
        #expect(try KeyChord.parse("Print").keyCode == 99)
        #expect(try KeyChord.parse("PrintScreen").keyCode == 99)
    }

    @Test func mediaKeysAreBindable() throws {
        #expect(try KeyChord.parse("VolumeUp").keyCode == 115)
        #expect(try KeyChord.parse("Mute").keyCode == 113)
        #expect(try KeyChord.parse("PlayPause").keyCode == 164)
        #expect(try KeyChord.parse("BrightnessUp").keyCode == 225)
    }

    // MARK: errors

    @Test func rejectsAnUnknownModifier() {
        #expect(throws: KeyChord.ParseError.unknownModifier("Hyper")) {
            try KeyChord.parse("Hyper+Q")
        }
    }

    @Test func rejectsAnUnknownKey() {
        #expect(throws: KeyChord.ParseError.unknownKey("Frobnicate")) {
            try KeyChord.parse("Super+Frobnicate")
        }
    }

    @Test func rejectsAnEmptyOrDanglingCombination() {
        #expect(throws: KeyChord.ParseError.empty) { try KeyChord.parse("") }
        #expect(throws: KeyChord.ParseError.missingKey) {
            try KeyChord.parse("Super+")
        }
    }

    // MARK: round trip

    @Test func canonicalTextRoundTripsThroughParsing() throws {
        for text in [
            "Super+Q", "Ctrl+Alt+Left", "Escape", "Super+Shift+M",
            "Super+Ctrl+Alt+Shift+F5", "VolumeUp", "KP0",
        ] {
            let chord = try KeyChord.parse(text)
            #expect(chord.text == text, "round trip of \(text)")
            #expect(try KeyChord.parse(chord.text) == chord)
        }
    }

    @Test func canonicalTextNormalizesAliasesAndOrder() throws {
        #expect(try KeyChord.parse("shift+ctrl+mod+q").text == "Super+Ctrl+Shift+Q")
        #expect(try KeyChord.parse("Enter").text == "Return")
    }
}

@Suite struct BindDecodingTests {
    private func binds(_ json: String) throws -> [KeyBind] {
        switch ConfigLoader.load(text: json) {
        case .loaded(let configuration, _):
            return configuration.binds
        case .failed(let diagnostics):
            Issue.record("load failed: \(diagnostics.map(\.summary))")
            throw CancellationError()
        }
    }

    private func failure(_ json: String) throws -> ConfigDiagnostic {
        switch ConfigLoader.load(text: json) {
        case .loaded:
            Issue.record("expected a failure")
            throw CancellationError()
        case .failed(let diagnostics):
            return try #require(diagnostics.first)
        }
    }

    // MARK: defaults

    @Test func anAbsentBindsSectionKeepsTheBuiltInTable() throws {
        #expect(try binds("{}") == DefaultBinds.table)
    }

    @Test func aBindsArrayReplacesTheTableOutright() throws {
        // Replacement, not merge: a binding you cannot see in your own file
        // should not still be live.
        let table = try binds(#"""
        { "binds": [ { "keys": "Super+Q", "action": "close-window" } ] }
        """#)
        #expect(table.count == 1)
        #expect(table.first?.action == .closeWindow)
    }

    @Test func anEmptyBindsArrayUnbindsEverything() throws {
        #expect(try binds(#"{ "binds": [] }"#).isEmpty)
    }

    // MARK: each action shape

    @Test func decodesParameterlessActions() throws {
        let table = try binds(#"""
        { "binds": [
            { "keys": "Super+Q", "action": "close-window" },
            { "keys": "Super+Shift+M", "action": "show-window-menu" },
            { "keys": "Super+Slash", "action": "toggle-hotkey-overlay" },
            { "keys": "Escape", "action": "dismiss-hotkey-overlay" }
        ] }
        """#)
        #expect(table.map(\.action) == [
            .closeWindow, .showWindowMenu,
            .toggleHotkeyOverlay, .dismissHotkeyOverlay,
        ])
    }

    @Test func decodesParameterizedActions() throws {
        let table = try binds(#"""
        { "binds": [
            { "keys": "Ctrl+Alt+Left", "action": "tile", "direction": "left" },
            { "keys": "Ctrl+Alt+U", "action": "tile", "direction": "top-left" },
            { "keys": "Super+3", "action": "activate-workspace", "index": 3 },
            { "keys": "Super+Shift+3", "action": "move-window-to-workspace", "index": 3 },
            { "keys": "Super+Alt+Minus", "action": "adjust-backdrop-intensity", "delta": -0.2 }
        ] }
        """#)
        #expect(table.map(\.action) == [
            .tile(.left), .tile(.topLeft),
            .activateWorkspace(3), .moveWindowToWorkspace(3),
            .adjustBackdropIntensity(-0.2),
        ])
    }

    @Test func decodesLaunchWithEitherAppIDsOrACommand() throws {
        let table = try binds(#"""
        { "binds": [
            { "keys": "Super+T", "action": "launch",
              "app_ids": ["kitty.desktop"], "command": ["kitty"] },
            { "keys": "Super+E", "action": "launch", "command": ["nautilus"] },
            { "keys": "Super+B", "action": "launch", "app_ids": ["firefox.desktop"] }
        ] }
        """#)
        #expect(table[0].action
            == .launch(appIDs: ["kitty.desktop"], command: ["kitty"]))
        #expect(table[1].action == .launch(appIDs: [], command: ["nautilus"]))
        #expect(table[2].action
            == .launch(appIDs: ["firefox.desktop"], command: []))
    }

    // MARK: diagnostics

    @Test func anUnparseableChordNamesTheBindThatIsWrong() throws {
        let diagnostic = try failure(#"""
        { "binds": [
            { "keys": "Super+Q", "action": "close-window" },
            { "keys": "Hyper+Q", "action": "close-window" }
        ] }
        """#)
        #expect(diagnostic.severity == .error)
        // The index is what makes this actionable in a long table.
        #expect(diagnostic.keyPath == ["binds", "[1]", "keys"])
        #expect(diagnostic.message.contains("Hyper"))
    }

    @Test func anUnknownActionListsWhatIsAvailable() throws {
        let diagnostic = try failure(#"""
        { "binds": [ { "keys": "Super+Q", "action": "destroy-everything" } ] }
        """#)
        #expect(diagnostic.keyPath == ["binds", "[0]", "action"])
        #expect(diagnostic.message.contains("close-window"))
    }

    @Test func aMissingActionParameterNamesTheParameter() throws {
        let diagnostic = try failure(#"""
        { "binds": [ { "keys": "Ctrl+Alt+Left", "action": "tile" } ] }
        """#)
        #expect(diagnostic.keyPath == ["binds", "[0]", "direction"])
    }

    @Test func aZeroWorkspaceIndexIsRejectedAsAMistake() throws {
        // Indices are 1-based everywhere a user sees them, so 0 is far more
        // likely a mistake than a request for the first workspace.
        let diagnostic = try failure(#"""
        { "binds": [ { "keys": "Super+1", "action": "activate-workspace", "index": 0 } ] }
        """#)
        #expect(diagnostic.keyPath == ["binds", "[0]", "index"])
        #expect(diagnostic.message.contains("1-based"))
    }

    @Test func launchWithNeitherAppIDsNorCommandIsRejected() throws {
        let diagnostic = try failure(#"""
        { "binds": [ { "keys": "Super+T", "action": "launch" } ] }
        """#)
        #expect(diagnostic.keyPath == ["binds", "[0]"])
        #expect(diagnostic.message.contains("app_ids"))
    }

    // MARK: unknown-key auditing across a tagged union

    @Test func parametersOfEveryActionShapeAuditAsKnown() throws {
        // The auditor compares against the union of the default table's
        // elements, not the first one. A single exemplar would flag
        // `direction` as unknown merely because the first default is a launch.
        switch ConfigLoader.load(text: #"""
        { "binds": [
            { "keys": "Ctrl+Alt+Left", "action": "tile", "direction": "left" },
            { "keys": "Super+2", "action": "activate-workspace", "index": 2 },
            { "keys": "Super+T", "action": "launch", "command": ["kitty"] },
            { "keys": "Super+Alt+Minus", "action": "adjust-backdrop-intensity", "delta": 0.2 }
        ] }
        """#) {
        case .loaded(_, let warnings):
            #expect(warnings.isEmpty, "\(warnings.map(\.summary))")
        case .failed(let diagnostics):
            Issue.record("load failed: \(diagnostics.map(\.summary))")
        }
    }

    @Test func aMisspelledBindParameterStillWarns() throws {
        switch ConfigLoader.load(text: #"""
        { "binds": [
            { "keys": "Ctrl+Alt+Left", "action": "tile", "direction": "left",
              "durection": "left" }
        ] }
        """#) {
        case .loaded(_, let warnings):
            #expect(warnings.count == 1)
            #expect(warnings.first?.keyPath == ["binds", "[0]", "durection"])
        case .failed(let diagnostics):
            Issue.record("load failed: \(diagnostics.map(\.summary))")
        }
    }

    // MARK: export

    @Test func theDefaultTableSurvivesAnExportAndReload() throws {
        let exported = try ConfigExport.json(NucleusConfiguration.defaults)
        #expect(try binds(exported) == DefaultBinds.table)
    }
}

@Suite struct OutputConfigTests {
    private func outputs(_ json: String) throws -> [OutputConfig] {
        switch ConfigLoader.load(text: json) {
        case .loaded(let configuration, _): return configuration.outputs
        case .failed(let diagnostics):
            Issue.record("load failed: \(diagnostics.map(\.summary))")
            throw CancellationError()
        }
    }

    @Test func noOutputsSectionMeansNoOverrides() throws {
        #expect(try outputs("{}").isEmpty)
    }

    @Test func anEntryCarriesScaleAndPosition() throws {
        let table = try outputs(#"""
        { "outputs": [
            { "name": "DP-1", "scale": 1.5,
              "position": { "x": 0, "y": 0 } },
            { "name": "HDMI-A-1", "scale": 1.0,
              "position": { "x": 2560, "y": 0 } }
        ] }
        """#)
        #expect(table.count == 2)
        #expect(table.entry(named: "DP-1")?.scale == 1.5)
        #expect(table.entry(named: "HDMI-A-1")?.position?.x == 2560)
    }

    @Test func absentFieldsStayAbsentRatherThanDefaulting() throws {
        // A missing scale means "session default" and a missing position means
        // "place automatically" — both are real states, not missing values.
        let table = try outputs(#"{ "outputs": [ { "name": "DP-1" } ] }"#)
        #expect(table.first?.scale == nil)
        #expect(table.first?.position == nil)
    }

    @Test func lookupIsByConnectorName() throws {
        let table = try outputs(#"""
        { "outputs": [ { "name": "DP-2", "scale": 2.0 } ] }
        """#)
        #expect(table.entry(named: "DP-2")?.scale == 2.0)
        #expect(table.entry(named: "DP-1") == nil)
    }

    @Test func aMisspelledOutputKeyWarnsDespiteTheEmptyDefault() throws {
        // The audit reference carries one exemplar output precisely so an
        // array that ships empty still has its element keys checked.
        switch ConfigLoader.load(text: #"""
        { "outputs": [ { "name": "DP-1", "scail": 1.5 } ] }
        """#) {
        case .loaded(_, let warnings):
            #expect(warnings.count == 1)
            #expect(warnings.first?.keyPath == ["outputs", "[0]", "scail"])
        case .failed(let diagnostics):
            Issue.record("load failed: \(diagnostics.map(\.summary))")
        }
    }

    @Test func aWronglyTypedScaleNamesTheOutputEntry() {
        switch ConfigLoader.load(text: #"""
        { "outputs": [ { "name": "DP-1", "scale": "big" } ] }
        """#) {
        case .loaded:
            Issue.record("expected a failure")
        case .failed(let diagnostics):
            #expect(diagnostics.first?.keyPath == ["outputs", "[0]", "scale"])
        }
    }
}

@Suite struct OutputAdaptiveSyncTests {
    private func outputs(_ json: String) throws -> [OutputConfig] {
        switch ConfigLoader.load(text: json) {
        case .loaded(let configuration, _): return configuration.outputs
        case .failed(let diagnostics):
            Issue.record("load failed: \(diagnostics.map(\.summary))")
            throw CancellationError()
        }
    }

    @Test func adaptiveSyncCanBeTurnedOffPerOutput() throws {
        // The setting exists for the panel that flickers under VRR; a capable
        // connector drives it by default, so `false` is the meaningful value.
        let table = try outputs(#"""
        { "outputs": [ { "name": "DP-1", "adaptive_sync": false } ] }
        """#)
        #expect(table.entry(named: "DP-1")?.adaptiveSync == false)
    }

    @Test func anAbsentAdaptiveSyncPreferenceStaysAbsent() throws {
        // nil means "no preference", distinct from false: it leaves the
        // compositor's own default in place.
        let table = try outputs(#"{ "outputs": [ { "name": "DP-1" } ] }"#)
        #expect(table.first?.adaptiveSync == nil)
    }

    @Test func aMisspelledAdaptiveSyncKeyWarns() {
        switch ConfigLoader.load(text: #"""
        { "outputs": [ { "name": "DP-1", "adaptive_synk": false } ] }
        """#) {
        case .loaded(_, let warnings):
            #expect(warnings.first?.keyPath
                == ["outputs", "[0]", "adaptive_synk"])
        case .failed(let diagnostics):
            Issue.record("load failed: \(diagnostics.map(\.summary))")
        }
    }

    @Test func theAuditReferenceCoversAdaptiveSync() {
        // The unknown-key audit derives valid keys from a reference whose
        // arrays carry one element; a field missing there goes unchecked.
        switch ConfigLoader.load(text: #"""
        { "outputs": [ { "name": "DP-1", "adaptive_sync": true } ] }
        """#) {
        case .loaded(_, let warnings): #expect(warnings.isEmpty)
        case .failed(let d): Issue.record("\(d.map(\.summary))")
        }
    }
}
