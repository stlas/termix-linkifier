#!/usr/bin/env bash
# ============================================================================
# termix-linkifier v2.1.0
# Make any text pattern clickable in Termix / xterm.js terminals
#
# v2.1: Uses Docker volume mounts + index.html script injection.
#       Survives Termix updates (volume-mounted files persist).
#
# Public Domain - The Unlicense
# https://github.com/stlas/termix-linkifier
# ============================================================================
set -euo pipefail

VERSION="2.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Defaults ────────────────────────────────────────────────────────────────
CONTAINER="termix"
HTML_DIR="/app/html"
HOST_DIR=""
PATTERN=""
CUSTOM_REGEX=""
URL_TEMPLATE=""
USE_CLIPBOARD=false
COLOR="#4fc3f7"
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
termix-linkifier v2.1.0 - Make text patterns clickable in Termix terminals

Deploys linkifier.js + config via Docker volume mounts.
Survives Termix updates!

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
  --html-dir PATH       HTML directory inside container (default: /app/html)
  --host-dir PATH       Directory on host for persistent files (default: /opt/termix-linkifier)

APPEARANCE:
  --color HEX           Highlight color (default: #4fc3f7)

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
USAGE
    exit 0
}

# ── Parse Arguments ─────────────────────────────────────────────────────────
[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
    case "$1" in
        --container)     CONTAINER="$2"; shift 2 ;;
        --html-dir)      HTML_DIR="$2"; shift 2 ;;
        --host-dir)      HOST_DIR="$2"; shift 2 ;;
        --pattern)       PATTERN="$2"; shift 2 ;;
        --regex)         CUSTOM_REGEX="$2"; shift 2 ;;
        --url)           URL_TEMPLATE="$2"; shift 2 ;;
        --clipboard)     USE_CLIPBOARD=true; shift ;;
        --color)         COLOR="$2"; shift 2 ;;
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
command -v python3 &>/dev/null || die "python3 is required"

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
    JS_REGEX="${ESCAPED_PATTERN}[^\\\\s\"'<>)\\\\]\\\\}|,;:]+"
fi

[[ -z "$HOST_DIR" ]] && HOST_DIR="/opt/termix-linkifier"

# ── Display Config ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}termix-linkifier v${VERSION}${NC}"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  Method:      ${CYAN}Docker volume + index.html injection${NC}"
echo -e "  Pattern:     ${CYAN}${PATTERN:-"(custom regex)"}${NC}"
echo -e "  Action:      ${CYAN}${URL_TEMPLATE:-"Copy to clipboard"}${NC}"
echo -e "  Color:       ${CYAN}${COLOR}${NC}"
echo -e "  Container:   ${CYAN}${CONTAINER}${NC}"
echo -e "  Host dir:    ${CYAN}${HOST_DIR}${NC}"
$DRY_RUN && echo -e "  ${YELLOW}DRY RUN — no changes will be made${NC}"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if $DRY_RUN; then
    ok "Dry run complete. Remove --dry-run to apply."
    exit 0
fi

# ── Step 1: Create host directory and deploy files ──────────────────────────
info "Creating host directory ${HOST_DIR}..."
mkdir -p "$HOST_DIR"

info "Deploying linkifier.js..."
LINKIFIER_SRC="${SCRIPT_DIR}/linkifier.js"
[[ -f "$LINKIFIER_SRC" ]] || die "linkifier.js not found in ${SCRIPT_DIR}/"
cp "$LINKIFIER_SRC" "${HOST_DIR}/linkifier.js"
ok "Deployed: ${HOST_DIR}/linkifier.js"

# ── Step 2: Generate linkifier-config.js ────────────────────────────────────
info "Generating linkifier-config.js..."

python3 -c "
import sys

regex = sys.argv[1]
url = sys.argv[2] if sys.argv[2] != 'null' else None
prefix = sys.argv[3]
color = sys.argv[4]
out = sys.argv[5]

# Escape for JS string literals (double-escape backslashes)
def js_str(s):
    return s.replace(chr(92), chr(92)+chr(92)).replace('\"', chr(92)+'\"')

parts = []
parts.append('regex:\"' + js_str(regex) + '\"')
parts.append('url:' + ('\"' + js_str(url) + '\"' if url else 'null'))
parts.append('prefix:\"' + js_str(prefix) + '\"')
parts.append('color:\"' + js_str(color) + '\"')
parts.append('decoration:true')

with open(out, 'w') as f:
    f.write('window.__LINKIFIER_CONFIG__={' + ','.join(parts) + '};' + chr(10))
" "$JS_REGEX" "${URL_TEMPLATE:-null}" "${PATTERN:-}" "$COLOR" "${HOST_DIR}/linkifier-config.js"

ok "Generated: ${HOST_DIR}/linkifier-config.js"

# ── Step 3: Check container volume mounts ───────────────────────────────────
info "Checking container volume mounts..."

if docker inspect "$CONTAINER" --format '{{json .Mounts}}' 2>/dev/null | grep -q "linkifier.js"; then
    ok "Volume mounts already present"
else
    warn "Container needs recreation with volume mounts"
    warn "This will briefly stop Termix (active sessions will be lost)"

    IMAGE=$(docker inspect "$CONTAINER" --format '{{.Config.Image}}')
    RESTART=$(docker inspect "$CONTAINER" --format '{{.HostConfig.RestartPolicy.Name}}')

    PORT_ARGS=$(docker inspect "$CONTAINER" --format '{{json .HostConfig.PortBindings}}' | python3 -c "
import json, sys
ports = json.load(sys.stdin)
args = []
for cp, binds in ports.items():
    for b in binds:
        p = cp.split('/')[0]
        args.append('-p ' + b.get('HostPort','') + ':' + p)
print(' '.join(args))
")

    VOL_ARGS=$(docker inspect "$CONTAINER" --format '{{range .Mounts}}{{if eq .Type "volume"}}-v {{.Name}}:{{.Destination}} {{end}}{{end}}')

    info "Recreating container..."
    docker stop "$CONTAINER" >/dev/null
    docker rm "$CONTAINER" >/dev/null

    eval "docker run -d --name ${CONTAINER} --restart ${RESTART} ${PORT_ARGS} ${VOL_ARGS} \
        -v ${HOST_DIR}/linkifier.js:${HTML_DIR}/assets/linkifier.js:ro \
        -v ${HOST_DIR}/linkifier-config.js:${HTML_DIR}/assets/linkifier-config.js:ro \
        ${IMAGE}" >/dev/null

    ok "Container recreated with volume mounts"
    info "Waiting for startup..."
    sleep 5
fi

# ── Step 4: Patch index.html ───────────────────────────────────────────────
info "Checking index.html..."

if docker exec "$CONTAINER" grep -q "linkifier" "${HTML_DIR}/index.html" 2>/dev/null; then
    ok "Script tags already present in index.html"
else
    info "Adding script tags to index.html..."
    tmp_html=$(mktemp)
    docker cp "${CONTAINER}:${HTML_DIR}/index.html" "$tmp_html"
    sed -i 's|</head>|<script src="./assets/linkifier-config.js"></script><script src="./assets/linkifier.js"></script></head>|' "$tmp_html"
    docker cp "$tmp_html" "${CONTAINER}:${HTML_DIR}/index.html"
    rm -f "$tmp_html"
    ok "Script tags added to index.html"
fi

# ── Done ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Installation complete!${NC}"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  Pattern:   ${PATTERN:-"(custom regex)"}"
echo -e "  Action:    ${URL_TEMPLATE:-"Copy to clipboard"}"
echo -e "  Color:     ${COLOR}"
echo -e "  Files:     ${HOST_DIR}/linkifier.js (volume mounted)"
echo -e "             ${HOST_DIR}/linkifier-config.js (volume mounted)"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e "  Reload Termix in your browser (Ctrl+Shift+R) to activate."
echo ""
echo -e "  ${YELLOW}Note: After a Termix image update, re-run this script"
echo -e "  to re-add the script tags to the new index.html.${NC}"
echo ""
