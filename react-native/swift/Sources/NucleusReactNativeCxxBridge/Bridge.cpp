#include "NucleusReactNativeCxxBridge/Bridge.h"

#include <hermes/hermes.h>
#include <jsi/jsi.h>

#include <folly/json.h>
#include <folly/dynamic.h>

#include <cmath>
#include <memory>
#include <string>

double nucleus_rn_hermes_runtime_roundtrip(double value) {
    auto runtime = facebook::hermes::makeHermesRuntime();
    try {
        auto &rt = *runtime;
        rt.global().setProperty(rt, "nucleusAnswer", facebook::jsi::Value(value));
        return rt.global().getProperty(rt, "nucleusAnswer").getNumber();
    } catch (const facebook::jsi::JSIException &) {
        return std::nan("");
    }
}

int nucleus_rn_folly_roundtrip(int n) {
    folly::dynamic obj = folly::dynamic::object("x", n);
    std::string json = folly::toJson(obj);
    folly::dynamic parsed = folly::parseJson(json);
    return parsed["x"].asInt() == n ? n : -1;
}
