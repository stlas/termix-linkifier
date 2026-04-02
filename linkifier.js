// ============================================================================
// termix-linkifier v2.0.0 — Standalone xterm.js Link Provider
//
// Injected via nginx sub_filter — no bundle patching required.
// Waits for xterm.js Terminal instances, then registers a custom LinkProvider
// that makes matching text patterns clickable.
//
// Configuration is read from window.__LINKIFIER_CONFIG__ (set by install.sh
// via an inline <script> before this file loads).
//
// Public Domain — The Unlicense
// https://github.com/stlas/termix-linkifier
// ============================================================================
(function () {
  "use strict";

  var CFG = window.__LINKIFIER_CONFIG__;
  if (!CFG) {
    console.warn("[termix-linkifier] No config found (window.__LINKIFIER_CONFIG__). Skipping.");
    return;
  }

  var REGEX = new RegExp(CFG.regex, "g");
  var COLOR = CFG.color || "#4fc3f7";
  var PREFIX = CFG.prefix || "";
  var USE_DECORATION = CFG.decoration !== false;

  // Click handler: open URL or copy to clipboard
  function handleClick(_event, text) {
    var clean = text.replace(/[.]+$/, "");
    if (CFG.url) {
      var u = CFG.url.replace("{path}", encodeURIComponent(clean));
      window.open(u, "_blank");
    } else {
      navigator.clipboard.writeText(clean).then(function () {
        showToast("Copied: " + clean);
      });
    }
  }

  function showToast(msg) {
    var el = document.createElement("div");
    el.textContent = msg;
    el.style.cssText =
      "position:fixed;bottom:20px;right:20px;background:#333;color:#fff;" +
      "padding:8px 16px;border-radius:6px;font-size:13px;z-index:99999;" +
      "opacity:0;transition:opacity 0.3s";
    document.body.appendChild(el);
    setTimeout(function () { el.style.opacity = "1"; }, 10);
    setTimeout(function () {
      el.style.opacity = "0";
      setTimeout(function () { el.remove(); }, 300);
    }, 2000);
  }

  // ── LinkProvider (official xterm.js API) ──────────────────────────────────
  function createLinkProvider(terminal) {
    return {
      provideLinks: function (lineNumber, callback) {
        try {
          var line = terminal.buffer.active.getLine(lineNumber - 1);
          if (!line) { callback(undefined); return; }
          var text = line.translateToString();

          // Fast path: skip lines without prefix
          if (PREFIX && text.indexOf(PREFIX) === -1) {
            callback(undefined);
            return;
          }

          var links = [];
          var match;
          REGEX.lastIndex = 0;
          while ((match = REGEX.exec(text)) !== null) {
            var mt = match[0].replace(/[.]+$/, "");
            links.push({
              range: {
                start: { x: match.index + 1, y: lineNumber },
                end: { x: match.index + mt.length, y: lineNumber }
              },
              text: mt,
              activate: handleClick
            });
          }
          callback(links.length > 0 ? links : undefined);
        } catch (e) {
          callback(undefined);
        }
      }
    };
  }

  // ── Decoration Manager (persistent underlines) ────────────────────────────
  function setupDecorations(terminal) {
    var cache = {};
    var running = false;

    function scan() {
      if (running) return;
      running = true;
      try {
        var rows = terminal.rows;
        var base = terminal.buffer.active.baseY;
        var cursorY = terminal.buffer.active.cursorY;
        var currentBase = base + cursorY;

        for (var i = 0; i < rows; i++) {
          var bufLine = base + i;
          var line = terminal.buffer.active.getLine(bufLine);
          if (!line) continue;
          var text = line.translateToString();

          // Check if cached entry is stale
          if (cache[bufLine]) {
            if (PREFIX && text.indexOf(PREFIX) !== -1) continue;
            // Dispose stale decorations
            cache[bufLine].forEach(function (d) { try { d.dispose(); } catch (e) {} });
            delete cache[bufLine];
            if (PREFIX) continue; // no prefix = no match
          }

          if (PREFIX && text.indexOf(PREFIX) === -1) continue;
          if (cache[bufLine]) continue;

          var decorations = [];
          var match;
          REGEX.lastIndex = 0;
          while ((match = REGEX.exec(text)) !== null) {
            var mt = match[0].replace(/[.]+$/, "");
            var marker = terminal.registerMarker(bufLine - currentBase);
            if (!marker) continue;
            var dec = terminal.registerDecoration({
              marker: marker,
              x: match.index,
              width: mt.length,
              layer: "top"
            });
            if (dec) {
              (function (color) {
                dec.onRender(function (el) {
                  el.style.borderBottom = "2px solid " + color;
                  el.style.pointerEvents = "none";
                });
              })(COLOR);
              decorations.push(dec);
            }
          }
          if (decorations.length > 0) cache[bufLine] = decorations;
        }

        // Cleanup old entries far above viewport
        var keys = Object.keys(cache);
        for (var j = 0; j < keys.length; j++) {
          var k = parseInt(keys[j]);
          if (k < base - 200) {
            cache[k].forEach(function (d) { try { d.dispose(); } catch (e) {} });
            delete cache[k];
          }
        }
      } catch (e) {
        // silently ignore
      } finally {
        running = false;
      }
    }

    terminal.onRender(function () { scan(); });
    setTimeout(function () { scan(); }, 1000);
  }

  // ── Terminal Discovery ────────────────────────────────────────────────────
  // xterm.js creates Terminal instances that get .open(container) called.
  // We hook into the DOM to detect when xterm terminals appear.
  var attached = new WeakSet();

  function tryAttach(terminal) {
    if (attached.has(terminal)) return;
    attached.add(terminal);

    terminal.registerLinkProvider(createLinkProvider(terminal));
    if (USE_DECORATION) {
      setupDecorations(terminal);
    }
    console.log("[termix-linkifier] Attached to terminal instance");
  }

  // Strategy: observe DOM for xterm containers, then find Terminal via
  // the React fiber or the xterm internal reference on the DOM element.
  function findTerminalFromElement(el) {
    // xterm.js stores a reference on the container element
    if (el._core && el._core._terminal) return el._core._terminal;
    // Some versions store it differently
    if (el.terminal) return el.terminal;

    // Walk React fiber tree to find Terminal instance
    var fiberKey = Object.keys(el).find(function (k) {
      return k.startsWith("__reactFiber$") || k.startsWith("__reactInternalInstance$");
    });
    if (!fiberKey) return null;

    var fiber = el[fiberKey];
    var maxDepth = 30;
    while (fiber && maxDepth-- > 0) {
      if (fiber.memoizedProps) {
        var props = fiber.memoizedProps;
        // react-xtermjs passes terminal via ref or props
        if (props.terminal && props.terminal.registerLinkProvider) return props.terminal;
      }
      if (fiber.stateNode && fiber.stateNode.terminal &&
          fiber.stateNode.terminal.registerLinkProvider) {
        return fiber.stateNode.terminal;
      }
      fiber = fiber.return;
    }
    return null;
  }

  function scanForTerminals() {
    // xterm.js adds class "xterm" to its container
    var containers = document.querySelectorAll(".xterm");
    containers.forEach(function (el) {
      // The actual Terminal object is on the element with class "xterm"
      // that has a child with class "xterm-screen"
      if (!el.querySelector(".xterm-screen")) return;

      var term = findTerminalFromElement(el);
      if (term) tryAttach(term);
    });
  }

  // Observe DOM for new terminal instances
  var observer = new MutationObserver(function (mutations) {
    for (var i = 0; i < mutations.length; i++) {
      var added = mutations[i].addedNodes;
      for (var j = 0; j < added.length; j++) {
        var node = added[j];
        if (node.nodeType !== 1) continue;
        if (node.classList && node.classList.contains("xterm")) {
          setTimeout(scanForTerminals, 500);
          return;
        }
        if (node.querySelector && node.querySelector(".xterm")) {
          setTimeout(scanForTerminals, 500);
          return;
        }
      }
    }
  });

  // ── Fallback: Hook into Terminal.prototype.open ───────────────────────────
  // This is the most reliable approach: intercept Terminal.open() calls
  function hookTerminalPrototype() {
    // xterm.js may already be loaded — check global
    if (window.Terminal && window.Terminal.prototype) {
      patchOpen(window.Terminal.prototype);
      return;
    }

    // For bundled xterm.js (Termix bundles it), we need to intercept
    // the constructor. We do this by patching Element.prototype.classList
    // to detect when xterm adds its CSS class, then find the terminal.
    var origAdd = DOMTokenList.prototype.add;
    var patched = false;
    DOMTokenList.prototype.add = function () {
      origAdd.apply(this, arguments);
      if (!patched && arguments[0] === "xterm") {
        patched = true;
        DOMTokenList.prototype.add = origAdd; // restore immediately
        // Terminal was just opened — scan after a short delay
        setTimeout(scanForTerminals, 300);
        // Keep scanning periodically for new terminals
        setInterval(scanForTerminals, 3000);
      }
    };
  }

  function patchOpen(proto) {
    var origOpen = proto.open;
    proto.open = function (container) {
      origOpen.call(this, container);
      var self = this;
      setTimeout(function () { tryAttach(self); }, 100);
    };
  }

  // ── Start ─────────────────────────────────────────────────────────────────
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", function () {
      hookTerminalPrototype();
      observer.observe(document.body, { childList: true, subtree: true });
    });
  } else {
    hookTerminalPrototype();
    observer.observe(document.body, { childList: true, subtree: true });
  }

  console.log("[termix-linkifier] v2.0.0 loaded — pattern: " + (PREFIX || CFG.regex));
})();
