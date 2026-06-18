#!/usr/bin/env bash
#
# Chrome/Chromium Version Manager
# Downloads and manages isolated Chrome/Chromium installations by version.
#
# Data sources:
#   - Chrome for Testing (CfT): v113+ official Chrome builds
#   - Chromium googlesource tags: ALL Chrome versions from v10+
#   - chromium-browser-snapshots (legacy): pre-v113 Chromium builds
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CHROME_BASE="$SCRIPT_DIR/chrome"
CHROMIUM_BASE="$SCRIPT_DIR/chromium"
CACHE_DIR="$SCRIPT_DIR/.cache"
CACHE_TTL=3600
TAGS_TTL=86400

CFT_BASE="https://googlechromelabs.github.io/chrome-for-testing"
CFT_KNOWN_GOOD="$CFT_BASE/known-good-versions-with-downloads.json"
CFT_LATEST="$CFT_BASE/last-known-good-versions-with-downloads.json"
CHROMIUM_LEGACY_BASE="https://commondatastorage.googleapis.com/chromium-browser-snapshots"
GOOGLESOURCE_TAGS="https://chromium.googlesource.com/chromium/src/+refs/tags?format=JSON"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { error "$*"; exit 1; }

usage() {
    cat <<'USAGE'
Usage: install-chrome.sh <command> [options]

Commands:
  list local [chrome|chromium]      List locally installed versions
  list chrome [N]                 List latest N Chrome for Testing versions (v113+, default: 30)
  list tags [N]                   List latest N Chrome tags from googlesource (v10+, default: 30)
  list chromium [N]               List latest N Chromium revisions (default: 30)
  search chrome <ver> [N]         Search Chrome by version (e.g. "80", "80.0.3987")
  search chromium <rev> [N]       Search Chromium revisions matching pattern
  download chrome <version>       Download specific Chrome version (auto-selects source)
  download chromium <revision>    Download specific Chromium revision
  remove chrome <version>         Delete a downloaded Chrome version
  remove chromium <revision>      Delete a downloaded Chromium revision
  run chrome <version> [args...]  Run Chrome with isolated user-data dir
  run chromium <revision> [args..]Run Chromium with isolated user-data dir
  latest chrome                   Download latest stable Chrome (via CfT)
  latest chromium                 Download latest stable Chromium
  help                            Show this help message

Examples:
  install-chrome.sh download chrome 80          # auto-resolve to latest in major 80
  install-chrome.sh download chrome v80.0.3987  # v prefix auto-stripped
  install-chrome.sh search chrome 80.0.3987     # semantic: major=80, build=3987
  install-chrome.sh run chrome 130.0.6723.69 --headless
USAGE
    exit 0
}

check_deps() {
    local missing=()
    for cmd in curl unzip jq; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [ ${#missing[@]} -eq 0 ] || die "Missing dependencies: ${missing[*]} (install with: apt install ${missing[*]})"
}

# --- Cache helpers ---

cached_fetch() {
    local url="$1" cache_name="$2" ttl="${3:-$CACHE_TTL}"
    local cache_file="$CACHE_DIR/$cache_name"
    mkdir -p "$CACHE_DIR"
    if [ -f "$cache_file" ] && [ $(( $(date +%s) - $(stat -c %Y "$cache_file") )) -lt "$ttl" ]; then
        cat "$cache_file"
    else
        info "Fetching $url ..."
        curl -sSfL "$url" -o "$cache_file" || die "Failed to fetch $url"
        cat "$cache_file"
    fi
}

# Fetch Chrome version tags from googlesource (cached 24h)
fetch_tags() {
    local cache_file="$CACHE_DIR/chrome-tags.json"
    mkdir -p "$CACHE_DIR"
    if [ -f "$cache_file" ] && [ $(( $(date +%s) - $(stat -c %Y "$cache_file") )) -lt $TAGS_TTL ]; then
        return 0
    fi
    info "Fetching all Chrome version tags from googlesource (this may take ~30s) ..."
    curl -sSfL "$GOOGLESOURCE_TAGS" -o "$cache_file.tmp" || die "Failed to fetch tags"
    # Strip leading ")]}'\n" JSON hijacking prefix
    tail -c +6 "$cache_file.tmp" > "$cache_file" && rm -f "$cache_file.tmp"
    local count; count=$(jq 'keys | length' "$cache_file")
    info "Cached $count version tags"
}

list_local() {
    local type="${1:-chrome}"
    local base
    case "$type" in
        chrome)   base="$CHROME_BASE" ;;
        chromium) base="$CHROMIUM_BASE" ;;
        all)      _list_all_local; return ;;
        *) die "Usage: list local chrome|chromium|all" ;;
    esac

    if [ ! -d "$base" ] || [ -z "$(ls -A "$base" 2>/dev/null)" ]; then
        warn "No local $type versions installed"
        return 0
    fi

    echo -e "\n${CYAN}Local $type installations:${NC}"
    echo -e "${CYAN}------------------------------------------${NC}"
    local i=1
    for dir in "$base"/*/; do
        [ -d "$dir" ] || continue
        local name; name=$(basename "$dir")
        local size; size=$(du -sh "$dir" 2>/dev/null | cut -f1)
        printf "  %d. %s  (%s)\n" "$i" "$name" "$size"
        i=$((i + 1))
    done
}

_list_all_local() {
    local found=0
    for type in chrome chromium; do
        local base
        case "$type" in
            chrome)   base="$CHROME_BASE" ;;
            chromium) base="$CHROMIUM_BASE" ;;
        esac
        if [ -d "$base" ] && [ -n "$(ls -A "$base" 2>/dev/null)" ]; then
            [ "$found" -eq 0 ] || echo
            echo -e "\n${CYAN}Local $type installations:${NC}"
            echo -e "${CYAN}------------------------------------------${NC}"
            local i=1
            for dir in "$base"/*/; do
                [ -d "$dir" ] || continue
                local name; name=$(basename "$dir")
                local size; size=$(du -sh "$dir" 2>/dev/null | cut -f1)
                printf "  %d. %s  (%s)\n" "$i" "$name" "$size"
                i=$((i + 1))
                found=1
            done
        fi
    done
    [ "$found" -eq 1 ] || warn "No local installations found"
}

list_tags() {
    local count="${1:-30}"
    fetch_tags
    local cache_file="$CACHE_DIR/chrome-tags.json"
    local total; total=$(jq 'keys | length' "$cache_file")
    echo -e "\n${CYAN}All Chrome version tags (latest $count of $total total):${NC}"
    echo -e "${CYAN}--------------------------------------------------------${NC}"
    jq -r 'keys | .[]' "$cache_file" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -n "$count" | tac | nl -w2 -s'. '
}

# --- Semantic version search (using googlesource tags) ---

# Build jq filter from semantic version query like "80" or "80.0.3987"
_semver_jq_filter() {
    local q="$1"
    IFS='.' read -ra parts <<< "$q"
    local conditions=()
    for i in "${!parts[@]}"; do
        [ -n "${parts[$i]}" ] || continue
        conditions+=("(.[$i] == \"${parts[$i]}\")")
    done
    local cond_str
    cond_str=$(printf "%s and " "${conditions[@]}" | sed 's/ and $//')
    echo 'keys | map(split(".")) | map(select('"$cond_str"') | join("."))'
}

_strip_v() {
    local ver="$1"
    ver="${ver#v}"
    ver="${ver#V}"
    echo "$ver"
}

_resolve_version() {
    local ver; ver=$(_strip_v "$1")
    local dots; dots=$(tr -dc '.' <<< "$ver" | wc -c)
    if [ "$dots" -ge 3 ]; then
        echo "$ver"
        return
    fi
    fetch_tags >&2
    local cache_file="$CACHE_DIR/chrome-tags.json"
    local jq_filter; jq_filter=$(_semver_jq_filter "$ver")
    jq -r "$jq_filter[]" "$cache_file" \
        | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n \
        | tail -n 1
}

search_chrome() {
    local query; query=$(_strip_v "$1")
    local count="${2:-10}"
    [ -n "$query" ] || die "Usage: search chrome <version> [N]"
    fetch_tags
    local cache_file="$CACHE_DIR/chrome-tags.json"
    local jq_filter; jq_filter=$(_semver_jq_filter "$query")
    local total; total=$(jq "$jq_filter | length" "$cache_file")
    echo -e "\n${CYAN}Chrome tags matching '$query' (latest $count of $total):${NC}"
    echo -e "${CYAN}------------------------------------------------------${NC}"
    jq -r "$jq_filter[]" "$cache_file" \
        | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n \
        | tail -n "$count" | tac | nl -w2 -s'. '
}

# --- CfT listing (v113+) ---

list_chrome() {
    local count="${1:-30}"
    info "Fetching Chrome for Testing versions ..."
    local data; data=$(cached_fetch "$CFT_KNOWN_GOOD" "cft-versions.json")
    local total; total=$(echo "$data" | jq '.versions | length')
    echo -e "\n${CYAN}Chrome for Testing versions (latest $count of $total):${NC}"
    echo -e "${CYAN}----------------------------------------------------${NC}"
    echo "$data" | jq -r '.versions[].version' | tail -n "$count" | tac | nl -w2 -s'. '
}

list_chromium() {
    local count="${1:-30}"
    info "Fetching Chromium revisions (via Chrome for Testing data) ..."
    local data; data=$(cached_fetch "$CFT_KNOWN_GOOD" "cft-versions.json")
    echo -e "\n${CYAN}Chromium revisions (latest $count):${NC}"
    echo -e "${CYAN}-----------------------------------${NC}"
    echo "$data" | jq -r '.versions[] | "v\(.version)  →  revision \(.revision)"' | tail -n "$count" | tac | nl -w2 -s'. '
}

search_chromium() {
    local query; query=$(_strip_v "$1")
    local count="${2:-10}"
    [ -n "$query" ] || die "Usage: search chromium <version> [N]"
    fetch_tags
    local cache_file="$CACHE_DIR/chrome-tags.json"
    local jq_filter; jq_filter=$(_semver_jq_filter "$query")
    local total; total=$(jq "$jq_filter | length" "$cache_file")

    echo -e "\n${CYAN}Chromium revisions matching '$query' (latest $count of $total):${NC}"
    echo -e "${CYAN}---------------------------------------------------------------${NC}"

    # Get matching versions sorted newest-first
    local versions=()
    while IFS= read -r ver; do
        versions+=("$ver")
    done < <(jq -r "$jq_filter[]" "$cache_file" \
        | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n \
        | tail -n "$count" | tac)

    # Pre-build revision lookup from CfT data (v113+)
    declare -A rev_map
    local cft_data
    cft_data=$(cached_fetch "$CFT_KNOWN_GOOD" "cft-versions.json" 2>/dev/null) || true
    if [ -n "$cft_data" ]; then
        while IFS='=' read -r ver rev; do
            rev_map["$ver"]="$rev"
        done < <(echo "$cft_data" | jq -r '.versions[] | "\(.version)=\(.revision)"' 2>/dev/null || true)
    fi

    # Output with revision info
    for ver in "${versions[@]}"; do
        local rev="${rev_map[$ver]:-}"
        if [ -n "$rev" ]; then
            printf "v%s  →  revision %s\n" "$ver" "$rev"
        else
            printf "v%s  →  revision ?\n" "$ver"
        fi
    done | nl -w2 -s'. '
}

# --- Snapshot position resolution (for legacy download) ---

# Resolve a Chrome version string to a chromium-browser-snapshots position number.
# Uses googlesource API: tag commit -> parent commit -> Cr-Branched-From position.
_resolve_commit_position() {
    local version="$1"
    info "Resolving commit position for Chrome $version ..."

    # Fetch tag commit info
    local tag_url="https://chromium.googlesource.com/chromium/src/+/refs/tags/$version?format=JSON"
    local tag_data
    tag_data=$(curl -sSfL --retry 3 --retry-delay 2 "$tag_url" 2>/dev/null) || die "Version '$version' not found in googlesource tags"

    tag_data=$(echo "$tag_data" | tail -c +6)  # strip ")]}'\n"

    # Get parent commit hash
    local parent
    parent=$(echo "$tag_data" | jq -r '.parents[0] // empty')
    [ -n "$parent" ] || die "No parent commit found for tag $version"

    # Fetch parent commit to get Cr-Branched-From
    local parent_url="https://chromium.googlesource.com/chromium/src/+/$parent?format=JSON"
    local parent_data
    parent_data=$(curl -sSfL --retry 3 --retry-delay 2 "$parent_url" 2>/dev/null) || die "Failed to fetch parent commit $parent"
    parent_data=$(echo "$parent_data" | tail -c +6)

    local message
    message=$(echo "$parent_data" | jq -r '.message // empty')

    # Extract Cr-Branched-From position: "refs/heads/main@{#930000}" or "refs/heads/master@{#722274}"
    local position
    position=$(echo "$message" | grep -oP 'refs/heads/(main|master)@\{#\K[0-9]+' | head -1)

    if [ -z "$position" ]; then
        # Fallback: try Cr-Commit-Position on main/master branch (not branch-heads)
        position=$(echo "$message" | grep -oP 'Cr-Commit-Position: refs/heads/(main|master)@\{#\K[0-9]+' | head -1)
    fi

    if [ -z "$position" ]; then
        # Last resort: any Cr-Commit-Position numeric value
        position=$(echo "$message" | grep -oP 'Cr-Commit-Position:.*?@\{#\K[0-9]+' | head -1)
    fi

    [ -n "$position" ] || die "Could not determine commit position for Chrome $version"
    info "Commit position: $position"
    echo "$position"
}

# Find nearest position that has an actual build, searching outward from base
_find_nearest_build() {
    local base="$1" max_search="${2:-200}"
    local code

    _check_build() {
        curl -sI --retry 2 --retry-delay 1 --connect-timeout 5 \
            -o /dev/null -w "%{http_code}" "$1" 2>/dev/null
    }

    code=$(_check_build "$CHROMIUM_LEGACY_BASE/Linux_x64/$base/chrome-linux.zip")
    if [ "$code" = "200" ]; then echo "$base"; return 0; fi

    info "Searching for nearest build around position $base ..." >&2
    for offset in $(seq 1 "$max_search"); do
        [ $((offset % 10)) -eq 0 ] && printf "  searched ±%d\r" "$offset" >&2
        code=$(_check_build "$CHROMIUM_LEGACY_BASE/Linux_x64/$((base - offset))/chrome-linux.zip")
        if [ "$code" = "200" ]; then echo "$((base - offset))"; return 0; fi
        code=$(_check_build "$CHROMIUM_LEGACY_BASE/Linux_x64/$((base + offset))/chrome-linux.zip")
        if [ "$code" = "200" ]; then echo "$((base + offset))"; return 0; fi
    done
    printf "  \n" >&2
    return 1
}

# --- Download / install ---

# Extract a chrome-linux.zip from chromium-browser-snapshots into dest
_extract_legacy_build() {
    local position="$1" dest="$2"
    local url="$CHROMIUM_LEGACY_BASE/Linux_x64/$position/chrome-linux.zip"

    mkdir -p "$dest"
    info "Download URL: $url"
    curl -#fL --retry 3 --retry-delay 5 --connect-timeout 15 \
        "$url" -o "$dest/chrome.zip" || die "Download failed"

    info "Extracting ..."
    unzip -q "$dest/chrome.zip" -d "$dest" && rm -f "$dest/chrome.zip"

    local extracted
    extracted=$(find "$dest" -maxdepth 1 -type d -name 'chrome-*' | head -1)
    [ -n "$extracted" ] && mv "$extracted" "$dest/chrome"

    mkdir -p "$dest/user-data"
    chmod +x "$dest/chrome/chrome" 2>/dev/null || true

    local size; size=$(du -sh "$dest/chrome" 2>/dev/null | cut -f1)
    info "Chrome installed at $dest/chrome (${size:-?}, commit pos: $position)"
}

install_chrome() {
    local version
    version=$(_resolve_version "$1")
    [ -n "$version" ] || die "Version '$1' not found"
    local dest="$CHROME_BASE/$version"
    info "Target version: $version"
    [ ! -d "$dest/chrome" ] || { warn "Chrome $version already exists at $dest"; return 0; }

    # Try CfT first, fallback to legacy snapshots
    info "Trying Chrome for Testing ..."
    local cft_url
    cft_url=$(cached_fetch "$CFT_KNOWN_GOOD" "cft-versions.json" 2>/dev/null \
        | jq -r --arg v "$version" '
            .versions[] | select(.version == $v) |
            .downloads.chrome[] | select(.platform == "linux64") | .url
        ' 2>/dev/null) || true

    if [ -n "$cft_url" ]; then
        mkdir -p "$dest"
        info "Download URL: $cft_url"
        curl -#fL --retry 3 --retry-delay 5 --connect-timeout 15 \
            "$cft_url" -o "$dest/chrome.zip" || die "Download failed"
        info "Extracting ..."
        unzip -q "$dest/chrome.zip" -d "$dest" && rm -f "$dest/chrome.zip"
        local extracted
        extracted=$(find "$dest" -maxdepth 1 -type d -name 'chrome-*' | head -1)
        [ -n "$extracted" ] && mv "$extracted" "$dest/chrome"
    else
        info "Not in CfT, trying chromium-browser-snapshots ..."
        local position
        position=$(_resolve_commit_position "$version") || die "Failed to resolve commit position for $version"
        info "Base commit position: $position"
        local nearest
        nearest=$(_find_nearest_build "$position") || die "No build found near position $position in snapshots bucket"
        info "Found build at position $nearest"
        _extract_legacy_build "$nearest" "$dest"
        echo "$nearest" > "$dest/.position"
    fi

    mkdir -p "$dest/user-data"
    chmod +x "$dest/chrome/chrome" 2>/dev/null || true

    local size; size=$(du -sh "$dest/chrome" 2>/dev/null | cut -f1)
    info "Chrome $version installed at $dest/chrome (${size:-?})"
}

install_chromium() {
    local input="$1"
    [ -n "$input" ] || die "Revision required"

    # Resolve Chrome version to revision number
    local revision="$input"
    if echo "$input" | grep -q '\.' || [ "${#input}" -le 5 ] 2>/dev/null; then
        local resolved
        resolved=$(_resolve_version "$input" 2>/dev/null) || true
        if [ -n "$resolved" ]; then
            local pos
            pos=$(_resolve_commit_position "$resolved" 2>/dev/null) || true
            if [ -n "$pos" ]; then
                local nearest
                nearest=$(_find_nearest_build "$pos" 2>/dev/null) || true
                [ -n "$nearest" ] && revision="$nearest"
            fi
        fi
    fi

    local dest="$CHROMIUM_BASE/$revision"
    if [ -d "$dest/chrome" ]; then
        echo "$revision"
        return 0
    fi

    local url="$CHROMIUM_LEGACY_BASE/Linux_x64/$revision/chrome-linux.zip"

    info "Checking Chromium revision $revision ..."
    local http_code
    http_code=$(curl -sI --retry 3 --retry-delay 2 --connect-timeout 10 \
        -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)
    [ "$http_code" = "200" ] || die "Chromium revision $revision not found (HTTP $http_code)"

    mkdir -p "$dest"
    info "Download URL: $url"
    curl -#fL --retry 3 --retry-delay 5 --connect-timeout 15 \
        "$url" -o "$dest/chromium.zip" || die "Download failed"

    info "Extracting ..."
    unzip -q "$dest/chromium.zip" -d "$dest" && rm -f "$dest/chromium.zip"

    local extracted
    extracted=$(find "$dest" -maxdepth 1 -type d -name 'chrome-*' | head -1)
    [ -n "$extracted" ] && mv "$extracted" "$dest/chrome"

    mkdir -p "$dest/user-data"
    chmod +x "$dest/chrome/chrome" 2>/dev/null || true

    local size; size=$(du -sh "$dest/chrome" 2>/dev/null | cut -f1)
    info "Chromium revision $revision installed at $dest/chrome (${size:-?})"
    echo "$revision"
}

run_chromium() {
    local input="$1"; shift
    local revision

    # Quick check if already downloaded as-is
    if [ -f "$CHROMIUM_BASE/$input/chrome/chrome" ]; then
        revision="$input"
    else
        revision=$(install_chromium "$input") || die "Failed to install chromium $input"
    fi

    local dest="$CHROMIUM_BASE/$revision"
    local bin="$dest/chrome/chrome"
    [ -f "$bin" ] || die "Something went wrong - binary not found at $bin"

    info "Starting Chromium revision $revision ..."
    exec "$bin" "--user-data-dir=$dest/user-data" "$@"
}

run_chrome() {
    local input="$1"; shift
    local version; version=$(_resolve_version "$input")
    local dest="$CHROME_BASE/$version"
    local bin="$dest/chrome/chrome"
    if [ ! -f "$bin" ]; then
        warn "Chrome $version not downloaded."
        read -r -p "Download now? [Y/n] " reply
        case "$reply" in
            [nN]*) die "Aborted." ;;
            *) install_chrome "$input" ;;
        esac
    fi
    # Re-resolve in case download just happened
    version=$(_resolve_version "$input")
    dest="$CHROME_BASE/$version"
    bin="$dest/chrome/chrome"

    local extra=()
    local major; major=$(echo "$version" | cut -d. -f1)
    if [ "$major" -lt 113 ] 2>/dev/null; then
        extra+=(--disable-gpu)
    fi

    info "Starting Chrome $version ..."
    exec "$bin" "--user-data-dir=$dest/user-data" "${extra[@]}" "$@"
}

run_chromium() {
    local input="$1"; shift
    # Try resolving as Chrome version first, fallback to literal revision
    local revision="$input"
    local resolved
    resolved=$(_resolve_version "$input" 2>/dev/null) || true
    if [ -n "$resolved" ]; then
        local pos
        pos=$(_resolve_commit_position "$resolved" 2>/dev/null) || true
        if [ -n "$pos" ]; then
            local nearest
            nearest=$(_find_nearest_build "$pos" 2>/dev/null) || true
            [ -n "$nearest" ] && revision="$nearest"
        fi
    fi

    local dest="$CHROMIUM_BASE/$revision"
    local bin="$dest/chrome/chrome"
    if [ ! -f "$bin" ]; then
        warn "Chromium revision $revision not downloaded."
        read -r -p "Download now? [Y/n] " reply
        case "$reply" in
            [nN]*) die "Aborted." ;;
            *) install_chromium "$input" ;;
        esac
    fi
    # Re-resolve in case download just happened
    revision="$input"
    resolved=$(_resolve_version "$input" 2>/dev/null) || true
    if [ -n "$resolved" ]; then
        pos=$(_resolve_commit_position "$resolved" 2>/dev/null) || true
        if [ -n "$pos" ]; then
            nearest=$(_find_nearest_build "$pos" 2>/dev/null) || true
            [ -n "$nearest" ] && revision="$nearest"
        fi
    fi
    dest="$CHROMIUM_BASE/$revision"
    bin="$dest/chrome/chrome"
    info "Starting Chromium revision $revision ..."
    exec "$bin" "--user-data-dir=$dest/user-data" "$@"
}

# --- Latest ---

latest_chrome() {
    info "Fetching latest stable Chrome ..."
    local data version
    data=$(cached_fetch "$CFT_LATEST" "cft-latest.json")
    version=$(echo "$data" | jq -r '.channels.Stable.version')
    [ -n "$version" ] || die "Could not determine latest Chrome version"
    info "Latest stable: $version"
    install_chrome "$version"
}

latest_chromium() {
    info "Fetching latest Chromium revision ..."
    local data revision
    data=$(cached_fetch "$CFT_LATEST" "cft-latest.json")
    revision=$(echo "$data" | jq -r '.channels.Stable.revision')
    [ -n "$revision" ] || die "Could not determine latest Chromium revision"
    info "Latest stable Chromium revision: $revision"
    install_chromium "$revision"
}

# --- Clean ---

clean_cache() {
    rm -rf "$CACHE_DIR"
    info "Cache cleared"
}

clean_all() {
    rm -rf "$CACHE_DIR" "$CHROME_BASE" "$CHROMIUM_BASE"
    info "All data and cache cleared"
}

remove_chrome() {
    local ver; ver=$(_resolve_version "$1" 2>/dev/null) || ver="$1"
    local dir="$CHROME_BASE/$ver"
    [ -d "$dir" ] || die "Chrome $ver not found at $dir"
    rm -rf "$dir"
    info "Removed Chrome $ver"
}

remove_chromium() {
    local rev="$1"
    local dir="$CHROMIUM_BASE/$rev"
    [ -d "$dir" ] || die "Chromium $rev not found at $dir"
    rm -rf "$dir"
    info "Removed Chromium $rev"
}

# --- Main ---

check_deps

cmd="${1:-help}"
shift 2>/dev/null || true

case "$cmd" in
    list)
        sub="${1:-chrome}"
        val="${2:-30}"
        case "$sub" in
            local)    list_local "$val" ;;
            chrome)   list_chrome "$val" ;;
            tags)     list_tags "$val" ;;
            chromium) list_chromium "$val" ;;
            *) die "Usage: list local|chrome|tags|chromium [N]" ;;
        esac
        ;;
    search)
        sub="${1:-}"; val="${2:-}"; count="${3:-10}"
        [ -n "$sub" ] && [ -n "$val" ] || die "Usage: search chrome|chromium <query> [N]"
        case "$sub" in
            chrome)   search_chrome "$val" "$count" ;;
            chromium) search_chromium "$val" "$count" ;;
            *) die "Usage: search chrome|chromium <query> [N]" ;;
        esac
        ;;
    download)
        sub="${1:-}"; val="${2:-}"
        [ -n "$sub" ] && [ -n "$val" ] || die "Usage: download chrome|chromium <version|revision>"
        case "$sub" in
            chrome)   install_chrome "$val" ;;
            chromium) install_chromium "$val" ;;
            *) die "Usage: download chrome|chromium <version|revision>" ;;
        esac
        ;;
    remove)
        sub="${1:-}"; val="${2:-}"
        [ -n "$sub" ] && [ -n "$val" ] || die "Usage: remove chrome|chromium <version|revision>"
        case "$sub" in
            chrome)   remove_chrome "$val" ;;
            chromium) remove_chromium "$val" ;;
            *) die "Usage: remove chrome|chromium <version|revision>" ;;
        esac
        ;;
    run)
        sub="${1:-}"; val="${2:-}"
        [ -n "$sub" ] && [ -n "$val" ] || die "Usage: run chrome|chromium <version|revision> [args...]"
        shift 2
        case "$sub" in
            chrome)   run_chrome "$val" "$@" ;;
            chromium) run_chromium "$val" "$@" ;;
            *) die "Usage: run chrome|chromium <version|revision> [args...]" ;;
        esac
        ;;
    latest)
        sub="${1:-chrome}"
        case "$sub" in
            chrome)   latest_chrome ;;
            chromium) latest_chromium ;;
            *) die "Usage: latest chrome|chromium" ;;
        esac
        ;;
    clean)
        sub="${1:-cache}"
        case "$sub" in
            cache) clean_cache ;;
            all)   clean_all ;;
            *) die "Usage: clean cache|all" ;;
        esac
        ;;
    help|*) usage ;;
esac
