import NucleusReactRuntimeCxx
import NucleusReactRuntimeCxxBridge
import Testing

@Suite
struct TextLayoutConcurrencyTests {
    @Test func fabricMeasurementRunsConcurrentlyThroughSendableManager() async {
        let manager = SwiftTextLayoutManager(DefaultTextLayoutHandler())
        let results = await withTaskGroup(
            of: (Float, Float).self,
            returning: [(Float, Float)].self
        ) { group in
            for index in 0..<32 {
                group.addTask {
                    let request = "parallel-\(index)".withCString {
                        unsafe nucleus.react.makeSingleRunMeasureRequest(
                            $0,
                            14,
                            320)
                    }
                    let result = manager.measure(request)
                    return (result.width, result.height)
                }
            }
            var results: [(Float, Float)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        #expect(results.count == 32)
        #expect(results.allSatisfy { $0.0 > 0 && $0.1 > 0 })
    }
}
