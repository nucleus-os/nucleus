// Registry model for the Vulkan generator — the subset the
// Swift-emitting backend actually consumes (enums, bitmasks,
// handles, commands' dispatch classification, features, extensions, tags).
// Structs, full command signatures, api-constants, and C-type parsing are not
// rendered by this backend, so they are not modeled.

enum EnumValue {
    case bitpos(Int)        // 1 << bitpos
    case bitVector(Int32)   // combined flags & some vendor IDs (from value="0x..")
    case int(Int32)
    case alias(name: String)
}

struct EnumField {
    var name: String
    var value: EnumValue
}

struct EnumDecl {
    var fields: [EnumField]
    var bitwidth: Int
    var isBitmask: Bool
}

enum DeclType {
    case enumeration(EnumDecl)
    case bitmask(bitsEnum: String?, bitwidth: Int)
    case handle(isDispatchable: Bool)
    case command(firstParamTypeName: String?)
    case aliasType(name: String)      // alias → other_type
    case aliasCommand(name: String)   // alias → other_command
}

struct Decl {
    var name: String
    var type: DeclType
}

struct FeatureLevel {
    var major: UInt32
    var minor: UInt32
}

// Only the `.field` form of an enum extension is kept (new-api-constant extends
// feed api-constants, which this backend does not render).
struct EnumExtension {
    var extends: String
    var field: EnumField
}

struct Require {
    var extends: [EnumExtension]
    var commands: [String]
}

struct Feature {
    var name: String
    var level: FeatureLevel
    var requires: [Require]
}

enum ExtensionType { case instance, device, video }

struct Extension {
    var name: String
    var number: Int
    var extensionType: ExtensionType?
    var platform: String?
    var supported: String?
    var requires: [Require]
}

struct Registry {
    var decls: [Decl]
    var tags: [String]
    var features: [Feature]
    var extensions: [Extension]
}
