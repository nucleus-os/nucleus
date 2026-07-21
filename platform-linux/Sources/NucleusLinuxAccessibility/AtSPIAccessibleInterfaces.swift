import NucleusLinuxDBus
import NucleusUI

extension AtSPIService {
    func handleAccessible(
        _ message: SDBusMessage,
        object: AtSPIExportedObject,
        member: String
    ) -> Int32 {
        switch member {
        case "GetRole":
            return reply(message) { $0.uint32(object.role) }
        case "GetRoleName", "GetLocalizedRoleName":
            return reply(message) { $0.string(object.roleName) }
        case "GetState":
            return reply(message) { $0.uint32Array(object.states) }
        case "GetAttributes":
            return reply(message) { $0.stringDictionary([:]) }
        case "GetRelationSet":
            return reply(message) { writer in
                writer.relationSet(
                    object.relationships,
                    busName: uniqueName)
            }
        case "GetApplication":
            return reply(message) {
                $0.objectReference(
                    busName: uniqueName,
                    path: AtSPIExportModel.rootPath)
            }
        case "GetInterfaces":
            return reply(message) { $0.stringArray(object.interfaces) }
        case "GetChildAtIndex":
            guard let index = readInt32(message) else {
                return invalidArguments(message)
            }
            let path = object.childPaths.indices.contains(Int(index))
                ? object.childPaths[Int(index)]
                : AtSPIExportModel.nullPath
            return reply(message) {
                $0.objectReference(
                    busName: path == AtSPIExportModel.nullPath
                        ? "" : uniqueName,
                    path: path)
            }
        case "GetChildren":
            return reply(message) {
                $0.objectReferenceArray(
                    object.childPaths,
                    busName: uniqueName)
            }
        case "GetIndexInParent":
            let index: Int32
            if let parentPath = object.parentPath,
               let parent = model.objects[parentPath],
               let found = parent.childPaths.firstIndex(of: object.path)
            {
                index = Int32(clamping: found)
            } else {
                index = -1
            }
            return reply(message) { $0.int32(index) }
        default:
            return unknownMethod(
                message,
                interface: AtSPIInterface.accessible,
                member: member)
        }
    }


    func handleApplication(
        _ message: SDBusMessage,
        object: AtSPIExportedObject,
        member: String
    ) -> Int32 {
        guard object.path == AtSPIExportModel.rootPath else {
            return unknownMethod(
                message,
                interface: AtSPIInterface.application,
                member: member)
        }
        switch member {
        case "GetLocale":
            _ = readUInt32(message)
            return reply(message) { $0.string(locale) }
        case "GetApplicationBusAddress":
            return reply(message) { $0.string(busAddress) }
        default:
            return unknownMethod(
                message,
                interface: AtSPIInterface.application,
                member: member)
        }
    }

}
