#!/bin/bash
# ============================================================================
#  APTKernel / Droidspaces 构建脚本
#  基于 AstideLabs/kernel_xiaomi_sm8250_mod 的 build_kernel.sh，
#  增加了：patches/ 自动打补丁 + droidspaces 配置注入 + 配置校验 + DS 命名
#
#  用法：./build_kernel.sh <device> [ksu] [ds] [miui|aosp]
#    ./build_kernel.sh pipa ksu ds miui
# ============================================================================
set -e

# ==========================================
# 参数解析
# ==========================================
if [ -z "$1" ]; then
    echo "[!] Error: No device specified."
    echo "Usage: $0 <device_name> [ksu] [ds] [miui|aosp]"
    echo "Example: $0 pipa ksu ds miui"
    exit 1
fi

DEVICE_NAME="$1"
DEFCONFIG="${DEVICE_NAME}_defconfig"
DEFCONFIG_PATH="arch/arm64/configs/${DEFCONFIG}"

if [ ! -f "$DEFCONFIG_PATH" ]; then
    echo "[!] Error: Defconfig not found at $DEFCONFIG_PATH"
    exit 1
fi

ENABLE_KSU=0
ENABLE_DS=0
TARGET_OS="both"

shift
for arg in "$@"; do
    case "$arg" in
        ksu) ENABLE_KSU=1 ;;
        ds)  ENABLE_DS=1 ;;
        miui) TARGET_OS="miui" ;;
        aosp) TARGET_OS="aosp" ;;
    esac
done

# ==========================================
# 环境
# ==========================================
KERNEL_DIR="$(pwd)"
TOOLCHAIN_BIN="$HOME/zyc-clang/bin"

export PATH="${TOOLCHAIN_BIN}:${PATH}"
export ARCH="arm64"
export SUBARCH="arm64"

export CCACHE_DIR="$HOME/.cache/ccache_mikernel"
export CCACHE_EXEC=$(command -v ccache)
if [ -z "$CCACHE_EXEC" ]; then
    echo "[!] ccache not found!"
    exit 1
fi
export USE_CCACHE=1
export CROSS_COMPILE="aarch64-linux-gnu-"
export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"

echo "[*] Clang:"
clang --version || { echo "[!] clang not found at ${TOOLCHAIN_BIN}"; exit 1; }
mkdir -p "$CCACHE_DIR"

# ==========================================
# 内核补丁（Droidspaces non-GKI 补丁，来自 patches/）
# ==========================================
PATCH_DIR="${KERNEL_DIR}/patches"
if [ -d "$PATCH_DIR" ]; then
    echo "==========================================="
    echo " [*] Applying kernel patches from patches/"
    echo "==========================================="
    for p in "$PATCH_DIR"/*.patch; do
        [ -f "$p" ] || continue
        if patch -p1 --forward --dry-run -s < "$p" >/dev/null 2>&1; then
            patch -p1 --forward -s < "$p"
            echo "[+] applied $(basename "$p")"
        else
            echo "[!] skipped $(basename "$p") (already applied / not applicable)"
        fi
    done
fi

# ==========================================
# KernelSU (ReSukiSU)
# ==========================================
if [ "$ENABLE_KSU" -eq 1 ]; then
    echo "==========================================="
    echo " [*] Initializing KernelSU (ReSukiSU)"
    echo "==========================================="
    curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash
    echo "[+] KernelSU setup finished."
fi

# ==========================================
# Baseband-guard（原作者脚本自带，保持不变）
# ==========================================
echo "==========================================="
echo " [*] Initializing Baseband-guard"
echo "==========================================="
wget -O- https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh | bash
sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' security/Kconfig
echo "[+] Baseband-guard setup finished."

# ==========================================
# AnyKernel3
# ==========================================
echo "[*] Cloning AnyKernel3..."
rm -rf anykernel
git clone https://github.com/liyafe1997/AnyKernel3 -b kona --single-branch --depth=1 anykernel

# ==========================================
# 配置校验：droidspaces 必需项
# ==========================================
verify_ds_config() {
    local cfg="$1"
    local missing=0
    echo "-------------------------------------------"
    echo "[*] droidspaces 必需配置核对 ($cfg)"
    echo "-------------------------------------------"
    for opt in NAMESPACES PID_NS UTS_NS IPC_NS SYSVIPC POSIX_MQUEUE DEVTMPFS CGROUP_DEVICE USER_NS NET_NS SECCOMP OVERLAY_FS; do
        if grep -q "^CONFIG_${opt}=y" "$cfg"; then
            echo "  [OK]   CONFIG_${opt}=y"
        else
            echo "  [FAIL] CONFIG_${opt}  (未启用)"
            missing=$((missing + 1))
        fi
    done
    echo "-------------------------------------------"
    if [ "$missing" -ne 0 ]; then
        echo "[!] 有 ${missing} 项关键配置缺失 —— 停止，不要刷这个内核"
        return 1
    fi
    echo "[+] droidspaces 必需配置全部就绪"
    return 0
}

# ==========================================
# 构建
# ==========================================
build_target() {
    local OS_TYPE=$1
    echo "==========================================="
    echo " Building ${DEVICE_NAME} (Target: $OS_TYPE)"
    echo "==========================================="

    local OUT_DIR="${KERNEL_DIR}/out_${OS_TYPE}"

    local MAKE_OPTS=(
        -j"$(nproc)"
        O="${OUT_DIR}"
        ARCH="${ARCH}"
        SUBARCH="${SUBARCH}"
        LLVM=1
        LLVM_IAS=1
        CC="ccache clang"
        HOSTCC="ccache clang"
        CROSS_COMPILE="${CROSS_COMPILE}"
        CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32}"
    )

    rm -rf "${OUT_DIR}"
    mkdir -p "${OUT_DIR}"

    local DTS_SOURCE="arch/arm64/boot/dts/vendor/qcom"
    local DTS_BACKUP=".dts.bak.${OS_TYPE}"

    if [ "$OS_TYPE" == "miui" ]; then
        echo "[*] Applying MIUI DTS patches..."
        cp -a "${DTS_SOURCE}" "${DTS_BACKUP}"
        sed -i 's/<154>/<1537>/g' ${DTS_SOURCE}/dsi-panel-j1s* || true
        sed -i 's/<154>/<1537>/g' ${DTS_SOURCE}/dsi-panel-j2* || true
        sed -i 's/<155>/<1544>/g' ${DTS_SOURCE}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi || true
        sed -i 's/<155>/<1545>/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/<155>/<1546>/g' ${DTS_SOURCE}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<155>/<1546>/g' ${DTS_SOURCE}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<71>/<710>/g' ${DTS_SOURCE}/dsi-panel-j1s* || true
        sed -i 's/<71>/<710>/g' ${DTS_SOURCE}/dsi-panel-j2* || true
        sed -i 's/\/\/ mi,mdss-dsi-pan-enable-smart-fps/mi,mdss-dsi-pan-enable-smart-fps/g' ${DTS_SOURCE}/dsi-panel* || true
        sed -i 's/\/\/ mi,mdss-dsi-smart-fps-max_framerate/mi,mdss-dsi-smart-fps-max_framerate/g' ${DTS_SOURCE}/dsi-panel* || true
        sed -i 's/\/\/ qcom,mdss-dsi-pan-enable-smart-fps/qcom,mdss-dsi-pan-enable-smart-fps/g' ${DTS_SOURCE}/dsi-panel* || true
        sed -i 's/qcom,mdss-dsi-qsync-min-refresh-rate/\/\/qcom,mdss-dsi-qsync-min-refresh-rate/g' ${DTS_SOURCE}/dsi-panel* || true
        sed -i 's/120 90 60/120 90 60 50 30/g' ${DTS_SOURCE}/dsi-panel-g7a-36-02-0c-dsc-video.dtsi || true
        sed -i 's/120 90 60/120 90 60 50 30/g' ${DTS_SOURCE}/dsi-panel-g7a-37-02-0a-dsc-video.dtsi || true
        sed -i 's/120 90 60/120 90 60 50 30/g' ${DTS_SOURCE}/dsi-panel-g7a-37-02-0b-dsc-video.dtsi || true
        sed -i 's/144 120 90 60/144 120 90 60 50 48 30/g' ${DTS_SOURCE}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 03 51 03 FF/39 00 00 00 00 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 03 51 0D FF/39 00 00 00 00 00 03 51 0D FF/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 00 00/39 01 00 00 00 00 03 51 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-38-0c-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${DTS_SOURCE}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${DTS_SOURCE}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${DTS_SOURCE}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${DTS_SOURCE}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${DTS_SOURCE}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${DTS_SOURCE}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 01 00 03 51 03 FF/39 01 00 00 01 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 11 00 03 51 03 FF/39 01 00 00 11 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi || true
    fi

    echo "[*] Making defconfig: ${DEFCONFIG}"
    make "${MAKE_OPTS[@]}" "${DEFCONFIG}"

    # ----------------------------------------------------
    # 配置注入
    # ----------------------------------------------------
    echo "[*] Injecting Baseband-guard configuration..."
    scripts/config --file "${OUT_DIR}/.config" -e BBG

    if [ "$ENABLE_KSU" -eq 1 ]; then
        echo "[*] Injecting KernelSU & SUSFS configurations..."
        scripts/config --file "${OUT_DIR}/.config" \
            -e KSU \
            -e THREAD_INFO_IN_TASK \
            -e KSU_SUSFS
    fi

    if [ "$OS_TYPE" == "miui" ]; then
        echo "[*] Injecting MIUI specific configurations..."
        scripts/config --file "${OUT_DIR}/.config" \
            --set-str STATIC_USERMODEHELPER_PATH /system/bin/micd \
            -e PERF_CRITICAL_RT_TASK \
            -e SF_BINDER \
            -e OVERLAY_FS \
            -e MIGT \
            -e MIGT_ENERGY_MODEL \
            -e MIHW \
            -e PACKAGE_RUNTIME_INFO \
            -e BINDER_OPT \
            -e KPERFEVENTS \
            -e MILLET \
            -e PERF_HUMANTASK \
            -d LTO_CLANG \
            -e LTO_NONE \
            -e XIAOMI_MIUI \
            -d MI_MEMORY_SYSFS \
            -e TASK_DELAY_ACCT \
            -e MIUI_ZRAM_MEMORY_TRACKING \
            -e PERF_HELPER \
            -e BOOTUP_RECLAIM \
            -e MI_RECLAIM \
            -e RTMM \
            -d REKERNEL \
            -d REKERNEL_NETWORK
    fi

    # ----------------------------------------------------
    # Droidspaces 配置注入（核心变更）
    # ----------------------------------------------------
    if [ "$ENABLE_DS" -eq 1 ]; then
        echo "==========================================="
        echo " [*] Injecting Droidspaces configurations"
        echo "==========================================="
        scripts/config --file "${OUT_DIR}/.config" \
            -e SYSVIPC \
            -e POSIX_MQUEUE \
            -e PID_NS \
            -e IPC_NS \
            -e UTS_NS \
            -e NET_NS \
            -e USER_NS \
            -e DEVTMPFS \
            -d DEVTMPFS_MOUNT \
            -e CGROUP_DEVICE \
            -e CGROUP_PIDS \
            -e CGROUP_FREEZER \
            -e CGROUP_NET_PRIO \
            -e CFS_BANDWIDTH \
            -e SECCOMP \
            -e SECCOMP_FILTER \
            -e OVERLAY_FS \
            -e TMPFS_POSIX_ACL \
            -e TMPFS_XATTR \
            -e VETH \
            -e BRIDGE \
            -e NETFILTER \
            -e NF_CONNTRACK \
            -e IP_NF_IPTABLES \
            -e IP_NF_FILTER \
            -e IP_NF_NAT \
            -e NF_NAT \
            -e IP_NF_TARGET_MASQUERADE \
            -e NETFILTER_XT_TARGET_MASQUERADE \
            -e NETFILTER_XT_TARGET_TCPMSS \
            -e NETFILTER_XT_MATCH_ADDRTYPE \
            -e IP_ADVANCED_ROUTER \
            -e IP_MULTIPLE_TABLES \
            -e NF_CONNTRACK_NETLINK \
            -e NF_NAT_REDIRECT
    fi

    # BBG 是无条件注入的，必须重新展开依赖
    echo "[*] make olddefconfig ..."
    make "${MAKE_OPTS[@]}" olddefconfig

    # 注入后的硬校验：缺一项就别刷
    if [ "$ENABLE_DS" -eq 1 ]; then
        if ! verify_ds_config "${OUT_DIR}/.config"; then
            exit 1
        fi
        if [ -n "$GITHUB_STEP_SUMMARY" ]; then
            {
                echo "### droidspaces 配置核对 ($OS_TYPE)"
                echo '```'
                grep -E '^CONFIG_(NAMESPACES|PID_NS|UTS_NS|IPC_NS|SYSVIPC|POSIX_MQUEUE|DEVTMPFS|CGROUP_DEVICE|CGROUP_PIDS|USER_NS|NET_NS|SECCOMP|OVERLAY_FS|VETH|BRIDGE)=' "${OUT_DIR}/.config" || true
                echo '```'
            } >> "$GITHUB_STEP_SUMMARY"
        fi
    fi

    # ----------------------------------------------------
    # 编译
    # ----------------------------------------------------
    echo "[*] Building kernel..."
    make "${MAKE_OPTS[@]}"

    if [ "$OS_TYPE" == "miui" ]; then
        echo "[*] Restoring DTS backups..."
        rm -rf "${DTS_SOURCE}"
        mv "${DTS_BACKUP}" "${DTS_SOURCE}"
    fi

    echo "==========================================="
    if [ -f "${OUT_DIR}/arch/arm64/boot/Image" ]; then
        echo "[+] $OS_TYPE Build Successful!"
        echo "[*] Generating dtb..."
        find "${OUT_DIR}/arch/arm64/boot/dts" -name '*.dtb' -exec cat {} + > "${OUT_DIR}/arch/arm64/boot/dtb"

        echo "[*] Packaging to AnyKernel3 ($OS_TYPE)..."
        rm -rf anykernel/kernels/*
        mkdir -p "anykernel/kernels/${OS_TYPE}/"
        cp "${OUT_DIR}/arch/arm64/boot/Image" "anykernel/kernels/${OS_TYPE}/"
        cp "${OUT_DIR}/arch/arm64/boot/dtb" "anykernel/kernels/${OS_TYPE}/"

        # 注意：不打包 dtbo。上游明确建议保留原厂 dtbo。
        local KSU_ZIP_STR="NoKernelSU"
        if [ "$ENABLE_KSU" -eq 1 ]; then
            KSU_ZIP_STR="ReSukiSU-SuSFS"
        fi
        local DS_STR="DSfalse"
        if [ "$ENABLE_DS" -eq 1 ]; then
            DS_STR="DStrue"
        fi
        local GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD 2>/dev/null || echo "unknown")
        local OS_UPPER=$(echo "$OS_TYPE" | tr '[:lower:]' '[:upper:]')
        local ZIP_FILENAME="APTKernel_${OS_UPPER}_${DEVICE_NAME}_${KSU_ZIP_STR}_${DS_STR}_$(date +'%Y%m%d_%H%M%S')_anykernel3_${GIT_COMMIT_ID}.zip"

        echo "[*] Zipping $ZIP_FILENAME ..."
        pushd anykernel > /dev/null
        zip -r9 "$ZIP_FILENAME" ./* -x .git .gitignore out/ ./*.zip > /dev/null
        mv "$ZIP_FILENAME" ../
        popd > /dev/null

        echo "[+] packed: $ZIP_FILENAME"
    else
        echo "[-] $OS_TYPE Build Failed. Kernel Image not found."
        exit 1
    fi
}

if [ "$TARGET_OS" == "aosp" ] || [ "$TARGET_OS" == "both" ]; then
    build_target "aosp"
fi
if [ "$TARGET_OS" == "miui" ] || [ "$TARGET_OS" == "both" ]; then
    build_target "miui"
fi

echo "==========================================="
echo "[*] ccache stats:"
ccache -s || true
echo "[+] All requested builds completed!"
