import NucleusCompositorOverlay
import NucleusConfig
import Testing
@testable import NucleusCompositorShell

// The shortcut overlay is derived from the live binding table. These pin the
// derivation, because the failure mode it replaced — a hand-written list that
// confidently showed shortcuts nobody was bound to — is silent.
@Suite @MainActor struct HotkeyOverlayEntriesTests {
    private func rows(_ binds: [KeyBind]) -> [ShellOverlayHotkeyEntry] {
        HotkeyOverlayEntries.rows(for: binds)
    }

    private func bind(_ keys: String, _ action: BindAction) throws -> KeyBind {
        KeyBind(keys: try KeyChord.parse(keys), action: action)
    }

    // MARK: derivation

    @Test func aBindRendersItsOwnChordText() throws {
        let entries = rows([try bind("Super+Shift+M", .showWindowMenu)])
        #expect(entries.count == 1)
        #expect(entries.first?.key == "Super+Shift+M")
        #expect(entries.first?.description == "Window menu")
    }

    @Test func rebindingAKeyChangesWhatTheOverlayShows() throws {
        // The whole point: the overlay cannot disagree with the table.
        let before = rows([try bind("Super+Q", .closeWindow)])
        let after = rows([try bind("Ctrl+Shift+W", .closeWindow)])
        #expect(before.first?.key == "Super+Q")
        #expect(after.first?.key == "Ctrl+Shift+W")
        #expect(before.first?.description == after.first?.description)
    }

    @Test func anEmptyTableRendersNoRows() {
        #expect(rows([]).isEmpty)
    }

    @Test func everyActionHasADescription() throws {
        let actions: [BindAction] = [
            .closeWindow, .showWindowMenu, .toggleHotkeyOverlay,
            .dismissHotkeyOverlay, .tile(.left), .tile(.maximize),
            .adjustBackdropIntensity(0.2), .activateWorkspace(3),
            .moveWindowToWorkspace(3),
            .launch(appIDs: ["kitty.desktop"], command: ["kitty"]),
        ]
        for action in actions {
            let description = HotkeyOverlayEntries.describe(action)
            #expect(!description.isEmpty, "\(action) has no description")
        }
    }

    @Test func parameterizedActionsNameTheirParameter() {
        #expect(HotkeyOverlayEntries.describe(.activateWorkspace(4))
            == "Switch to workspace 4")
        #expect(HotkeyOverlayEntries.describe(.tile(.bottomRight))
            == "Tile bottom right")
        // Direction is the only thing distinguishing these two rows.
        #expect(HotkeyOverlayEntries.describe(.adjustBackdropIntensity(-0.2))
            == "Dim backdrop")
        #expect(HotkeyOverlayEntries.describe(.adjustBackdropIntensity(0.2))
            == "Brighten backdrop")
    }

    // MARK: launch naming

    @Test func launchIsNamedByItsDesktopEntry() {
        #expect(HotkeyOverlayEntries.launchName(
            appIDs: ["kitty.desktop"], command: ["kitty"]) == "Kitty")
        // Reverse-DNS identifiers reduce to their last component.
        #expect(HotkeyOverlayEntries.launchName(
            appIDs: ["org.wezfurlong.wezterm.desktop"], command: [])
            == "Wezterm")
    }

    @Test func launchFallsBackToTheCommandWithoutADesktopEntry() {
        #expect(HotkeyOverlayEntries.launchName(
            appIDs: [], command: ["foot"]) == "Foot")
    }

    @Test func launchWithNothingUsableStillNamesSomething() {
        // Decoding rejects this combination, but the renderer must not be the
        // thing that falls over if it ever arrives.
        #expect(!HotkeyOverlayEntries.launchName(
            appIDs: [], command: []).isEmpty)
    }

    // MARK: grouping

    @Test func relatedShortcutsAreGroupedRegardlessOfFileOrder() throws {
        let entries = rows([
            try bind("Super+1", .activateWorkspace(1)),
            try bind("Super+T", .launch(appIDs: [], command: ["kitty"])),
            try bind("Super+2", .activateWorkspace(2)),
            try bind("Super+Q", .closeWindow),
        ])
        let keys = entries.map(\.key)
        // Applications, then window, then workspaces — with separators between.
        #expect(keys.first == "Super+T")
        let workspaceOne = try #require(keys.firstIndex(of: "Super+1"))
        let workspaceTwo = try #require(keys.firstIndex(of: "Super+2"))
        #expect(workspaceTwo == workspaceOne + 1)
        let close = try #require(keys.firstIndex(of: "Super+Q"))
        #expect(close < workspaceOne)
    }

    @Test func separatorsAppearBetweenGroupsAndNeverAtTheEdges() throws {
        let entries = rows([
            try bind("Super+T", .launch(appIDs: [], command: ["kitty"])),
            try bind("Super+Q", .closeWindow),
        ])
        #expect(entries.first?.key.isEmpty == false)
        #expect(entries.last?.key.isEmpty == false)
        #expect(entries.filter { $0.key.isEmpty }.count == 1)
    }

    @Test func aSingleGroupGetsNoSeparators() throws {
        let entries = rows([
            try bind("Super+Q", .closeWindow),
            try bind("Super+Shift+M", .showWindowMenu),
        ])
        #expect(entries.allSatisfy { !$0.key.isEmpty })
    }

    // MARK: footer

    @Test func theFooterNamesWhateverChordDismissesTheOverlay() throws {
        // It used to say "Press Esc" unconditionally — correct only by
        // coincidence, and wrong the moment anyone rebound it.
        let footer = HotkeyOverlayEntries.footer(for: [
            try bind("Ctrl+Shift+Escape", .dismissHotkeyOverlay),
        ])
        #expect(footer.contains("Ctrl+Shift+Escape"))
        #expect(!footer.contains("Esc or"))
    }

    @Test func theFooterFallsBackWhenNothingDismissesTheOverlay() throws {
        // Now that the table is data, unbinding dismissal is possible, and
        // naming a key that does nothing is the failure being avoided.
        let footer = HotkeyOverlayEntries.footer(for: [
            try bind("Super+Q", .closeWindow),
        ])
        #expect(footer == "Click outside controls to dismiss")
    }

    @Test func theDefaultTableFooterMatchesItsDismissBind() throws {
        let footer = HotkeyOverlayEntries.footer(for: DefaultBinds.table)
        let dismiss = DefaultBinds.table.first {
            if case .dismissHotkeyOverlay = $0.action { return true }
            return false
        }
        let chord = try #require(dismiss).keys.text
        #expect(footer.contains(chord))
    }

    @Test func contentCarriesRowsAndFooterTogether() throws {
        let content = HotkeyOverlayEntries.content(for: [
            try bind("Super+Q", .closeWindow),
            try bind("F1", .dismissHotkeyOverlay),
        ])
        #expect(content.entries.contains { $0.key == "Super+Q" })
        #expect(content.footer.contains("F1"))
    }

    // MARK: the default table

    @Test func theDefaultTableRendersEveryBindPlusSeparators() {
        let entries = rows(DefaultBinds.table)
        let shortcuts = entries.filter { !$0.key.isEmpty }
        #expect(shortcuts.count == DefaultBinds.table.count)
        #expect(entries.count > shortcuts.count, "expected group separators")
    }

    @Test func theDefaultTableNoLongerAdvertisesARetiredScreenshotBind() {
        // The list this replaced still showed "Super + P — Screenshot", long
        // after the compositor stopped binding a screenshot key.
        let entries = rows(DefaultBinds.table)
        #expect(!entries.contains { $0.description.contains("Screenshot") })
    }

    @Test func theDefaultTableShowsWorkspaceBindsItPreviouslyOmitted() {
        let entries = rows(DefaultBinds.table)
        #expect(entries.contains { $0.description == "Switch to workspace 1" })
        #expect(entries.contains {
            $0.description == "Move window to workspace 9"
        })
    }
}
