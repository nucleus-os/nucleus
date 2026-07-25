import Foundation
import Testing
@testable import WaylandProtocolModel

@Suite
struct WaylandProtocolModelTests {
    @Test
    func parsesCompleteSemanticModel() throws {
        let xml = """
            <protocol name="fixture">
              <interface name="fixture_manager_v1" version="3">
                <description summary="manager">
                  Creates fixture objects.
                </description>
                <request name="create" since="2">
                  <description summary="create one">Creates a child.</description>
                  <arg name="id" type="new_id" interface="fixture_child_v1"/>
                  <arg name="mode" type="uint" enum="mode" summary="creation mode"/>
                  <arg name="label" type="string" allow-null="true"/>
                </request>
                <event name="ready" since="3">
                  <arg name="flags" type="uint" enum="flags"/>
                </event>
                <enum name="mode">
                  <entry name="normal" value="0" summary="normal mode"/>
                  <entry name="fast" value="1" since="2" deprecated-since="3"/>
                </enum>
                <enum name="flags" bitfield="true">
                  <entry name="active" value="0x1"/>
                </enum>
              </interface>
              <interface name="fixture_child_v1" version="1">
                <request name="destroy" type="destructor"/>
              </interface>
            </protocol>
            """

        let document = try WaylandProtocolParser.parse(
            data: Data(xml.utf8),
            path: "fixture.xml")

        #expect(document.name == "fixture")
        #expect(document.xmlPath == "fixture.xml")
        #expect(document.definedInterfaces == [
            "fixture_manager_v1", "fixture_child_v1",
        ])
        #expect(document.referencedInterfaces == ["fixture_child_v1"])
        #expect(document.interfaces.count == 2)

        let manager = try #require(document.interfaces.first)
        #expect(manager.name == "fixture_manager_v1")
        #expect(manager.version == 3)
        #expect(manager.description == WaylandDescription(
            summary: "manager",
            body: "Creates fixture objects."))

        let request = try #require(manager.requests.first)
        #expect(request.name == "create")
        #expect(request.since == 2)
        #expect(!request.isDestructor)
        #expect(request.description == WaylandDescription(
            summary: "create one",
            body: "Creates a child."))
        #expect(request.arguments.count == 3)
        #expect(request.arguments[0].interface == "fixture_child_v1")
        #expect(request.arguments[1].enumName == "mode")
        #expect(request.arguments[1].summary == "creation mode")
        #expect(request.arguments[2].allowNull)

        let event = try #require(manager.events.first)
        #expect(event.name == "ready")
        #expect(event.since == 3)

        #expect(manager.enumerations.count == 2)
        #expect(!manager.enumerations[0].isBitfield)
        #expect(manager.enumerations[0].entries[1].since == 2)
        #expect(manager.enumerations[0].entries[1].deprecatedSince == 3)
        #expect(manager.enumerations[1].isBitfield)
        #expect(manager.enumerations[1].entries[0].value == "0x1")

        let child = document.interfaces[1]
        #expect(child.requests.first?.isDestructor == true)
    }

    @Test
    func reportsSemanticParsePath() {
        let xml = """
            <protocol name="fixture">
              <interface name="fixture_v1" version="not-a-version"/>
            </protocol>
            """

        #expect(throws: WaylandProtocolParseError.self) {
            _ = try WaylandProtocolParser.parse(
                data: Data(xml.utf8),
                path: "broken.xml")
        }
    }

    @Test
    func rejectsArgumentsOutsideMessages() {
        let xml = """
            <protocol name="fixture">
              <interface name="fixture_v1" version="1">
                <arg name="orphan" type="uint"/>
              </interface>
            </protocol>
            """

        #expect(throws: WaylandProtocolParseError.self) {
            _ = try WaylandProtocolParser.parse(
                data: Data(xml.utf8),
                path: "orphan.xml")
        }
    }
}
