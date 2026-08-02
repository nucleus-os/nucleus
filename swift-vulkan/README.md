# swift-vulkan

Root-package Swift bindings for the [Vulkan](https://www.vulkan.org/) API,
generated from the Khronos registry (`vk.xml`).

- **`Vulkan`** — the generated typed Swift API: scoped enums, option sets,
  typed handles, per-object dispatch tables (`VK.InstanceDispatch` /
  `VK.DeviceDispatch`). Includes a hand-written ergonomics layer
  (`VulkanErgonomics.swift`): `VkOwned<T>` RAII wrapper,
  `VkOwnedImageBox`, `VK.loadBaseDispatch()`, `VkEnumerate.array()`,
  `withCStringArray()`, and device-child resource constructors.
- **`VulkanC`** — the raw C API (`vulkan_core.h`). The Khronos
  [Vulkan-Headers](https://github.com/KhronosGroup/Vulkan-Headers) are vendored
  (`v1.4.350`), so importers resolve `<vulkan/vulkan_core.h>` with no `-I` flags and
  the package builds with no system Vulkan SDK. Only the loader (`libvulkan`) is
  linked. Android / Wayland surface extensions are behind platform guards.

Root-manifest targets depend directly on `Vulkan` and import it normally.

## Regenerating the bindings

The generated `Sources/Vulkan/Vulkan.swift` is committed. After bumping
the vendored headers (`Sources/VulkanC/vulkan` + `third-party/vk.xml`):

```sh
collider generate vulkan
```
