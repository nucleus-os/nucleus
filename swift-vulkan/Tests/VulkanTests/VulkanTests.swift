import Testing
import Vulkan

@Test func cStringArrayBorrowsEveryStringForTheBody() {
    unsafe withCStringArray([]) { pointers, count in
        let pointersAreNil = unsafe pointers == nil
        #expect(pointersAreNil)
        #expect(count == 0)
    }

    unsafe withCStringArray(["VK_ONLY"]) { pointers, count in
        #expect(count == 1)
        let decoded = unsafe pointers.map {
            unsafe String(cString: $0[0]!)
        }
        #expect(decoded == "VK_ONLY")
    }

    let strings = ["VK_ONE", "VK_TWO", "Vulkan-λ"]
    unsafe withCStringArray(strings) { pointers, count in
        #expect(count == UInt32(strings.count))
        guard let pointers = unsafe pointers else {
            Issue.record("nonempty input must provide a pointer table")
            return
        }
        for index in strings.indices {
            let decoded = unsafe String(cString: pointers[index]!)
            #expect(decoded == strings[index])
        }
    }
}

// Proves the plugin-generated Vulkan binding compiles and exposes the
// scoped enums, typed Result, option sets, typed handles, dispatch tables, and
// the extension/feature inventories.
@Test func resultClassification() {
    #expect(VK.Result.success.rawValue == 0)
    #expect(VK.Result.success.isSuccess)
    #expect(VK.Result.errorOutOfHostMemory.isError)
}

@Test func featureLevelsPresent() {
    #expect(VK.featureLevels.contains { $0.name == "VK_VERSION_1_0" })
}

@Test func extensionInventory() {
    #expect(VK.Ext.khrSwapchain == "VK_KHR_swapchain")
}

@Test func typedHandlesAndOptionSets() {
    #expect(VK.Instance.null.isNull)
    // Dispatch tables are typed structs; just confirm the type composes.
    let empty: VK.QueryPoolCreateFlags = []
    #expect(empty.rawValue == 0)
}
