#!/bin/bash

# Exit on any error
set -e

# ==========================================
# Argument Parsing
# ==========================================
if [ -z "$1" ]; then
    echo "[!] Error: No device specified."
    echo "Usage: $0 <device_name> [ksu] [miui|aosp]"
    echo "Example: $0 lmi"
    echo "         $0 lmi ksu"
    echo "         $0 lmi ksu miui"
    echo "         $0 lmi aosp"
    exit 1
fi

DEVICE_NAME="$1"
DEFCONFIG="${DEVICE_NAME}_defconfig"
DEFCONFIG_PATH="arch/arm64/configs/${DEFCONFIG}"

if [ ! -f "$DEFCONFIG_PATH" ]; then
    echo "[!] Error: Defconfig not found at $DEFCONFIG_PATH"
    echo "[!] Please verify the device name and try again."
    exit 1
fi

ENABLE_KSU=0
TARGET_OS="both"

shift
# Parse remaining arguments loosely
for arg in "$@"; do
    case "$arg" in
        ksu) ENABLE_KSU=1 ;;
        miui) TARGET_OS="miui" ;;
        aosp) TARGET_OS="aosp" ;;
    esac
done

# ==========================================
# Configuration & Environment
# ==========================================
KERNEL_DIR="$(pwd)"
TOOLCHAIN_BIN="$HOME/zyc-clang/bin"

export PATH="${TOOLCHAIN_BIN}:${PATH}"
export ARCH="arm64"
export SUBARCH="arm64"

# ccache Setup
export CCACHE_DIR="$HOME/.cache/ccache_mikernel"
export CCACHE_EXEC=$(command -v ccache)

if [ -z "$CCACHE_EXEC" ]; then
    echo "[!] ccache not found! Please install ccache first."
    exit 1
fi

export USE_CCACHE=1
export CROSS_COMPILE="aarch64-linux-gnu-"
export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"

echo "[*] Checking Clang version..."
clang --version || { echo "[!] Clang not found at ${TOOLCHAIN_BIN}. Please check the path."; exit 1; }

echo "[*] Setting up ccache in $CCACHE_DIR..."
mkdir -p "$CCACHE_DIR"

# ==========================================
# KernelSU Setup
# ==========================================
if [ "$ENABLE_KSU" -eq 1 ]; then
    echo "==========================================="
    echo " [*] Initializing KernelSU (BakaSU) Setup"
    echo "==========================================="
    echo "[*] Downloading and running BakaSU remote setup script..."
    curl -LSs "https://raw.githubusercontent.com/Baka-SU/BakaSU/main/kernel/setup.sh" | bash

    # Compatibility layer: use newer SUSFS APIs only when the kernel tree provides them.
    # Older 4.19 trees (such as this v2.3.0 backport) keep their legacy behavior.
    python3 - <<'PY'
from pathlib import Path
import re

header = Path("include/linux/susfs.h").read_text()
susfs_source = Path("fs/susfs.c").read_text()

def has_decl(text, name):
    pattern = rf"(?m)^\s*(?:extern\s+)?(?:inline\s+)?(?:int|void|bool|long)\s+{re.escape(name)}\s*\("
    return re.search(pattern, text) is not None

def patch_file(path, edits, defines):
    file = Path(path)
    source = file.read_text()

    # Add feature macros after the include block. They are intentionally
    # defined only when the kernel-side API is actually present.
    if defines:
        lines = source.splitlines()
        last_include = max((i for i, line in enumerate(lines) if line.startswith("#include ")), default=-1)
        if last_include < 0:
            raise SystemExit(f"[!] No include block found in {path}")
        for macro in defines:
            define = f"#define {macro} 1"
            if define not in source:
                lines.insert(last_include + 1, define)
                last_include += 1
        source = "\n".join(lines) + ("\n" if source.endswith("\n") else "")

    for old_block, new_block, label in edits:
        if new_block in source:
            continue
        if old_block not in source:
            raise SystemExit(f"[!] Cannot locate expected compatibility site in {path}: {label}")
        source = source.replace(old_block, new_block, 1)

    file.write_text(source)

# 1) Native SELinux registration exists only in newer SUSFS patch sets.
# BakaSU already supplies extern declarations, so probe the kernel header
# and implementation; otherwise retain the legacy policy-generation path.
selinux_names = (
    "susfs_add_sus_avd_allowed_by_type",
    "susfs_add_sus_type",
)
selinux_supported = all(
    has_decl(header, name) and has_decl(susfs_source, name)
    for name in selinux_names
)
selinux_defines = ["KSU_SUSFS_COMPAT_HAS_SELINUX_REGISTRATION"] if selinux_supported else []
patch_file(
    "KernelSU/kernel/selinux/sepolicy.c",
    [
        (
            "#ifdef CONFIG_KSU_SUSFS\nextern int susfs_add_sus_avd_allowed_by_type",
            "#if defined(CONFIG_KSU_SUSFS) && defined(KSU_SUSFS_COMPAT_HAS_SELINUX_REGISTRATION)\nextern int susfs_add_sus_avd_allowed_by_type",
            "SELinux API declarations",
        ),
        (
            "#ifdef CONFIG_KSU_SUSFS\n        susfs_add_sus_avd_allowed_by_type",
            "#if defined(CONFIG_KSU_SUSFS) && defined(KSU_SUSFS_COMPAT_HAS_SELINUX_REGISTRATION)\n        susfs_add_sus_avd_allowed_by_type",
            "SELinux AV registration",
        ),
        (
            "#ifdef CONFIG_KSU_SUSFS\n    susfs_add_sus_type",
            "#if defined(CONFIG_KSU_SUSFS) && defined(KSU_SUSFS_COMPAT_HAS_SELINUX_REGISTRATION)\n    susfs_add_sus_type",
            "SELinux type registration",
        ),
    ],
    selinux_defines,
)

# 2) Optional app UID parsers: enable only when the kernel header declares them.
priority_supported = (
    has_decl(header, "susfs_parse_priority_app_strings")
    and has_decl(susfs_source, "susfs_parse_priority_app_strings")
)
sus_path_apps_supported = (
    has_decl(header, "susfs_parse_sus_path_app_strings")
    and has_decl(susfs_source, "susfs_parse_sus_path_app_strings")
)

# Do not advertise the priority UID feature when its kernel-side API is absent.
priority_marker = Path(".ksu_susfs_disable_priority_uid_filter")
priority_marker.unlink(missing_ok=True)
if not priority_supported:
    priority_marker.touch()

tracker_defines = []
if priority_supported:
    tracker_defines.append("KSU_SUSFS_COMPAT_HAS_PRIORITY_UID_PARSER")
if sus_path_apps_supported:
    tracker_defines.append("KSU_SUSFS_COMPAT_HAS_SUS_PATH_APP_PARSER")

patch_file(
    "KernelSU/kernel/manager/throne_tracker.c",
    [
        (
            "#ifdef CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER\n    // Refresh after tracking completes, including deferred scans.\n    susfs_parse_priority_app_strings();\n#endif",
            "#if defined(CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER) && defined(KSU_SUSFS_COMPAT_HAS_PRIORITY_UID_PARSER)\n    // Refresh after tracking completes, including deferred scans.\n    susfs_parse_priority_app_strings();\n#endif",
            "priority UID parser",
        ),
        (
            "#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n    // Renew the sus path uid bitmap filter\n    susfs_parse_sus_path_app_strings();\n#endif // #ifdef CONFIG_KSU_SUSFS_SUS_PATH",
            "#if defined(CONFIG_KSU_SUSFS_SUS_PATH) && defined(KSU_SUSFS_COMPAT_HAS_SUS_PATH_APP_PARSER)\n    // Renew the sus path uid bitmap filter\n    susfs_parse_sus_path_app_strings();\n#endif // SUSFS app parser compatibility",
            "sus path app parser",
        ),
    ],
    tracker_defines,
)

# 3) New command IDs are compiled only when the matching kernel header defines them.
dispatch = Path("KernelSU/kernel/supercall/dispatch.c")
source = dispatch.read_text()
compat_cases = {
    "CMD_SUSFS_SET_SUS_PATH_UID_FILTER": """    case CMD_SUSFS_SET_SUS_PATH_UID_FILTER: {
        susfs_set_sus_path_uid_filter(arg);
        return 0;
    }""",
    "CMD_SUSFS_SET_PRIORITY_UID_FILTER": """    case CMD_SUSFS_SET_PRIORITY_UID_FILTER: {
        susfs_set_priority_uid_filter(arg);
        return 0;
    }""",
}
for command, block in compat_cases.items():
    guarded = f"#ifdef {command}\n{block}\n#endif"
    if guarded in source:
        continue
    if block not in source:
        raise SystemExit(f"[!] Cannot find expected BakaSU dispatch block: {command}")
    source = source.replace(block, guarded, 1)
dispatch.write_text(source)

print("[+] SUSFS compatibility probe:")
print(f"    Native SELinux registration: {'enabled' if selinux_supported else 'skipped (legacy policy fallback)'}")
print(f"    Priority UID parser: {'enabled' if priority_supported else 'skipped (not declared by kernel SUSFS)'}")
print(f"    Sus-path app parser: {'enabled' if sus_path_apps_supported else 'skipped (not declared by kernel SUSFS)'}")
print("[+] Missing SUSFS command IDs are guarded; supported APIs remain enabled.")
PY
    echo "[+] BakaSU setup finished."
fi

# ==========================================
# NoMount Setup (Linux 4.19 integration)
# Resolve the latest stable GitHub Release at build time.
# ==========================================
echo "==========================================="
echo " [*] Resolving latest stable NoMount release"
echo "==========================================="
# Use the Actions token to avoid unauthenticated GitHub API rate limits.
# Keep the request usable outside Actions when no token is available.
NOMOUNT_API_HEADERS=(
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
)
if [ -n "${GITHUB_TOKEN:-}" ]; then
    NOMOUNT_API_HEADERS+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

NOMOUNT_RESPONSE="$(curl -fsSL --retry 3 --retry-delay 2 \
    "${NOMOUNT_API_HEADERS[@]}" \
    https://api.github.com/repos/maxsteeel/nomount/releases/latest)" || {
    echo "[!] Failed to fetch NoMount release information from GitHub API."
    echo "[!] Check GITHUB_TOKEN permissions and GitHub API availability."
    exit 1
}

NOMOUNT_VERSION="$(printf '%s' "$NOMOUNT_RESPONSE" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except json.JSONDecodeError as exc:
    raise SystemExit(f"[!] GitHub API returned invalid JSON: {exc}")
if not isinstance(data, dict) or not data.get("tag_name"):
    message = data.get("message", "tag_name is missing") if isinstance(data, dict) else "unexpected response"
    raise SystemExit(f"[!] Cannot resolve NoMount release: {message}")
print(data["tag_name"])
')" || {
    echo "[!] Failed to parse the latest stable NoMount release."
    exit 1
}
echo "[*] Latest stable NoMount release: ${NOMOUNT_VERSION}"
curl -fsSL --retry 3 --retry-delay 2 \
    "https://raw.githubusercontent.com/maxsteeel/nomount/${NOMOUNT_VERSION}/kernel/setup.sh" \
    | sh -s "${NOMOUNT_VERSION}"
echo "[+] NoMount ${NOMOUNT_VERSION} setup finished."

# ==========================================
# Baseband-guard Setup
# ==========================================
echo "==========================================="
echo " [*] Initializing Baseband-guard Setup"
echo "==========================================="
echo "[*] Downloading and running Baseband-guard remote setup script..."
wget -O- https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh | bash

echo "[*] Patching security/Kconfig for baseband_guard..."
sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' security/Kconfig
echo "[+] Baseband-guard setup finished."
echo "==========================================="

# ==========================================
# AnyKernel3 Setup
# ==========================================
echo "==========================================="
echo " [*] Initializing AnyKernel3 Workspace"
echo "==========================================="
rm -rf anykernel
echo "[*] Cloning AnyKernel3..."
git clone https://github.com/wdgu/AnyKernel3 -b kona --single-branch --depth=1 anykernel
echo "[+] AnyKernel3 cloned successfully."
echo "[*] Adjusting AnyKernel3..."
sed -i "s/^device\.name1=.*/device.name1=${DEVICE_NAME}/" anykernel/anykernel.sh
echo "[*] AnyKernel3 adjusted successfully."
echo "==========================================="

# ==========================================
# Modular Build Function
# ==========================================
build_target() {
    local OS_TYPE=$1
    echo "==========================================="
    echo " Starting Kernel Compilation for ${DEVICE_NAME} (Target: $OS_TYPE)"
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

    echo "[*] Cleaning ${OUT_DIR}..."
    rm -rf "${OUT_DIR}"
    mkdir -p "${OUT_DIR}"

    local DTS_SOURCE="arch/arm64/boot/dts/vendor/qcom"
    local DTS_BACKUP=".dts.bak.${OS_TYPE}"

    if [ "$OS_TYPE" == "miui" ]; then
        echo "[*] Applying MIUI DTS patches..."
        cp -a "${DTS_SOURCE}" "${DTS_BACKUP}"
        
        # Apply MIUI specific sed patches to dts
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

    echo "[*] Making defconfig: ${DEFCONFIG}..."
    make "${MAKE_OPTS[@]}" "${DEFCONFIG}"

    # ----------------------------------------------------
    # Configuration tweaks
    # ----------------------------------------------------
    
    # 1. Baseband-guard configuration (Always applied)
    echo "[*] Injecting Baseband-guard configuration..."
    scripts/config --file "${OUT_DIR}/.config" -e BBG

    # 2. NoMount configuration (available with or without KernelSU)
    echo "[*] Enabling NoMount..."
    scripts/config --file "${OUT_DIR}/.config" -e NOMOUNT

    # 3. KernelSU configurations
    if [ "$ENABLE_KSU" -eq 1 ]; then
        echo "[*] Injecting BakaSU & SUSFS configurations..."
        scripts/config --file "${OUT_DIR}/.config" \
            -e KSU \
            -e THREAD_INFO_IN_TASK \
            -e KSU_SUSFS
        if [ -f ".ksu_susfs_disable_priority_uid_filter" ]; then
            echo "[!] SUSFS priority UID API is unavailable; disabling KSU_SUSFS_PRIORITY_UID_FILTER."
            scripts/config --file "${OUT_DIR}/.config" -d KSU_SUSFS_PRIORITY_UID_FILTER
        fi
    fi

    # 3. MIUI configurations
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
            -e PERF_HUMANTASK \
            -d LTO_CLANG \
            -e LTO_NONE \
            -d SHADOW_CALL_STACK \
            -e XIAOMI_MIUI \
            -d MI_MEMORY_SYSFS \
            -e TASK_DELAY_ACCT \
            -e MIUI_ZRAM_MEMORY_TRACKING \
            -e PERF_HELPER \
            -e BOOTUP_RECLAIM \
            -e MI_RECLAIM \
            -e RTMM \
            -e MILLET_CGROUP \
            -e MILLET_SIG \
            -e MILLET_BINDER \
            -e MILLET_PKG \
            -e MILLET_BINDER_GKI \
            -e MILLET_CORE \
            -e MILLET_HS \
            -e BINDER_PRIO \
            -d REKERNEL \
            -d REKERNEL_NETWORK
    fi

    # 4. AOSP configurations
    if [ "$OS_TYPE" == "aosp" ]; then
        echo "[*] Injecting AOSP specific configurations..."
        scripts/config --file "${OUT_DIR}/.config" \
            -e REKERNEL \
            -e REKERNEL_NETWORK
    fi

    # We always need to re-evaluate dependencies because BBG is injected unconditionally
    echo "[*] Updating config (make olddefconfig)..."
    make "${MAKE_OPTS[@]}" olddefconfig

    # ----------------------------------------------------
    # Compilation
    # ----------------------------------------------------
    echo "[*] Building kernel..."
    make "${MAKE_OPTS[@]}" 

    # Restore DTS backup for MIUI
    if [ "$OS_TYPE" == "miui" ]; then
        echo "[*] Restoring DTS backups..."
        rm -rf "${DTS_SOURCE}"
        mv "${DTS_BACKUP}" "${DTS_SOURCE}"
    fi

    echo "==========================================="
    if [ -f "${OUT_DIR}/arch/arm64/boot/Image" ]; then
        echo "[+] $OS_TYPE Build Successful!"
        echo "[+] Kernel Image path: ${OUT_DIR}/arch/arm64/boot/Image"

        echo "[*] Packaging to AnyKernel3 ($OS_TYPE)..."
        # 确保独立打包：清空现有的 kernels 目录
        rm -rf anykernel/kernels/*
        mkdir -p "anykernel/kernels/${OS_TYPE}/"
        
        cp "${OUT_DIR}/arch/arm64/boot/Image" "anykernel/kernels/${OS_TYPE}/"
        cp "${OUT_DIR}/arch/arm64/boot/dtb" "anykernel/kernels/${OS_TYPE}/"
        
        if [ -f "${OUT_DIR}/arch/arm64/boot/dtbo.img" ]; then
            cp "${OUT_DIR}/arch/arm64/boot/dtbo.img" "anykernel/kernels/${OS_TYPE}/"
        fi
        
        # 确定 ZIP 文件名
        local KSU_ZIP_STR="NoKernelSU"
        if [ "$ENABLE_KSU" -eq 1 ]; then
            KSU_ZIP_STR="BakaSU-SuSFS"
        fi
        local GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD 2>/dev/null || echo "unknown")
        local OS_UPPER=$(echo "$OS_TYPE" | tr '[:lower:]' '[:upper:]')
        local ZIP_FILENAME="APTKernel_${OS_UPPER}_${DEVICE_NAME}_${KSU_ZIP_STR}_$(date +'%Y%m%d_%H%M%S')_anykernel3_${GIT_COMMIT_ID}.zip"
        
        echo "[*] Zipping $ZIP_FILENAME ..."
        pushd anykernel > /dev/null
        zip -r9 "$ZIP_FILENAME" ./* -x .git .gitignore out/ ./*.zip > /dev/null
        mv "$ZIP_FILENAME" ../
        popd > /dev/null
        
        echo "[+] $OS_TYPE kernel binaries successfully packed into: $ZIP_FILENAME"
    else
        echo "[-] $OS_TYPE Build Failed. Kernel Image not found."
        exit 1
    fi
}

# ==========================================
# Execute builds based on target OS
# ==========================================
if [ "$TARGET_OS" == "aosp" ] || [ "$TARGET_OS" == "both" ]; then
    build_target "aosp"
fi

if [ "$TARGET_OS" == "miui" ] || [ "$TARGET_OS" == "both" ]; then
    build_target "miui"
fi

echo "==========================================="
echo "[*] ccache stats:"
ccache -s
echo "[+] All requested builds completed!"
