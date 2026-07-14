#include "include/core/SkRefCnt.h"
#include "include/core/SkString.h"
#include "include/effects/SkRuntimeEffect.h"

#include <cstdio>

extern "C" void* nucleus_runtime_effect_make(const char* sksl, int sksl_len) {
    auto [effect, err] = SkRuntimeEffect::MakeForShader(SkString(sksl, sksl_len));
    if (!effect) {
        std::fprintf(stderr, "SKSL compile error: %s\n", err.c_str());
        return nullptr;
    }
    return effect.release();
}

extern "C" void nucleus_runtime_effect_destroy(void* effect) {
    SkSafeUnref(static_cast<SkRuntimeEffect*>(effect));
}

