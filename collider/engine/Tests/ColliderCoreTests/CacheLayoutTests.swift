import ColliderCore
import SystemPackage
import Testing

@Test func cacheLayoutsKeepProductNamespacesDisjoint() {
    let first = ColliderCacheLayout(
        root: FilePath("/cache/fixture"),
        downloadNamespace: FilePath("first/downloads"))
    let second = ColliderCacheLayout(
        root: FilePath("/cache/fixture"),
        downloadNamespace: FilePath("second/downloads"))

    #expect(first.downloads == FilePath("/cache/fixture/first/downloads"))
    #expect(second.downloads == FilePath("/cache/fixture/second/downloads"))
    #expect(first.downloads != second.downloads)
}
