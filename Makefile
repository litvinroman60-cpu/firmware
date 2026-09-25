BR_VER = 2024.02.10
BR_MAKE = $(MAKE) -C $(TARGET)/buildroot-$(BR_VER) BR2_EXTERNAL=$(PWD)/general O=$(TARGET)
BR_LINK = https://github.com/buildroot/buildroot/archive
BR_FILE = /tmp/buildroot-$(BR_VER).tar.gz
BR_CONF = $(TARGET)/openipc_defconfig
TARGET ?= $(PWD)/output
export CMAKE_POLICY_VERSION_MINIMUM := 3.5

# GCC 15 defaults to -std=gnu23, where an empty parameter list means "takes no
# arguments" rather than "unspecified". Several host packages Buildroot pins
# here predate that and their configure probes stop compiling: gmp 6.3.0 fails
# its compiler test with "too many arguments to function 'g'", which surfaces as
# the far less helpful "could not find a working compiler" and halts any
# `make toolchain` on a current distro. Pin the dialect rather than carry a
# version bump for every affected host package. Applies only to host C builds,
# is overridable from the environment, and is a no-op on hosts whose GCC still
# defaults to gnu17.
#
# "Applies only to host C builds" is what the prepare: rule below has to make
# true -- Buildroot appends HOST_CFLAGS to HOST_CXXFLAGS wholesale.
HOST_CFLAGS ?= -O2 -std=gnu17
export HOST_CFLAGS

CONFIG = $(error variable BOARD not defined)
TIMER := $(shell date +%s)

ifeq ($(or $(MAKECMDGOALS), $(BOARD)),)
LIST := $(shell find ./br-ext-*/configs/*_defconfig | sort | \
	sed -E "s/br-ext-chip-(.+).configs.(.+)_defconfig/'\2' '\1 \2'/")
BOARD := $(or $(shell whiptail --title "Available boards" --menu "Select a config:" 20 70 12 \
	--notags $(LIST) 3>&1 1>&2 3>&2),$(CONFIG))
endif

ifneq ($(BOARD),)
CONFIG := $(shell find br-ext-*/configs/*_defconfig | grep -m1 $(BOARD))
include $(CONFIG)
endif

ifneq ($(filter repack,$(MAKECMDGOALS)),)
-include $(BR_CONF)
endif

all: repack-final timer

build: defconfig
	@$(BR_MAKE) all -j$(shell nproc)

br-%: defconfig
	@$(BR_MAKE) $(subst br-,,$@) -j$(shell nproc)

defconfig: prepare
	@echo --- $(or $(CONFIG),$(error variable BOARD not found))
	@cat $(CONFIG) $(PWD)/general/openipc.fragment > $(BR_CONF)
	@grep -s '^BR2_GLOBAL_PATCH_DIR=' $(CONFIG) >> $(BR_CONF) || true
	@$(BR_MAKE) BR2_DEFCONFIG=$(BR_CONF) defconfig

prepare:
	@if test ! -e $(TARGET)/buildroot-$(BR_VER); then \
		wget -c -q $(BR_LINK)/$(BR_VER).tar.gz -O $(BR_FILE); \
		mkdir -p $(TARGET); tar -xf $(BR_FILE) -C $(TARGET); fi
	@# The majestic and majestic-webui tarballs are rolling release assets:
	@# a fixed filename, no hash, refreshed upstream whenever those repos
	@# publish. Buildroot's dl cache keeps the first copy forever, so a
	@# from-source build with an old cache pairs a majestic that expects the
	@# setup page with a webui from before the page existed -- the browser
	@# door then 404s while SSH works. Expire cached copies after a day;
	@# fresh ones are kept, offline rebuilds inside that window still work,
	@# and CI downloads into an empty cache every run and never gets here.
	@find $(or $(BR2_DL_DIR),$(TARGET)/buildroot-$(BR_VER)/dl) -maxdepth 2 \
		\( -name 'majestic.*.master.tar.bz2' -o -name 'majestic-webui-dist.tar.gz' \) \
		-mmin +1440 -delete 2>/dev/null || true
	@if test -f $(TARGET)/buildroot-$(BR_VER)/linux/Config.in; then \
		sed -i '/source "$$(BR2_EXTERNAL_GENERAL_PATH)\/linux\/Config.ext.in"/d' \
			$(TARGET)/buildroot-$(BR_VER)/linux/Config.in; \
		grep -qF 'source "$$BR2_EXTERNAL_GENERAL_PATH/linux/Config.ext.in"' \
			$(TARGET)/buildroot-$(BR_VER)/linux/Config.in || \
		sed -i '/source "linux\/Config.ext.in"/a source "$$BR2_EXTERNAL_GENERAL_PATH/linux/Config.ext.in"' \
			$(TARGET)/buildroot-$(BR_VER)/linux/Config.in; \
	fi
	@if test -f $(TARGET)/buildroot-$(BR_VER)/package/Makefile.in; then \
		grep -qF 'filter-out -std=%' \
			$(TARGET)/buildroot-$(BR_VER)/package/Makefile.in || \
		sed -i 's|^HOST_CXXFLAGS += \$$(HOST_CFLAGS)$$|HOST_CXXFLAGS += $$(filter-out -std=%,$$(HOST_CFLAGS))|' \
			$(TARGET)/buildroot-$(BR_VER)/package/Makefile.in; \
	fi

help:
	@printf "BR-OpenIPC usage:\n \
	- make list - show available device configurations\n \
	- make deps - install build dependencies\n \
	- make clean - remove defconfig and target folder\n \
	- make package - list available packages\n \
	- make distclean - remove buildroot and output folder\n \
	- make br-linux - build linux kernel only\n\n"

list:
	@ls -1 br-ext-chip-*/configs

package:
	@find $(PWD)/general/package/* -maxdepth 0 -type d -printf "br-%f\n" | grep -v patch

toolname:
	@echo toolchain.$(BR2_OPENIPC_SOC_VENDOR)-$(BR2_OPENIPC_SOC_FAMILY)

clean:
	@rm -rf $(TARGET)/build $(TARGET)/images $(TARGET)/per-package $(TARGET)/target

distclean:
	@rm -rf $(BR_FILE) $(TARGET)

audit-abi:
	@python3 $(PWD)/general/scripts/audit-vendor-abi.py

deps:
	sudo apt-get install -y automake autotools-dev bc build-essential cpio \
		curl file fzf git libncurses-dev libtool lzop make rsync unzip wget libssl-dev \
		python3 python3-pip
	python3 -m pip install --user --break-system-packages kconfiglib

timer:
	@echo - Build time: $(shell date -d @$(shell expr $(shell date +%s) - $(TIMER)) -u +%M:%S)

toolchain: defconfig
ifeq ($(BR2_TOOLCHAIN_EXTERNAL),y)
	@cp -rf $(PWD)/general/package/gcc $(TARGET)/buildroot-$(BR_VER)/package
	@$(MAKE) -f $(PWD)/general/toolchain.mk BR_CONF=$(BR_CONF) CONFIG=$(PWD)/$(CONFIG)
	@$(BR_MAKE) BR2_DEFCONFIG=$(BR_CONF) defconfig
endif
	@$(BR_MAKE) sdk -j$(shell nproc)
	@$(call BUNDLE_SDK)

toolchain-asan: defconfig
ifeq ($(BR2_TOOLCHAIN_EXTERNAL),y)
	@cp -rf $(PWD)/general/package/gcc $(TARGET)/buildroot-$(BR_VER)/package
	@$(MAKE) -f $(PWD)/general/toolchain.mk BR_CONF=$(BR_CONF) CONFIG=$(PWD)/$(CONFIG)
	@$(BR_MAKE) BR2_DEFCONFIG=$(BR_CONF) defconfig
endif
	@echo 'BR2_EXTRA_GCC_CONFIG_OPTIONS="--enable-libsanitizer"' >> $(BR_CONF)
	@$(BR_MAKE) BR2_DEFCONFIG=$(BR_CONF) defconfig
	@$(BR_MAKE) sdk -j$(shell nproc)
	@$(call BUNDLE_SDK)

define BUNDLE_SDK
	OSDRV_DIR=$(PWD)/general/package/$(BR2_OPENIPC_SOC_VENDOR)-osdrv-$(BR2_OPENIPC_SOC_FAMILY)/files; \
	MPP_HEADERS=$(PWD)/general/package/hisilicon-osdrv-hi3516cv100/files/include; \
	SDK_TGZ=$$(find $(TARGET)/images -name '*_sdk-buildroot.tar.gz' | head -1); \
	UCLIBC_COMPAT_SRC=$(PWD)/general/package/uclibc-compat/src/uclibc-compat.c; \
	UCLIBC_COMPAT_STATIC=$(PWD)/general/package/uclibc-compat/src/uclibc-compat-static.c; \
	GLIBC_COMPAT_SRC=$(PWD)/general/package/glibc-compat/src/glibc-compat.c; \
	GLIBC_COMPAT_STATIC=$(PWD)/general/package/glibc-compat/src/glibc-compat-static.c; \
	SDK_CC=$$(ls $(TARGET)/host/bin/*-gcc 2>/dev/null | head -1); \
	if [ -d "$$OSDRV_DIR" ] && [ -n "$$SDK_TGZ" ]; then \
		SDK_TOP=$$(tar tzf $$SDK_TGZ | head -1 | cut -d/ -f1); \
		rm -rf /tmp/sdk-overlay && mkdir -p /tmp/sdk-overlay/$$SDK_TOP/sdk; \
		cp -a $$OSDRV_DIR/* /tmp/sdk-overlay/$$SDK_TOP/sdk/; \
		if [ "$(BR2_OPENIPC_SOC_VENDOR)" = "hisilicon" ] && [ ! -d "$$OSDRV_DIR/include" ] && [ -d "$$MPP_HEADERS" ]; then \
			mkdir -p /tmp/sdk-overlay/$$SDK_TOP/sdk/include; \
			cp -a $$MPP_HEADERS/. /tmp/sdk-overlay/$$SDK_TOP/sdk/include/; \
		fi; \
		if [ -n "$$SDK_CC" ]; then \
			SDK_AR=$$(echo $$SDK_CC | sed 's/-gcc$$/-ar/'); \
			if [ -f "$$UCLIBC_COMPAT_SRC" ]; then \
				$$SDK_CC -shared -Wall -O2 -fPIC -o /tmp/sdk-overlay/$$SDK_TOP/sdk/lib/libuclibc-compat.so $$UCLIBC_COMPAT_SRC; \
			fi; \
			if [ -f "$$UCLIBC_COMPAT_STATIC" ]; then \
				$$SDK_CC -Wall -O2 -fPIC -c -o /tmp/sdk-overlay/$$SDK_TOP/sdk/lib/uclibc-compat-static.o $$UCLIBC_COMPAT_STATIC; \
				$$SDK_AR rcs /tmp/sdk-overlay/$$SDK_TOP/sdk/lib/libuclibc-compat-static.a /tmp/sdk-overlay/$$SDK_TOP/sdk/lib/uclibc-compat-static.o; \
				rm -f /tmp/sdk-overlay/$$SDK_TOP/sdk/lib/uclibc-compat-static.o; \
			fi; \
			if [ -f "$$GLIBC_COMPAT_SRC" ]; then \
				$$SDK_CC -shared -Wall -O2 -fPIC -o /tmp/sdk-overlay/$$SDK_TOP/sdk/lib/libglibc-compat.so $$GLIBC_COMPAT_SRC; \
			fi; \
			if [ -f "$$GLIBC_COMPAT_STATIC" ]; then \
				$$SDK_CC -Wall -O2 -fPIC -c -o /tmp/sdk-overlay/$$SDK_TOP/sdk/lib/glibc-compat-static.o $$GLIBC_COMPAT_STATIC; \
				$$SDK_AR rcs /tmp/sdk-overlay/$$SDK_TOP/sdk/lib/libglibc-compat-static.a /tmp/sdk-overlay/$$SDK_TOP/sdk/lib/glibc-compat-static.o; \
				rm -f /tmp/sdk-overlay/$$SDK_TOP/sdk/lib/glibc-compat-static.o; \
			fi; \
		fi; \
		if [ -f "$$SDK_TGZ" ]; then \
			tar czf $$SDK_TGZ -C /tmp/sdk-overlay $$SDK_TOP; \
		fi; \
		rm -rf /tmp/sdk-overlay; \
	fi
endef

repack-final: build
	@$(MAKE) --no-print-directory BOARD=$(BOARD) TARGET=$(TARGET) repack

repack:
ifeq ($(BR2_PACKAGE_OPENIPC_NFS_ROOT),y)
ifeq ($(BR2_OPENIPC_SOC_VENDOR),"rockchip")
	@$(call PREPARE_REPACK,zboot.img,16384,,,nfs-root)
else
	@$(call PREPARE_REPACK,uImage,16384,,,nfs-root)
endif
else
ifeq ($(BR2_OPENIPC_SOC_FAMILY),"hi3516cv6xx")
ifeq ($(BR2_OPENIPC_FLASH_SIZE),"8")
	@$(call CHECK_SIZE,fitImage,2048)
	@$(call CHECK_SIZE,rootfs.squashfs,5120)
endif
	@$(call PREPARE_REPACK,firmware.bin,$(shell expr $(subst ",,$(BR2_OPENIPC_FLASH_SIZE)) \* 1024),,,nor)
else ifeq ($(BR2_OPENIPC_SOC_FAMILY),"hi3519dv500")
	@$(call PREPARE_REPACK,firmware.bin,$(shell expr $(subst ",,$(BR2_OPENIPC_FLASH_SIZE)) \* 1024),,,nor)
else ifneq ($(wildcard $(TARGET)/images/firmware.bin),)
	@$(call PREPARE_REPACK,firmware.bin,8192,,,nor)
else
ifeq ($(BR2_TARGET_ROOTFS_SQUASHFS),y)
ifeq ($(BR2_OPENIPC_SOC_VENDOR),"rockchip")
	@$(call PREPARE_REPACK,zboot.img,4096,rootfs.squashfs,8192,nor)
else ifeq ($(BR2_OPENIPC_FLASH_SIZE),"8")
	@$(call PREPARE_REPACK,uImage,2048,rootfs.squashfs,5120,nor)
else ifeq ($(BR2_OPENIPC_SOC_MODEL),"ssc377d")
	@$(call PREPARE_REPACK,uImage,2048,rootfs.squashfs,10240,nor)
else
	@$(call PREPARE_REPACK,uImage,2048,rootfs.squashfs,8192,nor)
endif
endif
ifeq ($(BR2_TARGET_ROOTFS_UBI),y)
ifneq ($(filter $(BR2_OPENIPC_SOC_VENDOR),"rockchip" "sigmastar"),)
	@$(call PREPARE_REPACK,,,rootfs.ubi,16384,nand)
else
	@$(call PREPARE_REPACK,uImage,4096,rootfs.ubi,16384,nand)
endif
endif
ifeq ($(BR2_TARGET_ROOTFS_INITRAMFS),y)
	@$(call PREPARE_REPACK,uImage,16384,,,initramfs)
endif
endif
endif

size-report:
	@TARGET_DIR=$(TARGET)/target \
	BR2_OUTPUT_DIR=$(TARGET) \
	IMAGES_DIR=$(TARGET)/images \
	OPENIPC_SOC_MODEL=$(BR2_OPENIPC_SOC_MODEL) \
	OPENIPC_VARIANT=$(BR2_OPENIPC_VARIANT) \
	BR2_OPENIPC_FLASH_SIZE=$(BR2_OPENIPC_FLASH_SIZE) \
	BR2_OPENIPC_SOC_VENDOR=$(BR2_OPENIPC_SOC_VENDOR) \
	BR2_TARGET_ROOTFS_SQUASHFS=$(BR2_TARGET_ROOTFS_SQUASHFS) \
	BR2_TARGET_ROOTFS_UBI=$(BR2_TARGET_ROOTFS_UBI) \
	python3 $(PWD)/general/scripts/size_report.py

kconfig-graph:
	@TARGET_DIR=$(TARGET)/target \
	BR2_OUTPUT_DIR=$(TARGET) \
	IMAGES_DIR=$(TARGET)/images \
	OPENIPC_SOC_MODEL=$(BR2_OPENIPC_SOC_MODEL) \
	OPENIPC_VARIANT=$(BR2_OPENIPC_VARIANT) \
	BR_VER=$(BR_VER) \
	PWD=$(PWD) \
	python3 $(PWD)/general/scripts/kconfig_graph.py
