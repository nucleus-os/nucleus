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
// Drives the real NucleusHostCommand TurboModule on a worker-owned Hermes
// runtime using the supplied Swift callback/context ownership pair.
typedef void (*nucleus_rn_host_command_callback)(
    void *context,
    const char *command,
    const char *argsJson);
typedef void (*nucleus_rn_host_command_release)(void *context);
int nucleus_rn_invoke_host_command_on_js_worker(
    nucleus_rn_host_command_callback callback,
    void *context,
    nucleus_rn_host_command_release release,
    const char *hbcPath);
// Swift-side actor-delivery probe layered over the worker invocation above.
// start returns zero when invocation was queued; status returns zero while
// pending, one on success, and a negative or greater-than-one value on failure.
int nucleus_rn_command_handler_actor_smoke_start(const char *hbcPath);
int nucleus_rn_command_handler_actor_smoke_status(void);
void nucleus_rn_command_handler_actor_smoke_reset(void);
// Exercises replacement, in-flight entry retirement, and unused-handler
// teardown directly against HostCommandHandler.
int nucleus_rn_command_handler_ownership_smoke(void);
#ifdef __cplusplus
}
#endif
