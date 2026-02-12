# termix-linkifier

Make any text pattern clickable in [Termix](https://github.com/nickadam/termix) and other xterm.js-based web terminals.

Matched patterns get a persistent colored underline and become clickable -- opening a URL or copying to clipboard.

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

termix-linkifier patches the minified xterm.js bundle inside your Termix installation to inject:

1. **A custom Link Provider** that detects your text pattern and makes matches clickable
2. **Persistent Decorations** that draw colored underlines beneath matched text (not just on hover)

The patch hooks into xterm.js's `WebLinksAddon.activate()` method -- the same code path that makes `http://` URLs clickable. This ensures correct coordinate handling and native terminal rendering.

### What gets modified

- The main JavaScript bundle (e.g. `assets/index-D97JNeu.js`) is copied to `index-LINKIFIER.js` with the patch applied
- `index.html` is updated to load the patched bundle (with a cache-busting query string)
- The original bundle is backed up as `*.bak` for easy uninstall

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

### Docker Mode (default)

| Option | Default | Description |
|--------|---------|-------------|
| `--container NAME` | `termix` | Docker container name |
| `--bundle-dir PATH` | `/app/html/assets` | Asset directory inside container |
| `--index-html PATH` | `/app/html/index.html` | index.html path inside container |

### Local Mode

| Option | Description |
|--------|-------------|
| `--local` | Work directly on filesystem instead of Docker |
| `--bundle-dir PATH` | Asset directory on local filesystem |
| `--index-html PATH` | index.html on local filesystem |

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

### Local installation (no Docker)

```bash
./install.sh --local \
  --bundle-dir /srv/termix/html/assets \
  --index-html /srv/termix/html/index.html \
  --pattern '/home/' \
  --clipboard
```

## Uninstall

```bash
# Docker mode
./uninstall.sh --container termix

# Local mode
./uninstall.sh --local --bundle-dir /path/to/assets --index-html /path/to/index.html
```

This restores the original bundle from backup and updates `index.html`.

## Compatibility

| Component | Tested Version |
|-----------|---------------|
| Termix | 1.11.0 |
| xterm.js | 5.x (with WebLinksAddon) |
| Browser | Chromium-based (Chrome, Brave, Edge) |
| Python | 3.6+ |
| Bash | 4.0+ |
| Docker | 20.0+ |

Should work with any web terminal that uses xterm.js with the `@xterm/addon-web-links` package.

## Requirements

- **Python 3** (for the patcher -- available on most systems)
- **Docker CLI** (for container mode) or direct filesystem access (`--local`)
- **Bash 4+**

## Technical Details

The patcher finds this specific code pattern in the minified xterm.js bundle:

```
this._linkProvider=this._terminal.registerLinkProvider(
  new s.WebLinkProvider(this._terminal,h,this._handler,p)
)}dispose
```

It injects a custom `registerLinkProvider` call (using xterm.js's native API) and optional `registerDecoration` calls for persistent visual highlighting.

Key technical insights discovered during development:

- `provideLinks(lineNumber)` passes **1-based** line numbers, but `buffer.getLine()` expects **0-based** indices
- xterm.js's built-in `WebLinkProvider` validates matches with `new URL()`, so it only works for actual URLs -- custom patterns need a raw link provider
- `registerMarker(offset)` requires `bufferLine - (baseY + cursorY)` as the offset parameter
- `WebLinkProvider.computeLink` internally appends the `g` regex flag, so never pass a regex that already has it

## License

Public Domain ([The Unlicense](https://unlicense.org)). Use it however you want.

## Credits

Built by the [RASSELBANDE](https://github.com/stlas) -- a collaborative AI development team.
