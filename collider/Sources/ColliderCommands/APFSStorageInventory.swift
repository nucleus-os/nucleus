import Foundation

struct APFSStorageInventory {
    struct Volume: Sendable {
        let name: String
        let capacityInUse: UInt64
        let capacityQuota: UInt64
        let capacityReserve: UInt64
    }

    static func decode(_ output: String) throws -> [String: Volume] {
        let list = try PropertyListDecoder().decode(
            APFSList.self,
            from: Data(output.utf8))
        var result: [String: Volume] = [:]
        var ambiguousNames = Set<String>()
        for volume in list.containers.flatMap(\.volumes) {
            if result[volume.name] != nil {
                result.removeValue(forKey: volume.name)
                ambiguousNames.insert(volume.name)
                continue
            }
            guard !ambiguousNames.contains(volume.name) else { continue }
            result[volume.name] = Volume(
                name: volume.name,
                capacityInUse: volume.capacityInUse,
                capacityQuota: volume.capacityQuota,
                capacityReserve: volume.capacityReserve)
        }
        return result
    }
}

private struct APFSList: Decodable {
    struct Container: Decodable {
        let volumes: [Volume]

        enum CodingKeys: String, CodingKey {
            case volumes = "Volumes"
        }
    }

    struct Volume: Decodable {
        let name: String
        let capacityInUse: UInt64
        let capacityQuota: UInt64
        let capacityReserve: UInt64

        enum CodingKeys: String, CodingKey {
            case name = "Name"
            case capacityInUse = "CapacityInUse"
            case capacityQuota = "CapacityQuota"
            case capacityReserve = "CapacityReserve"
        }
    }

    let containers: [Container]

    enum CodingKeys: String, CodingKey {
        case containers = "Containers"
    }
}
