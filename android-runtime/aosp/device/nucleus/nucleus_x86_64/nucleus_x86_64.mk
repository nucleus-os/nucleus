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

# Framework and architecture.
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit_only.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/generic_system.mk)

# Framework extensions and the current AOSP application/WebView product.
$(call inherit-product, $(SRC_TARGET_DIR)/product/handheld_system_ext.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/telephony_system_ext.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/aosp_product.mk)

# Container-owned vendor surface.
$(call inherit-product, device/nucleus/nucleus_x86_64/device.mk)

PRODUCT_NAME := nucleus_x86_64
PRODUCT_DEVICE := nucleus_x86_64
PRODUCT_BRAND := Nucleus
PRODUCT_MANUFACTURER := Nucleus
PRODUCT_MODEL := Nucleus Android Runtime

PRODUCT_SHIPPING_API_LEVEL := 37
PRODUCT_CHARACTERISTICS := tablet,nosdcard

PRODUCT_ENFORCE_ARTIFACT_PATH_REQUIREMENTS := true
PRODUCT_USE_DYNAMIC_PARTITIONS := false
PRODUCT_USE_DYNAMIC_PARTITION_SIZE := false

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
