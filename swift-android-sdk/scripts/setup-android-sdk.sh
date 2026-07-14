#!/usr/bin/env bash
# this script will setup the ndk-sysroot with links to the
# local installation indicated by ANDROID_NDK_HOME
set -e
if [ -z "${ANDROID_NDK_HOME}" ]; then
    echo "$(basename $0): error: missing environment variable ANDROID_NDK_HOME"
    exit 1
fi

ndk_prebuilt="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt"
if [ ! -d "${ndk_prebuilt}" ]; then
    echo "$(basename $0): error: ANDROID_NDK_HOME not found: ${ndk_prebuilt}"
    exit 1
fi

#Pkg.Revision = 27.0.12077973
#Pkg.Revision = 28.1.13356709
ndk_version=$(grep '^Pkg.Revision = ' "${ANDROID_NDK_HOME}/source.properties" | cut -f3- -d' ' | cut -f 1 -d '.')
if [[ "${ndk_version}" -lt 27 ]]; then
    echo "$(basename $0): error: minimum NDK version 27 required; found ${ndk_version} in ${ANDROID_NDK_HOME}/source.properties"
    exit 1
fi

cd $(dirname $(dirname $(realpath -- "${BASH_SOURCE[0]}")))
swift_resources=swift-resources
ndk_sysroot=ndk-sysroot
# Legacy directory: older bundles symlinked the NDK tool binaries here for a
# swift-toolset.json `rootPath` -> -tools-directory. The SWBAndroidPlatform
# plugin now derives -tools-directory from the discovered NDK directly
# (NUCLEUS_SWIFT_BUILD_ANDROID_NDK_TOOLS_DIRECTORY), so it is no longer linked.
# Still cleared on re-setup so a stale link from an older bundle never wins.
ndk_toolchain=ndk-toolchain

if [[ -d "${ndk_sysroot}" || -e "${ndk_toolchain}" ]]; then
    # clear out any previous NDK setup
    rm -rf ${ndk_sysroot} ${ndk_toolchain}
    ndk_re="re-"
fi

# link vs. copy the NDK files
SWIFT_ANDROID_NDK_LINK=${SWIFT_ANDROID_NDK_LINK:-1}
if [[ "${SWIFT_ANDROID_NDK_LINK}" == 1 ]]; then
    ndk_action="${ndk_re}linked"
    mkdir -p ${ndk_sysroot}/usr/lib
    ln -s ${ndk_prebuilt}/*/sysroot/usr/include ${ndk_sysroot}/usr/include
    for triplePath in ${ndk_prebuilt}/*/sysroot/usr/lib/*; do
        triple=$(basename ${triplePath})
        ln -s ${triplePath} ${ndk_sysroot}/usr/lib/${triple}
    done
else
    ndk_action="${ndk_re}copied"
    cp -a ${ndk_prebuilt}/*/sysroot ${ndk_sysroot}
fi

# link the NDK's clang resource directory
# e.g., ~/Library/Android/sdk/ndk/27.0.12077973/toolchains/llvm/prebuilt/darwin-x86_64/lib/clang/18 or /opt/homebrew/share/android-ndk/toolchains/llvm/prebuilt/darwin-x86_64/lib/clang/19
ln -sf ${ndk_prebuilt}/*/lib/clang/* ${swift_resources}/usr/lib/swift/clang

# copy each architecture's swiftrt.o into the sysroot,
# working around https://github.com/swiftlang/swift/pull/79621
for folder in swift swift_static; do
    for swiftrt in ${swift_resources}/usr/lib/${folder}-*/android/*/swiftrt.o; do
        arch=$(basename $(dirname ${swiftrt}))
        mkdir -p ${ndk_sysroot}/usr/lib/${folder}/android/${arch}
        if [[ "${SWIFT_ANDROID_NDK_LINK}" == 1 ]]; then
            ln -s ../../../../../../${swiftrt} ${ndk_sysroot}/usr/lib/${folder}/android/${arch}/
        else
            cp -a ${swiftrt} ${ndk_sysroot}/usr/lib/${folder}/android/${arch}/
        fi
    done
done

echo "$(basename $0): success: ndk-sysroot ${ndk_action} to Android NDK at ${ndk_prebuilt}"
