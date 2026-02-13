#!/usr/bin/env bash
# ============================================================================
# termix-linkifier - Uninstaller
# Restores the original xterm.js bundle and removes the linkifier patch
#
# Public Domain - The Unlicense
# https://github.com/stlas/termix-linkifier
# ============================================================================
set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
CONTAINER="termix"
BUNDLE_DIR="/app/html/assets"
INDEX_HTML="/app/html/index.html"
LOCAL_MODE=false

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

info() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Parse Arguments ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --container)  CONTAINER="$2"; shift 2 ;;
        --bundle-dir) BUNDLE_DIR="$2"; shift 2 ;;
        --index-html) INDEX_HTML="$2"; shift 2 ;;
        --local)      LOCAL_MODE=true; shift ;;
        --help|-h)
            echo "Usage: ./uninstall.sh [--container NAME] [--local --bundle-dir PATH --index-html PATH]"
            exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

# Docker commands need different approaches for read vs write
exec_cmd() {
    if $LOCAL_MODE; then eval "$@"; else docker exec "$CONTAINER" sh -c "$*"; fi
}
# Use docker cp for file operations (runs as root, avoids permission issues)
copy_within() {
    local src="$1" dst="$2"
    if $LOCAL_MODE; then
        cp "$src" "$dst"
    else
        local tmp_dir=$(mktemp -d)
        docker cp "${CONTAINER}:${src}" "${tmp_dir}/file"
        docker cp "${tmp_dir}/file" "${CONTAINER}:${dst}"
        rm -rf "$tmp_dir"
    fi
}

# ── Find backup ─────────────────────────────────────────────────────────────
info "Looking for backup..."

BACKUP_FILE=$(exec_cmd "ls ${BUNDLE_DIR}/index-*.js.bak 2>/dev/null | head -1" || true)
[[ -z "$BACKUP_FILE" ]] && die "No backup found in ${BUNDLE_DIR}/. Was termix-linkifier installed?"

BACKUP_NAME=$(basename "$BACKUP_FILE")
ORIGINAL_NAME="${BACKUP_NAME%.bak}"
ok "Found backup: ${BACKUP_NAME} -> ${ORIGINAL_NAME}"

# ── Restore original bundle ─────────────────────────────────────────────────
info "Restoring original bundle..."
copy_within "$BACKUP_FILE" "${BUNDLE_DIR}/${ORIGINAL_NAME}"
ok "Restored: ${ORIGINAL_NAME}"

# ── Update index.html ───────────────────────────────────────────────────────
info "Updating index.html..."
CACHE_BUSTER="v=$(date +%s)"

if $LOCAL_MODE; then
    sed -i -E "s|src=\"\./assets/index-[^\"]+\"|src=\"./assets/${ORIGINAL_NAME}?${CACHE_BUSTER}\"|" "$INDEX_HTML"
else
    # Pull index.html, modify locally, push back (avoids permission issues)
    tmp_html=$(mktemp)
    docker cp "${CONTAINER}:${INDEX_HTML}" "$tmp_html"
    sed -i -E "s|src=\"\./assets/index-[^\"]+\"|src=\"./assets/${ORIGINAL_NAME}?${CACHE_BUSTER}\"|" "$tmp_html"
    docker cp "$tmp_html" "${CONTAINER}:${INDEX_HTML}"
    rm -f "$tmp_html"
fi
ok "index.html restored"

# ── Remove patched bundle ───────────────────────────────────────────────────
info "Removing patched bundle..."
if $LOCAL_MODE; then
    rm -f "${BUNDLE_DIR}/index-LINKIFIER.js"
else
    # docker exec as root to remove
    docker exec -u root "$CONTAINER" rm -f "${BUNDLE_DIR}/index-LINKIFIER.js"
fi
ok "Removed: index-LINKIFIER.js"

# ── Done ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Uninstall complete!${NC}"
echo -e "  Original bundle restored: ${ORIGINAL_NAME}"
echo -e "  Reload Termix in your browser (Ctrl+Shift+R) to apply."
echo ""
