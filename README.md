# termix-linkifier

Make any text pattern clickable in [Termix](https://github.com/lukegus/termix) and other xterm.js-based web terminals.

Matched patterns get a colored underline and become clickable — opening a URL or copying to clipboard.

![Screenshot showing clickable file paths in a Termix terminal](https://img.shields.io/badge/v2.1.0-stable-brightgreen)

## Quick Start

```bash
git clone https://github.com/stlas/termix-linkifier.git
cd termix-linkifier

# Make /opt/shared/ paths open in a web viewer
./install.sh --container termix --pattern '/opt/shared/' \
  --url 'http://viewer.example.com/?file={path}'

# Or just copy paths to clipboard on click
./install.sh --container termix --pattern '/var/log/'
```

Reload Termix in your browser (`Ctrl+Shift+R`). Done.

## How It Works

The linkifier runs as a standalone JavaScript file inside Termix — **no bundle patching, no nginx modification**.

1. `linkifier.js` and `linkifier-config.js` are deployed to the Docker host and **volume-mounted** into the container
2. Two `<script>` tags are added to `index.html` (before `</head>`)
3. A **MutationObserver** detects when xterm.js terminals appear in the DOM
4. A **periodic scanner** (every 1.5s) checks rendered terminal rows for pattern matches
5. The **Range API** calculates the exact pixel position of matched text
6. Transparent **overlay elements** are placed on top of matches — clickable, with a colored underline

### Version History

| Version | Method | Stability |
|---------|--------|-----------|
| v1.0 | Bundle patching (sed on minified JS) | Fragile — breaks on every update |
| v2.0 | nginx `sub_filter` injection | Unstable — nginx crashes on reload |
| **v2.1** | **Docker volume mount + index.html** | **Stable** — survives updates |

### What gets deployed

```
Host filesystem (/opt/termix-linkifier/):
  linkifier.js          ← volume-mounted into container (read-only)
  linkifier-config.js   ← volume-mounted into container (read-only)

Inside container (/app/html/):
  index.html            ← two <script> tags added before </head>
```

## Usage

```
./install.sh [OPTIONS]
```

### Required

| Option | Description |
|--------|-------------|
| `--pattern TEXT` | Text prefix to match (e.g. `/opt/shared/`, `JIRA-`, `/var/log/`) |

### Click Action (pick one)

| Option | Description |
|--------|-------------|
| `--clipboard` | Copy matched text to clipboard (default) |
| `--url TEMPLATE` | Open URL on click. Use `{path}` as placeholder |

### Docker Options

| Option | Default | Description |
|--------|---------|-------------|
| `--container NAME` | `termix` | Docker container name |
| `--html-dir PATH` | `/app/html` | HTML directory inside container |
| `--host-dir PATH` | `/opt/termix-linkifier` | Host directory for persistent files |

### Appearance

| Option | Default | Description |
|--------|---------|-------------|
| `--color HEX` | `#4fc3f7` | Color of the underline and hover highlight |

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

Volume-mounted files (`linkifier.js`, `linkifier-config.js`) persist across updates automatically. Only `index.html` needs to be re-patched after an image update:

```bash
# Re-run after docker pull / image update
./install.sh --container termix --pattern '/opt/shared/' \
  --url 'http://viewer.example.com/?file={path}'
```

The installer detects existing volume mounts and only re-adds the `<script>` tags if missing.

## Uninstall

```bash
./uninstall.sh --container termix
```

This removes the script tags from `index.html`, deletes the linkifier files, and handles legacy v1/v2.0 artifacts.

## Compatibility

| Component | Tested Version |
|-----------|---------------|
| Termix | 2.0.0 |
| xterm.js | 5.x (`@xterm/xterm`) |
| Browser | Chromium-based (Chrome, Brave, Edge) |
| Python | 3.6+ (for config generation) |
| Bash | 4.0+ |
| Docker | 20.0+ |

Should work with any web terminal that uses xterm.js and renders text in `.xterm-rows` DOM elements.

## Technical Details

### Text Detection

The scanner runs every 1.5s and checks all visible terminal rows:

1. Gets `textContent` from each `.xterm-rows > div` element
2. Fast-path: skips rows that don't contain the prefix pattern
3. Runs the configured regex against matching rows
4. Strips trailing punctuation from matches (`.`, `,`, `)`, etc.)

### Pixel-Perfect Positioning with Range API

Previous versions calculated overlay positions using `charWidth * characterIndex` — this broke across different screen sizes, DPI settings, and xterm.js rendering modes (canvas vs DOM).

v2.1 uses the browser's **Range API** instead:

```javascript
var range = document.createRange();
range.setStart(textNode, matchStart);
range.setEnd(textNode, matchEnd);
var rect = range.getClientRects()[0];  // exact pixel coordinates
```

This gives pixel-perfect positioning regardless of:
- Font size, family, or rendering engine
- Canvas vs DOM renderer
- Screen DPI / zoom level
- Multi-monitor setups with different scaling

### Terminal Discovery

A `MutationObserver` watches the document for elements with the `.xterm` CSS class. When found, the scanner begins checking that terminal's rows for pattern matches.

### Overlay Architecture

Overlays are transparent `<a>` elements positioned absolutely inside `.xterm-screen`:

- `pointer-events: auto` makes them clickable
- `border-bottom: 2px solid <color>` creates the underline
- Hover effect changes opacity and adds background highlight
- The overlay container has `overflow: hidden` to clip at terminal edges

Overlays are re-created on every scan cycle to stay in sync with terminal content (scrolling, new output, resize).

## Requirements

- **Docker CLI** — to manage the Termix container
- **Python 3** — for config file generation
- **Bash 4+**

## License

Public Domain ([The Unlicense](https://unlicense.org)). Use it however you want.

## Credits

Built by the [RASSELBANDE](https://github.com/stlas) — a collaborative AI development team.
