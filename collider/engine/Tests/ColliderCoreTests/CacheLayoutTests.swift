import ColliderCore
import SystemPackage
import Testing

@Test func cacheLayoutUsesOneXDGAndHomeResolutionContract() {
    let xdg = ColliderCacheLayout(
        environment: [
            "HOME": "/home/fixture",
            "XDG_CACHE_HOME": "/cache/fixture",
        ])
    #expect(xdg.root == FilePath("/cache/fixture"))
    #expect(xdg.downloads == FilePath("/cache/fixture/nucleus/downloads"))

    let home = ColliderCacheLayout(environment: ["HOME": "/home/fixture"])
    #expect(home.root == FilePath("/home/fixture/.cache"))
    #expect(home.downloads == FilePath("/home/fixture/.cache/nucleus/downloads"))
}
