import ColliderCore
import Synchronization

package enum LinuxNativePackageStage: String, CaseIterable, Sendable {
    case payloadMaterialization = "payload-materialization"
    case debianAssembly = "debian-assembly"
    case debianValidation = "debian-validation"
    case rpmAssembly = "rpm-assembly"
    case rpmValidation = "rpm-validation"
    case archAssembly = "arch-assembly"
    case archValidation = "arch-validation"
    case productEnvelopeConstruction = "product-envelope-construction"
    case productStorePublication = "product-store-publication"
    case generationPublication = "generation-publication"

    package static var assemblyCases: [Self] {
        allCases.filter { $0 != .productStorePublication }
    }

    package var observationName: String {
        "linux-native-package.\(rawValue)"
    }
}

package enum LinuxNativePackageChildStage: String, CaseIterable, Sendable {
    case payloadMaterialization = "payload-materialization"
    case familyViewConstruction = "family-view-construction"
    case assembly
    case validation
    case productEnvelopeConstruction = "product-envelope-construction"
    case rpmSourceViewConstruction = "rpm-source-view-construction"
    case rpmBuild = "rpmbuild"
    case rpmArchivePublication = "rpm-archive-publication"
    case rpmCleanup = "rpm-cleanup"

    package func observationName(
        package: LinuxNativePackageName,
        family: LinuxDistributionFamily
    ) -> String {
        "linux-native-package.\(family.rawValue).\(package.rawValue).\(rawValue)"
    }

    package func observationName(package: LinuxNativePackageName) -> String {
        "linux-native-package.payload.\(package.rawValue).\(rawValue)"
    }
}

package final class LinuxNativePackageStageRecorder: Sendable {
    private struct Totals: Sendable {
        var durationNanoseconds: UInt64 = 0
        var inputByteCount: UInt64 = 0
        var outputByteCount: UInt64 = 0
    }

    private let totals = Mutex<[LinuxNativePackageStage: Totals]>([:])
    private let childTotals = Mutex<[String: Totals]>([:])

    package init() {}

    package func record(
        _ stage: LinuxNativePackageStage,
        durationNanoseconds: UInt64,
        inputByteCount: UInt64,
        outputByteCount: UInt64
    ) {
        totals.withLock {
            $0[stage, default: Totals()].durationNanoseconds &+= durationNanoseconds
            $0[stage, default: Totals()].inputByteCount &+= inputByteCount
            $0[stage, default: Totals()].outputByteCount &+= outputByteCount
        }
    }

    package func record(
        _ stage: LinuxNativePackageChildStage,
        package: LinuxNativePackageName,
        durationNanoseconds: UInt64,
        inputByteCount: UInt64,
        outputByteCount: UInt64
    ) {
        let name = stage.observationName(package: package)
        childTotals.withLock {
            $0[name, default: Totals()].durationNanoseconds &+= durationNanoseconds
            $0[name, default: Totals()].inputByteCount &+= inputByteCount
            $0[name, default: Totals()].outputByteCount &+= outputByteCount
        }
    }

    package func record(
        _ stage: LinuxNativePackageChildStage,
        package: LinuxNativePackageName,
        family: LinuxDistributionFamily,
        durationNanoseconds: UInt64,
        inputByteCount: UInt64,
        outputByteCount: UInt64
    ) {
        let name = stage.observationName(package: package, family: family)
        childTotals.withLock {
            $0[name, default: Totals()].durationNanoseconds &+= durationNanoseconds
            $0[name, default: Totals()].inputByteCount &+= inputByteCount
            $0[name, default: Totals()].outputByteCount &+= outputByteCount
        }
    }

    package var observations: [ActionStageObservation] {
        let topLevel: [ActionStageObservation] = totals.withLock { totals in
            LinuxNativePackageStage.allCases.compactMap { stage in
                guard let total = totals[stage] else { return nil }
                return ActionStageObservation(
                    name: stage.observationName,
                    durationNanoseconds: total.durationNanoseconds,
                    inputByteCount: total.inputByteCount,
                    outputByteCount: total.outputByteCount)
            }
        }
        let children: [ActionStageObservation] = childTotals.withLock { totals in
            totals.keys.sorted().compactMap { name in
                guard let total = totals[name] else { return nil }
                return ActionStageObservation(
                    name: name,
                    durationNanoseconds: total.durationNanoseconds,
                    inputByteCount: total.inputByteCount,
                    outputByteCount: total.outputByteCount)
            }
        }
        return topLevel + children
    }
}
