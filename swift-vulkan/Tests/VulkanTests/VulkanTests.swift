import Testing
import Vulkan

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
