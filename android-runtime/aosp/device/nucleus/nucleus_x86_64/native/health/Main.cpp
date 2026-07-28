//
// Copyright 2026 Nucleus
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#include <aidl/android/hardware/health/BatteryCapacityLevel.h>
#include <aidl/android/hardware/health/BatteryChargingPolicy.h>
#include <aidl/android/hardware/health/BatteryChargingState.h>
#include <aidl/android/hardware/health/BatteryHealth.h>
#include <aidl/android/hardware/health/BatteryStatus.h>
#include <android-base/logging.h>
#include <health-impl/HalHealthLoop.h>
#include <health-impl/Health.h>
#include <health/utils.h>

#include <memory>

namespace aidl::android::hardware::health {
namespace {

ndk::ScopedAStatus UnsupportedBatteryProperty() {
    return ndk::ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
}

class NucleusHealth final : public Health {
  public:
    explicit NucleusHealth(std::unique_ptr<healthd_config> config)
        : Health("default", std::move(config)) {}

    ndk::ScopedAStatus getChargeCounterUah(int32_t*) override {
        return UnsupportedBatteryProperty();
    }

    ndk::ScopedAStatus getCurrentNowMicroamps(int32_t*) override {
        return UnsupportedBatteryProperty();
    }

    ndk::ScopedAStatus getCurrentAverageMicroamps(int32_t*) override {
        return UnsupportedBatteryProperty();
    }

    ndk::ScopedAStatus getCapacity(int32_t*) override {
        return UnsupportedBatteryProperty();
    }

    ndk::ScopedAStatus getEnergyCounterNwh(int64_t*) override {
        return UnsupportedBatteryProperty();
    }

    ndk::ScopedAStatus getChargeStatus(BatteryStatus*) override {
        return UnsupportedBatteryProperty();
    }

    ndk::ScopedAStatus setChargingPolicy(BatteryChargingPolicy) override {
        return UnsupportedBatteryProperty();
    }

    ndk::ScopedAStatus getChargingPolicy(BatteryChargingPolicy*) override {
        return UnsupportedBatteryProperty();
    }

    ndk::ScopedAStatus getBatteryHealthData(BatteryHealthData*) override {
        return UnsupportedBatteryProperty();
    }

  protected:
    void UpdateHealthInfo(HealthInfo* health_info) override {
        // The Android payload has no battery device. Its lifetime is supplied
        // by the host runtime, represented as an always-online external source.
        // Replace the monitor result wholesale so host power-supply devices
        // cannot leak through the container's read-only sysfs view.
        *health_info = {};
        health_info->chargerAcOnline = true;
        health_info->batteryStatus = BatteryStatus::UNKNOWN;
        health_info->batteryHealth = BatteryHealth::UNKNOWN;
        health_info->batteryPresent = false;
        health_info->batteryCapacityLevel = BatteryCapacityLevel::UNKNOWN;
        health_info->batteryChargeTimeToFullNowSeconds = 0;
        health_info->chargingState = BatteryChargingState::INVALID;
        health_info->chargingPolicy = BatteryChargingPolicy::INVALID;
    }
};

}  // namespace
}  // namespace aidl::android::hardware::health

int main(int, char** argv) {
    android::base::InitLogging(argv);

    auto config = std::make_unique<healthd_config>();
    ::android::hardware::health::InitHealthdConfig(config.get());
    auto service = ndk::SharedRefBase::make<
        aidl::android::hardware::health::NucleusHealth>(std::move(config));

    LOG(INFO) << "Starting Nucleus health HAL: externally powered, battery absent";
    auto loop = std::make_shared<
        aidl::android::hardware::health::HalHealthLoop>(service, service);
    return loop->StartLoop();
}
