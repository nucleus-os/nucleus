# NucleusStorage volume

## Invariant

`/Volumes/NucleusStorage` holds artifacts distributed through distro package
managers, served from a Nucleus-hosted repository. It is an archive and
publication volume. It never holds Collider workspaces, build intermediates,
compiler caches, or developer source, and no build step depends on it being
mounted.

## Hardware

SanDisk Professional G-DRIVE, 22 TB, enclosing a WD Ultrastar DC HC570
(`WUH722222ALE6L4`), attached over USB. The macOS device node is not stable
across reconnects; address the volume by mount path.

## Format and configuration

The volume is APFS, **case-insensitive**, with the configuration below applied
at format time.

**Ownership enabled** (`diskutil enableOwnership`), volume root owned by
`maddy:staff`. Ownership is not the trust boundary for a package repository —
apt's trust anchor is the GPG signature over `Release`/`InRelease` — but it
governs signing-key file permissions, constrains a web-server user to read-only
access, and survives `rsync -a` to a Linux host.

**Spotlight indexing off** (`mdutil -i off`).

**`disksleep 0` and `sleep 0`.** The enclosure cuts drive power rather than
parking heads, so any sleep timer costs a full spin-up. SMART recorded 1662
power cycles against 1870 power-on hours before this was set — roughly one
spin-up per hour of runtime.

Case-insensitivity is deliberate. A Debian pool is safe because Debian policy
requires lowercase package names. The volume therefore must not hold unpacked
Linux source trees or rootfs images, which collide on case. Changing this
requires a reformat.

## Throughput

Measured at full spec: raw outer-track read 279.9 MB/s, filesystem sequential
write 278.5 MB/s, against a rated 280 MB/s.

## Link negotiation

The USB bridge negotiates 5 Gbps on macOS regardless of cable. This was
verified with two cables including a certified 10 Gbps e-marked Club3D
CAC-1522. macOS implements no USB 3.2 Gen 2x2 support, so the bridge falls back
to Gen 1.

This is not a bottleneck and is settled: 280 MB/s is approximately 2.24 Gbps
against a 5 Gbps link, so the drive saturates its mechanism well before the
link. Do not re-investigate cabling or link rate for throughput reasons.
