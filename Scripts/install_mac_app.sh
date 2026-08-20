#!/bin/bash

set -Eeuo pipefail

readonly EXPECTED_BUNDLE_ID="com.auralis.player.macos"
readonly INSTALL_DIR="/Applications"
readonly INSTALL_PATH="${INSTALL_DIR}/Auralis.app"
readonly STAGING_PATH="${INSTALL_DIR}/.Auralis.installing.app"
readonly BACKUP_PATH="${INSTALL_DIR}/.Auralis.previous.app"
readonly XCODE_DERIVED_DATA_ROOT="${HOME}/Library/Developer/Xcode/DerivedData"
readonly SPOTLIGHT_QUERY='kMDItemCFBundleIdentifier == "com.auralis.player.macos"'

BUILD_ROOT=""
DERIVED_DATA=""
APP_SOURCE=""
INSTALL_STAGING_ACTIVE=0
INSTALL_BACKUP_ACTIVE=0

cleanup() {
    local exit_code=$?
    local cleanup_failed=0

    trap - EXIT INT TERM

    # If replacement failed after moving the old app aside, restore it before
    # removing any temporary install artifacts.
    if [[ "$INSTALL_BACKUP_ACTIVE" -eq 1 && -e "$BACKUP_PATH" ]]; then
        if [[ ! -e "$INSTALL_PATH" ]]; then
            if ! run_as_install_admin /bin/mv "$BACKUP_PATH" "$INSTALL_PATH"; then
                echo "错误：无法恢复原有 /Applications/Auralis.app" >&2
                cleanup_failed=1
            else
                INSTALL_BACKUP_ACTIVE=0
            fi
        else
            if ! run_as_install_admin /bin/rm -rf "$BACKUP_PATH"; then
                echo "错误：无法清理临时旧版 App：$BACKUP_PATH" >&2
                cleanup_failed=1
            else
                INSTALL_BACKUP_ACTIVE=0
            fi
        fi
    fi

    if [[ "$INSTALL_STAGING_ACTIVE" -eq 1 && -e "$STAGING_PATH" ]]; then
        if ! run_as_install_admin /bin/rm -rf "$STAGING_PATH"; then
            echo "错误：无法清理临时安装 App：$STAGING_PATH" >&2
            cleanup_failed=1
        else
            INSTALL_STAGING_ACTIVE=0
        fi
    fi

    if [[ -n "${BUILD_ROOT:-}" && -d "$BUILD_ROOT" ]]; then
        if ! /bin/rm -rf "$BUILD_ROOT"; then
            echo "错误：无法清理临时构建目录：$BUILD_ROOT" >&2
            cleanup_failed=1
        fi
    fi

    if [[ "$exit_code" -eq 0 && "$cleanup_failed" -ne 0 ]]; then
        exit_code=1
    fi

    exit "$exit_code"
}

trap cleanup EXIT INT TERM

fail() {
    echo "错误：$*" >&2
    exit 1
}

step() {
    printf '[%s/7] %s\n' "$1" "$2"
}

run_as_install_admin() {
    if [[ "$EUID" -eq 0 || -w "$INSTALL_DIR" ]]; then
        "$@"
        return
    fi

    if ! command -v sudo >/dev/null 2>&1; then
        fail "没有写入 $INSTALL_DIR 的权限，且找不到 sudo"
    fi

    echo "需要管理员权限执行：$*"
    sudo "$@"
}

official_app_pids() {
    local pid
    local command_line

    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
        if [[ "$command_line" == *"${INSTALL_PATH}/Contents/MacOS/Auralis"* ]]; then
            printf '%s\n' "$pid"
        fi
    done < <(pgrep -x Auralis 2>/dev/null || true)
}

all_auralis_processes_are_official() {
    local pid
    local command_line

    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
        if [[ "$command_line" != *"${INSTALL_PATH}/Contents/MacOS/Auralis"* ]]; then
            return 1
        fi
    done < <(pgrep -x Auralis 2>/dev/null || true)

    return 0
}

quit_official_app() {
    local running_pids

    running_pids="$(official_app_pids || true)"
    [[ -n "$running_pids" ]] || return 0

    echo "正在优雅退出已安装的 Auralis..."
    osascript -e '
tell application "System Events"
    if exists process "Auralis" then
        tell application "Auralis" to quit
    end if
end tell
' >/dev/null 2>&1 || true

    for ((attempt = 1; attempt <= 20; attempt++)); do
        [[ -z "$(official_app_pids || true)" ]] && return 0
        sleep 0.25
    done

    running_pids="$(official_app_pids || true)"
    if [[ -n "$running_pids" ]]; then
        echo "Auralis 未在 5 秒内退出，发送最后的正常终止信号..."
        while IFS= read -r pid; do
            [[ -n "$pid" ]] || continue
            kill "$pid" 2>/dev/null || true
        done <<< "$running_pids"
        sleep 0.5
    fi

    running_pids="$(official_app_pids || true)"
    if [[ -n "$running_pids" && "$(all_auralis_processes_are_official && echo yes || echo no)" == "yes" ]]; then
        echo "仍有正式 Auralis 进程，执行最后 fallback：pkill -x Auralis..."
        pkill -x Auralis || true
        sleep 0.5
    fi

    if [[ -n "$(official_app_pids || true)" ]]; then
        fail "无法退出 /Applications/Auralis.app，请先手动退出后重试"
    fi
}

cleanup_repo_build_artifacts() {
    local build_artifact_root
    local repo_build_roots=(
        "$REPO_ROOT/build"
        "$REPO_ROOT/Build"
        "$REPO_ROOT/DerivedData"
        "$REPO_ROOT/.derivedData"
        "$REPO_ROOT/.build"
        "$REPO_ROOT/Packages/AuralisCore/.build"
    )

    for build_artifact_root in "${repo_build_roots[@]}"; do
        if [[ -e "$build_artifact_root" || -L "$build_artifact_root" ]]; then
            echo "删除项目构建产物：$build_artifact_root"
            /bin/rm -rf "$build_artifact_root"
        fi
    done
}

cleanup_historical_derived_data() {
    local derived_data_path

    if [[ ! -d "$XCODE_DERIVED_DATA_ROOT" ]]; then
        return 0
    fi

    while IFS= read -r -d '' derived_data_path; do
        echo "删除旧 Auralis DerivedData：$derived_data_path"
        /bin/rm -rf "$derived_data_path"
    done < <(
        find "$XCODE_DERIVED_DATA_ROOT" \
            -maxdepth 1 \
            -mindepth 1 \
            -type d \
            -name 'Auralis-*' \
            -print0
    )
}

is_known_repo_build_app_path() {
    local candidate="$1"

    case "$candidate" in
        "$REPO_ROOT/build"/*|\
        "$REPO_ROOT/Build"/*|\
        "$REPO_ROOT/DerivedData"/*|\
        "$REPO_ROOT/.derivedData"/*|\
        "$REPO_ROOT/.build"/*|\
        "$REPO_ROOT/Packages/AuralisCore/.build"/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_known_derived_data_app_path() {
    local candidate="$1"

    case "$candidate" in
        "$XCODE_DERIVED_DATA_ROOT"/Auralis-*/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

cleanup_repo_app_copies() {
    local app_path

    while IFS= read -r -d '' app_path; do
        echo "发现项目目录中的 Auralis.app：$app_path" >&2
        if is_known_repo_build_app_path "$app_path"; then
            echo "删除已确认的项目构建副本：$app_path"
            /bin/rm -rf "$app_path"
        else
            fail "项目目录仍存在无法安全判定的 Auralis.app：$app_path"
        fi
    done < <(
        find "$REPO_ROOT" \
            -type d \
            -name 'Auralis.app' \
            -print0
    )
}

cleanup_spotlight_build_copies() {
    local spotlight_results
    local result_path

    spotlight_results="$(mdfind "$SPOTLIGHT_QUERY" 2>/dev/null || true)"
    [[ -n "$spotlight_results" ]] || return 0

    echo "Spotlight 当前索引结果："
    printf '%s\n' "$spotlight_results"

    while IFS= read -r result_path; do
        [[ -n "$result_path" ]] || continue
        [[ "$result_path" == "$INSTALL_PATH" ]] && continue
        [[ -e "$result_path" ]] || continue

        if is_known_repo_build_app_path "$result_path" || is_known_derived_data_app_path "$result_path"; then
            echo "删除已确认的 Spotlight 构建副本：$result_path"
            /bin/rm -rf "$result_path"
        else
            fail "Spotlight 发现真实存在但无法安全判定的 Auralis.app：$result_path"
        fi
    done <<< "$spotlight_results"
}

verify_installed_app() {
    local bundle_id
    local info_plist="$INSTALL_PATH/Contents/Info.plist"

    [[ -d "$INSTALL_PATH" ]] || fail "安装后的 Auralis.app 不存在：$INSTALL_PATH"
    [[ -f "$info_plist" ]] || fail "安装后的 Info.plist 不存在：$info_plist"

    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
    [[ "$bundle_id" == "$EXPECTED_BUNDLE_ID" ]] || fail "安装后的 Bundle ID 不匹配：$bundle_id"

    codesign --verify --deep --strict --verbose=2 "$INSTALL_PATH"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

cd "$REPO_ROOT"

step 1 "检查项目"
[[ -d "$REPO_ROOT/Auralis.xcodeproj" ]] || fail "未找到 Auralis.xcodeproj：$REPO_ROOT"
[[ -d "$INSTALL_DIR" ]] || fail "未找到安装目录：$INSTALL_DIR"

step 2 "创建临时 .noindex 构建目录"
[[ -n "${TMPDIR:-}" ]] || fail "TMPDIR 未设置，无法创建安全的临时构建目录"
BUILD_ROOT="${TMPDIR%/}/AuralisBuild-$(uuidgen).noindex"
DERIVED_DATA="$BUILD_ROOT/DerivedData"
mkdir -p "$DERIVED_DATA"

step 3 "Release 构建 AuralisMac"
xcodebuild \
    -project "$REPO_ROOT/Auralis.xcodeproj" \
    -scheme AuralisMac \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    build

step 4 "验证签名与 Bundle ID"
APP_SOURCE="$DERIVED_DATA/Build/Products/Release/Auralis.app"
[[ -d "$APP_SOURCE" ]] || fail "Release Auralis.app 不存在：$APP_SOURCE"

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_SOURCE/Contents/Info.plist")"
[[ "$bundle_id" == "$EXPECTED_BUNDLE_ID" ]] || fail "Bundle ID 不匹配：$bundle_id"

codesign --verify --deep --strict --verbose=2 "$APP_SOURCE"
codesign -dv --verbose=4 "$APP_SOURCE" 2>&1

step 5 "安装到 /Applications/Auralis.app"
quit_official_app

if [[ -e "$STAGING_PATH" || -L "$STAGING_PATH" ]]; then
    run_as_install_admin /bin/rm -rf "$STAGING_PATH"
fi
if [[ -e "$BACKUP_PATH" || -L "$BACKUP_PATH" ]]; then
    run_as_install_admin /bin/rm -rf "$BACKUP_PATH"
fi

INSTALL_STAGING_ACTIVE=1
run_as_install_admin /usr/bin/ditto "$APP_SOURCE" "$STAGING_PATH"
codesign --verify --deep --strict --verbose=2 "$STAGING_PATH"

if [[ -e "$INSTALL_PATH" || -L "$INSTALL_PATH" ]]; then
    run_as_install_admin /bin/mv "$INSTALL_PATH" "$BACKUP_PATH"
    INSTALL_BACKUP_ACTIVE=1
fi

run_as_install_admin /bin/mv "$STAGING_PATH" "$INSTALL_PATH"
INSTALL_STAGING_ACTIVE=0

if [[ "$INSTALL_BACKUP_ACTIVE" -eq 1 ]]; then
    run_as_install_admin /bin/rm -rf "$BACKUP_PATH"
    INSTALL_BACKUP_ACTIVE=0
fi

step 6 "清理 Auralis 构建产物"
cleanup_repo_build_artifacts
cleanup_repo_app_copies
cleanup_historical_derived_data
cleanup_spotlight_build_copies

if [[ -n "$BUILD_ROOT" && -d "$BUILD_ROOT" ]]; then
    /bin/rm -rf "$BUILD_ROOT"
fi

step 7 "验证唯一正式应用"
verify_installed_app

spotlight_results="$(mdfind "$SPOTLIGHT_QUERY" 2>/dev/null || true)"
if [[ -n "$spotlight_results" ]]; then
    echo "Spotlight 最终结果："
    printf '%s\n' "$spotlight_results"
fi

while IFS= read -r result_path; do
    [[ -n "$result_path" ]] || continue
    [[ "$result_path" == "$INSTALL_PATH" ]] && continue
    if [[ -e "$result_path" ]]; then
        fail "Spotlight 仍发现真实的重复 Auralis.app：$result_path"
    fi
done <<< "$spotlight_results"

remaining_repo_apps="$(find "$REPO_ROOT" -type d -name 'Auralis.app' -print 2>/dev/null || true)"
if [[ -n "$remaining_repo_apps" ]]; then
    fail "项目目录仍存在 Auralis.app 构建副本：$remaining_repo_apps"
fi

open "$INSTALL_PATH"

echo ""
echo "Auralis 安装完成"
echo "位置：$INSTALL_PATH"
echo "Bundle ID：$EXPECTED_BUNDLE_ID"
echo "构建产物：已清理"
