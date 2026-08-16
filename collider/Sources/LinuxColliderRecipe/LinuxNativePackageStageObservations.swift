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

    package var observationName: String {
        "linux-native-package.\(rawValue)"
    }
}

package final class LinuxNativePackageStageRecorder: Sendable {
    private struct Totals: Sendable {
        var durationNanoseconds: UInt64 = 0
        var inputByteCount: UInt64 = 0
        var outputByteCount: UInt64 = 0
    }

    private let totals = Mutex<[LinuxNativePackageStage: Totals]>([:])

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

    package var observations: [ActionStageObservation] {
        totals.withLock { totals in
            LinuxNativePackageStage.allCases.compactMap { stage in
                guard let total = totals[stage] else { return nil }
                return ActionStageObservation(
                    name: stage.observationName,
                    durationNanoseconds: total.durationNanoseconds,
                    inputByteCount: total.inputByteCount,
                    outputByteCount: total.outputByteCount)
            }
        }
    }
}
