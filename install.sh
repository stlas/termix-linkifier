#!/usr/bin/env bash
# ============================================================================
# termix-linkifier v2.0.0
# Make any text pattern clickable in Termix / xterm.js terminals
#
# v2.0: Uses nginx sub_filter injection instead of bundle patching.
#       Survives Termix updates — no minified JS is modified.
#
# Usage:
#   ./install.sh --container termix --pattern '/opt/shared/' --clipboard
#   ./install.sh --container termix --pattern '/opt/shared/' --url 'http://viewer.example.com/?file={path}'
#
# Public Domain - The Unlicense
# https://github.com/stlas/termix-linkifier
# ============================================================================
set -euo pipefail

VERSION="2.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Defaults ────────────────────────────────────────────────────────────────
CONTAINER="termix"
NGINX_CONF="/app/nginx/nginx.conf"
HTML_DIR="/app/html"
PATTERN=""
CUSTOM_REGEX=""
URL_TEMPLATE=""
USE_CLIPBOARD=false
COLOR="#4fc3f7"
DECORATION=true
DRY_RUN=false

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
termix-linkifier v2.0.0 - Make text patterns clickable in Termix terminals

v2.0: Uses nginx sub_filter — survives Termix updates!

USAGE:
  ./install.sh [OPTIONS]

REQUIRED:
  --pattern TEXT        Text prefix to match (e.g. '/opt/shared/', 'JIRA-')

CLICK ACTION (pick one):
  --clipboard           Copy matched text to clipboard (default)
  --url TEMPLATE        Open URL on click. Use {path} as placeholder
                        Example: --url 'http://viewer.example.com/?file={path}'

DOCKER:
  --container NAME      Docker container name (default: termix)
  --nginx-conf PATH     nginx.conf path inside container (default: /app/nginx/nginx.conf)
  --html-dir PATH       HTML directory inside container (default: /app/html)

APPEARANCE:
  --color HEX           Highlight color (default: #4fc3f7)
  --no-decoration       Disable persistent underline (only show on hover)

ADVANCED:
  --regex REGEX         Custom JavaScript regex (instead of auto-generated from --pattern)
  --dry-run             Show what would be done without making changes
  --version             Show version
  --help                Show this help

EXAMPLES:
  # Make /opt/shared/ paths clickable, open in web viewer
  ./install.sh --container termix --pattern '/opt/shared/' \
    --url 'http://viewer.local:5590/?file={path}'

  # Copy file paths to clipboard
  ./install.sh --container termix --pattern '/var/log/' --clipboard

  # Match JIRA ticket numbers with orange highlight
  ./install.sh --container termix --pattern 'JIRA-' \
    --url 'https://jira.example.com/browse/{path}' --color '#ff9800'
USAGE
    exit 0
}

# ── Parse Arguments ─────────────────────────────────────────────────────────
[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
    case "$1" in
        --container)     CONTAINER="$2"; shift 2 ;;
        --nginx-conf)    NGINX_CONF="$2"; shift 2 ;;
        --html-dir)      HTML_DIR="$2"; shift 2 ;;
        --pattern)       PATTERN="$2"; shift 2 ;;
        --regex)         CUSTOM_REGEX="$2"; shift 2 ;;
        --url)           URL_TEMPLATE="$2"; shift 2 ;;
        --clipboard)     USE_CLIPBOARD=true; shift ;;
        --color)         COLOR="$2"; shift 2 ;;
        --no-decoration) DECORATION=false; shift ;;
        --dry-run)       DRY_RUN=true; shift ;;
        --version)       echo "termix-linkifier v${VERSION}"; exit 0 ;;
        --help|-h)       usage ;;
        *)               die "Unknown option: $1 (use --help for usage)" ;;
    esac
done

# ── Validate ────────────────────────────────────────────────────────────────
[[ -z "$PATTERN" && -z "$CUSTOM_REGEX" ]] && die "--pattern or --regex is required"

if [[ -z "$URL_TEMPLATE" ]] && [[ "$USE_CLIPBOARD" == false ]]; then
    USE_CLIPBOARD=true
    info "No --url specified, defaulting to --clipboard mode"
fi

if [[ -n "$URL_TEMPLATE" ]] && [[ "$URL_TEMPLATE" != *"{path}"* ]]; then
    warn "URL template does not contain {path} placeholder. Appending it."
    URL_TEMPLATE="${URL_TEMPLATE}{path}"
fi

command -v docker &>/dev/null || die "docker is required"

# ── Build JS Regex ──────────────────────────────────────────────────────────
if [[ -n "$CUSTOM_REGEX" ]]; then
    JS_REGEX="$CUSTOM_REGEX"
else
    ESCAPED_PATTERN=$(python3 -c "
import re, sys
p = sys.argv[1]
escaped = re.escape(p).replace('/', '\\\\/')
print(escaped, end='')
" "$PATTERN")
    JS_REGEX="${ESCAPED_PATTERN}[^\s\"'<>)\]\}|,;:]+"
fi

# ── Display Config ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}termix-linkifier v${VERSION}${NC} (nginx sub_filter)"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  Method:      ${CYAN}nginx sub_filter (stable!)${NC}"
echo -e "  Pattern:     ${CYAN}${PATTERN:-"(custom regex)"}${NC}"
echo -e "  Action:      ${CYAN}${URL_TEMPLATE:-"Copy to clipboard"}${NC}"
echo -e "  Color:       ${CYAN}${COLOR}${NC}"
echo -e "  Decoration:  ${CYAN}${DECORATION}${NC}"
echo -e "  Container:   ${CYAN}${CONTAINER}${NC}"
$DRY_RUN && echo -e "  ${YELLOW}DRY RUN — no changes will be made${NC}"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Temp dir ────────────────────────────────────────────────────────────────
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

# ── Step 1: Check nginx has sub_filter module ───────────────────────────────
info "Checking nginx sub_filter module..."
if docker exec "$CONTAINER" nginx -V 2>&1 | grep -q "http_sub_module"; then
    ok "nginx has http_sub_module"
else
    die "nginx does not have http_sub_module. Cannot inject script."
fi

# ── Step 2: Check for existing installation ─────────────────────────────────
info "Checking for existing installation..."
if docker exec "$CONTAINER" sh -c "grep -q 'termix-linkifier' '${NGINX_CONF}' 2>/dev/null"; then
    warn "Existing linkifier found in nginx.conf — will be replaced"
fi

# ── Step 3: Deploy linkifier.js ─────────────────────────────────────────────
info "Deploying linkifier.js..."
LINKIFIER_SRC="${SCRIPT_DIR}/linkifier.js"
[[ -f "$LINKIFIER_SRC" ]] || die "linkifier.js not found in ${SCRIPT_DIR}/"

if ! $DRY_RUN; then
    docker cp "$LINKIFIER_SRC" "${CONTAINER}:${HTML_DIR}/assets/linkifier.js"
    ok "Deployed: ${HTML_DIR}/assets/linkifier.js"
fi

# ── Step 4: Build config file ───────────────────────────────────────────────
info "Building linkifier-config.js..."

# Escape for JSON
JS_URL_JSON="null"
if [[ -n "$URL_TEMPLATE" ]]; then
    JS_URL_JSON="\"$(echo "$URL_TEMPLATE" | sed 's/"/\\"/g')\""
fi
JS_DECO="true"
[[ "$DECORATION" == false ]] && JS_DECO="false"

# Escape pattern for JS string
JS_PREFIX=""
if [[ -n "$PATTERN" ]]; then
    JS_PREFIX=$(echo "$PATTERN" | sed 's/\\/\\\\/g; s/"/\\"/g')
fi

# Write config to a separate JS file (avoids nginx quoting issues)
cat > "${tmp_dir}/linkifier-config.js" <<JSEOF
window.__LINKIFIER_CONFIG__={regex:"${JS_REGEX}",url:${JS_URL_JSON},prefix:"${JS_PREFIX}",color:"${COLOR}",decoration:${JS_DECO}};
JSEOF

if ! $DRY_RUN; then
    docker cp "${tmp_dir}/linkifier-config.js" "${CONTAINER}:${HTML_DIR}/assets/linkifier-config.js"
    ok "Deployed: ${HTML_DIR}/assets/linkifier-config.js"
fi

# ── Step 5: Patch nginx.conf ────────────────────────────────────────────────
info "Patching nginx.conf..."

docker cp "${CONTAINER}:${NGINX_CONF}" "${tmp_dir}/nginx.conf"
cp "${tmp_dir}/nginx.conf" "${tmp_dir}/nginx.conf.bak"

# Remove any existing linkifier block
sed -i '/# >>> termix-linkifier/,/# <<< termix-linkifier/d' "${tmp_dir}/nginx.conf"

# sub_filter injects two simple script tags — no special chars that break nginx quoting
python3 - "${tmp_dir}/nginx.conf" <<'PATCHER'
import sys

conf_path = sys.argv[1]

with open(conf_path, 'r') as f:
    content = f.read()

# Find the location / block with try_files ... /index.html
marker = "try_files $uri $uri/ /index.html;"
if marker not in content:
    print("ERROR: Could not find 'try_files $uri $uri/ /index.html;' in nginx.conf", file=sys.stderr)
    sys.exit(1)

# Only safe ASCII in the sub_filter string — no quotes, angle brackets in values
injection = """
        # >>> termix-linkifier v2.0 (DO NOT EDIT — managed by install.sh) >>>
        sub_filter '</head>' '<script src="./assets/linkifier-config.js"></script><script src="./assets/linkifier.js"></script></head>';
        sub_filter_once on;
        # sub_filter_types not needed — text/html is the default
        # <<< termix-linkifier <<<"""

# Insert after the try_files line
content = content.replace(marker, marker + injection)

with open(conf_path, 'w') as f:
    f.write(content)

print("nginx.conf patched successfully")
PATCHER

if [[ $? -ne 0 ]]; then
    die "Failed to patch nginx.conf"
fi

if $DRY_RUN; then
    echo ""
    info "DRY RUN — nginx.conf diff:"
    diff "${tmp_dir}/nginx.conf.bak" "${tmp_dir}/nginx.conf" || true
    echo ""
    ok "Dry run complete. Remove --dry-run to apply."
    exit 0
fi

# ── Step 6: Deploy nginx.conf and reload ────────────────────────────────────
info "Deploying nginx.conf..."
docker cp "${tmp_dir}/nginx.conf" "${CONTAINER}:${NGINX_CONF}"
ok "nginx.conf updated"

# Backup original nginx.conf (only first time)
BACKUP_EXISTS=$(docker exec "$CONTAINER" sh -c "[ -f '${NGINX_CONF}.pre-linkifier' ] && echo yes || echo no")
if [[ "$BACKUP_EXISTS" == "no" ]]; then
    docker cp "${tmp_dir}/nginx.conf.bak" "${CONTAINER}:${NGINX_CONF}.pre-linkifier"
    ok "Backup saved: ${NGINX_CONF}.pre-linkifier"
fi

info "Reloading nginx (no restart needed, sessions preserved)..."
docker exec "$CONTAINER" sh -c 'kill -HUP $(cat /app/nginx/nginx.pid 2>/dev/null)' 2>&1 || die "nginx reload failed!"
ok "nginx reloaded"

# ── Step 7: Clean up legacy v1 artifacts ────────────────────────────────────
if docker exec "$CONTAINER" sh -c "[ -f '${HTML_DIR}/assets/index-LINKIFIER.js' ]" 2>/dev/null; then
    info "Cleaning up legacy v1 bundle patch..."
    # Restore original index.html if it was pointing to LINKIFIER
    if docker exec "$CONTAINER" grep -q "index-LINKIFIER" "${HTML_DIR}/index.html" 2>/dev/null; then
        ORIG_BUNDLE=$(docker exec "$CONTAINER" sh -c "ls ${HTML_DIR}/assets/index-*.js.bak 2>/dev/null | head -1" || true)
        if [[ -n "$ORIG_BUNDLE" ]]; then
            ORIG_NAME=$(basename "${ORIG_BUNDLE%.bak}")
            docker cp "${CONTAINER}:${HTML_DIR}/index.html" "${tmp_dir}/index.html"
            sed -i -E "s|src=\"\./assets/index-[^\"]+\"|src=\"./assets/${ORIG_NAME}\"|" "${tmp_dir}/index.html"
            docker cp "${tmp_dir}/index.html" "${CONTAINER}:${HTML_DIR}/index.html"
            ok "Restored index.html to original bundle: ${ORIG_NAME}"
        fi
    fi
    docker exec -u root "$CONTAINER" rm -f "${HTML_DIR}/assets/index-LINKIFIER.js"
    ok "Removed legacy index-LINKIFIER.js"
fi

# ── Done ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Installation complete!${NC}"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  Method:    nginx sub_filter (stable!)"
echo -e "  Pattern:   ${PATTERN:-"(custom regex)"}"
echo -e "  Action:    ${URL_TEMPLATE:-"Copy to clipboard"}"
echo -e "  Color:     ${COLOR}"
echo -e "  Files:     ${HTML_DIR}/assets/linkifier.js"
echo -e "             ${HTML_DIR}/assets/linkifier-config.js"
echo -e "             ${NGINX_CONF} (sub_filter block)"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e "  Reload Termix in your browser (Ctrl+Shift+R) to activate."
echo ""
echo -e "  To uninstall:"
echo -e "  ${CYAN}./uninstall.sh --container ${CONTAINER}${NC}"
echo ""
