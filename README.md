# termix-linkifier

Make any text pattern clickable in [Termix](https://github.com/lukegus/termix) and other xterm.js-based web terminals.

Matched patterns get a persistent colored underline and become clickable — opening a URL or copying to clipboard.

## Quick Start

```bash
git clone https://github.com/stlas/termix-linkifier.git
cd termix-linkifier

# Make /opt/shared/ paths clickable (copies to clipboard)
./install.sh --container termix --pattern '/opt/shared/'

# Make /var/log/ paths open in a web viewer
./install.sh --container termix --pattern '/var/log/' \
  --url 'http://logviewer.example.com/?file={path}'
```

Reload Termix in your browser (`Ctrl+Shift+R`). Done.

## How It Works

**v2.0** uses nginx `sub_filter` injection — a clean, stable approach that **survives Termix updates**:

1. A standalone `linkifier.js` is deployed to the assets directory
2. nginx's `sub_filter` injects a `<script>` tag into every HTML response (before `</body>`)
3. The script discovers xterm.js Terminal instances via DOM observation
4. It registers a **custom Link Provider** (using xterm.js's official API) that detects your text pattern
5. **Persistent Decorations** draw colored underlines beneath matched text

### Why nginx sub_filter?

| | v1 (Bundle Patching) | v2 (nginx sub_filter) |
|---|---|---|
| Survives updates | No — patch is lost | **Yes** — separate file + nginx config |
| Risk of breakage | **High** — modifies minified JS | None — no bundle modification |
| Injection method | sed/python on 11MB bundle | nginx injects `<script>` tag |
| Cleanup | Restore backup bundle | Remove 3 nginx lines |

### What gets deployed

- `assets/linkifier.js` — standalone script (no dependencies)
- A `sub_filter` block in `nginx.conf` (between marker comments)
- Backup of original `nginx.conf` as `nginx.conf.pre-linkifier`

## Usage

```
./install.sh [OPTIONS]
```

### Required

| Option | Description |
|--------|-------------|
| `--pattern TEXT` | Text prefix to match (e.g. `/opt/shared/`, `JIRA-`, `/var/log/`) |

### Click Action

| Option | Description |
|--------|-------------|
| `--clipboard` | Copy matched text to clipboard (default) |
| `--url TEMPLATE` | Open URL on click. Use `{path}` as placeholder for the matched text |

### Docker

| Option | Default | Description |
|--------|---------|-------------|
| `--container NAME` | `termix` | Docker container name |
| `--nginx-conf PATH` | `/app/nginx/nginx.conf` | nginx.conf path inside container |
| `--html-dir PATH` | `/app/html` | HTML directory inside container |

### Appearance

| Option | Default | Description |
|--------|---------|-------------|
| `--color HEX` | `#4fc3f7` | Color of the persistent underline |
| `--no-decoration` | | Disable persistent underline (links still work on hover) |

### Advanced

| Option | Description |
|--------|-------------|
| `--regex REGEX` | Custom JavaScript regex instead of auto-generated from `--pattern` |
| `--dry-run` | Preview what would happen without making changes |

## Examples

### File paths to web viewer

```bash
./install.sh --container termix \
  --pattern '/opt/shared/' \
  --url 'http://viewer.example.com/?file={path}' \
  --color '#4fc3f7'
```

### JIRA ticket numbers

```bash
./install.sh --container termix \
  --pattern 'JIRA-' \
  --url 'https://jira.example.com/browse/{path}' \
  --color '#ff9800'
```

### Error codes with custom regex

```bash
./install.sh --container termix \
  --regex 'ERR-[0-9]{3,6}' \
  --url 'https://docs.example.com/errors/{path}' \
  --color '#ef5350'
```

## After a Termix Update

With v2.0, **most updates preserve the linkifier automatically**:

- If only the JS bundle changes → linkifier keeps working (it's a separate file)
- If nginx.conf is regenerated → re-run `install.sh` with the same parameters

```bash
# Re-apply after update (if needed)
./install.sh --container termix --pattern '/opt/shared/' \
  --url 'http://viewer.example.com/?file={path}'
```

## Uninstall

```bash
./uninstall.sh --container termix
```

This removes the nginx sub_filter block, deletes `linkifier.js`, and reloads nginx. Also handles legacy v1 bundle patches if present.

## Compatibility

| Component | Tested Version |
|-----------|---------------|
| Termix | 2.0.0 |
| xterm.js | 5.x (`@xterm/xterm`) |
| Browser | Chromium-based (Chrome, Brave, Edge) |
| nginx | With `http_sub_module` (standard in Termix) |
| Python | 3.6+ |
| Bash | 4.0+ |
| Docker | 20.0+ |

Should work with any web terminal that uses xterm.js and serves HTML via nginx.

## Technical Details

### Terminal Discovery

Since Termix bundles xterm.js (it's not loaded as a separate script), the linkifier discovers Terminal instances through multiple strategies:

1. **DOM Observation** — a MutationObserver watches for elements with the `xterm` CSS class
2. **CSS Class Hook** — intercepts `DOMTokenList.add("xterm")` to detect the exact moment a terminal is created
3. **React Fiber Walking** — traverses the React component tree to find the Terminal instance from DOM elements

### Link Provider

Uses xterm.js's official `registerLinkProvider()` API:

- `provideLinks(lineNumber)` receives **1-based** line numbers; `buffer.getLine()` is **0-based**
- Fast-path: lines without the prefix pattern are skipped immediately
- Trailing dots are stripped from matches (e.g. `/opt/shared/file.md.` → `/opt/shared/file.md`)

### Decorations

- `registerMarker(offset)` uses `bufferLine - (baseY + cursorY)` as offset
- Decorations are cached per buffer line and disposed when content changes
- Old decorations (>200 lines above viewport) are garbage-collected

## Migrating from v1

v2's `install.sh` automatically detects and removes v1 artifacts:

- Restores `index.html` to the original bundle (removes `index-LINKIFIER.js` reference)
- Deletes the patched `index-LINKIFIER.js` file

No manual migration needed — just run the new `install.sh`.

## Requirements

- **Python 3** (for the nginx config patcher)
- **Docker CLI**
- **Bash 4+**

## License

Public Domain ([The Unlicense](https://unlicense.org)). Use it however you want.

## Credits

Built by the [RASSELBANDE](https://github.com/stlas) — a collaborative AI development team.
