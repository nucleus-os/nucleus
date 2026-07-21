import Glibc
import NucleusUI
import Testing
@testable import NucleusLinuxAccessibility

@MainActor
@Suite(.serialized, .uiContext)
/// Shared Linux transport gate. Queue, descriptor, connection, and slot bounds are
/// discrete ownership counts and therefore independent of host performance.
struct AtSPIServiceLiveTests {
    @Test func registrationTreePropertiesAndActionsUseLiveMessages() throws {
        let privateBus = try PrivateAccessibilityBus()
        let environment = ScopedEnvironmentVariable(
            name: "AT_SPI_BUS_ADDRESS",
            value: privateBus.address)
        defer {
            environment.restore()
            privateBus.stop()
        }

        let root = View()
        root.frame = Rect(x: 0, y: 0, width: 300, height: 260)
        let button = Button(title: "Apply")
        button.frame = Rect(x: 10, y: 12, width: 80, height: 30)
        root.addSubview(button)
        let field = TextField(string: "hello")
        field.frame = Rect(x: 10, y: 52, width: 180, height: 30)
        root.addSubview(field)
        var buttonProperties = button.accessibilityProperties
        buttonProperties.relationships[.controls] = [
            field.accessibilityID,
        ]
        button.accessibilityProperties = buttonProperties
        let secureField = TextField(
            string: "swordfish",
            isSecure: true)
        secureField.frame = Rect(
            x: 10, y: 92, width: 180, height: 30)
        root.addSubview(secureField)
        let slider = Slider()
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.step = 0.05
        slider.value = 0.25
        slider.frame = Rect(x: 10, y: 132, width: 180, height: 30)
        root.addSubview(slider)
        let tabs = SegmentedControl(segments: [
            SegmentOption(id: "one", title: "One"),
            SegmentOption(id: "two", title: "Two"),
        ])
        tabs.frame = Rect(x: 10, y: 172, width: 180, height: 30)
        tabs.setSelectedIDs([CollectionItemID("one")])
        root.addSubview(tabs)
        let window = Window(
            title: "Preferences",
            frame: Rect(x: 40, y: 30, width: 300, height: 260))
        window.setContentView(root)
        window.orderFront()
        let scene = WindowScene(inMemoryWindows: [window])

        let adapter = AtSPIService(applicationName: "Settings")
        defer { adapter.close() }
        let bridge = AtSPIBridge(scene: scene, service: adapter)
        adapter.onAction = { [weak bridge] request in
            bridge?.perform(request) ?? false
        }
        _ = bridge.publish()
        try privateBus.waitUntilReady(adapter)
        func liveCall(
            path: String,
            interface: String,
            member: String,
            signature: String? = nil,
            arguments: [String] = []
        ) throws -> BusctlResult {
            try privateBus.call(
                adapter: adapter,
                destination: adapter.applicationBusName,
                path: path,
                interface: interface,
                member: member,
                signature: signature,
                arguments: arguments)
        }

        let registration = try privateBus.registryApplications(
            pumping: adapter)
        #expect(registration.status == 0)
        #expect(registration.standardOutput.contains(
            adapter.applicationBusName))
        #expect(registration.standardOutput.contains(
            AtSPIExportModel.rootPath))

        let windowPath = AtSPIExportModel.path(
            for: window.accessibilityID)
        let rootChildren = try liveCall(
            path: AtSPIExportModel.rootPath,
            interface: AtSPIInterface.accessible,
            member: "GetChildren")
        #expect(rootChildren.status == 0)
        #expect(rootChildren.standardOutput.contains(windowPath))
        let rootChild = try liveCall(
            path: AtSPIExportModel.rootPath,
            interface: AtSPIInterface.accessible,
            member: "GetChildAtIndex",
            signature: "i",
            arguments: ["0"])
        #expect(rootChild.status == 0)
        #expect(rootChild.standardOutput.contains(windowPath))

        let buttonPath = AtSPIExportModel.path(
            for: button.accessibilityID)
        let role = try privateBus.call(
            adapter: adapter,
            destination: adapter.applicationBusName,
            path: buttonPath,
            interface: AtSPIInterface.accessible,
            member: "GetRole")
        #expect(role.status == 0)
        #expect(role.standardOutput == "u 43")

        let name = try privateBus.call(
            adapter: adapter,
            destination: adapter.applicationBusName,
            path: buttonPath,
            interface: "org.freedesktop.DBus.Properties",
            member: "Get",
            signature: "ss",
            arguments: [AtSPIInterface.accessible, "Name"])
        #expect(name.status == 0)
        #expect(name.standardOutput.contains("Apply"))

        let extents = try privateBus.call(
            adapter: adapter,
            destination: adapter.applicationBusName,
            path: buttonPath,
            interface: AtSPIInterface.component,
            member: "GetExtents",
            signature: "u",
            arguments: ["0"])
        #expect(extents.status == 0)
        #expect(extents.standardOutput.contains("50 42 80 30"))

        let state = try liveCall(
            path: buttonPath,
            interface: AtSPIInterface.accessible,
            member: "GetState")
        #expect(state.status == 0)
        #expect(state.standardOutput.hasPrefix("au 2"))
        let relations = try liveCall(
            path: buttonPath,
            interface: AtSPIInterface.accessible,
            member: "GetRelationSet")
        #expect(relations.status == 0)
        #expect(relations.standardOutput.contains(
            AtSPIExportModel.path(for: field.accessibilityID)))
        let interfaces = try liveCall(
            path: buttonPath,
            interface: AtSPIInterface.accessible,
            member: "GetInterfaces")
        #expect(interfaces.status == 0)
        #expect(interfaces.standardOutput.contains(AtSPIInterface.action))
        #expect(interfaces.standardOutput.contains(AtSPIInterface.component))
        let application = try liveCall(
            path: buttonPath,
            interface: AtSPIInterface.accessible,
            member: "GetApplication")
        #expect(application.status == 0)
        #expect(application.standardOutput.contains(
            AtSPIExportModel.rootPath))
        let indexInParent = try liveCall(
            path: buttonPath,
            interface: AtSPIInterface.accessible,
            member: "GetIndexInParent")
        #expect(indexInParent.status == 0)
        #expect(indexInParent.standardOutput == "i 0")

        let contains = try liveCall(
            path: buttonPath,
            interface: AtSPIInterface.component,
            member: "Contains",
            signature: "iiu",
            arguments: ["55", "45", "0"])
        #expect(contains.standardOutput == "b true")
        let position = try liveCall(
            path: buttonPath,
            interface: AtSPIInterface.component,
            member: "GetPosition",
            signature: "u",
            arguments: ["0"])
        #expect(position.standardOutput == "ii 50 42")
        let size = try liveCall(
            path: buttonPath,
            interface: AtSPIInterface.component,
            member: "GetSize")
        #expect(size.standardOutput == "ii 80 30")
        let layer = try liveCall(
            path: buttonPath,
            interface: AtSPIInterface.component,
            member: "GetLayer")
        #expect(layer.standardOutput == "u 3")
        let zOrder = try liveCall(
            path: buttonPath,
            interface: AtSPIInterface.component,
            member: "GetMDIZOrder")
        #expect(zOrder.standardOutput == "n 0")
        let alpha = try liveCall(
            path: buttonPath,
            interface: AtSPIInterface.component,
            member: "GetAlpha")
        #expect(alpha.standardOutput == "d 1")

        var pressCount = 0
        button.onPress { _ in pressCount += 1 }
        let action = try privateBus.call(
            adapter: adapter,
            destination: adapter.applicationBusName,
            path: buttonPath,
            interface: AtSPIInterface.action,
            member: "DoAction",
            signature: "i",
            arguments: ["0"])
        #expect(action.status == 0)
        #expect(action.standardOutput == "b true")
        #expect(pressCount == 1)
        let actions = try liveCall(
            path: buttonPath,
            interface: AtSPIInterface.action,
            member: "GetActions")
        #expect(actions.status == 0)
        #expect(actions.standardOutput.contains("click"))
        let actionName = try liveCall(
            path: buttonPath,
            interface: AtSPIInterface.action,
            member: "GetName",
            signature: "i",
            arguments: ["0"])
        #expect(actionName.standardOutput.contains("click"))
        let invalidAction = try liveCall(
            path: buttonPath,
            interface: AtSPIInterface.action,
            member: "DoAction",
            signature: "i",
            arguments: ["-1"])
        #expect(invalidAction.status != 0)
        #expect(invalidAction.standardError.contains(
            "arguments are invalid"))
        #expect(pressCount == 1)
        let wrongSignature = try liveCall(
            path: buttonPath,
            interface: AtSPIInterface.action,
            member: "DoAction",
            signature: "ii",
            arguments: ["0", "1"])
        #expect(wrongSignature.status != 0)
        #expect(wrongSignature.standardError.contains(
            "arguments are invalid"))
        #expect(pressCount == 1)
        let unclaimedInterface = try liveCall(
            path: buttonPath,
            interface: AtSPIInterface.text,
            member: "GetText",
            signature: "ii",
            arguments: ["0", "-1"])
        #expect(unclaimedInterface.status != 0)
        #expect(unclaimedInterface.standardError.contains(
            "does not implement"))

        let locale = try privateBus.call(
            adapter: adapter,
            destination: adapter.applicationBusName,
            path: AtSPIExportModel.rootPath,
            interface: AtSPIInterface.application,
            member: "GetLocale",
            signature: "u",
            arguments: ["0"])
        #expect(locale.status == 0)
        #expect(!locale.standardOutput.isEmpty)
        let applicationProperties = try liveCall(
            path: AtSPIExportModel.rootPath,
            interface: "org.freedesktop.DBus.Properties",
            member: "GetAll",
            signature: "s",
            arguments: [AtSPIInterface.application])
        #expect(applicationProperties.status == 0)
        #expect(applicationProperties.standardOutput.contains("NucleusUI"))
        let applicationAddress = try liveCall(
            path: AtSPIExportModel.rootPath,
            interface: AtSPIInterface.application,
            member: "GetApplicationBusAddress")
        #expect(applicationAddress.status == 0)
        #expect(applicationAddress.standardOutput.contains(privateBus.address))

        let fieldPath = AtSPIExportModel.path(
            for: field.accessibilityID)
        let text = try privateBus.call(
            adapter: adapter,
            destination: adapter.applicationBusName,
            path: fieldPath,
            interface: AtSPIInterface.text,
            member: "GetText",
            signature: "ii",
            arguments: ["0", "-1"])
        #expect(text.status == 0)
        #expect(text.standardOutput.contains("hello"))

        let setText = try privateBus.call(
            adapter: adapter,
            destination: adapter.applicationBusName,
            path: fieldPath,
            interface: AtSPIInterface.editableText,
            member: "SetTextContents",
            signature: "s",
            arguments: ["replacement"])
        #expect(setText.standardOutput == "b true")
        #expect(field.stringValue == "replacement")
        _ = bridge.publish()
        let textProperties = try liveCall(
            path: fieldPath,
            interface: "org.freedesktop.DBus.Properties",
            member: "GetAll",
            signature: "s",
            arguments: [AtSPIInterface.text])
        #expect(textProperties.status == 0)
        #expect(textProperties.standardOutput.contains("CharacterCount"))
        #expect(textProperties.standardOutput.contains("11"))
        let setSelection = try liveCall(
            path: fieldPath,
            interface: AtSPIInterface.text,
            member: "SetSelection",
            signature: "iii",
            arguments: ["0", "1", "5"])
        #expect(setSelection.standardOutput == "b true")
        _ = bridge.publish()
        let selectionRange = try liveCall(
            path: fieldPath,
            interface: AtSPIInterface.text,
            member: "GetSelection",
            signature: "i",
            arguments: ["0"])
        #expect(selectionRange.standardOutput == "ii 1 5")

        let sliderPath = AtSPIExportModel.path(
            for: slider.accessibilityID)
        let setValue = try privateBus.call(
            adapter: adapter,
            destination: adapter.applicationBusName,
            path: sliderPath,
            interface: AtSPIInterface.value,
            member: "SetCurrentValue",
            signature: "d",
            arguments: ["0.75"])
        #expect(setValue.standardOutput == "b true")
        #expect(slider.value == 0.75)
        _ = bridge.publish()
        let valueProperties = try liveCall(
            path: sliderPath,
            interface: "org.freedesktop.DBus.Properties",
            member: "GetAll",
            signature: "s",
            arguments: [AtSPIInterface.value])
        #expect(valueProperties.status == 0)
        #expect(valueProperties.standardOutput.contains("CurrentValue"))
        #expect(valueProperties.standardOutput.contains("0.75"))

        let tabsPath = AtSPIExportModel.path(
            for: tabs.accessibilityID)
        let selectedCount = try privateBus.call(
            adapter: adapter,
            destination: adapter.applicationBusName,
            path: tabsPath,
            interface: AtSPIInterface.selection,
            member: "GetNSelectedChildren")
        #expect(selectedCount.status == 0)
        #expect(selectedCount.standardOutput == "i 1")
        let selectedChild = try liveCall(
            path: tabsPath,
            interface: AtSPIInterface.selection,
            member: "GetSelectedChild",
            signature: "i",
            arguments: ["0"])
        #expect(selectedChild.status == 0)
        #expect(!selectedChild.standardOutput.contains(
            AtSPIExportModel.nullPath))
        let selectSecond = try liveCall(
            path: tabsPath,
            interface: AtSPIInterface.selection,
            member: "SelectChild",
            signature: "i",
            arguments: ["1"])
        #expect(selectSecond.standardOutput == "b true")
        #expect(tabs.selectedIDs == [CollectionItemID("two")])

        let securePath = AtSPIExportModel.path(
            for: secureField.accessibilityID)
        let secureText = try privateBus.call(
            adapter: adapter,
            destination: adapter.applicationBusName,
            path: securePath,
            interface: AtSPIInterface.text,
            member: "GetText",
            signature: "ii",
            arguments: ["0", "-1"])
        #expect(secureText.status != 0)
        #expect(!secureText.standardOutput.contains("swordfish"))
        #expect(!secureText.standardError.contains("swordfish"))
        let secureProperties = try privateBus.call(
            adapter: adapter,
            destination: adapter.applicationBusName,
            path: securePath,
            interface: "org.freedesktop.DBus.Properties",
            member: "GetAll",
            signature: "s",
            arguments: [AtSPIInterface.accessible])
        #expect(secureProperties.status == 0)
        #expect(!secureProperties.standardOutput.contains("swordfish"))

        button.title = "Save"
        _ = bridge.publish()
        let updatedName = try privateBus.call(
            adapter: adapter,
            destination: adapter.applicationBusName,
            path: buttonPath,
            interface: "org.freedesktop.DBus.Properties",
            member: "Get",
            signature: "ss",
            arguments: [AtSPIInterface.accessible, "Name"])
        #expect(updatedName.standardOutput.contains("Save"))

        button.isHidden = true
        _ = bridge.publish()
        let removed = try privateBus.call(
            adapter: adapter,
            destination: adapter.applicationBusName,
            path: buttonPath,
            interface: AtSPIInterface.accessible,
            member: "GetRole")
        #expect(removed.status != 0)
        #expect(removed.standardError.contains(
            "No accessible object exists"))
        #expect(removed.standardError.contains(buttonPath))

        try scene.disconnect()
        _ = bridge.publish()
        let disconnectedAction = try liveCall(
            path: fieldPath,
            interface: AtSPIInterface.editableText,
            member: "SetTextContents",
            signature: "s",
            arguments: ["must-not-apply"])
        #expect(disconnectedAction.status != 0)
        #expect(disconnectedAction.standardError.contains(
            "No accessible object exists"))
        #expect(field.stringValue == "replacement")

        let oldBusName = adapter.applicationBusName
        adapter.close()
        let deregistration = try privateBus.registryApplications(
            pumping: nil)
        #expect(deregistration.status == 0)
        #expect(!deregistration.standardOutput.contains(oldBusName))
    }

    @Test func incrementalEventsTravelOverTheLiveBus() throws {
        let privateBus = try PrivateAccessibilityBus()
        let environment = ScopedEnvironmentVariable(
            name: "AT_SPI_BUS_ADDRESS",
            value: privateBus.address)
        defer {
            environment.restore()
            privateBus.stop()
        }

        let root = View()
        root.frame = Rect(x: 0, y: 0, width: 300, height: 220)
        let button = Button(title: "Before")
        button.frame = Rect(x: 10, y: 10, width: 80, height: 30)
        root.addSubview(button)
        let field = TextField(string: "before")
        field.frame = Rect(x: 10, y: 50, width: 180, height: 30)
        root.addSubview(field)
        let secure = TextField(string: "never-export", isSecure: true)
        secure.frame = Rect(x: 10, y: 90, width: 180, height: 30)
        root.addSubview(secure)
        let tabs = SegmentedControl(segments: [
            SegmentOption(id: "one", title: "One"),
            SegmentOption(id: "two", title: "Two"),
        ])
        tabs.frame = Rect(x: 10, y: 130, width: 180, height: 30)
        tabs.setSelectedIDs([CollectionItemID("one")])
        root.addSubview(tabs)
        let window = Window(
            title: "Events",
            frame: Rect(x: 20, y: 30, width: 300, height: 220))
        window.setContentView(root)
        window.orderFront()
        let scene = WindowScene(inMemoryWindows: [window])
        let adapter = AtSPIService(applicationName: "EventTests")
        defer { adapter.close() }
        let bridge = AtSPIBridge(scene: scene, service: adapter)
        adapter.onAction = { [weak bridge] request in
            bridge?.perform(request) ?? false
        }
        _ = bridge.publish()
        try privateBus.waitUntilReady(adapter)

        func observe(
            interface: String,
            member: String,
            trigger: () -> Void
        ) throws -> String {
            let result = try privateBus.monitorSignals(
                adapter: adapter,
                count: 1,
                interface: interface,
                member: member
            ) {
                trigger()
                _ = bridge.publish()
            }
            #expect(result.status == 0)
            #expect(result.standardError.contains(
                "Received requested maximum number of messages"))
            #expect(result.standardOutput.contains(interface))
            #expect(result.standardOutput.contains(member))
            return result.standardOutput
        }

        let focus = try observe(
            interface: "org.a11y.atspi.Event.Focus",
            member: "Focus"
        ) {
            #expect(window.makeFirstResponder(button))
        }
        #expect(focus.contains(
            AtSPIExportModel.path(for: button.accessibilityID)))

        let property = try observe(
            interface: "org.a11y.atspi.Event.Object",
            member: "PropertyChange"
        ) {
            button.title = "After"
        }
        #expect(property.contains("accessible-name"))
        #expect(property.contains("After"))

        let state = try observe(
            interface: "org.a11y.atspi.Event.Object",
            member: "StateChanged"
        ) {
            button.isEnabled = false
        }
        #expect(state.contains("accessible-state"))

        let text = try observe(
            interface: "org.a11y.atspi.Event.Object",
            member: "TextChanged"
        ) {
            field.stringValue = "after"
        }
        #expect(text.contains("after"))

        let selection = try observe(
            interface: "org.a11y.atspi.Event.Object",
            member: "SelectionChanged"
        ) {
            tabs.setSelectedIDs([CollectionItemID("two")])
        }
        let segmentPaths = scene.accessibilityTree.snapshot.nodes[
            tabs.accessibilityID]?.childIDs.map(AtSPIExportModel.path(for:))
            ?? []
        #expect(segmentPaths.contains {
            selection.contains($0)
        })

        let announcement = try observe(
            interface: "org.a11y.atspi.Event.Object",
            member: "Announcement"
        ) {
            field.postAccessibilityAnnouncement(
                "Polite update",
                priority: .polite)
        }
        #expect(announcement.contains("Polite update"))

        let inserted = Button(title: "Inserted")
        inserted.frame = Rect(x: 210, y: 10, width: 70, height: 30)
        let insertion = try observe(
            interface: "org.a11y.atspi.Event.Object",
            member: "ChildrenChanged"
        ) {
            root.addSubview(inserted)
        }
        #expect(insertion.contains("add"))
        #expect(insertion.contains(
            AtSPIExportModel.path(for: inserted.accessibilityID)))

        let removal = try observe(
            interface: "org.a11y.atspi.Event.Object",
            member: "ChildrenChanged"
        ) {
            inserted.removeFromSuperview()
        }
        #expect(removal.contains("remove"))
        #expect(removal.contains(
            AtSPIExportModel.path(for: inserted.accessibilityID)))

        let bounds = try observe(
            interface: "org.a11y.atspi.Event.Object",
            member: "BoundsChanged"
        ) {
            secure.stringValue = "more-never-export"
            field.frame.origin.x += 5
        }
        #expect(bounds.contains(
            AtSPIExportModel.path(for: field.accessibilityID)))
        #expect(!bounds.contains("never-export"))
        #expect(!bounds.contains("more-never-export"))
    }

    @Test func initialBusAbsenceRecoversWithoutRecreatingService() throws {
        let environment = ScopedEnvironmentVariable(
            name: "AT_SPI_BUS_ADDRESS",
            value: "unix:path=/tmp/nucleus-missing-at-spi-bus-\(getpid())")
        defer { environment.restore() }
        let baseline = AtSPIService.liveResourceCounts
        let service = AtSPIService(applicationName: "LateBusTests")
        defer { service.close() }
        var diagnostics: [(AtSPIServiceError, UInt64)] = []
        service.diagnosticHandler = { diagnostics.append(($0, $1)) }

        for _ in 0..<1_000 where diagnostics.isEmpty {
            _ = service.process()
            usleep(250)
        }

        #expect(!service.isReady)
        #expect(service.connectionGeneration == 0)
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.1 == 0)
        #expect(AtSPIService.liveResourceCounts == baseline)

        let privateBus = try PrivateAccessibilityBus()
        defer { privateBus.stop() }
        #expect(setenv("AT_SPI_BUS_ADDRESS", privateBus.address, 1) == 0)
        try privateBus.waitUntilReady(service)

        #expect(service.isReady)
        #expect(service.connectionGeneration == 1)
        #expect(AtSPIService.liveResourceCounts == .init(
            connections: baseline.connections + 1,
            fallbackSlots: baseline.fallbackSlots + 1))

        let registration = try privateBus.registryApplications(
            pumping: service)
        #expect(registration.status == 0)
        #expect(registration.standardOutput.contains(
            service.applicationBusName))

        service.close()
        #expect(AtSPIService.liveResourceCounts == baseline)
    }

    @Test func busLossReconnectsOneTreeAndBoundsPendingWork() throws {
        let initialBus = try PrivateAccessibilityBus()
        let environment = ScopedEnvironmentVariable(
            name: "AT_SPI_BUS_ADDRESS",
            value: initialBus.address)
        defer {
            environment.restore()
            initialBus.stop()
        }

        let button = Button(title: "Persistent")
        button.frame = Rect(x: 5, y: 7, width: 90, height: 30)
        let window = Window(
            title: "Reconnect",
            frame: Rect(x: 30, y: 40, width: 200, height: 100))
        window.setContentView(button)
        window.orderFront()
        let scene = WindowScene(inMemoryWindows: [window])
        let adapter = AtSPIService(applicationName: "ReconnectTests")
        defer { adapter.close() }
        let bridge = AtSPIBridge(scene: scene, service: adapter)
        adapter.onAction = { [weak bridge] request in
            bridge?.perform(request) ?? false
        }
        _ = bridge.publish()
        try initialBus.waitUntilReady(adapter)

        #expect(adapter.connectionGeneration == 1)
        initialBus.stop()
        var observedLoss = false
        for _ in 0..<100 {
            _ = adapter.process()
            if !adapter.isReady {
                observedLoss = true
                break
            }
            usleep(1_000)
        }
        #expect(observedLoss)
        #expect(adapter.fileDescriptor == -1)

        var diagnostics: [(AtSPIServiceError, UInt64)] = []
        adapter.diagnosticHandler = { diagnostics.append(($0, $1)) }
        adapter.transportDidFail(operation: "repeated disconnect")
        adapter.transportDidFail(operation: "repeated disconnect")
        #expect(diagnostics.filter {
            $0.0.operation == "repeated disconnect" && $0.1 == 1
        }.count == 1)

        for index in 0..<300 {
            button.postAccessibilityAnnouncement("queued-\(index)")
            _ = bridge.publish()
        }
        #expect(adapter.queuedEventCount == 256)

        let replacementBus = try PrivateAccessibilityBus()
        defer { replacementBus.stop() }
        #expect(setenv(
            "AT_SPI_BUS_ADDRESS",
            replacementBus.address,
            1) == 0)

        for _ in 0..<1_000 where adapter.connectionGeneration == 1 {
            _ = adapter.process()
            usleep(1_000)
        }
        #expect(adapter.connectionGeneration == 2)
        #expect(adapter.queuedEventCount == 0)
        #expect(!adapter.applicationBusName.isEmpty)

        let registration = try replacementBus.registryApplications(
            pumping: adapter)
        #expect(registration.status == 0)
        let nameOccurrences = registration.standardOutput.components(
            separatedBy: adapter.applicationBusName).count - 1
        #expect(nameOccurrences == 1)

        let buttonPath = AtSPIExportModel.path(
            for: button.accessibilityID)
        let role = try replacementBus.call(
            adapter: adapter,
            destination: adapter.applicationBusName,
            path: buttonPath,
            interface: AtSPIInterface.accessible,
            member: "GetRole")
        #expect(role.status == 0)
        #expect(role.standardOutput == "u 43")
        let address = try replacementBus.call(
            adapter: adapter,
            destination: adapter.applicationBusName,
            path: AtSPIExportModel.rootPath,
            interface: AtSPIInterface.application,
            member: "GetApplicationBusAddress")
        #expect(address.status == 0)
        #expect(address.standardOutput.contains(replacementBus.address))
    }

    @Test func virtualizedOffscreenObjectsRemainLiveAndStable() throws {
        let privateBus = try PrivateAccessibilityBus()
        let environment = ScopedEnvironmentVariable(
            name: "AT_SPI_BUS_ADDRESS",
            value: privateBus.address)
        defer {
            environment.restore()
            privateBus.stop()
        }

        let list = ListView()
        list.frame = Rect(x: 0, y: 0, width: 200, height: 84)
        list.makeRow = { View() }
        let itemLabels = Dictionary(uniqueKeysWithValues: (0..<100).map {
            (CollectionItemID($0), "Result \($0)")
        })
        list.accessibilityItemProperties = { item, _ in
            AccessibilityProperties(
                isElement: true,
                label: itemLabels[item.id],
                role: .listItem)
        }
        try list.applySnapshot(CollectionSnapshot(ids: Array(0..<100)))
        list.layoutIfNeeded()
        let window = Window(
            title: "Results",
            frame: Rect(x: 10, y: 20, width: 200, height: 84))
        window.setContentView(list)
        window.orderFront()
        let scene = WindowScene(inMemoryWindows: [window])
        let adapter = AtSPIService(
            applicationName: "VirtualizedTests")
        defer { adapter.close() }
        let bridge = AtSPIBridge(scene: scene, service: adapter)
        adapter.onAction = { [weak bridge] request in
            bridge?.perform(request) ?? false
        }
        _ = bridge.publish()
        try privateBus.waitUntilReady(adapter)

        #expect(list.materializedRowCount < 100)
        let item = try #require(
            scene.accessibilityTree.snapshot.nodes.values.first {
                $0.label == "Result 50"
            })
        let itemPath = AtSPIExportModel.path(for: item.id)
        let listPath = AtSPIExportModel.path(for: list.accessibilityID)
        let children = try privateBus.call(
            adapter: adapter,
            destination: adapter.applicationBusName,
            path: listPath,
            interface: AtSPIInterface.accessible,
            member: "GetChildren")
        #expect(children.status == 0)
        #expect(children.standardOutput.contains("100"))
        #expect(children.standardOutput.contains(itemPath))
        let name = try privateBus.call(
            adapter: adapter,
            destination: adapter.applicationBusName,
            path: itemPath,
            interface: "org.freedesktop.DBus.Properties",
            member: "Get",
            signature: "ss",
            arguments: [AtSPIInterface.accessible, "Name"])
        #expect(name.status == 0)
        #expect(name.standardOutput.contains("Result 50"))

        let reordered = [50] + Array(0..<50) + Array(51..<100)
        try list.applySnapshot(CollectionSnapshot(ids: reordered))
        _ = bridge.publish()
        let first = try privateBus.call(
            adapter: adapter,
            destination: adapter.applicationBusName,
            path: listPath,
            interface: AtSPIInterface.accessible,
            member: "GetChildAtIndex",
            signature: "i",
            arguments: ["0"])
        #expect(first.status == 0)
        #expect(first.standardOutput.contains(itemPath))
        let stableName = try privateBus.call(
            adapter: adapter,
            destination: adapter.applicationBusName,
            path: itemPath,
            interface: "org.freedesktop.DBus.Properties",
            member: "Get",
            signature: "ss",
            arguments: [AtSPIInterface.accessible, "Name"])
        #expect(stableName.status == 0)
        #expect(stableName.standardOutput.contains("Result 50"))
    }

    @Test func repeatedRegistrationAndIdempotentTeardownReturnToBaseline()
        throws
    {
        let privateBus = try PrivateAccessibilityBus()
        let environment = ScopedEnvironmentVariable(
            name: "AT_SPI_BUS_ADDRESS",
            value: privateBus.address)
        defer {
            environment.restore()
            privateBus.stop()
        }
        let baseline = AtSPIService.liveResourceCounts

        for iteration in 0..<5 {
            let adapter = AtSPIService(
                applicationName: "Lifetime-\(iteration)")
            try privateBus.waitUntilReady(adapter)
            #expect(AtSPIService.liveResourceCounts == .init(
                connections: baseline.connections + 1,
                fallbackSlots: baseline.fallbackSlots + 1))
            let name = adapter.applicationBusName
            let registered = try privateBus.registryApplications(
                pumping: adapter)
            #expect(registered.status == 0)
            #expect(registered.standardOutput.contains(name))

            adapter.close()
            adapter.close()
            #expect(AtSPIService.liveResourceCounts == baseline)
            let deregistered = try privateBus.registryApplications(
                pumping: nil)
            #expect(deregistered.status == 0)
            #expect(!deregistered.standardOutput.contains(name))
        }
        #expect(AtSPIService.liveResourceCounts == baseline)
    }
}
