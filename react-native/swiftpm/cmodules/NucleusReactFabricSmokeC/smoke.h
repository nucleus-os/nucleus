#pragma once
// Test-only smoke entries. Both drive the static RN fabric headless and return 0
// on success. Wrapped in extern "C" so a C++-interop consumer resolves the
// unmangled symbols the implementations export.
#ifdef __cplusplus
extern "C" {
#endif
// Runtime core only (raw facade): Hermes runtime + bytecode eval + JS drain.
int nucleus_rn_fabric_smoke(const char *hbcPath);
// Full Fabric path via the real RuntimeHost: + installFabric (UIManager) with the
// Swift mounting-observer / text-layout-manager bridges wired.
int nucleus_rn_fabric_full_smoke(const char *hbcPath);
// Cross-thread timer work makes the host wake exactly once until the JS queue
// is drained.
int nucleus_rn_js_work_wake_smoke(const char *hbcPath);
// Swift-native mount batching, generation retirement, and tagged-payload
// behavioral probes. Zero means success.
int nucleus_rn_mount_batching_smoke(void);
int nucleus_rn_mount_lifecycle_smoke(void);
int nucleus_rn_mount_event_payload_smoke(void);
#ifdef __cplusplus
}
#endif
