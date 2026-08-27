# Nvidia proprietary DRM observations

These are dated hardware observations, not presentation policy.

An RTX 3090 on proprietary driver 590.48 showed every-other-frame flicker when atomic commits alternated primary-plane framebuffer IDs. Holding one framebuffer in flight reduced the symptom. KWin and gamescope use different combinations of commit threading, fence handling, readiness checks, and buffering, so the observation does not justify a vendor-name branch by itself.

The current compositor has no general Nvidia single-buffer policy. Any new workaround requires a fresh reproducible capture on a supported driver, evidence identifying the failing kernel/driver contract, a narrow capability or failure-based gate, and regression coverage for other GPUs. Mailbox/latest-wins remains eligible unless runtime validation proves it unsafe.

When qualifying Nvidia, record driver version, GPU, connector/mode, atomic properties, explicit-sync path, framebuffer sequence, flip timestamps, and fallback behavior. Compare direct scanout and composed presentation before changing policy.
