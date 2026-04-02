#!/usr/bin/env bash
# ============================================================================
# termix-linkifier v2.0.0 — Uninstaller
# Removes nginx sub_filter injection and linkifier.js
# Also handles legacy v1 (bundle patch) cleanup
#
# Public Domain - The Unlicense
# https://github.com/stlas/termix-linkifier
# ============================================================================
set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
CONTAINER="termix"
NGINX_CONF="/app/nginx/nginx.conf"
HTML_DIR="/app/html"

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

info() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Parse Arguments ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --container)  CONTAINER="$2"; shift 2 ;;
        --nginx-conf) NGINX_CONF="$2"; shift 2 ;;
        --html-dir)   HTML_DIR="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: ./uninstall.sh [--container NAME] [--nginx-conf PATH] [--html-dir PATH]"
            exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

command -v docker &>/dev/null || die "docker is required"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

REMOVED_SOMETHING=false

# ── v2: Remove nginx sub_filter ─────────────────────────────────────────────
if docker exec "$CONTAINER" grep -q "termix-linkifier" "$NGINX_CONF" 2>/dev/null; then
    info "Removing nginx sub_filter block..."
    docker cp "${CONTAINER}:${NGINX_CONF}" "${tmp_dir}/nginx.conf"
    sed -i '/# >>> termix-linkifier/,/# <<< termix-linkifier/d' "${tmp_dir}/nginx.conf"
    docker cp "${tmp_dir}/nginx.conf" "${CONTAINER}:${NGINX_CONF}"
    docker exec "$CONTAINER" sh -c 'kill -HUP $(cat /app/nginx/nginx.pid 2>/dev/null)' 2>&1
    ok "nginx sub_filter removed and reloaded"
    REMOVED_SOMETHING=true
fi

# Remove linkifier.js and config
if docker exec "$CONTAINER" sh -c "[ -f '${HTML_DIR}/assets/linkifier.js' ]" 2>/dev/null; then
    info "Removing linkifier files..."
    docker exec -u root "$CONTAINER" rm -f "${HTML_DIR}/assets/linkifier.js" "${HTML_DIR}/assets/linkifier-config.js"
    ok "Removed: linkifier.js, linkifier-config.js"
    REMOVED_SOMETHING=true
fi

# ── v1 legacy: Remove bundle patch ──────────────────────────────────────────
if docker exec "$CONTAINER" sh -c "[ -f '${HTML_DIR}/assets/index-LINKIFIER.js' ]" 2>/dev/null; then
    info "Removing legacy v1 bundle patch..."

    BACKUP_FILE=$(docker exec "$CONTAINER" sh -c "ls ${HTML_DIR}/assets/index-*.js.bak 2>/dev/null | head -1" || true)
    if [[ -n "$BACKUP_FILE" ]]; then
        BACKUP_NAME=$(basename "$BACKUP_FILE")
        ORIGINAL_NAME="${BACKUP_NAME%.bak}"

        # Restore index.html to point to original bundle
        docker cp "${CONTAINER}:${HTML_DIR}/index.html" "${tmp_dir}/index.html"
        sed -i -E "s|src=\"\./assets/index-[^\"]+\"|src=\"./assets/${ORIGINAL_NAME}\"|" "${tmp_dir}/index.html"
        docker cp "${tmp_dir}/index.html" "${CONTAINER}:${HTML_DIR}/index.html"
        ok "Restored index.html → ${ORIGINAL_NAME}"
    fi

    docker exec -u root "$CONTAINER" rm -f "${HTML_DIR}/assets/index-LINKIFIER.js"
    ok "Removed: index-LINKIFIER.js"
    REMOVED_SOMETHING=true
fi

# ── Done ────────────────────────────────────────────────────────────────────
if $REMOVED_SOMETHING; then
    echo ""
    echo -e "${GREEN}${BOLD}Uninstall complete!${NC}"
    echo -e "  Reload Termix in your browser (Ctrl+Shift+R) to apply."
    echo ""
else
    echo ""
    warn "No linkifier installation found."
    echo ""
fi
