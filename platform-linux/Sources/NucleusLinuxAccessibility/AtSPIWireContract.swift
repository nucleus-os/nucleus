enum AtSPIWireContract {
    static func expectedInputSignature(
        interface: String,
        member: String
    ) -> String? {
        switch (interface, member) {
        case ("org.freedesktop.DBus.Properties", "Get"): "ss"
        case ("org.freedesktop.DBus.Properties", "GetAll"): "s"
        case ("org.freedesktop.DBus.Properties", "Set"): "ssv"
        case ("org.freedesktop.DBus.Introspectable", "Introspect"): ""
        case (AtSPIInterface.accessible, "GetChildAtIndex"): "i"
        case (AtSPIInterface.accessible, "GetRole"),
             (AtSPIInterface.accessible, "GetRoleName"),
             (AtSPIInterface.accessible, "GetLocalizedRoleName"),
             (AtSPIInterface.accessible, "GetState"),
             (AtSPIInterface.accessible, "GetAttributes"),
             (AtSPIInterface.accessible, "GetRelationSet"),
             (AtSPIInterface.accessible, "GetApplication"),
             (AtSPIInterface.accessible, "GetInterfaces"),
             (AtSPIInterface.accessible, "GetChildren"),
             (AtSPIInterface.accessible, "GetIndexInParent"),
             (AtSPIInterface.action, "GetActions"),
             (AtSPIInterface.application, "GetApplicationBusAddress"),
             (AtSPIInterface.component, "GetSize"),
             (AtSPIInterface.component, "GetLayer"),
             (AtSPIInterface.component, "GetMDIZOrder"),
             (AtSPIInterface.component, "GrabFocus"),
             (AtSPIInterface.component, "GetAlpha"),
             (AtSPIInterface.text, "GetNSelections"),
             (AtSPIInterface.selection, "GetNSelectedChildren"):
            ""
        case (AtSPIInterface.action, "GetName"),
             (AtSPIInterface.action, "GetLocalizedName"),
             (AtSPIInterface.action, "GetDescription"),
             (AtSPIInterface.action, "GetKeyBinding"),
             (AtSPIInterface.action, "DoAction"),
             (AtSPIInterface.text, "SetCaretOffset"),
             (AtSPIInterface.text, "GetSelection"),
             (AtSPIInterface.editableText, "PasteText"),
             (AtSPIInterface.selection, "GetSelectedChild"),
             (AtSPIInterface.selection, "SelectChild"):
            "i"
        case (AtSPIInterface.application, "GetLocale"): "u"
        case (AtSPIInterface.component, "Contains"),
             (AtSPIInterface.component, "GetAccessibleAtPoint"):
            "iiu"
        case (AtSPIInterface.component, "GetExtents"),
             (AtSPIInterface.component, "GetPosition"):
            "u"
        case (AtSPIInterface.value, "SetCurrentValue"): "d"
        case (AtSPIInterface.text, "GetText"),
             (AtSPIInterface.editableText, "CopyText"),
             (AtSPIInterface.editableText, "CutText"):
            "ii"
        case (AtSPIInterface.text, "SetSelection"): "iii"
        case (AtSPIInterface.editableText, "SetTextContents"): "s"
        default: nil
        }
    }

    static func introspectionXML(for object: AtSPIExportedObject) -> String {
        let interfaces = object.interfaces.map {
            "<interface name=\"\($0)\"/>"
        }.joined()
        return """
        <node>
          <interface name="org.freedesktop.DBus.Introspectable">
            <method name="Introspect"><arg direction="out" type="s"/></method>
          </interface>
          <interface name="org.freedesktop.DBus.Properties">
            <method name="Get"><arg direction="in" type="s"/><arg direction="in" type="s"/><arg direction="out" type="v"/></method>
            <method name="GetAll"><arg direction="in" type="s"/><arg direction="out" type="a{sv}"/></method>
            <method name="Set"><arg direction="in" type="s"/><arg direction="in" type="s"/><arg direction="in" type="v"/></method>
          </interface>
          \(interfaces)
        </node>
        """
    }
}
