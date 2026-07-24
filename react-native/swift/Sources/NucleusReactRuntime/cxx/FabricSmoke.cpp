// Test-only smoke entry: drives the React Native runtime headless (the runtime
// is single-threaded — JS runs on the calling thread, drained manually), so a
// unit test can prove the statically-linked full fabric *runs*, not just links.
// Compiled inside the host C++ target so it shares its build environment (the
// facade header transitively pulls the emitted Swift→C++ header). Catches C++
// exceptions (the Swift test runtime has them disabled) and returns 0 on full
// success; a nonzero code identifies the failing step (100 + step on a throw).
#include <NucleusReactRuntime/HostCommandBridge.hpp>
#include <NucleusReactRuntime/ReactRuntimeHostFacade.hpp>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <exception>
#include <mutex>
#include <string>
#include <thread>

namespace {

void countJSWorkWake(void *context) {
    static_cast<std::atomic<int> *>(context)->fetch_add(
        1, std::memory_order_relaxed);
}

struct CommandLifetimeState final {
    std::mutex mutex;
    std::condition_variable condition;
    bool entered{false};
    bool unblock{false};
    std::atomic<int> invocations{0};
    std::atomic<int> releases{0};
};

void blockingHostCommand(
    void *context,
    const char *,
    const char *) {
    auto *state = static_cast<CommandLifetimeState *>(context);
    state->invocations.fetch_add(1, std::memory_order_relaxed);
    std::unique_lock lock(state->mutex);
    state->entered = true;
    state->condition.notify_all();
    state->condition.wait(lock, [state] {
        return state->unblock;
    });
}

void countHostCommandRelease(void *context) {
    static_cast<CommandLifetimeState *>(context)
        ->releases.fetch_add(1, std::memory_order_relaxed);
}

} // namespace

extern "C" int nucleus_rn_fabric_smoke(const char *hbcPath) {
    using namespace nucleus::react;
    int step = 0;
    try {
        step = 1;
        if (!ReactRuntimeHostFacade::hermesCanCreateRuntime()) {
            return 1;
        }
        step = 2;
        auto facade = makeReactRuntimeHostFacade();
        if (!facade) {
            return 2;
        }
        // NB: installFabric() is intentionally not exercised here — the Fabric
        // UIManager requires a Swift SwiftTextLayoutManager handle (the render /
        // text-measurement bridge), which is surface wiring, not a link concern.
        // This smoke proves the runtime *core* runs statically: the RN runtime +
        // Hermes construct, evaluate real bytecode, and drain the JS queue.
        step = 3;
        facade->evaluateBytecode(std::string(hbcPath));
        step = 4;
        facade->drainPendingJSCalls();
        return 0;
    } catch (const std::exception &e) {
        std::fprintf(stderr, "nucleus_rn_fabric_smoke: step %d threw: %s\n", step, e.what());
        return 100 + step;
    } catch (...) {
        std::fprintf(stderr, "nucleus_rn_fabric_smoke: step %d threw (non-std)\n", step);
        return 200 + step;
    }
}

extern "C" int nucleus_rn_js_work_wake_smoke(const char *hbcPath) {
    using namespace nucleus::react;
    try {
        auto facade = makeReactRuntimeHostFacade();
        if (!facade) {
            return 1;
        }
        std::atomic<int> wakes{0};
        auto installed = facade->setJSWorkWakeHandler(
            countJSWorkWake, &wakes, nullptr);
        if (!installed.succeeded) {
            return 2;
        }
        auto evaluated = facade->evaluateBytecode(std::string(hbcPath));
        if (!evaluated.succeeded) {
            return 3;
        }
        const auto deadline =
            std::chrono::steady_clock::now() + std::chrono::seconds(2);
        while (wakes.load(std::memory_order_relaxed) == 0
               && std::chrono::steady_clock::now() < deadline) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        if (wakes.load(std::memory_order_relaxed) != 1) {
            return 4;
        }
        auto drained = facade->drainPendingJSCalls();
        if (!drained.succeeded || drained.unsignedValue == 0) {
            return 5;
        }
        return 0;
    } catch (...) {
        return 6;
    }
}

extern "C" int nucleus_rn_invoke_host_command_on_js_worker(
    void (*callback)(void *, const char *, const char *),
    void *context,
    void (*release)(void *),
    const char *hbcPath) {
    using namespace nucleus::react;
    int result = 0;
    std::thread worker;
    try {
        worker = std::thread([&] {
            ReactRuntimeHostFacade facade;
            const auto installed =
                facade.setCommandHandler(callback, context, release);
            if (!installed.succeeded) {
                result = 2;
                return;
            }
            const auto invoked = facade.evaluateBytecode(
                hbcPath == nullptr ? std::string() : std::string(hbcPath));
            if (!invoked.succeeded) {
                std::fprintf(
                    stderr,
                    "command-handler actor smoke bytecode invocation failed: %s\n",
                    invoked.error.c_str());
                result = 3;
            }
        });
    } catch (...) {
        if (release != nullptr) {
            release(context);
        }
        return 1;
    }
    worker.join();
    return result;
}

extern "C" int nucleus_rn_command_handler_ownership_smoke() {
    using namespace nucleus::react;
    CommandLifetimeState original;
    CommandLifetimeState replacement;
    {
        HostCommandHandler handler;
        handler.set(
            blockingHostCommand,
            &original,
            countHostCommandRelease);
        auto entry = handler.get();
        if (entry == nullptr) {
            return 1;
        }
        std::thread invocation([
            entry = std::move(entry)
        ] {
            entry->callback(
                entry->context,
                "original",
                "{}");
        });

        bool entered = false;
        {
            std::unique_lock lock(original.mutex);
            entered = original.condition.wait_for(
                lock,
                std::chrono::seconds(2),
                [&original] {
                    return original.entered;
                });
        }
        handler.set(
            blockingHostCommand,
            &replacement,
            countHostCommandRelease);
        const bool releasedWhileInFlight =
            original.releases.load(std::memory_order_relaxed) != 0;
        {
            std::lock_guard lock(original.mutex);
            original.unblock = true;
        }
        original.condition.notify_all();
        invocation.join();

        if (!entered) {
            return 2;
        }
        if (releasedWhileInFlight) {
            return 3;
        }
        if (original.invocations.load(std::memory_order_relaxed) != 1) {
            return 4;
        }
        if (original.releases.load(std::memory_order_relaxed) != 1) {
            return 5;
        }
        if (replacement.releases.load(std::memory_order_relaxed) != 0) {
            return 6;
        }
    }
    return replacement.releases.load(std::memory_order_relaxed) == 1
        ? 0
        : 7;
}
