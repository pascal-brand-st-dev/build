DEBUG ?= 1

-include common.mk

################################################################################
# Mandatory definition to use common.mk
################################################################################
CROSS_COMPILE_NS_USER	?= "$(CCACHE)$(AARCH64_CROSS_COMPILE)"
CROSS_COMPILE_NS_KERNEL	?= "$(CCACHE)$(AARCH64_CROSS_COMPILE)"
CROSS_COMPILE_S_USER	?= "$(CCACHE)$(AARCH32_CROSS_COMPILE)"
CROSS_COMPILE_S_KERNEL	?= "$(CCACHE)$(AARCH32_CROSS_COMPILE)"
OPTEE_OS_BIN		?= $(OPTEE_OS_PATH)/out/arm-plat-vexpress/core/tee.bin
OPTEE_OS_TA_DEV_KIT_DIR	?= $(OPTEE_OS_PATH)/out/arm-plat-vexpress/export-user_ta

################################################################################
# Paths to git projects and various binaries
################################################################################
ARM_TF_PATH		?= $(ROOT)/arm-trusted-firmware

EDK2_PATH		?= $(ROOT)/edk2
EDK2_BIN		?= $(EDK2_PATH)/Build/ArmVExpress-FVP-AArch64/RELEASE_GCC49/FV/FVP_AARCH64_EFI.fd

FOUNDATION_PATH		?= $(ROOT)/Foundation_Platformpkg
ifeq ($(wildcard $(FOUNDATION_PATH)),)
$(error $(FOUNDATION_PATH) does not exist)
endif

################################################################################
# Targets
################################################################################
all: arm-tf edk2 linux optee-os optee-client generate-dtb xtest update_rootfs
all-clean: arm-tf-clean busybox-clean edk2-clean optee-os-clean \
	optee-client-clean


-include toolchain.mk

################################################################################
# ARM Trusted Firmware
################################################################################
ARM_TF_EXPORTS ?= \
	CFLAGS="-O0 -gdwarf-2" \
	CROSS_COMPILE="$(CCACHE)$(AARCH64_NONE_CROSS_COMPILE)"

ARM_TF_FLAGS ?= \
	BL32=$(OPTEE_OS_BIN) \
	BL33=$(EDK2_BIN) \
	DEBUG=0 \
	FVP_TSP_RAM_LOCATION=tdram \
	FVP_SHARED_DATA_LOCATION=tdram \
	PLAT=fvp \
	SPD=opteed

arm-tf: optee-os edk2
	$(ARM_TF_EXPORTS) $(MAKE) -C $(ARM_TF_PATH) $(ARM_TF_FLAGS) all fip

arm-tf-clean:
	$(ARM_TF_EXPORTS) $(MAKE) -C $(ARM_TF_PATH) $(ARM_TF_FLAGS) clean

################################################################################
# Busybox
################################################################################
BUSYBOX_COMMON_TARGET = fvp-aarch64
BUSYBOX_CLEAN_COMMON_TARGET = fvp-aarch64 clean
BUSYBOX_COMMON_CCDIR = $(AARCH64_PATH)

busybox: busybox-common

busybox-clean: busybox-clean-common

busybox-cleaner: busybox-cleaner-common

################################################################################
# EDK2 / Tianocore
################################################################################
define edk2-call
	GCC49_AARCH64_PREFIX=$(AARCH64_NONE_CROSS_COMPILE) \
	     $(MAKE) -j1 -C $(EDK2_PATH) \
	     -f ArmPlatformPkg/Scripts/Makefile EDK2_ARCH=AARCH64 \
	     EDK2_DSC=ArmPlatformPkg/ArmVExpressPkg/ArmVExpress-FVP-AArch64.dsc \
	     EDK2_TOOLCHAIN=GCC49 EDK2_BUILD=RELEASE \
	     EDK2_MACROS="-n 6 -D ARM_FOUNDATION_FVP=1"
endef

edk2: edk2-common

edk2-clean: edk2-clean-common

################################################################################
# Linux kernel
################################################################################
$(LINUX_PATH)/.config:
	# Temporary fix until we have the driver integrated in the kernel
	cd $(LINUX_PATH) && git checkout arch/arm64/Kconfig usr/Kconfig
	sed -i '/config ARM64$$/a select TEE' $(LINUX_PATH)/arch/arm64/Kconfig;
	sed -i '/config ARM64$$/a select OPTEE' $(LINUX_PATH)/arch/arm64/Kconfig;
	# set INITRAMFS_SOURCE
	sed -i 's/default ""/default "\/home\/brand\/devel\/optee_fvp_gendrv\/gen_rootfs\/filesystem.cpio.gz"/g' $(LINUX_PATH)/usr/Kconfig;
	make -C $(LINUX_PATH) ARCH=arm64 defconfig

linux-defconfig: $(LINUX_PATH)/.config

LINUX_COMMON_FLAGS += ARCH=arm64

#Force linux recompilation to update the rootfs
linux: update_rootfs
	$(MAKE) linux-common

linux-defconfig-clean: linux-defconfig-clean-common

LINUX_CLEAN_COMMON_FLAGS += ARCH=arm64

linux-clean: linux-clean-common

LINUX_CLEANER_COMMON_FLAGS += ARCH=arm64

linux-cleaner: linux-cleaner-common

################################################################################
# OP-TEE
################################################################################
OPTEE_OS_COMMON_FLAGS += PLATFORM=vexpress-fvp
optee-os: optee-os-common

OPTEE_OS_CLEAN_COMMON_FLAGS += PLATFORM=vexpress-fvp
optee-os-clean: optee-os-clean-common

optee-client: optee-client-common

optee-client-clean: optee-client-clean-common

generate-dtb: linux
	$(LINUX_PATH)/scripts/dtc/dtc \
		-O dtb \
		-o $(FOUNDATION_PATH)/fdt.dtb \
		-b 0 \
		-i . $(LINUX_PATH)/arch/arm64/boot/dts/arm/foundation-v8.dts

################################################################################
# xtest / optee_test
################################################################################
xtest: xtest-common

xtest-clean: xtest-clean-common

xtest-patch: xtest-patch-common

################################################################################
# Root FS
################################################################################
.PHONY: filelist-tee
filelist-tee: optee-client xtest
	@echo "# xtest / optee_test" > $(GEN_ROOTFS_FILELIST)
	@find $(OPTEE_TEST_OUT_PATH) -type f -name "xtest" | sed 's/\(.*\)/file \/bin\/xtest \1 755 0 0/g' >> $(GEN_ROOTFS_FILELIST)
	@echo "# TAs" >> $(GEN_ROOTFS_FILELIST)
	@echo "dir /lib/teetz 755 0 0" >> $(GEN_ROOTFS_FILELIST)
	@find $(OPTEE_TEST_OUT_PATH) -name "*.ta" | \
		sed 's/\(.*\)\/\(.*\)/file \/lib\/teetz\/\2 \1\/\2 444 0 0/g' >> $(GEN_ROOTFS_FILELIST)
	@echo "# Secure storage dig" >> $(GEN_ROOTFS_FILELIST)
	@echo "dir /data 755 0 0" >> $(GEN_ROOTFS_FILELIST)
	@echo "dir /data/tee 755 0 0" >> $(GEN_ROOTFS_FILELIST)
	@echo "# OP-TEE device" >> $(GEN_ROOTFS_FILELIST)
	@echo "dir /lib/modules 755 0 0" >> $(GEN_ROOTFS_FILELIST)
	@echo "dir /lib/modules/$(call KERNEL_VERSION) 755 0 0" >> $(GEN_ROOTFS_FILELIST)
	@echo "# OP-TEE Client" >> $(GEN_ROOTFS_FILELIST)
	@echo "file /bin/tee-supplicant $(OPTEE_CLIENT_EXPORT)/bin/tee-supplicant 755 0 0" >> $(GEN_ROOTFS_FILELIST)
	@echo "dir /lib/aarch64-linux-gnu 755 0 0" >> $(GEN_ROOTFS_FILELIST)
	@echo "file /lib/aarch64-linux-gnu/libteec.so.1.0 $(OPTEE_CLIENT_EXPORT)/lib/libteec.so.1.0 755 0 0" >> $(GEN_ROOTFS_FILELIST)
	@echo "slink /lib/aarch64-linux-gnu/libteec.so.1 libteec.so.1.0 755 0 0" >> $(GEN_ROOTFS_FILELIST)
	@echo "slink /lib/aarch64-linux-gnu/libteec.so libteec.so.1 755 0 0" >> $(GEN_ROOTFS_FILELIST)

update_rootfs: busybox filelist-tee
	cat $(GEN_ROOTFS_PATH)/filelist-final.txt $(GEN_ROOTFS_PATH)/filelist-tee.txt > $(GEN_ROOTFS_PATH)/filelist.tmp
	cd $(GEN_ROOTFS_PATH) && \
	        $(LINUX_PATH)/usr/gen_init_cpio $(GEN_ROOTFS_PATH)/filelist.tmp | gzip > $(GEN_ROOTFS_PATH)/filesystem.cpio.gz

################################################################################
# Run targets
################################################################################
run: all
	$(MAKE) run-only

run-only:
	@ln -sf $(LINUX_PATH)/arch/arm64/boot/Image $(FOUNDATION_PATH)
	@ln -sf $(GEN_ROOTFS_PATH)/filesystem.cpio.gz $(FOUNDATION_PATH)
	@cd $(FOUNDATION_PATH); \
	$(FOUNDATION_PATH)/models/Linux64_GCC-4.1/Foundation_Platform \
	--cores=4 \
	--secure-memory \
	--visualization \
	--gicv3 \
	--data="$(ARM_TF_PATH)/build/fvp/release/bl1.bin"@0x0 \
	--data="$(ARM_TF_PATH)/build/fvp/release/fip.bin"@0x8000000
