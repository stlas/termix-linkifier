#!/usr/bin/env bash
# ============================================================================
# termix-linkifier v1.0.0
# Make any text pattern clickable in Termix / xterm.js terminals
#
# Usage:
#   ./install.sh --container termix --pattern '/opt/shared/' --clipboard
#   ./install.sh --container termix --pattern '/var/log/' --url 'http://logviewer.example.com/?file={path}'
#   ./install.sh --local --bundle-dir ./assets --index-html ./index.html --pattern '/home/' --clipboard
#
# Public Domain - The Unlicense
# https://github.com/stlas/termix-linkifier
# ============================================================================
set -euo pipefail

VERSION="1.0.0"

# ── Defaults ────────────────────────────────────────────────────────────────
CONTAINER="termix"
BUNDLE_DIR="/app/html/assets"
INDEX_HTML="/app/html/index.html"
PATTERN=""
CUSTOM_REGEX=""
URL_TEMPLATE=""
USE_CLIPBOARD=false
COLOR="#4fc3f7"
DECORATION=true
DRY_RUN=false
LOCAL_MODE=false

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
termix-linkifier v1.0.0 - Make text patterns clickable in Termix terminals

USAGE:
  ./install.sh [OPTIONS]

REQUIRED:
  --pattern TEXT        Text prefix to match (e.g. '/opt/shared/', 'JIRA-')

CLICK ACTION (pick one):
  --clipboard           Copy matched text to clipboard (default)
  --url TEMPLATE        Open URL on click. Use {path} as placeholder
                        Example: --url 'http://viewer.example.com/?file={path}'

DOCKER MODE (default):
  --container NAME      Docker container name (default: termix)
  --bundle-dir PATH     Asset directory inside container (default: /app/html/assets)
  --index-html PATH     index.html path inside container (default: /app/html/index.html)

LOCAL MODE:
  --local               Work directly on filesystem (no Docker)
  --bundle-dir PATH     Asset directory on local filesystem
  --index-html PATH     index.html path on local filesystem

APPEARANCE:
  --color HEX           Highlight color (default: #4fc3f7)
  --no-decoration       Disable persistent underline (only show on hover)

ADVANCED:
  --regex REGEX         Custom JavaScript regex (instead of auto-generated from --pattern)
  --dry-run             Show what would be done without making changes
  --version             Show version
  --help                Show this help

EXAMPLES:
  # Make /opt/shared/ paths clickable, copy to clipboard on click
  ./install.sh --container termix --pattern '/opt/shared/'

  # Make file paths open in a web viewer
  ./install.sh --container termix --pattern '/var/log/' \
    --url 'http://logviewer.local/?file={path}'

  # Match JIRA ticket numbers with orange highlight
  ./install.sh --container termix --pattern 'JIRA-' \
    --url 'https://jira.example.com/browse/{path}' --color '#ff9800'

  # Local mode (no Docker)
  ./install.sh --local --bundle-dir /srv/termix/assets \
    --index-html /srv/termix/index.html --pattern '/home/'
USAGE
    exit 0
}

# ── Parse Arguments ─────────────────────────────────────────────────────────
[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
    case "$1" in
        --container)     CONTAINER="$2"; shift 2 ;;
        --bundle-dir)    BUNDLE_DIR="$2"; shift 2 ;;
        --index-html)    INDEX_HTML="$2"; shift 2 ;;
        --pattern)       PATTERN="$2"; shift 2 ;;
        --regex)         CUSTOM_REGEX="$2"; shift 2 ;;
        --url)           URL_TEMPLATE="$2"; shift 2 ;;
        --clipboard)     USE_CLIPBOARD=true; shift ;;
        --color)         COLOR="$2"; shift 2 ;;
        --no-decoration) DECORATION=false; shift ;;
        --dry-run)       DRY_RUN=true; shift ;;
        --local)         LOCAL_MODE=true; shift ;;
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

command -v python3 &>/dev/null || die "python3 is required but not found."
if [[ "$LOCAL_MODE" == false ]]; then
    command -v docker &>/dev/null || die "docker is required for container mode. Use --local for filesystem mode."
fi

# ── Build JS Regex from Pattern ─────────────────────────────────────────────
if [[ -n "$CUSTOM_REGEX" ]]; then
    JS_REGEX="$CUSTOM_REGEX"
else
    # Escape special regex chars in the pattern prefix, then add character class for continuation
    ESCAPED_PATTERN=$(python3 -c "
import re, sys
p = sys.argv[1]
escaped = re.escape(p).replace('\\\\/', '/')
print(escaped, end='')
" "$PATTERN")
    JS_REGEX="${ESCAPED_PATTERN}[^\\\\s\"'<>)\\\\]\\\\}|,;:]+"
fi

# ── Build JS Click Handler ──────────────────────────────────────────────────
if [[ -n "$URL_TEMPLATE" ]]; then
    JS_URL_ESCAPED=$(echo "$URL_TEMPLATE" | sed 's/"/\\"/g')
    JS_HANDLER="function(_e,_lt){var _u=\"${JS_URL_ESCAPED}\".replace(\"{path}\",encodeURIComponent(_lt.replace(/[.]+\$/,\"\")));window.open(_u,\"_blank\")}"
else
    JS_HANDLER='function(_e,_lt){var _p=_lt.replace(/[.]+$/,"");navigator.clipboard.writeText(_p).then(function(){var _n=document.createElement("div");_n.textContent="Copied: "+_p;_n.style.cssText="position:fixed;bottom:20px;right:20px;background:#333;color:#fff;padding:8px 16px;border-radius:6px;font-size:13px;z-index:99999;opacity:0;transition:opacity 0.3s";document.body.appendChild(_n);setTimeout(function(){_n.style.opacity="1"},10);setTimeout(function(){_n.style.opacity="0";setTimeout(function(){_n.remove()},300)},2000)})}'
fi

# ── Display Config ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}termix-linkifier v${VERSION}${NC}"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  Pattern:     ${CYAN}${PATTERN:-"(custom regex)"}${NC}"
echo -e "  Action:      ${CYAN}${URL_TEMPLATE:-"Copy to clipboard"}${NC}"
echo -e "  Color:       ${CYAN}${COLOR}${NC}"
echo -e "  Decoration:  ${CYAN}${DECORATION}${NC}"
echo -e "  Mode:        ${CYAN}$($LOCAL_MODE && echo "Local" || echo "Docker ($CONTAINER)")${NC}"
$DRY_RUN && echo -e "  ${YELLOW}DRY RUN - no changes will be made${NC}"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Temp dir ────────────────────────────────────────────────────────────────
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

# ── File Operations (Docker or Local) ──────────────────────────────────────
copy_from() {
    if $LOCAL_MODE; then cp "$1" "$2"; else docker cp "${CONTAINER}:$1" "$2"; fi
}
copy_to() {
    if $LOCAL_MODE; then cp "$1" "$2"; else docker cp "$1" "${CONTAINER}:$2"; fi
}
exec_cmd() {
    if $LOCAL_MODE; then eval "$@"; else docker exec "$CONTAINER" sh -c "$*"; fi
}

# ── Step 1: Find the bundle ─────────────────────────────────────────────────
info "Finding xterm.js bundle..."

if $LOCAL_MODE; then
    BUNDLE_FILE=$(find "$BUNDLE_DIR" -maxdepth 1 -name 'index-*.js' ! -name '*LINKIFIER*' ! -name '*.bak' 2>/dev/null | head -1)
    [[ -z "$BUNDLE_FILE" ]] && BUNDLE_FILE=$(find "$BUNDLE_DIR" -maxdepth 1 -name 'index.js' 2>/dev/null | head -1)
else
    BUNDLE_FILE=$(exec_cmd "ls ${BUNDLE_DIR}/index-*.js 2>/dev/null | grep -v LINKIFIER | grep -v '.bak' | head -1" || true)
    [[ -z "$BUNDLE_FILE" ]] && BUNDLE_FILE=$(exec_cmd "ls ${BUNDLE_DIR}/index.js 2>/dev/null | head -1" || true)
fi

[[ -z "$BUNDLE_FILE" ]] && die "No xterm.js bundle found in ${BUNDLE_DIR}/. Expected index-*.js or index.js"

BUNDLE_NAME=$(basename "$BUNDLE_FILE")
info "Found bundle: ${BUNDLE_NAME}"

# ── Step 2: Copy bundle locally ──────────────────────────────────────────────
info "Copying bundle for patching..."
copy_from "$BUNDLE_FILE" "${tmp_dir}/original.js"

# ── Step 3: Verify injection point ──────────────────────────────────────────
info "Verifying xterm.js WebLinksAddon injection point..."

SEARCH_STR='this._linkProvider=this._terminal.registerLinkProvider(new s.WebLinkProvider(this._terminal,h,this._handler,p))}dispose'

if ! grep -qF "$SEARCH_STR" "${tmp_dir}/original.js"; then
    die "Injection point not found in bundle!
  - Is the bundle already patched? Run uninstall.sh first.
  - Is this an xterm.js-based terminal with WebLinksAddon?
  - The xterm.js version may use a different code structure."
fi
ok "Injection point found"

# ── Step 4: Run Python patcher ──────────────────────────────────────────────
info "Generating patch..."

export TL_REGEX="$JS_REGEX"
export TL_HANDLER="$JS_HANDLER"
export TL_COLOR="$COLOR"
export TL_PATTERN="$PATTERN"
export TL_DECORATION="$DECORATION"

python3 - "${tmp_dir}/original.js" "${tmp_dir}/patched.js" <<'PATCHER'
import sys, os

bundle_in, bundle_out = sys.argv[1], sys.argv[2]
js_regex = os.environ["TL_REGEX"]
js_handler = os.environ["TL_HANDLER"]
color = os.environ["TL_COLOR"]
pattern_text = os.environ.get("TL_PATTERN", "")
use_decoration = os.environ.get("TL_DECORATION", "true") == "true"

SEARCH = ('this._linkProvider=this._terminal.registerLinkProvider('
          'new s.WebLinkProvider(this._terminal,h,this._handler,p))}dispose')

# Escape pattern for JS indexOf check
escaped_check = pattern_text.replace('\\', '\\\\').replace('"', '\\"') if pattern_text else ""

# ── Link Provider ──
# Key: provideLinks(_ln) is 1-based, buffer.getLine() is 0-based → getLine(_ln-1)
lp = 'u.registerLinkProvider({provideLinks:function(_ln,_cb){try{'
lp += 'var _l=u.buffer.active.getLine(_ln-1);if(!_l){_cb(void 0);return}'
lp += 'var _t=_l.translateToString();'
if escaped_check:
    lp += f'if(_t.indexOf("{escaped_check}")===-1){{_cb(void 0);return}}'
lp += f'var _lks=[],_re=/{js_regex}/g,_m;'
lp += 'while((_m=_re.exec(_t))!==null){'
lp += 'var _mt=_m[0].replace(/[.]+$/,"");'
lp += '_lks.push({range:{start:{x:_m.index+1,y:_ln},'
lp += 'end:{x:_m.index+_mt.length,y:_ln}},'
lp += f'text:_mt,activate:{js_handler}}})}}'
lp += '_cb(_lks.length>0?_lks:void 0)'
lp += '}catch(_e){_cb(void 0)}}});'

# ── Persistent Decorations ──
dc = ''
if use_decoration:
    dc += 'var _dd={},_df=0;function _ds(){if(_df)return;_df=1;try{'
    dc += 'var r=u.rows,b=u.buffer.active.baseY,cy=u.buffer.active.cursorY,cb=b+cy;'
    dc += 'for(var i=0;i<r;i++){var bl=b+i;if(_dd[bl])continue;'
    dc += 'var ln=u.buffer.active.getLine(bl);if(!ln)continue;'
    dc += 'var t=ln.translateToString();'
    if escaped_check:
        dc += f'if(t.indexOf("{escaped_check}")===-1)continue;'
    dc += f'var re=/{js_regex}/g,m,ds=[];'
    dc += 'while((m=re.exec(t))!==null){'
    dc += 'var mt=m[0].replace(/[.]+$/,""),mk=u.registerMarker(bl-cb);'
    dc += 'if(!mk)continue;'
    dc += 'var d=u.registerDecoration({marker:mk,x:m.index,width:mt.length,layer:"top"});'
    dc += f'if(d){{d.onRender(function(el){{el.style.borderBottom="2px solid {color}";'
    dc += 'el.style.pointerEvents="none"});ds.push(d)}}'
    dc += '}if(ds.length>0)_dd[bl]=ds}'
    dc += 'var ks=Object.keys(_dd);for(var j=0;j<ks.length;j++){var k=parseInt(ks[j]);'
    dc += 'if(k<b-200){_dd[k].forEach(function(x){try{x.dispose()}catch(e){}});delete _dd[k]}}'
    dc += '}catch(e){}finally{_df=0}}'
    dc += 'u.onRender(function(){_ds()});setTimeout(function(){_ds()},1000);'

# ── Console Log ──
log_text = pattern_text or js_regex
lg = f'console.log("[termix-linkifier] Active: {log_text}")'

# ── Assemble & Patch ──
PATCH = lp + dc + lg
REPLACE = ('this._linkProvider=this._terminal.registerLinkProvider('
           'new s.WebLinkProvider(this._terminal,h,this._handler,p));'
           + PATCH + '}dispose')

with open(bundle_in, 'r') as f:
    content = f.read()

count = content.count(SEARCH)
if count == 0:
    print("ERROR: Injection point not found!", file=sys.stderr)
    sys.exit(1)

with open(bundle_out, 'w') as f:
    f.write(content.replace(SEARCH, REPLACE))

print(f"Patched {count} location(s) successfully")
PATCHER

[[ $? -ne 0 ]] && die "Patching failed!"
ok "Patch generated"

# ── Dry Run Exit ─────────────────────────────────────────────────────────────
if $DRY_RUN; then
    PATCHED_SIZE=$(wc -c < "${tmp_dir}/patched.js")
    ORIG_SIZE=$(wc -c < "${tmp_dir}/original.js")
    DIFF_KB=$(( (PATCHED_SIZE - ORIG_SIZE) / 1024 ))
    info "DRY RUN: Patch adds ~${DIFF_KB}KB to bundle"
    info "DRY RUN: Would deploy as index-LINKIFIER.js and update ${INDEX_HTML}"
    ok "Dry run complete. Remove --dry-run to apply."
    exit 0
fi

# ── Step 5: Backup ──────────────────────────────────────────────────────────
info "Creating backup..."
BACKUP_NAME="${BUNDLE_NAME}.bak"
BACKUP_EXISTS=$(exec_cmd "[ -f '${BUNDLE_DIR}/${BACKUP_NAME}' ] && echo yes || echo no")

if [[ "$BACKUP_EXISTS" == "no" ]]; then
    exec_cmd "cp '${BUNDLE_FILE}' '${BUNDLE_DIR}/${BACKUP_NAME}'"
    ok "Backup created: ${BACKUP_NAME}"
else
    ok "Backup already exists: ${BACKUP_NAME}"
fi

# ── Step 6: Deploy ──────────────────────────────────────────────────────────
info "Deploying patched bundle..."
PATCHED_NAME="index-LINKIFIER.js"
copy_to "${tmp_dir}/patched.js" "${BUNDLE_DIR}/${PATCHED_NAME}"
ok "Deployed: ${PATCHED_NAME}"

# ── Step 7: Update index.html ───────────────────────────────────────────────
info "Updating index.html..."
CACHE_BUSTER="v=$(date +%s)"
exec_cmd "sed -i -E 's|src=\"\./assets/index-[^\"]+\"|src=\"./assets/${PATCHED_NAME}?${CACHE_BUSTER}\"|' '${INDEX_HTML}'"
ok "index.html updated (cache buster: ${CACHE_BUSTER})"

# ── Done ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Installation complete!${NC}"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  Bundle:  ${PATCHED_NAME}?${CACHE_BUSTER}"
echo -e "  Backup:  ${BACKUP_NAME}"
echo -e "  Pattern: ${PATTERN:-"(custom regex)"}"
echo -e "  Action:  ${URL_TEMPLATE:-"Copy to clipboard"}"
echo -e "  Color:   ${COLOR}"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e "  Reload Termix in your browser (Ctrl+Shift+R) to activate."
echo ""
echo -e "  To uninstall:"
if $LOCAL_MODE; then
    echo -e "  ${CYAN}./uninstall.sh --local --bundle-dir ${BUNDLE_DIR} --index-html ${INDEX_HTML}${NC}"
else
    echo -e "  ${CYAN}./uninstall.sh --container ${CONTAINER}${NC}"
fi
echo ""
