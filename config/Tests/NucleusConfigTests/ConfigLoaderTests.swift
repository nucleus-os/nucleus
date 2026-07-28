import Testing
@testable import NucleusConfig
@testable import NucleusConfigIO
import NucleusConfigSyntax

@Suite struct ConfigLoaderTests {
    private func loaded(
        _ text: String, sourceLocation: Testing.SourceLocation = #_sourceLocation
    ) throws -> (NucleusConfiguration, [ConfigDiagnostic]) {
        switch ConfigLoader.load(text: text) {
        case .loaded(let configuration, let warnings):
            return (configuration, warnings)
        case .failed(let diagnostics):
            let summaries = diagnostics.map(\.summary).joined(separator: "; ")
            Issue.record(
                "expected success, got: \(summaries)",
                sourceLocation: sourceLocation)
            throw CancellationError()
        }
    }

    private func failure(
        _ text: String, sourceLocation: Testing.SourceLocation = #_sourceLocation
    ) throws -> [ConfigDiagnostic] {
        switch ConfigLoader.load(text: text) {
        case .loaded(let configuration, _):
            Issue.record(
                "expected failure, got \(configuration)",
                sourceLocation: sourceLocation)
            throw CancellationError()
        case .failed(let diagnostics):
            return diagnostics
        }
    }

    // MARK: resolution

    @Test func anEmptyObjectResolvesToTheBuiltInDefaults() throws {
        let (configuration, warnings) = try loaded("{}")
        #expect(configuration == NucleusConfiguration.defaults)
        #expect(warnings.isEmpty)
    }

    @Test func aPartialFileLeavesEverythingElseAtItsDefault() throws {
        let (configuration, _) = try loaded(#"""
        { "input": { "touchpad": { "accel_speed": 0.4 } } }
        """#)
        #expect(configuration.input.touchpad.accelSpeed == 0.4)
        // Untouched siblings, and untouched device classes, keep defaults.
        #expect(configuration.input.touchpad.tap
            == TouchpadConfig.defaults.tap)
        #expect(configuration.input.mouse == PointerConfig.mouseDefaults)
        #expect(configuration.input.keyboard == KeyboardConfig.defaults)
    }

    @Test func snakeCaseKeysMapOntoTheModel() throws {
        let (configuration, warnings) = try loaded(#"""
        {
          "input": {
            "touchpad": {
              "natural_scroll": false,
              "tap_button_map": "left-middle-right",
              "disable_while_typing": false
            },
            "keyboard": { "repeat_rate": 40, "repeat_delay": 300 }
          }
        }
        """#)
        #expect(warnings.isEmpty)
        #expect(configuration.input.touchpad.naturalScroll == false)
        #expect(configuration.input.touchpad.tapButtonMap == .leftMiddleRight)
        #expect(configuration.input.touchpad.disableWhileTyping == false)
        #expect(configuration.input.keyboard.repeatRate == 40)
        #expect(configuration.input.keyboard.repeatDelay == 300)
    }

    @Test func perDeviceClassSettingsStayIndependent() throws {
        let (configuration, _) = try loaded(#"""
        {
          "input": {
            "mouse": { "natural_scroll": true },
            "trackball": { "accel_speed": -0.3 }
          }
        }
        """#)
        #expect(configuration.input.mouse.naturalScroll == true)
        #expect(configuration.input.trackball.accelSpeed == -0.3)
        // Setting the mouse must not disturb the trackball, or vice versa.
        #expect(configuration.input.trackball.naturalScroll
            == PointerConfig.trackballDefaults.naturalScroll)
        #expect(configuration.input.mouse.accelSpeed
            == PointerConfig.mouseDefaults.accelSpeed)
    }

    @Test func nestedXkbSettingsResolveIndependently() throws {
        let (configuration, _) = try loaded(#"""
        { "input": { "keyboard": { "xkb": { "layout": "us,de" } } } }
        """#)
        #expect(configuration.input.keyboard.xkb.layout == "us,de")
        #expect(configuration.input.keyboard.xkb.options == "")
        #expect(configuration.input.keyboard.repeatRate
            == KeyboardConfig.defaults.repeatRate)
    }

    // MARK: comments

    @Test func commentsAreAcceptedAndDoNotAffectValues() throws {
        let (configuration, warnings) = try loaded("""
        {
          // pointer behavior
          "input": {
            "touchpad": {
              /* two-finger scrolling reads as natural on a trackpad */
              "natural_scroll": true,
              "accel_speed": 0.25 // slightly quicker than stock
            }
          }
        }
        """)
        #expect(warnings.isEmpty)
        #expect(configuration.input.touchpad.naturalScroll == true)
        #expect(configuration.input.touchpad.accelSpeed == 0.25)
    }

    // MARK: semantic diagnostics

    @Test func aWronglyTypedValueNamesTheSettingThatIsWrong() throws {
        let diagnostics = try failure(#"""
        { "input": { "touchpad": { "accel_speed": "fast" } } }
        """#)
        let diagnostic = try #require(diagnostics.first)
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.keyPath == ["input", "touchpad", "accel_speed"])
        #expect(diagnostic.summary.contains("input.touchpad.accel_speed"))
    }

    @Test func anInvalidEnumeratedValueNamesTheSetting() throws {
        let diagnostics = try failure(#"""
        { "input": { "touchpad": { "accel_profile": "quadratic" } } }
        """#)
        let diagnostic = try #require(diagnostics.first)
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.keyPath == ["input", "touchpad", "accel_profile"])
    }

    // MARK: unknown keys

    @Test func anUnknownKeyWarnsButStillYieldsAUsableConfiguration() throws {
        let (configuration, warnings) = try loaded(#"""
        { "input": { "touchpad": { "tap": false, "tabb": true } } }
        """#)
        // The valid sibling still applied — a typo must not cost the whole file.
        #expect(configuration.input.touchpad.tap == false)
        let warning = try #require(warnings.first)
        #expect(warning.severity == .warning)
        #expect(warning.keyPath == ["input", "touchpad", "tabb"])
    }

    @Test func anUnknownTopLevelSectionWarns() throws {
        let (_, warnings) = try loaded(#"{ "outupt": {} }"#)
        #expect(warnings.count == 1)
        #expect(warnings.first?.keyPath == ["outupt"])
    }

    @Test func knownKeysProduceNoWarnings() throws {
        let (_, warnings) = try loaded(#"""
        {
          "config_version": 1,
          "input": {
            "touchpad": { "tap": true, "click_method": "button-areas" },
            "trackpoint": { "scroll_method": "on-button-down" },
            "touch": { "map_to_output": "DP-1" }
          }
        }
        """#)
        #expect(warnings.isEmpty)
    }

    // MARK: structural diagnostics

    @Test func aStructuralDefectFailsTheLoadWithALocation() throws {
        let diagnostics = try failure("""
        {
          "input": {
            "touchpad": { "tap": true }
        }
        """)
        let diagnostic = try #require(diagnostics.first)
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.location?.line == 1)
        #expect(diagnostic.excerpt?.contains("^") == true)
    }

    @Test func aForgottenQuoteFailsAtTheOpeningQuote() throws {
        let diagnostics = try failure("""
        {
          "input": "unclosed
        }
        """)
        let diagnostic = try #require(diagnostics.first)
        #expect(diagnostic.location?.line == 2)
        #expect(diagnostic.message.contains("unterminated string"))
    }

    // MARK: versioning

    @Test func aNewerConfigVersionWarnsWithoutFailing() throws {
        let (configuration, warnings) = try loaded(#"""
        { "config_version": 99, "input": { "touchpad": { "tap": false } } }
        """#)
        #expect(configuration.input.touchpad.tap == false)
        let warning = try #require(warnings.first)
        #expect(warning.severity == .warning)
        #expect(warning.keyPath == ["config_version"])
    }

    @Test func theCurrentVersionIsAcceptedSilently() throws {
        let (_, warnings) = try loaded(#"{ "config_version": 1 }"#)
        #expect(warnings.isEmpty)
    }

    // MARK: export round trip

    @Test func resolvedDefaultsSurviveAnExportAndReload() throws {
        let exported = try ConfigExport.json(NucleusConfiguration.defaults)
        let (configuration, warnings) = try loaded(exported)
        #expect(configuration == NucleusConfiguration.defaults)
        #expect(warnings.isEmpty)
    }
}
