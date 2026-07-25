import Foundation
import Testing
import WaylandProtocolModel
@testable import SwiftWaylandGenerator

@Suite
struct SwiftWaylandGeneratorTests {
    @Test
    func validatesResolvedEnumsAndTypedNewIds() throws {
        let document = try parse(
            """
            <protocol name="fixture">
              <interface name="fixture_manager_v1" version="1">
                <request name="create">
                  <arg name="id" type="new_id" interface="fixture_child_v1"/>
                  <arg name="mode" type="uint" enum="mode"/>
                </request>
                <enum name="mode">
                  <entry name="normal" value="0"/>
                  <entry name="fast" value="0x1"/>
                </enum>
              </interface>
              <interface name="fixture_child_v1" version="1">
                <request name="destroy" type="destructor"/>
              </interface>
            </protocol>
            """)

        try SwiftWaylandGenerator.validate(protocols: [document])
    }

    @Test
    func acceptsOneEnumAcrossSignedAndUnsignedWireArguments() throws {
        let document = try parse(
            """
            <protocol name="fixture">
              <interface name="fixture_v1" version="1">
                <request name="set_mode">
                  <arg name="mode" type="int" enum="mode"/>
                </request>
                <event name="mode">
                  <arg name="mode" type="uint" enum="mode"/>
                </event>
                <enum name="mode">
                  <entry name="normal" value="0"/>
                </enum>
              </interface>
            </protocol>
            """)

        try SwiftWaylandGenerator.validate(protocols: [document])
    }

    @Test
    func rejectsUnresolvedEnumWithSemanticPath() throws {
        let document = try parse(
            """
            <protocol name="fixture">
              <interface name="fixture_v1" version="1">
                <request name="set_mode">
                  <arg name="mode" type="uint" enum="missing"/>
                </request>
              </interface>
            </protocol>
            """)

        do {
            try SwiftWaylandGenerator.validate(protocols: [document])
            Issue.record("expected validation failure")
        } catch let diagnostic as WaylandGeneratorDiagnostic {
            #expect(diagnostic.context == "fixture_v1.set_mode.mode")
            #expect(diagnostic.problem.contains("unresolved enum"))
        }
    }

    @Test
    func rejectsUntypedNewIdOutsideRegistryBootstrap() throws {
        let document = try parse(
            """
            <protocol name="fixture">
              <interface name="fixture_v1" version="1">
                <request name="bind">
                  <arg name="id" type="new_id"/>
                </request>
              </interface>
            </protocol>
            """)

        #expect(throws: WaylandGeneratorDiagnostic.self) {
            try SwiftWaylandGenerator.validate(protocols: [document])
        }
    }

    @Test
    func rejectsUnsupportedEnumExpressions() throws {
        let document = try parse(
            """
            <protocol name="fixture">
              <interface name="fixture_v1" version="1">
                <enum name="flags" bitfield="true">
                  <entry name="bad" value="1 &lt;&lt; 2"/>
                </enum>
              </interface>
            </protocol>
            """)

        #expect(throws: WaylandGeneratorDiagnostic.self) {
            try SwiftWaylandGenerator.validate(protocols: [document])
        }
    }

    private func parse(_ xml: String) throws -> WaylandProtocol {
        try WaylandProtocolParser.parse(
            data: Data(xml.utf8),
            path: "fixture.xml")
    }
}
