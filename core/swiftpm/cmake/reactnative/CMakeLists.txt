# First-party host build of the React Native C++ runtime layer, ported from the
# Zig build's react_native.zig + the RN-curated folly/jsi configs. One superbuild
# producing the static libs the NucleusReactRuntime modules link:
#   folly_runtime, jsi, react_native (ReactCommon), react_cxx_platform, yogacore
# Deps are wired by absolute -D paths (the vendored submodules + fetched boost +
# the glog/Hermes builds) instead of RN's Android parent orchestration.
cmake_minimum_required(VERSION 3.13)
project(reactnative_cxx CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Dep roots passed via -D (absolute):
#   FOLLY_DIR FAST_FLOAT_INC FMT_INC DOUBLE_CONVERSION_INC GLOG_INC GLOG_SRC_INC
#   BOOST_INC JSI_DIR RN_ROOT HERMES_DIR
set(RC ${RN_ROOT}/ReactCommon)
set(RCXXP ${RN_ROOT}/ReactCxxPlatform)

# Shared defines (react_native.zig rn_flags + the stable_deps_rn folly/Hermes set).
# FOLLY_MOBILE=0 (the host value — RN's =1 is Apple-only) so folly's ABI matches
# ReactCommon.
set(RN_DEFS
    -DJS_RUNTIME_HERMES=1 -DHERMES_V1_ENABLED=1 -DREACT_NATIVE_DEBUG=1
    -DFOLLY_NO_CONFIG=1 -DFOLLY_MOBILE=0 -DFOLLY_CFG_NO_COROUTINES=1
    -DFOLLY_HAVE_CLOCK_GETTIME=1 -DFOLLY_HAVE_PTHREAD=1 -DFMT_USE_CONSTEVAL=0)
set(RN_WARN -Wno-unused-parameter -Wno-comma -Wno-sign-compare)

# Dependency include dirs every RN C++ unit needs.
set(DEP_INCLUDES
    ${FOLLY_DIR} ${BOOST_INC} ${GLOG_INC} ${GLOG_SRC_INC}
    ${DOUBLE_CONVERSION_INC} ${FMT_INC} ${FAST_FLOAT_INC})

# RN include roots. JSI_DIR (RN's ReactCommon/jsi) must precede HERMES_DIR/API/jsi:
# as of RN 0.87 RN's own jsi/hermes-interfaces.h defines the hermes interfaces
# (IEventLoopControl, …) that RuntimeScheduler depends on; Hermes bundles an older
# copy, so RN's must win the <jsi/hermes-interfaces.h> lookup.
set(RN_INCLUDES
    ${JSI_DIR}
    ${RC}
    ${RN_ROOT}/React
    ${RN_CODEGEN_ROOT}
    ${RN_CODEGEN_ROOT}/FBReactNativeSpec
    ${RC}/callinvoker
    ${RC}/jsiexecutor
    ${RC}/yoga
    ${RC}/runtimeexecutor
    ${RC}/react/nativemodule/core
    ${RN_ROOT}
    ${HERMES_DIR}/API
    ${HERMES_DIR}/API/jsi
    ${HERMES_DIR}/public
    ${RC}/react/renderer/components/view/platform/cxx
    ${RC}/react/renderer/components/scrollview/platform/cxx
    ${RC}/react/renderer/graphics/platform/cxx
    ${RC}/react/renderer/imagemanager
    ${RC}/react/renderer/imagemanager/platform/cxx
    ${RC}/react/renderer/imagemanager/platform/cxx/react/renderer/imagemanager
    ${RC}/react/utils/platform/cxx
    ${RC}/react/renderer/components/textinput
    ${RC}/react/renderer/components/textinput/platform/ios
    ${RC}/react/renderer/components/text/platform/cxx
    ${RC}/react/renderer/textlayoutmanager/platform/cxx
    ${RC}/react/renderer/components/rncore
    ${RC}/reactperflogger
    ${RC}/runtimeexecutor/platform/cxx
    ${RC}/jsitooling
    ${RCXXP})

# Files RN excludes from the host build.
set(RN_EXCLUDE_PATTERNS "jsilib-windows.cpp" "OSCompatWindows.cpp")
# Additional ReactCxxPlatform exclusions (no packager / dev-server in-process).
set(RCXXP_EXCLUDE_PATTERNS ${RN_EXCLUDE_PATTERNS} "PackagerConnection.cpp" "DevServerHelper.cpp")

# Glob *.cpp (non-recursive) from each <root>/<subdir>, dropping excluded files,
# into the named accumulator variable.
function(rn_glob out_var root excludes)
    set(acc "")
    foreach(sub ${ARGN})
        file(GLOB cpps "${root}/${sub}/*.cpp")
        foreach(f ${cpps})
            set(skip FALSE)
            foreach(ex ${excludes})
                if(f MATCHES "${ex}$")
                    set(skip TRUE)
                endif()
            endforeach()
            if(NOT skip)
                list(APPEND acc ${f})
            endif()
        endforeach()
    endforeach()
    set(${out_var} ${acc} PARENT_SCOPE)
endfunction()

# ── folly_runtime ─────────────────────────────────────────────────────────────
add_library(folly_runtime STATIC
    ${FOLLY_DIR}/folly/Conv.cpp
    ${FOLLY_DIR}/folly/FileUtil.cpp
    ${FOLLY_DIR}/folly/Format.cpp
    ${FOLLY_DIR}/folly/ScopeGuard.cpp
    ${FOLLY_DIR}/folly/SharedMutex.cpp
    ${FOLLY_DIR}/folly/String.cpp
    ${FOLLY_DIR}/folly/Unicode.cpp
    ${FOLLY_DIR}/folly/concurrency/CacheLocality.cpp
    ${FOLLY_DIR}/folly/container/detail/F14Table.cpp
    ${FOLLY_DIR}/folly/detail/FileUtilDetail.cpp
    ${FOLLY_DIR}/folly/detail/Futex.cpp
    ${FOLLY_DIR}/folly/detail/SplitStringSimd.cpp
    ${FOLLY_DIR}/folly/detail/UniqueInstance.cpp
    ${FOLLY_DIR}/folly/hash/SpookyHashV2.cpp
    ${FOLLY_DIR}/folly/json/dynamic.cpp
    ${FOLLY_DIR}/folly/json/json_pointer.cpp
    ${FOLLY_DIR}/folly/json/json.cpp
    ${FOLLY_DIR}/folly/lang/CString.cpp
    ${FOLLY_DIR}/folly/lang/Exception.cpp
    ${FOLLY_DIR}/folly/lang/SafeAssert.cpp
    ${FOLLY_DIR}/folly/lang/ToAscii.cpp
    ${FOLLY_DIR}/folly/memory/detail/MallocImpl.cpp
    ${FOLLY_DIR}/folly/net/NetOps.cpp
    ${FOLLY_DIR}/folly/portability/SysUio.cpp
    ${FOLLY_DIR}/folly/synchronization/SanitizeThread.cpp
    ${FOLLY_DIR}/folly/synchronization/ParkingLot.cpp
    ${FOLLY_DIR}/folly/system/AtFork.cpp
    ${FOLLY_DIR}/folly/system/ThreadId.cpp)
# Demangle.cpp omitted: its libiberty path is unavailable on host (partial system
# demangle.h, no libiberty); folly::demangle is off the runtime path.
target_compile_options(folly_runtime PRIVATE -fexceptions -frtti -fno-omit-frame-pointer ${RN_DEFS} ${RN_WARN})
target_compile_options(folly_runtime PUBLIC ${RN_DEFS})
target_include_directories(folly_runtime PUBLIC ${DEP_INCLUDES})

# ── ReactCommon jsi ───────────────────────────────────────────────────────────
add_library(jsi STATIC
    ${JSI_DIR}/jsi/jsi.cpp
    ${JSI_DIR}/jsi/JSIDynamic.cpp
    ${JSI_DIR}/jsi/jsilib-posix.cpp)
target_compile_options(jsi PRIVATE -O3 -Wno-unused-lambda-capture ${RN_DEFS})
target_include_directories(jsi PUBLIC ${JSI_DIR})
target_link_libraries(jsi PUBLIC folly_runtime)

# ── react_native (ReactCommon) ────────────────────────────────────────────────
rn_glob(RC_SRC "${RC}" "${RN_EXCLUDE_PATTERNS}"
    cxxreact devtoolsruntimesettings hermes/executor hermes/inspector-modern/chrome
    jserrorhandler jsi/jsi jsiexecutor/jsireact jsinspector-modern jsinspector-modern/cdp
    jsinspector-modern/network jsinspector-modern/tracing jsitooling/react/runtime logger
    oscompat react/bridging react/debug react/featureflags react/nativemodule/core/ReactCommon
    react/nativemodule/defaults react/nativemodule/devtoolsruntimesettings react/nativemodule/dom
    react/nativemodule/featureflags react/nativemodule/idlecallbacks
    react/nativemodule/intersectionobserver react/nativemodule/microtasks
    react/nativemodule/mutationobserver react/nativemodule/webperformance react/networking
    react/performance/cdpmetrics react/performance/timeline react/renderer/animated
    react/renderer/animated/drivers react/renderer/animated/event_drivers
    react/renderer/animated/internal react/renderer/animated/nodes react/renderer/animationbackend
    react/renderer/animations react/renderer/attributedstring react/renderer/componentregistry
    react/renderer/componentregistry/native react/renderer/components/image
    react/renderer/components/legacyviewmanagerinterop react/renderer/components/modal
    react/renderer/components/modal/platform/cxx react/renderer/components/root
    react/renderer/components/safeareaview react/renderer/components/scrollview
    react/renderer/components/text
    react/renderer/components/text/platform/cxx/react/renderer/components/text
    react/renderer/components/textinput
    react/renderer/components/textinput/platform/ios/react/renderer/components/iostextinput
    react/renderer/components/unimplementedview react/renderer/components/view
    react/renderer/consistency react/renderer/core react/renderer/css react/renderer/debug
    react/renderer/dom react/renderer/element react/renderer/graphics react/renderer/imagemanager
    react/renderer/imagemanager/platform/cxx/react/renderer/imagemanager react/renderer/leakchecker
    react/renderer/mapbuffer react/renderer/mounting react/renderer/mounting/internal
    react/renderer/mounting/stubs react/renderer/observers/events react/renderer/observers/intersection
    react/renderer/observers/mutation react/renderer/runtimescheduler react/renderer/scheduler
    react/renderer/telemetry react/renderer/textlayoutmanager
    react/renderer/textlayoutmanager/platform/cxx/react/renderer/textlayoutmanager
    react/renderer/uimanager react/renderer/uimanager/consistency react/renderer/viewtransition
    react/runtime react/runtime/hermes react/runtime/nativeviewconfig react/utils
    reactperflogger/fusebox reactperflogger/reactperflogger runtimeexecutor/platform/cxx/ReactCommon)
add_library(react_native STATIC ${RC_SRC})
target_compile_options(react_native PRIVATE -fexceptions -frtti ${RN_DEFS} ${RN_WARN})
target_include_directories(react_native PUBLIC ${RN_INCLUDES} ${DEP_INCLUDES})

# ── react_cxx_platform ────────────────────────────────────────────────────────
rn_glob(RCXXP_SRC "${RCXXP}" "${RCXXP_EXCLUDE_PATTERNS}"
    react/coremodules react/devsupport react/http react/io react/logging
    react/runtime/platform/cxx/react/runtime react/threading)
add_library(react_cxx_platform STATIC ${RCXXP_SRC})
target_compile_options(react_cxx_platform PRIVATE -fexceptions -frtti ${RN_DEFS} ${RN_WARN})
target_include_directories(react_cxx_platform PUBLIC ${RN_INCLUDES} ${DEP_INCLUDES})

# ── yogacore ──────────────────────────────────────────────────────────────────
rn_glob(YOGA_SRC "${RC}/yoga" "${RN_EXCLUDE_PATTERNS}"
    yoga yoga/algorithm yoga/config yoga/debug yoga/event yoga/node)
add_library(yogacore STATIC ${YOGA_SRC})
target_compile_options(yogacore PRIVATE -fexceptions -frtti ${RN_DEFS} ${RN_WARN})
target_include_directories(yogacore PUBLIC ${RC}/yoga ${DEP_INCLUDES})
