import NucleusAndroidDrmC
import NucleusAndroidDrmCTestSupport
import Testing

private struct GpuLifetimeTestError: Error {}

@safe private final class TestGpuLifetimeDomain: @unchecked Sendable {
    let handle: OpaquePointer

    init() throws {
        guard
            let handle = unsafe nucleus_android_gpu_lifetime_domain_create()
        else {
            throw GpuLifetimeTestError()
        }
        unsafe self.handle = handle
    }

    deinit {
        unsafe nucleus_android_gpu_lifetime_domain_destroy(handle)
    }

    var snapshot: nucleus_android_gpu_lifetime_snapshot {
        var result = nucleus_android_gpu_lifetime_snapshot()
        unsafe nucleus_android_gpu_lifetime_domain_get_snapshot(
            handle,
            &result)
        return result
    }

    func makeResource() throws -> TestGpuLifetimeResource {
        guard
            let handle = unsafe nucleus_android_test_lifetime_resource_create(
                self.handle)
        else {
            throw GpuLifetimeTestError()
        }
        return unsafe TestGpuLifetimeResource(
            domain: self,
            handle: handle)
    }

    func complete(through serial: UInt64, result: Int32 = 0) {
        unsafe nucleus_android_gpu_lifetime_domain_complete_through(
            handle,
            serial,
            result)
    }
}

@safe private final class TestGpuLifetimeResource {
    let domain: TestGpuLifetimeDomain
    private var handle: OpaquePointer?

    init(domain: TestGpuLifetimeDomain, handle: OpaquePointer) {
        self.domain = domain
        unsafe self.handle = handle
    }

    deinit {
        retire()
    }

    func recordSubmission() -> UInt64 {
        guard let handle = unsafe handle else { return 0 }
        return unsafe nucleus_android_gpu_lifetime_record_submission(handle)
    }

    func retire() {
        guard let handle = unsafe handle else { return }
        unsafe self.handle = nil
        unsafe nucleus_android_gpu_lifetime_resource_retire(handle)
    }
}

@Suite
struct GpuLifetimeDomainTests {
    @Test
    func neverSubmittedResourceReclaimsImmediately() throws {
        let domain = try TestGpuLifetimeDomain()
        let resource = try domain.makeResource()

        resource.retire()

        let result = domain.snapshot
        #expect(result.live_resource_count == 0)
        #expect(result.retired_resource_count == 0)
        #expect(result.reclaimed_resource_count == 1)
    }

    @Test
    func submittedResourcesWaitForTheirCompletionSerial() throws {
        let domain = try TestGpuLifetimeDomain()
        let first = try domain.makeResource()
        let second = try domain.makeResource()
        let firstSerial = first.recordSubmission()
        let secondSerial = second.recordSubmission()
        #expect(firstSerial == 1)
        #expect(secondSerial == 2)

        first.retire()
        second.retire()
        var result = domain.snapshot
        #expect(result.live_resource_count == 2)
        #expect(result.retired_resource_count == 2)
        #expect(result.reclaimed_resource_count == 0)

        domain.complete(through: firstSerial)
        result = domain.snapshot
        #expect(result.live_resource_count == 1)
        #expect(result.retired_resource_count == 1)
        #expect(result.reclaimed_resource_count == 1)

        domain.complete(through: secondSerial, result: -4)
        result = domain.snapshot
        #expect(result.live_resource_count == 0)
        #expect(result.retired_resource_count == 0)
        #expect(result.reclaimed_resource_count == 2)
        #expect(result.completed_serial == secondSerial)
        #expect(result.terminal_submission_result == -4)

        domain.complete(through: secondSerial, result: -7)
        #expect(domain.snapshot.terminal_submission_result == -4)
    }
}
