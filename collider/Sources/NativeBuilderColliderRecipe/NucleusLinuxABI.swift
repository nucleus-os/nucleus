public enum NucleusLinuxABI {
    public enum ELFOwner: String, Codable, Hashable, Sendable {
        case artifact
        case host
    }

    public static let minimumGlibcVersion = "2.38"
    public static let sdkDirectoryName =
        "nucleus-linux-glibc-\(minimumGlibcVersion).sdk"

    private static let artifactOwnedSONames: Set<String> = [
        "libBlocksRuntime.so",
        "libFoundation.so",
        "libFoundationEssentials.so",
        "libFoundationInternationalization.so",
        "libTesting.so",
        "libXCTest.so",
        "lib_FoundationICU.so",
        "lib_TestingInterop.so",
        "libc++.so.1",
        "libc++abi.so.1",
        "libdispatch.so",
        "libunwind.so.1",
        "libxml2.so.2",
    ]

    package static let hostOwnedSONames: Set<String> = [
        "ld-linux-aarch64.so.1",
        "ld-linux-x86-64.so.2",
        "libc.so.6",
        "libaudit.so.1",
        "libbrotlidec.so.1",
        "libbsd.so.0",
        "libbz2.so.1.0",
        "libcap.so.2",
        "libcrypto.so.3",
        "libcurl.so.4",
        "libdl.so.2",
        "libdrm.so.2",
        "libevdev.so.2",
        "libexpat.so.1",
        "libfontconfig.so.1",
        "libfreetype.so.6",
        "libgbm.so.1",
        "libgcc_s.so.1",
        "libgcrypt.so.20",
        "libgssapi_krb5.so.2",
        "libidn2.so.0",
        "libinput.so.10",
        "liblber.so.2",
        "libldap.so.2",
        "liblz4.so.1",
        "liblzma.so.5",
        "libm.so.6",
        "libmtdev.so.1",
        "libnghttp2.so.14",
        "libpam.so.0",
        "libpng16.so.16",
        "libpthread.so.0",
        "libpsl.so.5",
        "libresolv.so.2",
        "librtmp.so.1",
        "librt.so.1",
        "libseat.so.1",
        "libssh.so.4",
        "libssl.so.3",
        "libsystemd.so.0",
        "libudev.so.1",
        "libutil.so.1",
        "libvulkan.so.1",
        "libwacom.so.9",
        "libwayland-client.so.0",
        "libwayland-server.so.0",
        "libXau.so.6",
        "libXdmcp.so.6",
        "libxcb-composite.so.0",
        "libxcb-ewmh.so.2",
        "libxcb-icccm.so.4",
        "libxcb-res.so.0",
        "libxcb-xfixes.so.0",
        "libxcb-randr.so.0",
        "libxcb.so.1",
        "libxkbcommon.so.0",
        "libz.so.1",
        "libzstd.so.1",
        "linux-vdso.so.1",
    ]

    public static func owner(ofSONAME name: String) -> ELFOwner? {
        if artifactOwnedSONames.contains(name) || name.hasPrefix("libswift") {
            return .artifact
        }
        if hostOwnedSONames.contains(name) {
            return .host
        }
        return nil
    }
}
