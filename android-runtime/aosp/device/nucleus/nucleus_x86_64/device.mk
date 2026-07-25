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

$(call inherit-product, $(SRC_TARGET_DIR)/product/handheld_vendor.mk)
$(call inherit-product, hardware/interfaces/audio/aidl/default/audio_effects.mk)

PRODUCT_SOONG_NAMESPACES += \
    device/nucleus/nucleus_x86_64

PRODUCT_PACKAGES += \
    android.hardware.graphics.composer3-service.nucleus \
    android.hardware.graphics.allocator-service.nucleus \
    com.android.hardware.audio \
    android.hardware.security.keymint-service.nonsecure \
    ip \
    mapper.nucleus \
    netutils-wrapper-1.0 \
    vulkan.nucleus

PRODUCT_COPY_FILES += \
    device/nucleus/nucleus_x86_64/init.nucleus.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.nucleus.rc \
    device/nucleus/nucleus_x86_64/permissions/nucleus-container.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/nucleus-container.xml

PRODUCT_VENDOR_PROPERTIES += \
    ro.control_privapp_permissions=enforce \
    ro.sf.lcd_density=160
