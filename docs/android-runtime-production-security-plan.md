# Android Runtime Production Security Plan

## Security invariant

Nucleus runs Android without a virtual machine. A malicious Android app or
compromised Android service must not gain the user's host identity, files,
session services, devices, network namespace, or broker privileges. Android
apps must remain isolated from each other. An Android image build must not
receive host credentials or production signing keys, and failure of an
expected sandbox must stop the build.

This plan implements that invariant with conventional, inspectable controls:
Linux namespaces, an unprivileged UID map, cgroups, seccomp, AppArmor, Android
SELinux, narrowly scoped brokers, a rootless OCI build container, and standard
AOSP signing tools. It does not introduce a VM, custom build authorities,
custom signing protocols, mandatory duplicate builds, or a second security
framework maintained only by Nucleus.

## Threat model

The production boundary assumes:

- Android applications can be malicious.
- Android framework services, HALs, media decoders, graphics command streams,
  translated ARM code, and broker requests can contain attacker-controlled
  input.
- An Android app may exploit another Android component and obtain Android root.
- A build dependency or build step can be compromised.
- The normal desktop user account contains sensitive files and session
  capabilities.

The boundary protects:

- the host kernel attack surface to the extent possible without a VM;
- the desktop user's files, credentials, devices, sockets, and processes;
- other Android apps and their data;
- production signing keys;
- release integrity against accidental contamination and a compromised build
  worker that does not also control the separately administered signer.

The boundary does not claim to survive:

- a host-kernel compromise;
- host root or an administrator deliberately changing the confinement;
- coordinated compromise of source review, the build environment, and the
  production signer;
- microarchitectural attacks requiring a hardware security boundary.

Those limits are explicit. Containers share the host kernel, so host kernel
maintenance and minimizing exposed kernel interfaces remain mandatory.

## Target architecture

The runtime has four boundaries:

1. The Android container runs in a user namespace whose root maps to a
   non-root subordinate host ID. It receives no host network interface and no
   direct GPU device.
2. Android SELinux runs enforcing inside Android and separates apps, framework
   services, HALs, and sensitive app data.
3. Host brokers are separate, unprivileged, sandboxed processes. Each exposes
   one authenticated Unix socket and only the resources needed for its job.
4. ARM translation, when enabled, is a separate sandboxed service. Translated
   code never executes in a general host process or a graphics/network broker.

The build has two boundaries:

1. Collider compiles AOSP once in the pinned rootless OCI image defined by
   `android-runtime/build-container/Containerfile`. The build has no network,
   host home, session sockets, credentials, or devices. Soong's own nsjail
   sandbox is required and fails closed.
2. Production signing happens outside the build job in a separately
   administered restricted or offline environment using standard AOSP release
   tools. Collider's signing task is only for a clearly identified local
   development key set and runs in a second rootless, networkless container
   invocation.

The release unit is the unsigned target-files archive and its SHA-256 digest.
There is no custom capsule schema, signing ledger, authority socket protocol,
or normalization format.

## Controls retained from the current runtime

The following controls are production requirements:

- Unprivileged user namespace and subordinate UID/GID mapping. Container UID 0
  never maps to host UID 0 or the desktop user.
- A private mount namespace, PID namespace, IPC namespace, UTS namespace, and
  cgroup namespace.
- A private binderfs instance. Host binder devices are never passed through.
- Device cgroup default deny. The allowlist contains only the pseudo-devices
  Android demonstrably requires.
- No `/dev/dri`, input, camera, audio, block, raw HID, kmsg, or arbitrary
  character devices in the Android container.
- `/dev/kmsg` remains a controlled PTY endpoint rather than the host kernel log.
- No host network interface in the Android container.
- Read-only system partitions and explicit writable data mounts.
- No host home directory, runtime directory, Wayland socket, D-Bus socket,
  SSH/GPG agent, keyring, or environment credential in the container.
- `no_new_privs`, AppArmor confinement, a syscall allowlist, and a capability
  allowlist.
- Production builds use `user`, not `userdebug`, and disable adb/root/debug
  surfaces.

## Phase 1 — Make the build boundary conventional and fail closed

This phase lands first because it removes custom security machinery while
retaining the security property that matters.

### Rootless OCI build

Collider performs these steps:

1. Require Podman with rootless user namespaces and configured subordinate
   UID/GID ranges.
2. Build `android-runtime/build-container/Containerfile`. Its Ubuntu base is
   pinned by OCI digest. Record Podman's content-addressed image ID as a task
   output.
3. Verify the image ID is a `sha256:` digest and execute subsequent tasks by
   that ID, not a mutable tag.
4. Validate the AOSP source lock, materialized Repo revisions, forward-patch
   provenance, and clean worktrees before entering the container.
5. Mount the AOSP source read-only at `/src`.
6. Mount only `.aosp-build/out` and `.aosp-build/dist` writable at the
   source-local `OUT_DIR` and `DIST_DIR` paths Soong requires.
7. Run Podman rootless with:
   `--network=none`, `--userns=keep-id`, `--cap-drop=all`,
   `--security-opt=no-new-privileges`, `--read-only`, bounded PIDs, private
   tmpfs for `/tmp` and the build home, and no device additions.
8. Pass an explicit deterministic build environment. Do not inherit proxy,
   cloud, SSH, GPG, desktop-session, or credential variables.
9. Build `target-files-package` and `otatools`.
10. Copy the resulting unsigned target-files archive to the declared output
    and hash it.

Image construction may use the network to fetch the pinned base and Ubuntu
packages. AOSP compilation does not use the network. Dependency updates happen
by intentionally updating the Containerfile and reviewing the resulting
change.

### Soong nsjail warning

`Build sandboxing disabled due to nsjail error` is not acceptable for a
production image build. Container isolation protects the host, but Soong's
inner sandbox limits build actions relative to other source and output.

Keep
`aosp/patches/platform-build-soong/0001-soong-fail-closed-when-nsjail-is-unavailable.patch`.
The patch turns sandbox setup failure into a build failure. Collider also
rejects the known degradation message even if an upstream code path returns
success.

The qualification gate runs a small AOSP build in the rootless OCI boundary
and proves:

- nsjail starts successfully with the host kernel and Podman configuration;
- a deliberately forbidden read and network access fail;
- the known warning is absent;
- the fail-closed patch aborts a deliberately broken nsjail configuration.

Do not work around nsjail by adding broad capabilities, host networking,
`--privileged`, or disabling the outer container boundary. Fix the specific
namespace, seccomp, or mount prerequisite.

### Signing

Local development signing uses the existing generated development RSA key set.
The signing command runs in a fresh rootless Podman invocation with:

- the OCI filesystem read-only;
- no network;
- all capabilities dropped;
- `no_new_privs`;
- unsigned target-files, AOSP host tools, and development keys read-only;
- only the signing output directory writable;
- a private tmpfs home and temporary directory.

Production signing is not a Collider build task. The production signer:

1. receives the unsigned target-files archive and expected SHA-256 digest;
2. verifies the digest and approved source/build metadata;
3. signs with standard `sign_target_files_apks`;
4. creates images with standard `img_from_target_files`;
5. emits the signed target-files archive, images, and their digests;
6. returns artifacts for independent validation.

Production keys never enter the source checkout, build worker, OCI image,
Collider state, or local-development signing directory. Hardware-backed or
offline key custody is preferred, but the interface remains standard AOSP
files/tools instead of a Nucleus-specific authority protocol.

Run a periodic reproducibility job that builds the same locked input on a
second clean worker and compares unsigned artifacts. This is a monitoring and
incident-detection control, not a prerequisite on every developer build.

### Removed architecture

Delete and do not replace:

- build-A/build-B mandatory workers;
- comparison, signing, and release-verification authority daemons;
- authority Unix sockets and descriptor-passing protocol;
- custom Ed25519 attestation chains;
- capsule root images and capsule qualification;
- security-root lock/schema/version tracking;
- custom target-files normalization and signing-transform proof tools;
- signing ledgers and mandatory dual-build approval objects.

## Phase 2 — Reduce the Android container kernel interface

Replace the runtime seccomp denylist with an allowlist derived from a successful
boot, app launch, rendering, audio, storage, and shutdown trace. Add syscalls
only with a documented caller and runtime requirement.

The final policy denies at minimum:

- `bpf`;
- `perf_event_open`;
- `userfaultfd`;
- `io_uring_setup`, `io_uring_enter`, and `io_uring_register`;
- `add_key`, `request_key`, and `keyctl`;
- `kexec_load`, `kexec_file_load`, and module-loading syscalls;
- `open_by_handle_at`;
- obsolete or architecture-specific syscall families not used by Android.

Nested namespace operations require a specific decision. Deny `setns` and
unneeded namespace types. Permit `unshare` or `clone3` namespace flags only
where Android's own process model demonstrably requires them. AppArmor also
denies namespace transitions and host paths that seccomp cannot express.

Audit the capability keep list from boot traces and kernel checks. Remove inert
or unnecessary entries, including capabilities checked only in the initial
user namespace. Keep the minimum needed to boot Android inside its namespaces.
Document every retained capability next to the runtime configuration.

Add a startup self-check that verifies the effective UID map, capability sets,
seccomp mode, AppArmor label, namespaces, device list, binderfs mount, mount
flags, and absence of a network interface. Refuse to boot on mismatch.

## Phase 3 — Sandbox every host broker

Treat the graphics, BPF, network, audio, clipboard, input, and future device
brokers as the highest-risk host components because they parse guest-controlled
requests across the boundary.

Each broker gets:

- a dedicated executable and AppArmor profile;
- a dedicated unprivileged service identity where practical;
- its own mount namespace with an empty or inaccessible home;
- `no_new_privs`;
- a broker-specific seccomp allowlist;
- no network unless it is the network broker;
- no ambient or retained capabilities unless one operation proves necessary;
- a private runtime directory and one socket;
- explicit resource limits and request-size limits;
- peer credential verification and protocol version negotiation;
- strict descriptor-count, descriptor-type, length, offset, and overflow
  validation.

The Android AppArmor profile connects only to named broker labels. Remove any
rule that permits a connection to a generic `unconfined` peer. Broker sockets
are not placed in a directory writable by Android.

The graphics broker alone opens the render node. It receives no host home,
input devices, desktop sockets, or arbitrary filesystem access. Prefer a render
node over a primary DRM node. Device selection and Vulkan extension
requirements fail closed.

Add libFuzzer harnesses for every guest-controlled native parser, beginning
with the gfxstream socket protocol, ring decoder, descriptor import, and size/
offset validation. Run ASan and UBSan corpora in CI. Keep TSan for concurrency
tests, but do not treat it as parser fuzzing.

## Phase 4 — Enable Android SELinux enforcing

SELinux is not the host-container boundary, but it is required for reasonable
multi-app security. Without it, one compromised Android system service can
reach substantially more app and system data before attempting a container
escape.

Start from AOSP policy for the selected platform release and add the smallest
Nucleus device policy needed for:

- init and container boot adaptations;
- binder services;
- Composer3 and allocator HALs;
- audio;
- KeyMint;
- storage and media;
- broker socket endpoints;
- any ARM translation client service.

Production images boot with SELinux enforcing and no permissive domains.
Never ship policy generated by accepting all audit denials. Every allow rule
names the subject, object, operation, and runtime reason. CI runs policy
compilation, neverallow checks, a clean enforcing boot, app-isolation tests,
and negative access tests.

Use a secure KeyMint design for production. `keymint-service.nonsecure` is a
development implementation and must not back claims of hardware-protected or
rollback-resistant secrets. If hardware-backed keys are unavailable, expose
the limitation accurately and isolate the software implementation and its
state.

## Phase 5 — Add brokered networking

Keep the Android container without a host network interface. Provide networking
through a dedicated userspace broker or narrowly configured slirp/pasta
process in its own namespace and AppArmor/seccomp profile.

The network boundary provides:

- no access to host loopback, link-local metadata services, or Unix sockets;
- default denial of inbound host connections;
- explicit DNS handling;
- egress policy and per-app accounting hooks;
- bounded connection, buffer, and file-descriptor counts;
- a clean teardown path;
- tests for host-service isolation and namespace escape.

Do not use host network namespace sharing. Do not give Android a bridge that
implicitly exposes host and LAN services. A veth/NAT design is acceptable only
if firewall policy provides the same default-deny properties and is installed
atomically before the interface becomes usable.

## Phase 6 — Support ARM applications with a separate translation boundary

ARM applications can meet the same reasonable security standard, but binary
translation adds a large native parser/JIT surface and must not be loaded into
the Android container supervisor or a general host broker.

Use a supported x86_64-to-ARM Android native-bridge implementation whose
license and redistribution terms permit shipping. Pin its source or binary
digest and update it through the same reviewed dependency process as other
runtime components.

Architecture:

1. Android's native bridge detects ARM-only application code.
2. A narrow Android-side client sends code and execution requests to a
   dedicated translation service.
3. The translation service runs as a separate unprivileged process with its
   own user, PID, mount, IPC, and network namespaces; AppArmor profile; seccomp
   allowlist; cgroup; and private tmpfs.
4. It receives only the application code/data and descriptors required for
   that execution. It cannot open the Android data tree, host files, GPU,
   broker sockets, or network directly.
5. Generated code is stored in a private bounded cache. Writable and executable
   mappings are never simultaneous. Enforce W^X and seal executable artifacts
   before use.
6. Translation crashes terminate the affected app/service, not the Android
   supervisor or a host broker.

The translator syscall policy excludes namespace creation, BPF, perf, keyring,
mount, ptrace outside its process tree, device access, and direct network
creation. If JIT operation requires a syscall otherwise denied to Android,
permit it only in this translator profile.

Qualification covers ARM32 and ARM64 APKs, JNI, signals, threads, exceptions,
Binder calls, graphics, audio, storage, lifecycle, cache corruption, malformed
ELF input, and translator restart. Fuzz ELF parsing, relocation, instruction
decoding, bridge metadata, and IPC framing. Run the translator under ASan/
UBSan where supported.

ARM support does not ship until the translator is independently sandboxed and
passes the same host-isolation tests as every broker. If a viable translator
cannot meet these constraints, Nucleus remains x86_64-only.

## Phase 7 — Adopt selected GrapheneOS hardening

GrapheneOS work is a source of reviewed hardening ideas, not a patch bundle.
Nucleus tracks the Android release it builds and ports only changes that apply
cleanly to that release and threat model.

Prioritize:

- hardened allocator integration for native system processes and apps;
- stronger stack protection, CFI, integer-overflow checks, and fortification
  where toolchain and performance validation permit;
- zero-on-free and memory initialization options for sensitive processes;
- hardened app spawning and package-installation behavior;
- tighter permissions and user-facing controls for sensors, network, storage,
  clipboard, and dynamic code loading;
- parser and media hardening;
- verified-boot and rollback-protection improvements that apply to container
  images;
- Android SELinux policy improvements and attack-surface reductions.

Do not port:

- Pixel-specific firmware, bootloader, TrustZone, hardware attestation, radio,
  or kernel-device patches with no Nucleus equivalent;
- changes whose security property depends on a GrapheneOS kernel configuration
  Nucleus does not provide;
- branding, updater, compatibility, or service changes unrelated to security;
- a large downstream patch stack without per-patch ownership and tests.

For each port, record upstream commit, Android release, local adaptation,
security property, tests, and update owner in the existing AOSP patch manifest
and patch header. Compile every integration in the single product; do not hide
ports behind optional profiles.

## Phase 8 — Production qualification and operations

Automate a single security qualification command that fails on any unmet
production invariant:

- rootless UID/GID map is correct;
- namespaces and cgroups are private;
- capability and device allowlists match;
- seccomp and AppArmor are enforcing;
- Android SELinux is enforcing with no permissive domains;
- no direct GPU or host network device is present;
- broker peer labels and credentials match;
- host home and session sockets are unreachable;
- malicious-app escape regression tests fail safely;
- signed images and AVB metadata validate;
- production artifacts contain release keys and no test keys;
- Soong nsjail is active and cannot degrade silently;
- ARM translator isolation passes when ARM support is enabled;
- parser fuzz targets meet their corpus and sanitizer gates.

Maintain a host kernel baseline with user namespaces, binderfs, cgroup v2,
seccomp, AppArmor, and the required namespace features enabled. Treat kernel,
Podman, AOSP, gfxstream, translation engine, and broker dependency updates as
security updates. Re-run qualification after each update.

Log security-relevant lifecycle events without logging app data, key material,
or guest command payloads: policy load, broker start/stop, peer rejection,
limit violations, sandbox mismatch, image provenance, and validation result.
Rate-limit attacker-triggerable logs.

## Completion criteria

This plan is complete when:

- no custom AOSP authority/capsule/signing protocol remains;
- Collider compiles AOSP only in the pinned rootless OCI boundary;
- Soong sandbox degradation is fatal;
- local signing uses a separate restricted container invocation;
- production signing is externally administered and never exposes keys to the
  build worker;
- the Android runtime uses syscall, capability, and device allowlists;
- all host brokers are independently confined and peer-labelled;
- Android SELinux is enforcing;
- networking is brokered and host services are unreachable;
- ARM translation, if shipped, is independently sandboxed;
- selected GrapheneOS hardening has explicit provenance and tests;
- the automated production qualification gate passes.
