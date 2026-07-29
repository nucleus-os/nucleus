#
# Copyright 2026 Nucleus
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Framework and architecture. Nucleus assembles the application-runtime
# substrate directly; phone/tablet and telephony products are not inherited.
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit_only.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/media_system.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/media_system_ext.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/media_vendor.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/media_product.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/languages_default.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/updatable_apex.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/emulated_storage.mk)
$(call inherit-product, frameworks/native/build/tablet-10in-xhdpi-2048-dalvik-heap.mk)

# Android's text stack requires the generated system font configurations and
# every font family referenced by them. Keep this contract explicit instead of
# inheriting the unrelated phone/tablet system package surface.
$(call inherit-product-if-exists, frameworks/base/data/fonts/fonts.mk)
$(call inherit-product-if-exists, external/google-fonts/dancing-script/fonts.mk)
$(call inherit-product-if-exists, external/google-fonts/carrois-gothic-sc/fonts.mk)
$(call inherit-product-if-exists, external/google-fonts/coming-soon/fonts.mk)
$(call inherit-product-if-exists, external/google-fonts/cutive-mono/fonts.mk)
$(call inherit-product-if-exists, external/google-fonts/source-sans-pro/fonts.mk)
$(call inherit-product-if-exists, external/noto-fonts/fonts.mk)
$(call inherit-product-if-exists, external/roboto-fonts/fonts.mk)
$(call inherit-product-if-exists, external/roboto-flex-fonts/fonts.mk)
$(call inherit-product-if-exists, external/roboto-mono/fonts.mk)
$(call inherit-product-if-exists, external/hyphenation-patterns/patterns.mk)

# Desktop application-runtime surface.
PRODUCT_PACKAGES += \
    cameraserver \
    DocumentsUI \
    FusedLocation \
    LatinIME \
    Launcher3QuickStep \
    NucleusRuntimeBridge \
    Settings \
    SettingsIntelligence \
    SystemUI \
    frameworks-base-overlays \
    librs_jni \
    preinstalled-packages-nucleus.xml

# LocationManagerService requires one direct-boot-aware fused provider before
# third-party applications can start. FusedLocation runs in the system process,
# so keep its system-server app class-loader contract explicit as well.
PRODUCT_SYSTEM_SERVER_APPS += \
    FusedLocation

# Container-owned vendor surface.
$(call inherit-product, device/nucleus/nucleus_x86_64/device.mk)

# Remove optional hardware and lifecycle services inherited by the reusable
# media/base partitions. Their absence is reported truthfully.
PRODUCT_PACKAGES -= \
    Camera2 \
    com.android.bt \
    com.android.devicelock \
    com.android.hardware.biometrics.fingerprint.virtual \
    com.android.healthfitness \
    com.android.ondevicepersonalization \
    com.android.uprobestats \
    com.android.uwb \
    gsid \
    recovery \
    recovery-refresh \
    update_engine \
    update_verifier

PRODUCT_NAME := nucleus_x86_64
PRODUCT_DEVICE := nucleus_x86_64
PRODUCT_BRAND := Nucleus
PRODUCT_MANUFACTURER := Nucleus
PRODUCT_MODEL := Nucleus Android Runtime

PRODUCT_SHIPPING_API_LEVEL := 37
PRODUCT_CHARACTERISTICS := tablet,nosdcard

PRODUCT_ENFORCE_ARTIFACT_PATH_REQUIREMENTS := true
PRODUCT_USE_DYNAMIC_PARTITIONS := false
# Derive each standalone filesystem image from its contents. Nucleus has no
# physical partition table and therefore carries no product-authored size caps.
PRODUCT_USE_DYNAMIC_PARTITION_SIZE := true

PRODUCT_BUILD_SYSTEM_IMAGE := true
PRODUCT_BUILD_VENDOR_IMAGE := true
PRODUCT_BUILD_PRODUCT_IMAGE := true
PRODUCT_BUILD_SYSTEM_EXT_IMAGE := true
PRODUCT_BUILD_SYSTEM_OTHER_IMAGE := false
PRODUCT_BUILD_CACHE_IMAGE := false
PRODUCT_BUILD_USERDATA_IMAGE := false
PRODUCT_BUILD_RAMDISK_IMAGE := false
PRODUCT_BUILD_BOOT_IMAGE := false
PRODUCT_BUILD_INIT_BOOT_IMAGE := false
PRODUCT_BUILD_RECOVERY_IMAGE := false
PRODUCT_BUILD_VENDOR_BOOT_IMAGE := false
PRODUCT_BUILD_SUPER_EMPTY_IMAGE := false

# Collider preactivates immutable APEX payloads before entering the container.
# EROFS payloads mount directly from their archives; the stock ext4 CTS shim
# uses a host-owned autoclearing loop association. Collider removes the loop
# device node before Android starts, and APEXd adopts the verified mounts
# without receiving loop or device-mapper control surfaces.
PRODUCT_COMPRESSED_APEX := false
PRODUCT_DEFAULT_APEX_PAYLOAD_TYPE := erofs
PRODUCT_PRODUCT_PROPERTIES += \
    apexd.config.nucleus_container=true

PRODUCT_SYSTEM_NAME := Nucleus
PRODUCT_SYSTEM_BRAND := Nucleus
PRODUCT_SYSTEM_MANUFACTURER := Nucleus
PRODUCT_SYSTEM_MODEL := Nucleus Android Runtime
PRODUCT_SYSTEM_DEVICE := nucleus_x86_64

PRODUCT_PRODUCT_PROPERTIES += \
    ro.setupwizard.mode=DISABLED

PRODUCT_VENDOR_PROPERTIES += \
    ro.hardware=nucleus \
    ro.hardware.egl=angle \
    ro.hardware.gralloc=nucleus \
    ro.hardware.hwcomposer=nucleus \
    ro.hardware.vulkan=nucleus \
    ro.nucleus.container=true

# Nucleus deliberately has no fallback guest renderer.
PRODUCT_VENDOR_PROPERTIES += \
    ro.kernel.qemu=0
