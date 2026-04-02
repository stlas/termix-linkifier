#!/usr/bin/env bash
# ============================================================================
# termix-linkifier v2.1.0 — Uninstaller
# Removes linkifier files and script tags from index.html
# Also handles legacy v1 (bundle patch) and v2.0 (nginx sub_filter) cleanup
#
# Public Domain - The Unlicense
# https://github.com/stlas/termix-linkifier
# ============================================================================
set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
CONTAINER="termix"
NGINX_CONF="/app/nginx/nginx.conf"
HTML_DIR="/app/html"
HOST_DIR="/opt/termix-linkifier"

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

info() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Parse Arguments ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --container)  CONTAINER="$2"; shift 2 ;;
        --html-dir)   HTML_DIR="$2"; shift 2 ;;
        --host-dir)   HOST_DIR="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: ./uninstall.sh [--container NAME] [--html-dir PATH] [--host-dir PATH]"
            exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

command -v docker &>/dev/null || die "docker is required"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

REMOVED_SOMETHING=false

# ── v2.1: Remove script tags from index.html ───────────────────────────────
if docker exec "$CONTAINER" grep -q "linkifier" "${HTML_DIR}/index.html" 2>/dev/null; then
    info "Removing script tags from index.html..."
    docker cp "${CONTAINER}:${HTML_DIR}/index.html" "${tmp_dir}/index.html"
    sed -i 's|<script src="./assets/linkifier-config.js"></script><script src="./assets/linkifier.js"></script>||' "${tmp_dir}/index.html"
    docker cp "${tmp_dir}/index.html" "${CONTAINER}:${HTML_DIR}/index.html"
    ok "Script tags removed from index.html"
    REMOVED_SOMETHING=true
fi

# Remove linkifier files from container (if not volume-mounted they live inside)
if docker exec "$CONTAINER" sh -c "[ -f '${HTML_DIR}/assets/linkifier.js' ]" 2>/dev/null; then
    info "Removing linkifier files from container..."
    docker exec -u root "$CONTAINER" rm -f "${HTML_DIR}/assets/linkifier.js" "${HTML_DIR}/assets/linkifier-config.js" 2>/dev/null || true
    ok "Removed linkifier files"
    REMOVED_SOMETHING=true
fi

# Remove host directory files
if [[ -d "$HOST_DIR" ]]; then
    info "Removing host files (${HOST_DIR})..."
    rm -f "${HOST_DIR}/linkifier.js" "${HOST_DIR}/linkifier-config.js"
    # Only remove dir if empty
    rmdir "$HOST_DIR" 2>/dev/null || true
    ok "Host files removed"
    REMOVED_SOMETHING=true
fi

# ── v2.0 legacy: Remove nginx sub_filter ────────────────────────────────────
if docker exec "$CONTAINER" grep -q "termix-linkifier" "$NGINX_CONF" 2>/dev/null; then
    info "Removing legacy nginx sub_filter block..."
    docker cp "${CONTAINER}:${NGINX_CONF}" "${tmp_dir}/nginx.conf"
    sed -i '/# >>> termix-linkifier/,/# <<< termix-linkifier/d' "${tmp_dir}/nginx.conf"
    docker cp "${tmp_dir}/nginx.conf" "${CONTAINER}:${NGINX_CONF}"
    docker exec "$CONTAINER" sh -c 'kill -HUP $(cat /app/nginx/nginx.pid 2>/dev/null)' 2>/dev/null || true
    ok "nginx sub_filter removed"
    REMOVED_SOMETHING=true
fi

# ── v1 legacy: Remove bundle patch ──────────────────────────────────────────
if docker exec "$CONTAINER" sh -c "[ -f '${HTML_DIR}/assets/index-LINKIFIER.js' ]" 2>/dev/null; then
    info "Removing legacy v1 bundle patch..."

    BACKUP_FILE=$(docker exec "$CONTAINER" sh -c "ls ${HTML_DIR}/assets/index-*.js.bak 2>/dev/null | head -1" || true)
    if [[ -n "$BACKUP_FILE" ]]; then
        BACKUP_NAME=$(basename "$BACKUP_FILE")
        ORIGINAL_NAME="${BACKUP_NAME%.bak}"
        docker cp "${CONTAINER}:${HTML_DIR}/index.html" "${tmp_dir}/index.html"
        sed -i -E "s|src=\"\./assets/index-[^\"]+\"|src=\"./assets/${ORIGINAL_NAME}\"|" "${tmp_dir}/index.html"
        docker cp "${tmp_dir}/index.html" "${CONTAINER}:${HTML_DIR}/index.html"
        ok "Restored index.html to original bundle: ${ORIGINAL_NAME}"
    fi

    docker exec -u root "$CONTAINER" rm -f "${HTML_DIR}/assets/index-LINKIFIER.js" 2>/dev/null || true
    ok "Removed legacy index-LINKIFIER.js"
    REMOVED_SOMETHING=true
fi

# ── Done ────────────────────────────────────────────────────────────────────
if $REMOVED_SOMETHING; then
    echo ""
    echo -e "${GREEN}${BOLD}Uninstall complete!${NC}"
    echo -e "  Reload Termix in your browser (Ctrl+Shift+R) to apply."
    echo ""
    warn "If linkifier files were volume-mounted, recreate the container"
    warn "without the -v flags to fully remove them."
    echo ""
else
    echo ""
    warn "No linkifier installation found."
    echo ""
fi
