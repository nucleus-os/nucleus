# GPU driver capability adoption plan

Status: active.

## Invariant

Nucleus selects a GPU by capability and fails closed. It never branches on
vendor name or driver version. Driver identity is recorded evidence for hardware
qualification, never an input to a code path.

A driver-gated capability enters the required Vulkan contract only when every
supported device satisfies it. Anything narrower is discovered at runtime and
its absence produces one named failure rather than a silent reduced path.

What the compositor advertises to clients and what it accepts from clients come
from one source of truth. An advertised format the acceptance path validates
under different rules is a defect, not a conservative default.

## Phase 1 — Record device and driver identity at selection

`DeviceOwner.selectPhysicalDevice` reads `VkPhysicalDeviceProperties` only to
compare `apiVersion`, then returns a `PhysicalSelection` carrying the device
handle and graphics queue family. Device name, vendor, driver identity, and
conformance version are discarded, and no bring-up path logs them.
`VkPhysicalDeviceDriverProperties` is core Vulkan 1.2, well below the required
1.4 floor, so it costs no extension.

Chain `VkPhysicalDeviceDriverProperties` onto a `VkPhysicalDeviceProperties2`
query during selection. Carry `deviceName`, `vendorID`, `deviceID`, `driverID`,
`driverName`, `driverInfo`, `driverVersion`, and `conformanceVersion` on the
selection as one value struct. Log the record once per bring-up on both the DRM
renderer path and the Wayland-client presenter path, and expose it through the
compositor render service so a session capture reports it without a manual step.

This is the prerequisite for every remaining phase and for the driver comparison
the Nvidia observations document already demands. That document requires each
qualification capture to record driver version, GPU, connector and mode, atomic
properties, explicit-sync path, framebuffer sequence, and flip timestamps. Only
the items after the first two are obtainable from the running system today.

Gate: `collider test core` and `collider test compositor` cover the identity
record and the path where the driver properties structure is unavailable. A DRM
session names its device and driver in its startup log.

## Phase 2 — Make advertised and accepted client buffer formats one contract

Advertisement is device-derived. `querySampleableDmaBufFormats` probes
`XRGB8888`, `ARGB8888`, `XBGR8888`, `ABGR8888`, `ABGR16161616F`, and
`ABGR2101010` for sampleable DRM modifiers, and the surviving set reaches
`zwp_linux_dmabuf` feedback unchanged through the render service and router.

Acceptance does not match. `DmabufLayoutValidator.validate` requires
`stride >= width * 4` for every format. `ABGR16161616F` is eight bytes per
pixel, so a client can pass a stride between four and eight times the width,
have the buffer accepted, and have the renderer import and sample an image
larger than the memory behind it. The validator also computes a required end
offset and discards the result.

Derive bytes per pixel from the same fourcc table that produces the Vulkan
format, pass the format into the validator, and reject any stride below that
format's own minimum. Keep the single-plane rule explicit and named; Phase 3
replaces it deliberately rather than by loosening a constant.

Gate: behavioral tests over every advertised format prove an undersized stride
is rejected and an exact stride is accepted, and that a format the renderer does
not advertise is rejected at buffer creation. `collider test compositor`.

## Phase 3 — Multiplanar YCbCr client buffers

Most of the import machinery exists. `importDmaBufImage` already accepts one to
three planes with either a single aliased fd or one distinct fd per plane,
tracks fd ownership by value so an aliased fd is neither double-closed nor
closed after Vulkan owns it, and already populates
`drmFormatModifierPlaneCount`. `samplerYcbcrConversion` is a required feature
and is enabled at device creation.

Nothing consumes any of it. No `VkSamplerYcbcrConversion` object is created
anywhere, and Graphite receives an empty `VulkanYcbcrConversionInfo` at both
texture-wrap sites. The reachable blockers are the fourcc-to-Vulkan format
table, the probed format list, the single-plane acceptance rule from Phase 2,
and the missing conversion object. The required feature currently buys nothing
and begins paying here.

Entry condition: a named product consumer that actually exports YCbCr dmabufs.
The candidate is Chromium accelerated video decode, exercised by Phase 4 of the
Nucleus Browser qualification plan. The pinned Chromium revision is not
materialized in this checkout, so what its Ozone Wayland presenter exports is
unverified; verify it against the pinned revision before this phase starts. On
Nvidia the enabling platform condition is driver support for multiplanar YCbCr
DRM format modifiers, which the 610 branch supplies and earlier branches do not.

Extend the fourcc table and probed format list to `NV12` and `P010`, validate
each plane's offset and stride against that plane's subsampled dimensions and
bytes per pixel, accept the plane counts the renderer already handles, create
the `VkSamplerYcbcrConversion` matching the model and range the client declares,
and carry it into the Graphite texture wrap. Direct scanout stays RGB.

Gate: import, sample, and release a planar buffer end to end, and reject every
malformed planar layout with a named error. `collider test compositor` and
`collider test gpu-drm`.

## Phase 4 — Output color management on the DRM color pipeline

`color-management-v1` has complete generated server and client bindings and no
server implementation: no state machine, no global registration, no per-surface
or per-output color state. Under the Wayland protocol coverage plan, generated
bindings are not an implementation, and the color-management family is an
explicit consumer-gated candidate rather than scheduled work.

KMS color state today is the legacy set: CRTC `GAMMA_LUT`, `DEGAMMA_LUT`, and
`CTM`, plane `COLOR_RANGE`, and connector Broadcast RGB. Scanout format
preference is fixed, taking eight-bit `XRGB8888` ahead of `ABGR2101010`
specifically to avoid HDMI and Nvidia color behavior. Graphite applies the sRGB
transfer function in fragment shaders, and the blending model that follows from
it is a deliberate choice recorded in the color debugging document.

Entry condition: the browser qualification plan's presentation gate, which names
color metadata and HDR metadata, produces a real consumer. The enabling platform
is the per-plane DRM color pipeline introduced in kernel 6.19 with a driver that
implements it; on Nvidia the 610 branch is the first proprietary branch that
does. Target the upstream per-plane interface, never a vendor-specific color
control.

Implement the `wp_color_manager_v1` state machine with per-surface image
descriptions and per-output preferred descriptions. Decide the compositor
blending space once and record it in the graphics contract rather than changing
it implicitly. Represent output transfer function and primaries as compositor
state. Program the per-plane color pipeline where the kernel exposes it, and
composite the conversion where it does not. Make ten-bit scanout selection a
consequence of the output's declared color state instead of a fixed preference
order.

Gate: protocol conformance and hostile-client coverage, per-output color state
across mode change and hot-plug, and a DRM session capture proving the
programmed pipeline and the composited path agree.

## Explicit exclusions

Do not add a vendor or driver-version branch. The recorded Nvidia driver version
is qualification evidence attached to a capture, not a runtime condition.

`VK_KHR_internally_synchronized_queues` solves a problem Nucleus does not have.
The swapchain presenter, renderer submission, and renderer device are all main
actor isolated, so there is no application-owned queue lock to remove.

`VK_EXT_shader_long_vector` has no consumer. Nucleus authors no SPIR-V; shaders
come from Graphite and from SkSL runtime effects, which cannot express it.

`VK_NV_push_constant_bank` and descriptor-heap binding target D3D12 translation.
No Nucleus path emits either, and a vendor extension cannot enter a required
contract that every supported device must satisfy.

Vulkan device groups are out of scope. Nucleus creates one logical device on one
physical device selected against the presenting DRM node.

DMA-BUF mmap is out of scope. Neither the renderer nor the compositor maps a GPU
buffer for CPU access; capture is a Vulkan copy.

FP16 EGL framebuffer configurations are out of scope. Nucleus has no EGL.
