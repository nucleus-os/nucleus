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

$(call inherit-product, hardware/interfaces/audio/aidl/default/audio_effects.mk)

PRODUCT_SOONG_NAMESPACES += \
    device/nucleus/nucleus_x86_64

DEVICE_PACKAGE_OVERLAYS += \
    device/nucleus/nucleus_x86_64/overlay

PRODUCT_PACKAGES += \
    android.hardware.graphics.composer3-service.nucleus \
    android.hardware.graphics.allocator-service.nucleus \
    android.hardware.health-service.nucleus \
    audio_policy_configuration.xml \
    com.android.hardware.audio \
    android.hardware.security.keymint-service.nonsecure \
    ip \
    mapper.nucleus \
    netutils-wrapper-1.0 \
    vulkan.nucleus

PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/android.software.app_widgets.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.software.app_widgets.xml \
    device/nucleus/nucleus_x86_64/init.nucleus.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.nucleus.rc \
    device/nucleus/nucleus_x86_64/permissions/nucleus-container.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/nucleus-container.xml

PRODUCT_VENDOR_PROPERTIES += \
    ro.control_privapp_permissions=enforce

PRODUCT_PRODUCT_PROPERTIES += \
    sys.use_memfd=true
