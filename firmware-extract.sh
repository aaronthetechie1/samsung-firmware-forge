#!/usr/bin/env bash
# Download stock One UI and ColorOS firmware archives.
# SPDX-License-Identifier: GPL-3.0-or-later

set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_ROOT="$PROJECT_DIR/output"
STAGE_ROOT="$PROJECT_DIR/.work"
VENV_DIR="$PROJECT_DIR/.venv"
TOOLS_DIR="$PROJECT_DIR/.tools"
VERSION="1.0.0"
ASGARD_BIN="$VENV_DIR/bin/asgard"
ASGARD_TQDM_RUNNER="$PROJECT_DIR/asgard_tqdm.py"
OPPO_OTA_BIN="$VENV_DIR/bin/oppo-ota"
OPPO_OTA_INSTALL_URL="git+https://github.com/kestr31/OPPO-OTA-Downloader-CLI.git@20bea70fd4d637e67722eac3b8b4a8e2ecafcc2e"
PAYLOAD_DUMPER_BIN="$TOOLS_DIR/payload-dumper-go"
PAYLOAD_DUMPER_VERSION="2.1.0"

SOURCE=""
MODEL=""
CSC=""
REGION=""
MODE=""
COLOROS_VARIANT=""
COLOROS_QUERY_REGION=""
COLOROS_OTA_VERSION=""
COLOROS_MAJOR=""
COLOROS_NV_ID=""
COLOROS_DOWNLOAD_URL=""
COLOROS_DOWNLOAD_SIZE=""
COLOROS_DOWNLOAD_MD5=""
COLOROS_FILENAME=""
MOUNT_DIR=""
MOUNTED=false
MOUNTED_AS_USER=false
STAGE_DIR=""
SYSTEM_IMAGE=""
ASGARD_ERROR_LOG=""
FINISHED=false
PACKAGE_MANAGER=""

info() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
    local status="$?"
    if $MOUNTED && mountpoint -q "$MOUNT_DIR"; then
        if $MOUNTED_AS_USER && command -v fusermount3 >/dev/null 2>&1; then
            fusermount3 -u "$MOUNT_DIR" || true
        else
            sudo umount "$MOUNT_DIR" || true
        fi
    fi
    [ -n "$MOUNT_DIR" ] && rmdir "$MOUNT_DIR" 2>/dev/null || true
    if $FINISHED && [ -n "$STAGE_DIR" ]; then
        rm -rf -- "$STAGE_DIR" || true
    elif [ "$status" -eq 130 ]; then
        if [ -n "$STAGE_DIR" ]; then
            printf '\n==> Cancelled by user. The working state is kept for the next run.\n'
        else
            printf '\n==> Cancelled by user.\n'
        fi
    elif [ -n "$STAGE_DIR" ] && [ "$status" -ne 0 ]; then
        printf '\n==> The working state is kept so you can resume later.\n'
    fi
}

abort() {
    exit 130
}

trap cleanup EXIT
trap abort INT TERM

usage() {
    cat <<'EOF'
Usage:
  ./firmware-extract.sh
  ./firmware-extract.sh --source oneui --model SM-S938B --csc EUX --mode apps
  ./firmware-extract.sh --source coloros --model CPH2765 --region EU

Options:
  --source SOURCE    oneui (Samsung) or coloros (OPPO/realme/OnePlus)
  --model MODEL      Device model, for example SM-S938B or CPH2765
  --csc CSC          Samsung CSC, for example EUX
  --region REGION    Optional ColorOS firmware variant, for example EU
  --mode MODE        Extraction mode for One UI or ColorOS: apps or all
  --asgard-source P  Path to the local Asgard source checkout (One UI only)
  -V, --version      Show the tool version
  -h, --help         Show this help

With no options, the script first asks for One UI or ColorOS.
EOF
}

ASGARD_SOURCE="${FIRMWARE_SCRIPT_ASGARD_SOURCE:-}"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --source) SOURCE="${2:-}"; shift 2 ;;
        --model) MODEL="${2:-}"; shift 2 ;;
        --csc) CSC="${2:-}"; shift 2 ;;
        --region) REGION="${2:-}"; shift 2 ;;
        --mode) MODE="${2:-}"; shift 2 ;;
        --asgard-source) ASGARD_SOURCE="${2:-}"; shift 2 ;;
        -V|--version) printf 'Samsung Firmware Forge %s\n' "$VERSION"; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' is missing. Installation instructions are in README.md."
}

run_as_root() {
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        die "sudo is required for automatic installation. Run the script once as root or install sudo manually."
    fi
}

detect_package_manager() {
    [ -n "$PACKAGE_MANAGER" ] && return 0
    if command -v apt-get >/dev/null 2>&1; then
        PACKAGE_MANAGER="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PACKAGE_MANAGER="dnf"
    elif command -v pacman >/dev/null 2>&1; then
        PACKAGE_MANAGER="pacman"
    elif command -v zypper >/dev/null 2>&1; then
        PACKAGE_MANAGER="zypper"
    else
        die "Automatic dependency installation requires apt, dnf, pacman, or zypper. Install the missing tools manually and run the script again."
    fi
}

package_for() {
    local dependency="$1"
    case "$PACKAGE_MANAGER:$dependency" in
        apt:python) printf 'python3\n' ;;
        pacman:python) printf 'python\n' ;;
        dnf:python|zypper:python) printf 'python3\n' ;;
        apt:python-venv) printf 'python3-venv\n' ;;
        pacman:python-venv) printf 'python\n' ;;
        dnf:python-venv|zypper:python-venv) printf 'python3\n' ;;
        apt:go) printf 'golang-go\n' ;;
        dnf:go|zypper:go) printf 'go\n' ;;
        pacman:go) printf 'go\n' ;;
        apt:xz) printf 'xz-utils\n' ;;
        dnf:xz|pacman:xz|zypper:xz) printf 'xz\n' ;;
        apt:erofs) printf 'erofsfuse\n' ;;
        dnf:erofs|pacman:erofs|zypper:erofs) printf 'erofs-utils\n' ;;
        *) printf '%s\n' "$dependency" ;;
    esac
}

add_package_once() {
    local package="$1"
    local present
    for present in "${MISSING_PACKAGES[@]:-}"; do
        [ "$present" = "$package" ] && return 0
    done
    MISSING_PACKAGES+=("$package")
}

check_command_dependency() {
    local command_name="$1"
    local package="$2"
    command -v "$command_name" >/dev/null 2>&1 || add_package_once "$package"
}

install_missing_packages() {
    local dependency package existing
    local present
    local -a packages=()

    detect_package_manager
    for dependency in "$@"; do
        package="$(package_for "$dependency")"
        present=false
        for existing in "${packages[@]:-}"; do
            [ "$existing" = "$package" ] && present=true && break
        done
        $present || packages+=("$package")
    done

    info "Installing missing dependencies with $PACKAGE_MANAGER: ${packages[*]}"
    case "$PACKAGE_MANAGER" in
        apt)
            run_as_root apt-get update
            run_as_root apt-get install -y "${packages[@]}"
            ;;
        dnf)
            run_as_root dnf install -y "${packages[@]}"
            ;;
        pacman)
            run_as_root pacman -S --needed --noconfirm "${packages[@]}"
            ;;
        zypper)
            run_as_root zypper --non-interactive install --no-recommends "${packages[@]}"
            ;;
    esac
}

install_lpunpack() {
    detect_package_manager
    info "Installing Android tools required by all mode"
    case "$PACKAGE_MANAGER" in
        apt)
            run_as_root apt-get update
            run_as_root apt-get install -y android-sdk-platform-tools android-sdk-libsparse-utils || true
            ;;
        dnf)
            run_as_root dnf install -y android-tools || true
            ;;
        pacman)
            run_as_root pacman -S --needed --noconfirm android-tools || true
            ;;
        zypper)
            run_as_root zypper --non-interactive install android-tools || true
            ;;
    esac
    command -v lpunpack >/dev/null 2>&1 || die "lpunpack could not be installed automatically with $PACKAGE_MANAGER. This firmware contains super.img, so install Android Logical Partition Tools manually and run the script again."
}

ensure_lpunpack() {
    command -v lpunpack >/dev/null 2>&1 || install_lpunpack
}

ensure_dependencies() {
    local mode="$1"
    local verification_failed=false
    local package
    MISSING_PACKAGES=()

    check_command_dependency python3 python
    if ! python3 -m venv --help >/dev/null 2>&1; then
        add_package_once python-venv
    fi
    check_command_dependency tar tar
    check_command_dependency unzip unzip
    check_command_dependency lz4 lz4
    check_command_dependency sudo sudo
    check_command_dependency mount util-linux
    check_command_dependency umount util-linux
    check_command_dependency mountpoint util-linux
    check_command_dependency dd coreutils
    check_command_dependency od coreutils
    check_command_dependency tr coreutils
    check_command_dependency cp coreutils
    check_command_dependency mv coreutils
    check_command_dependency mkdir coreutils
    check_command_dependency rm coreutils
    check_command_dependency tee coreutils
    check_command_dependency awk gawk
    check_command_dependency find findutils
    check_command_dependency rsync rsync
    if ! command -v fuse.erofs >/dev/null 2>&1 && ! command -v erofsfuse >/dev/null 2>&1; then
        add_package_once erofs
    fi

    if [ "${#MISSING_PACKAGES[@]}" -gt 0 ]; then
        install_missing_packages "${MISSING_PACKAGES[@]}"
    else
        info "All required system tools are already installed"
    fi

    for package in python3 tar unzip lz4 sudo mount umount mountpoint dd od tr cp mv mkdir rm tee awk find rsync; do
        if ! command -v "$package" >/dev/null 2>&1; then
            printf '  - %s\n' "$package" >&2
            verification_failed=true
        fi
    done
    python3 -m venv --help >/dev/null 2>&1 || verification_failed=true
    if ! command -v fuse.erofs >/dev/null 2>&1 && ! command -v erofsfuse >/dev/null 2>&1; then
        printf '  - fuse.erofs or erofsfuse\n' >&2
        verification_failed=true
    fi
    if $verification_failed; then
        die "At least one dependency could not be installed. Check the package-manager output above."
    fi

}

ensure_coloros_dependencies() {
    local verification_failed=false

    MISSING_PACKAGES=()
    check_command_dependency python3 python
    if ! python3 -m venv --help >/dev/null 2>&1; then
        add_package_once python-venv
    fi
    check_command_dependency git git

    if [ "${#MISSING_PACKAGES[@]}" -gt 0 ]; then
        install_missing_packages "${MISSING_PACKAGES[@]}"
    else
        info "All required ColorOS downloader tools are already installed"
    fi

    command -v python3 >/dev/null 2>&1 || verification_failed=true
    python3 -m venv --help >/dev/null 2>&1 || verification_failed=true
    command -v git >/dev/null 2>&1 || verification_failed=true
    if $verification_failed; then
        die "The ColorOS downloader dependencies could not be installed. Check the package-manager output above."
    fi
}

ensure_coloros_extraction_dependencies() {
    local mode="$1"
    local verification_failed=false
    local command_name

    MISSING_PACKAGES=()
    check_command_dependency go go
    check_command_dependency xz xz
    check_command_dependency unzip unzip
    check_command_dependency sudo sudo
    check_command_dependency mount util-linux
    check_command_dependency umount util-linux
    check_command_dependency mountpoint util-linux
    check_command_dependency script util-linux
    check_command_dependency dd coreutils
    check_command_dependency od coreutils
    check_command_dependency tr coreutils
    check_command_dependency cp coreutils
    check_command_dependency mkdir coreutils
    check_command_dependency rm coreutils
    check_command_dependency find findutils
    check_command_dependency rsync rsync
    if ! command -v fuse.erofs >/dev/null 2>&1 && ! command -v erofsfuse >/dev/null 2>&1; then
        add_package_once erofs
    fi

    if [ "${#MISSING_PACKAGES[@]}" -gt 0 ]; then
        install_missing_packages "${MISSING_PACKAGES[@]}"
    else
        info "All required ColorOS extraction tools are already installed"
    fi

    for command_name in go xz unzip sudo mount umount mountpoint script dd od tr cp mkdir rm find rsync; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            printf '  - %s\n' "$command_name" >&2
            verification_failed=true
        fi
    done
    if ! command -v fuse.erofs >/dev/null 2>&1 && ! command -v erofsfuse >/dev/null 2>&1; then
        printf '  - fuse.erofs or erofsfuse\n' >&2
        verification_failed=true
    fi
    if $verification_failed; then
        die "At least one ColorOS extraction dependency could not be installed. Check the package-manager output above."
    fi

}

ensure_payload_dumper() {
    if [ ! -x "$PAYLOAD_DUMPER_BIN" ]; then
        info "Setting up the Android payload extractor"
        mkdir -p "$TOOLS_DIR"
        GOBIN="$TOOLS_DIR" go install "github.com/ssut/payload-dumper-go@$PAYLOAD_DUMPER_VERSION"
    fi
    "$PAYLOAD_DUMPER_BIN" -h >/dev/null
}

ensure_venv() {
    if [ ! -x "$VENV_DIR/bin/python" ]; then
        python3 -m venv "$VENV_DIR"
    fi
}

ensure_oppo_downloader() {
    if [ ! -x "$OPPO_OTA_BIN" ]; then
        info "Setting up the OPPO OTA Downloader"
        ensure_venv
        "$VENV_DIR/bin/python" -m pip install --upgrade pip
        "$VENV_DIR/bin/python" -m pip install "$OPPO_OTA_INSTALL_URL"
    fi
    "$OPPO_OTA_BIN" --version >/dev/null
}

run_oppo_download() {
    local command_line

    printf -v command_line '%q ' "$OPPO_OTA_BIN" "$@"
    if command -v script >/dev/null 2>&1; then
        script -q -e -c "$command_line" /dev/null
    else
        "$OPPO_OTA_BIN" "$@"
    fi
}

find_asgard_source() {
    local candidate
    for candidate in \
        "$ASGARD_SOURCE" \
        "$PROJECT_DIR/asgard" \
        "$PROJECT_DIR/../asgard" \
        "/home/$USER/asgard" \
        "/home/aaron_pc/asgard"; do
        [ -n "$candidate" ] || continue
        if [ -f "$candidate/pyproject.toml" ] && [ -f "$candidate/asgard/__main__.py" ]; then
            printf '%s\n' "$(cd "$candidate" && pwd)"
            return 0
        fi
    done
    return 1
}

ensure_asgard() {
    local source
    source="$(find_asgard_source)" || die "Asgard source not found. Place it next to this project as ../asgard or pass --asgard-source /path/to/asgard."

    if [ ! -x "$ASGARD_BIN" ]; then
        info "Setting up Asgard from $source"
        require_command python3
        ensure_venv
        "$VENV_DIR/bin/python" -m pip install --upgrade pip
        "$VENV_DIR/bin/python" -m pip install -e "$source" tqdm
    fi

    "$ASGARD_BIN" --help >/dev/null
    [ -f "$ASGARD_TQDM_RUNNER" ] || die "Asgard progress wrapper is missing: $ASGARD_TQDM_RUNNER"
    if ! "$VENV_DIR/bin/python" -c 'import tqdm' >/dev/null 2>&1; then
        info "Installing the MonsterROM-style progress display (tqdm)"
        "$VENV_DIR/bin/python" -m pip install tqdm
    fi
}

run_asgard() {
    local status
    if "$VENV_DIR/bin/python" "$ASGARD_TQDM_RUNNER" "$@" 2>"$ASGARD_ERROR_LOG"; then
        return 0
    else
        status="$?"
    fi
    [ "$status" -eq 130 ] && exit 130
    [ -s "$ASGARD_ERROR_LOG" ] && cat "$ASGARD_ERROR_LOG" >&2
    return "$status"
}

run_asgard_with_status() {
    local label="$1"
    local output_file status pid spinner='|/-\\' frame=0 elapsed=0
    shift
    output_file="$(mktemp)"

    "$VENV_DIR/bin/python" "$ASGARD_TQDM_RUNNER" "$@" >"$output_file" 2>"$ASGARD_ERROR_LOG" &
    pid="$!"
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r==> %s [%s] %02d:%02d' "$label" "${spinner:frame:1}" "$((elapsed / 60))" "$((elapsed % 60))" >&2
        sleep 1
        frame=$(( (frame + 1) % 4 ))
        elapsed=$(( elapsed + 1 ))
    done

    if wait "$pid"; then
        printf '\r\033[K==> %s completed\n' "$label" >&2
        cat "$output_file"
        rm -f "$output_file"
        return 0
    fi
    status="$?"
    printf '\r\033[K' >&2
    rm -f "$output_file"
    [ "$status" -eq 130 ] && exit 130
    return "$status"
}

prepare_stage() {
    local label="$1"
    local stage_key="$2"
    local stage="$STAGE_ROOT/$stage_key"
    local choice

    if [ -d "$stage" ] && [ -n "$(find "$stage" -mindepth 1 -print -quit)" ]; then
        printf '\nAn incomplete working state for %s was found.\n' "$label"
        printf '  1) Resume — reuse files that were already downloaded\n'
        printf '  2) Start over — discard the working state\n'
        printf '  3) Cancel\n'
        read -r -p "Choice [1]: " choice
        case "${choice:-1}" in
            1) info "Resuming the existing working state" ;;
            2)
                case "$stage" in
                    "$STAGE_ROOT"/*) rm -rf -- "$stage" ;;
                    *) die "Unsafe working-state path: $stage" ;;
                esac
                ;;
            3) info "Cancelled before starting"; exit 0 ;;
            *) die "Please choose 1, 2, or 3." ;;
        esac
    fi

    mkdir -p "$stage"
    STAGE_DIR="$stage"
    ASGARD_ERROR_LOG="$stage/asgard.stderr"
}

read_uppercase_input() {
    local prompt="$1"
    local character=""
    local value=""

    printf '%s' "$prompt"
    while :; do
        character=""
        IFS= read -r -s -n 1 character || true
        case "$character" in
            '') break ;;
            $'\177'|$'\b')
                if [ -n "$value" ]; then
                    value="${value%?}"
                    printf '\b \b'
                fi
                ;;
            *)
                character="${character^^}"
                value+="$character"
                printf '%s' "$character"
                ;;
        esac
    done
    printf '\n'
    UPPERCASE_INPUT="$value"
}

prompt_for_source() {
    local selection
    SOURCE="${SOURCE,,}"
    if [ -z "$SOURCE" ]; then
        printf 'Choose firmware source:\n'
        printf '  1) One UI — Samsung firmware via Asgard\n'
        printf '  2) ColorOS — OPPO, realme, and OnePlus Full OTA\n'
        read -r -p "Choice [1]: " selection
        case "${selection:-1}" in
            1) SOURCE="oneui" ;;
            2) SOURCE="coloros" ;;
            *) die "Please choose 1 or 2." ;;
        esac
    fi
    case "$SOURCE" in
        samsung|oneui) SOURCE="oneui" ;;
        coloros|oppo|realme|oneplus) SOURCE="coloros" ;;
        *) die "--source must be oneui or coloros." ;;
    esac
}

prompt_for_oneui_input() {
    if [ -z "$MODEL" ]; then
        read_uppercase_input "Samsung model number (for example, SM-S938B): "
        MODEL="$UPPERCASE_INPUT"
    fi
    if [ -z "$CSC" ]; then
        read_uppercase_input "CSC/region (for example, EUX): "
        CSC="$UPPERCASE_INPUT"
    fi

    MODEL="${MODEL^^}"
    CSC="${CSC^^}"
    [[ "$MODEL" =~ ^SM-[A-Z0-9]+$ ]] || die "Invalid model number: $MODEL"
    [[ "$CSC" =~ ^[A-Z0-9]{3}$ ]] || die "Invalid CSC: $CSC"
    printf 'Using model/CSC: %s / %s\n' "$MODEL" "$CSC"

    prompt_for_extraction_mode
}

prompt_for_extraction_mode() {
    local selection

    if [ -z "$MODE" ]; then
        printf '\nWhat should be extracted?\n'
        if [ "$SOURCE" = "coloros" ]; then
            printf '  1) All preinstalled apps: system plus ColorOS app partitions\n'
        else
            printf '  1) System apps only: /system/app and /system/priv-app\n'
        fi
        printf '  2) Everything: all available OS partitions\n'
        read -r -p "Choice [1]: " selection
        case "${selection:-1}" in
            1) MODE="apps" ;;
            2) MODE="all" ;;
            *) die "Please choose 1 or 2." ;;
        esac
    fi

    MODE="${MODE,,}"
    [[ "$MODE" == "apps" || "$MODE" == "all" ]] || die "--mode must be apps or all."
}

prompt_for_coloros_input() {
    if [ -z "$MODEL" ]; then
        read_uppercase_input "OPPO/realme/OnePlus model (for example, CPH2765): "
        MODEL="$UPPERCASE_INPUT"
    fi
    if [ -z "$REGION" ]; then
        read_uppercase_input "Firmware variant (optional, for example EU; Enter lists all): "
        REGION="$UPPERCASE_INPUT"
    fi

    MODEL="${MODEL^^}"
    REGION="${REGION^^}"
    [[ "$MODEL" =~ ^[A-Z0-9.-]+$ ]] || die "Invalid ColorOS model: $MODEL"
    [[ -z "$REGION" || "$REGION" =~ ^[A-Z0-9-]+$ ]] || die "Invalid ColorOS variant: $REGION"
    if [ -n "$REGION" ]; then
        printf 'Using ColorOS model/variant: %s / %s\n' "$MODEL" "$REGION"
    else
        printf 'Using ColorOS model: %s\n' "$MODEL"
    fi
    prompt_for_extraction_mode
}

discover_coloros_profile() {
    local discovery choice selected
    local -a discover_args=(discover --model "$MODEL" --json)

    [ -n "$REGION" ] && discover_args+=(--region "$REGION")
    discovery="$(mktemp)"
    if ! "$OPPO_OTA_BIN" "${discover_args[@]}" >"$discovery"; then
        rm -f "$discovery"
        die "The OPPO OTA Downloader could not find a ColorOS profile for $MODEL."
    fi

    "$VENV_DIR/bin/python" - "$discovery" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
number = 0
for profile in data.get("profiles", []):
    for update in profile.get("updates", []):
        if (
            "full" in str(update.get("method", "")).lower()
            and update.get("ota_version")
            and update.get("coloros_major")
        ):
            number += 1
            variant = profile.get("variant_region") or profile.get("query_region") or "unknown"
            print(
                f"  {number}) {variant} — ColorOS {update['coloros_major']} — "
                f"{update.get('version') or update['ota_version']}"
            )
if not number:
    raise SystemExit("No Full OTA profiles were found. Incremental and delta updates are not accepted.")
PY

    read -r -p "Full OTA profile: " choice
    [[ "${choice:-}" =~ ^[1-9][0-9]*$ ]] || {
        rm -f "$discovery"
        die "Enter the number of a Full OTA profile."
    }
    selected="$("$VENV_DIR/bin/python" - "$discovery" "$choice" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
wanted = int(sys.argv[2])
number = 0
for profile in data.get("profiles", []):
    for update in profile.get("updates", []):
        if (
            "full" in str(update.get("method", "")).lower()
            and update.get("ota_version")
            and update.get("coloros_major")
        ):
            number += 1
            if number == wanted:
                fields = (
                    profile.get("variant_region") or profile.get("query_region") or "unknown",
                    profile.get("query_region") or "GL",
                    update["ota_version"],
                    str(update["coloros_major"]),
                    profile.get("nv_id_hint") or "",
                    update.get("download_url") or "",
                    str(update.get("download_size") or ""),
                    update.get("md5") or "",
                    update.get("filename") or "",
                )
                print("\t".join(fields))
                raise SystemExit(0)
raise SystemExit("Selected Full OTA profile does not exist.")
PY
)" || {
        rm -f "$discovery"
        die "Selected Full OTA profile does not exist."
    }
    rm -f "$discovery"
    IFS=$'\t' read -r COLOROS_VARIANT COLOROS_QUERY_REGION COLOROS_OTA_VERSION COLOROS_MAJOR COLOROS_NV_ID COLOROS_DOWNLOAD_URL COLOROS_DOWNLOAD_SIZE COLOROS_DOWNLOAD_MD5 COLOROS_FILENAME <<< "$selected"
    [ -n "$COLOROS_OTA_VERSION" ] || die "The selected Full OTA profile has no OTA version."
}

verify_coloros_full_packet() {
    local query_file="$1"
    "$VENV_DIR/bin/python" - "$query_file" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
response = data.get("response", {})
if response.get("gka_required"):
    raise SystemExit("This Full OTA requires hardware attestation and cannot be downloaded by a desktop client.")
for index, packet in enumerate(response.get("packets", [])):
    packet_type = str(packet.get("packet_type", "")).lower()
    component_name = str(packet.get("component_name", "")).lower()
    if packet_type == "full" or (packet_type == "1" and component_name == "my_manifest"):
        print(index)
        raise SystemExit(0)
raise SystemExit("The official response contains no matching Full OTA packet. Delta and incremental packets are rejected.")
PY
}

current_coloros_gate_metadata() {
    "$VENV_DIR/bin/python" - "$MODEL" "$COLOROS_VARIANT" <<'PY'
import json
import sys
from urllib.parse import urlencode
from urllib.request import urlopen

model, region = sys.argv[1:3]
url = "https://roms.danielspringer.at/api/ota.php?" + urlencode(
    {"model": model, "region": region, "latest": "1"}
)
try:
    with urlopen(url, timeout=30) as response:
        releases = json.load(response).get("releases", [])
except Exception as error:
    raise SystemExit(f"Current Full OTA catalog request failed: {error}")

for release in releases:
    if (
        str(release.get("region", "")).upper() == region.upper()
        and release.get("source_url")
        and release.get("size")
        and release.get("md5")
        and release.get("version")
    ):
        print(
            "\t".join(
                str(release[field])
                for field in ("source_url", "size", "md5", "version")
            )
        )
        raise SystemExit(0)
raise SystemExit("Current Full OTA catalog has no usable release for this variant.")
PY
}

download_coloros_from_current_catalog() {
    local destination="$1"
    local metadata source_url size md5 version filename

    if ! metadata="$(current_coloros_gate_metadata)"; then
        return 1
    fi
    IFS=$'\t' read -r source_url size md5 version <<< "$metadata"
    [ -n "$source_url" ] && [ -n "$size" ] && [ -n "$md5" ] && [ -n "$version" ] || return 1
    version="${version//[^A-Za-z0-9._-]/_}"
    filename="${MODEL}_${COLOROS_VARIANT}_${version}_full_ota.zip"

    info "Downloading the current catalog Full OTA ($version) — progress follows"
    run_oppo_download fetch "$source_url" \
        --output "$destination/$filename" \
        --size "$size" \
        --md5 "$md5"
}

download_coloros_from_catalog() {
    local destination="$1"

    [ -n "$COLOROS_DOWNLOAD_URL" ] || die "The selected Full OTA profile has no download URL."
    [ -n "$COLOROS_DOWNLOAD_SIZE" ] || die "The selected Full OTA profile has no expected size."
    [ -n "$COLOROS_DOWNLOAD_MD5" ] || die "The selected Full OTA profile has no MD5 checksum."
    [ -n "$COLOROS_FILENAME" ] || die "The selected Full OTA profile has no filename."
    case "$COLOROS_FILENAME" in
        .*|*[!A-Za-z0-9._-]*) die "The selected Full OTA filename is unsafe." ;;
    esac

    info "Downloading the catalog-verified Full OTA — progress follows"
    run_oppo_download fetch "$COLOROS_DOWNLOAD_URL" \
        --output "$destination/$COLOROS_FILENAME" \
        --size "$COLOROS_DOWNLOAD_SIZE" \
        --md5 "$COLOROS_DOWNLOAD_MD5"
}

download_coloros_full_ota() {
    local stage="$1"
    local destination="$2"
    local query_file="$stage/oppo-ota-query.json"
    local component=""
    local downloaded=false
    local -a query_args=(
        query --no-adb --model "$MODEL" --ota-version "$COLOROS_OTA_VERSION"
        --coloros "$COLOROS_MAJOR" --region "$COLOROS_QUERY_REGION"
    )

    [ -n "$COLOROS_NV_ID" ] && query_args+=(--nv-id "$COLOROS_NV_ID")
    mkdir -p "$destination"
    if find "$destination" -maxdepth 1 -type f -name '*.zip' -print -quit | grep -q .; then
        info "Using the already downloaded ColorOS Full OTA"
        return 0
    fi

    info "Querying OPPO for the selected Full OTA"
    if "$OPPO_OTA_BIN" "${query_args[@]}" --save "$query_file"; then
        component="$(verify_coloros_full_packet "$query_file" || true)"
        if [ -n "$component" ]; then
            info "Downloading the verified Full OTA — progress follows"
            run_oppo_download "${query_args[@]}" --save "$query_file" --download \
                --component "$component" --output-dir "$destination"
            downloaded=true
        fi
    fi
    if ! $downloaded; then
        info "Official profile query was unavailable — refreshing the catalog Full OTA gate"
        download_coloros_from_current_catalog "$destination" || {
            info "Current catalog gate was unavailable — using the selected catalog Full OTA"
            download_coloros_from_catalog "$destination"
        }
    fi

    if [ -f "$query_file" ]; then
        cp -f "$query_file" "$destination/oppo-ota-query.json"
    fi
    printf 'model=%s\nvariant=%s\nquery_region=%s\nota_version=%s\ncoloros_major=%s\n' \
        "$MODEL" "$COLOROS_VARIANT" "$COLOROS_QUERY_REGION" "$COLOROS_OTA_VERSION" "$COLOROS_MAJOR" \
        > "$destination/coloros-profile.txt"
}

coloros_archive() {
    local destination="$1"

    find "$destination" -maxdepth 1 -type f \
        \( -iname '*.zip' -o -iname '*.ozip' -o -iname '*.ofp' -o -iname '*.ops' \) \
        -print -quit
}

require_coloros_payload_zip() {
    local archive="$1"

    if ! unzip -Z1 "$archive" 2>/dev/null | grep -Eq '(^|/)payload\.bin$'; then
        die "Unsupported ColorOS archive: $(basename "$archive"). Extraction requires an unencrypted Full OTA ZIP containing payload.bin; encrypted OZIP, OFP, and OPS packages are not decrypted automatically."
    fi
}

coloros_system_partition() {
    local archive="$1"
    local partition_list

    partition_list="$("$PAYLOAD_DUMPER_BIN" -m -l "$archive")"
    printf '%s\n' "$partition_list" | awk -F: '$1 == "system" || $1 == "system_a" || $1 == "system_b" { print $1; exit }'
}

coloros_app_partitions() {
    local archive="$1"
    local partition_list

    partition_list="$("$PAYLOAD_DUMPER_BIN" -m -l "$archive")"
    printf '%s\n' "$partition_list" | awk -F: '
        $1 == "system" || $1 == "system_a" || $1 == "system_b" ||
        $1 == "system_ext" || $1 == "system_ext_a" || $1 == "system_ext_b" ||
        $1 == "product" || $1 == "product_a" || $1 == "product_b" ||
        $1 == "vendor" || $1 == "vendor_a" || $1 == "vendor_b" ||
        $1 == "odm" || $1 == "odm_a" || $1 == "odm_b" ||
        $1 == "preload" || $1 ~ /^my_/ || $1 ~ /^oplus_/ {
            print $1
        }
    '
}

copy_apps_from_coloros_partition() {
    local image="$1"
    local partition="$2"
    local target="$3"
    local fs source relative destination

    [[ "$partition" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Unsafe ColorOS partition name: $partition"
    fs="$(filesystem_type "$image")"
    if [ "$fs" = "unknown" ]; then
        info "Skipping $partition; its filesystem cannot be mounted automatically"
        return 0
    fi
    mount_image "$image"
    info "Scanning $partition for preinstalled apps"
    while IFS= read -r -d '' source; do
        relative="${source#"$MOUNT_DIR"/}"
        destination="$target/apps/$partition/$relative"
        mkdir -p "$destination"
        info "Copying /$relative from $partition — progress follows"
        if $MOUNTED_AS_USER; then
            rsync -a --human-readable --info=progress2,name0 "$source/" "$destination/"
        else
            sudo rsync -a --human-readable --info=progress2,name0 "$source/" "$destination/"
            sudo chown -hR "$(id -u):$(id -g)" "$target/apps/$partition"
        fi
    done < <(find "$MOUNT_DIR" -type d \( -name app -o -name priv-app \) -print0)
    unmount_image
}

copy_coloros_filesystems() {
    local images="$1"
    local destination="$2"
    local stage="$3"
    local image name partition fs

    while IFS= read -r -d '' image; do
        name="$(basename "${image%.img}")"
        partition="$(normalise_slot_name "$name")"
        case "$partition" in
            system|vendor|product|system_ext|odm|vendor_dlkm|odm_dlkm|system_dlkm)
                [ -f "$stage/.coloros-${partition}-complete" ] && continue
                fs="$(filesystem_type "$image")"
                if [ "$fs" = "unknown" ]; then
                    info "Keeping raw $name.img; its filesystem cannot be mounted automatically"
                    continue
                fi
                copy_partition "$image" "$partition" "$destination/$partition"
                touch "$stage/.coloros-${partition}-complete"
                ;;
            *) ;;
        esac
    done < <(find "$images" -maxdepth 1 -type f -name '*.img' -print0)
}

extract_coloros_full_ota() {
    local stage="$1"
    local destination="$2"
    local archive images partition image super

    archive="$(coloros_archive "$destination")"
    [ -n "$archive" ] || die "No ColorOS OTA archive was found in $destination."
    require_coloros_payload_zip "$archive"
    images="$stage/images"
    mkdir -p "$images" "$destination/images"

    if [ "$MODE" = "apps" ]; then
        local -a app_partitions=()
        local app_partition_csv
        mapfile -t app_partitions < <(coloros_app_partitions "$archive")
        [ "${#app_partitions[@]}" -gt 0 ] || die "The ColorOS payload contains no app-capable OS partitions."
        if [ -f "$stage/.coloros-preinstalled-apps-complete" ] \
            && [ -d "$destination/apps" ] \
            && [ -d "$destination/system/system/app" ] \
            && [ -d "$destination/system/system/priv-app" ]; then
            info "Using the already extracted ColorOS preinstalled apps"
            return 0
        fi
        app_partition_csv="$(IFS=,; printf '%s' "${app_partitions[*]}")"
        if [ ! -f "$stage/.coloros-app-images-complete" ]; then
            info "Extracting all app-capable ColorOS partitions — progress follows"
            "$PAYLOAD_DUMPER_BIN" -p "$app_partition_csv" -o "$images" "$archive"
            touch "$stage/.coloros-app-images-complete"
        else
            info "Using the already extracted ColorOS app partitions"
        fi
        for partition in "${app_partitions[@]}"; do
            image="$images/$partition.img"
            [ -f "$image" ] || die "The payload extractor did not produce $partition.img."
            [ -f "$stage/.coloros-${partition}-apps-complete" ] && continue
            copy_apps_from_coloros_partition "$image" "$partition" "$destination"
            touch "$stage/.coloros-${partition}-apps-complete"
        done
        partition="$(coloros_system_partition "$archive")"
        [ -n "$partition" ] || die "The ColorOS payload does not contain a system partition."
        image="$images/$partition.img"
        if [ ! -f "$stage/.coloros-system-layout-complete" ]; then
            copy_apps_from_system "$image" "$destination"
            touch "$stage/.coloros-system-layout-complete"
        fi
        touch "$stage/.coloros-preinstalled-apps-complete"
        return 0
    fi

    if [ ! -f "$stage/.coloros-images-complete" ]; then
        info "Extracting all partitions from the Full OTA — progress follows"
        "$PAYLOAD_DUMPER_BIN" -o "$images" "$archive"
        touch "$stage/.coloros-images-complete"
    else
        info "Using the already extracted ColorOS partition images"
    fi
    super="$(find "$images" -maxdepth 1 -type f -name 'super.img' -print -quit)"
    if [ -n "$super" ] && [ ! -f "$stage/.coloros-super-complete" ]; then
        info "Splitting super.img into logical partitions"
        ensure_lpunpack
        lpunpack "$super" "$images"
        touch "$stage/.coloros-super-complete"
    fi
    find "$images" -maxdepth 1 -type f -name '*.img' -exec cp -a {} "$destination/images/" \;
    copy_coloros_filesystems "$images" "$destination" "$stage"
    touch "$stage/.coloros-all-complete"
}

filesystem_type() {
    local image="$1"
    local erofs ext4 f2fs
    erofs="$(dd if="$image" bs=1 skip=1024 count=4 status=none | od -An -tx1 | tr -d ' \n')"
    ext4="$(dd if="$image" bs=1 skip=1080 count=2 status=none | od -An -tx1 | tr -d ' \n')"
    f2fs="$(dd if="$image" bs=1 skip=1024 count=4 status=none | od -An -tx1 | tr -d ' \n')"
    case "$erofs" in
        # od returns the little-endian byte sequence stored on disk, rather
        # than the numeric superblock magic value.
        e2e1f5e0) printf 'erofs\n' ;;
        *)
            case "$ext4" in
                53ef) printf 'ext4\n' ;;
                *)
                    case "$f2fs" in
                        1020f5f2) printf 'f2fs\n' ;;
                        *) printf 'unknown\n' ;;
                    esac
                    ;;
            esac
            ;;
    esac
}

mount_image() {
    local image="$1"
    local fs
    fs="$(filesystem_type "$image")"
    MOUNT_DIR="$(mktemp -d)"
    MOUNTED_AS_USER=false
    case "$fs" in
        erofs)
            # FUSE mounts are readable only by the user who created them by
            # default. Mounting with sudo would hide the content from the
            # subsequent directory checks run as the regular user.
            if command -v fuse.erofs >/dev/null 2>&1; then
                env "PATH=$PATH" fuse.erofs "$image" "$MOUNT_DIR"
            elif command -v erofsfuse >/dev/null 2>&1; then
                env "PATH=$PATH" erofsfuse "$image" "$MOUNT_DIR"
            else
                die "EROFS requires fuse.erofs or erofsfuse."
            fi
            MOUNTED_AS_USER=true
            ;;
        ext4|f2fs)
            sudo mount -o ro "$image" "$MOUNT_DIR"
            ;;
        *) die "Unknown filesystem in $(basename "$image")" ;;
    esac
    MOUNTED=true
}

unmount_image() {
    if $MOUNTED; then
        if $MOUNTED_AS_USER && command -v fusermount3 >/dev/null 2>&1; then
            fusermount3 -u "$MOUNT_DIR"
        else
            sudo umount "$MOUNT_DIR"
        fi
        MOUNTED=false
        MOUNTED_AS_USER=false
    fi
    rmdir "$MOUNT_DIR"
    MOUNT_DIR=""
}

copy_partition() {
    local image="$1"
    local partition="$2"
    local destination="$3"
    mount_image "$image"
    mkdir -p "$destination"
    info "Copying /$partition — progress follows"
    if $MOUNTED_AS_USER; then
        rsync -a --human-readable --info=progress2,name0 "$MOUNT_DIR/" "$destination/"
    else
        sudo rsync -a --human-readable --info=progress2,name0 "$MOUNT_DIR/" "$destination/"
        sudo chown -hR "$(id -u):$(id -g)" "$destination"
    fi
    unmount_image
    info "Extracted: /$partition"
}

copy_apps_from_system() {
    local image="$1"
    local target="$2"
    mount_image "$image"

    # Current devices use /system (system-as-root). Older images keep app and
    # priv-app directly in the partition root.
    local source_root="$MOUNT_DIR/system"
    [ -d "$source_root" ] || source_root="$MOUNT_DIR"
    [ -d "$source_root/app" ] || die "No /system/app structure found in $(basename "$image")."
    [ -d "$source_root/priv-app" ] || die "No /system/priv-app structure found in $(basename "$image")."

    mkdir -p "$target/system/system"
    info "Copying /system/app and /system/priv-app — progress follows"
    if $MOUNTED_AS_USER; then
        rsync -a --human-readable --info=progress2,name0 "$source_root/app/" "$target/system/system/app/"
        rsync -a --human-readable --info=progress2,name0 "$source_root/priv-app/" "$target/system/system/priv-app/"
    else
        sudo rsync -a --human-readable --info=progress2,name0 "$source_root/app/" "$target/system/system/app/"
        sudo rsync -a --human-readable --info=progress2,name0 "$source_root/priv-app/" "$target/system/system/priv-app/"
        sudo chown -hR "$(id -u):$(id -g)" "$target/system"
    fi
    unmount_image
}

download_system_partition() {
    local stage="$1"
    local listing partition
    if [ -s "$stage/system_partition.txt" ]; then
        partition="$(cat "$stage/system_partition.txt")"
        info "Using saved partition choice: $partition"
    else
        info "Finding the system partition with Asgard"
        if ! listing="$(run_asgard_with_status "Checking the AP archive for a system image" download "$MODEL" "$CSC" --archive AP --list-partitions --json)"; then
            # Older firmware has no dynamic super partition. Asgard's error log
            # confirms the direct system image before we use the direct path.
            case "$(cat "$ASGARD_ERROR_LOG")" in
                *"does not contain super.img"*)
                    SYSTEM_IMAGE="$stage/images/system.img"
                    if [ -f "$SYSTEM_IMAGE" ]; then
                        info "Using the already downloaded system.img"
                        return 0
                    fi
                    info "No super.img found — downloading system.img.lz4 directly"
                    run_asgard download "$MODEL" "$CSC" --archive AP --file system.img.lz4 --resume -o "$stage/images"
                    [ -f "$SYSTEM_IMAGE" ] || die "Asgard did not produce system.img."
                    return 0
                    ;;
                *)
                    cat "$ASGARD_ERROR_LOG" >&2
                    die "Asgard could not identify the system partition."
                    ;;
            esac
        fi
        partition="$("$VENV_DIR/bin/python" - "$listing" <<'PY'
import json
import sys

for candidate in ("system_a", "system", "system_b"):
    if any(item["name"] == candidate for item in json.loads(sys.argv[1])):
        print(candidate)
        break
PY
)"
        [ -n "$partition" ] || die "The firmware does not contain a system partition."
        printf '%s\n' "$partition" > "$stage/system_partition.txt"
    fi
    [ -n "$partition" ] || die "The firmware does not contain a system partition."
    SYSTEM_IMAGE="$stage/images/${partition}.img"
    if [ -f "$SYSTEM_IMAGE" ]; then
        info "Using the already downloaded $partition.img"
        return 0
    fi
    info "Found: $partition — starting the app download"
    run_asgard download "$MODEL" "$CSC" --archive AP --partition "$partition" --resume -o "$stage/images"
    SYSTEM_IMAGE="$(find "$stage/images" -maxdepth 1 -type f -name "${partition}.img" -print -quit)"
}

normalise_slot_name() {
    local name="$1"
    name="${name%_a}"
    name="${name%_b}"
    printf '%s\n' "$name"
}

extract_all() {
    local destination="$1"
    local stage="$2"
    local zip ap_dir super image partition name

    mkdir -p "$stage/download" "$stage/ap" "$stage/images" "$destination/images"
    zip="$(find "$stage/download" -maxdepth 1 -type f -name '*.zip' -print -quit)"
    if [ -z "$zip" ]; then
        info "Downloading and decrypting the complete firmware ZIP with Asgard"
        run_asgard download "$MODEL" "$CSC" --decrypt --resume -o "$stage/download"
        zip="$(find "$stage/download" -maxdepth 1 -type f -name '*.zip' -print -quit)"
    else
        info "Using the already downloaded and decrypted firmware ZIP"
    fi
    [ -n "$zip" ] || die "Asgard did not produce a decrypted ZIP file."

    info "Unpacking the AP archive"
    unzip -q -o "$zip" -d "$stage/ap"
    ap_dir="$stage/ap/unpacked-ap"
    mkdir -p "$ap_dir"
    local ap_tar
    ap_tar="$(find "$stage/ap" -maxdepth 1 -type f -name 'AP_*.tar.md5' -print -quit)"
    [ -n "$ap_tar" ] || die "AP_*.tar.md5 was not found in the firmware ZIP."
    tar -xf "$ap_tar" -C "$ap_dir"

    while IFS= read -r -d '' image; do
        lz4 -d -f "$image" "${image%.lz4}"
    done < <(find "$ap_dir" -type f -name '*.img.lz4' -print0)
    while IFS= read -r -d '' image; do
        mv -f "$image" "${image%.ext4}"
    done < <(find "$ap_dir" -type f -name '*.img.ext4' -print0)

    super="$(find "$ap_dir" -maxdepth 1 -type f -name 'super.img' -print -quit)"
    if [ -n "$super" ]; then
        info "Splitting super.img into logical partitions"
        ensure_lpunpack
        lpunpack "$super" "$stage/images"
    else
        find "$ap_dir" -maxdepth 1 -type f -name '*.img' -exec cp -a {} "$stage/images/" \;
    fi

    find "$ap_dir" -maxdepth 1 -type f -name '*.img' -exec cp -a {} "$destination/images/" \;
    find "$stage/images" -maxdepth 1 -type f -name '*.img' -exec cp -a {} "$destination/images/" \;
    while IFS= read -r -d '' image; do
        name="$(basename "${image%.img}")"
        partition="$(normalise_slot_name "$name")"
        case "$partition" in
            system|vendor|product|system_ext|odm|vendor_dlkm|odm_dlkm|system_dlkm)
                [ -f "$stage/.${partition}-complete" ] && continue
                copy_partition "$image" "$partition" "$destination/$partition"
                touch "$stage/.${partition}-complete"
                ;;
            *) ;;
        esac
    done < <(find "$stage/images" -maxdepth 1 -type f -name '*.img' -print0)
}

main() {
    local destination stage system_image
    prompt_for_source

    if [ "$SOURCE" = "oneui" ]; then
        prompt_for_oneui_input
        ensure_dependencies "$MODE"
        ensure_asgard

        destination="$OUTPUT_ROOT/${MODEL}_${CSC}"
        prepare_stage "$MODEL / $CSC" "${MODEL}_${CSC}"
        stage="$STAGE_DIR"

        info "One UI firmware: $MODEL / $CSC"
        if [ "$MODE" = "apps" ]; then
            mkdir -p "$stage/images" "$destination"
            download_system_partition "$stage"
            system_image="$SYSTEM_IMAGE"
            [ -f "$system_image" ] || die "Asgard did not provide a system image."
            copy_apps_from_system "$system_image" "$destination"
            touch "$stage/.apps-complete"
            info "Done. APKs are available at: $destination/system/system/app and $destination/system/system/priv-app"
        else
            extract_all "$destination" "$stage"
            info "Done. Complete filesystems and raw images are available at: $destination"
        fi
    else
        prompt_for_coloros_input
        ensure_coloros_dependencies
        ensure_coloros_extraction_dependencies "$MODE"
        ensure_oppo_downloader
        ensure_payload_dumper
        discover_coloros_profile

        destination="$OUTPUT_ROOT/coloros/${MODEL}_${COLOROS_VARIANT}"
        prepare_stage "ColorOS $MODEL / $COLOROS_VARIANT" "coloros_${MODEL}_${COLOROS_VARIANT}"
        stage="$STAGE_DIR"
        info "ColorOS Full OTA: $MODEL / $COLOROS_VARIANT"
        download_coloros_full_ota "$stage" "$destination"
        extract_coloros_full_ota "$stage" "$destination"
        if [ "$MODE" = "apps" ]; then
            info "Done. System APKs are available at: $destination/system/system/app and $destination/system/system/priv-app"
            info "All ColorOS preinstalled-app directories are available at: $destination/apps"
        else
            info "Done. Complete filesystems and raw images are available at: $destination"
        fi
    fi
    FINISHED=true
}

main
