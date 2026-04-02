// ============================================================================
// termix-linkifier v2.1.0 — DOM-based Terminal Link Injector
//
// Scans rendered xterm.js terminal output and makes matching text patterns
// clickable by adding overlay elements. Works with any xterm.js version
// without needing access to the Terminal API.
//
// Configuration is read from window.__LINKIFIER_CONFIG__.
//
// Public Domain — The Unlicense
// https://github.com/stlas/termix-linkifier
// ============================================================================
(function () {
  "use strict";

  var CFG = window.__LINKIFIER_CONFIG__;
  if (!CFG) {
    console.warn("[termix-linkifier] No config found. Skipping.");
    return;
  }

  var REGEX = new RegExp(CFG.regex, "g");
  var COLOR = CFG.color || "#4fc3f7";
  var PREFIX = CFG.prefix || "";

  console.log("[termix-linkifier] v2.1.0 loaded — pattern: " + (PREFIX || CFG.regex));

  // ── Click handler ─────────────────────────────────────────────────────────
  function handleClick(text) {
    var clean = text.replace(/[.,:;!?)}\]]+$/, "");
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

  // ── Overlay Manager ───────────────────────────────────────────────────────
  // Creates invisible clickable overlays positioned exactly over matched text.
  // We use overlays instead of modifying the DOM because xterm.js manages
  // its own rendering and would overwrite any changes.

  var overlayContainer = null;
  var scanTimer = null;
  var lastScanKey = "";

  function ensureOverlayContainer(xtermEl) {
    // Find the xterm-screen element (the actual rendered area)
    var screen = xtermEl.querySelector(".xterm-screen");
    if (!screen) return null;

    var existing = screen.querySelector(".linkifier-overlays");
    if (existing) return existing;

    var container = document.createElement("div");
    container.className = "linkifier-overlays";
    container.style.cssText =
      "position:absolute;top:0;left:0;right:0;bottom:0;" +
      "pointer-events:none;z-index:10;overflow:hidden;";
    screen.style.position = "relative";
    screen.appendChild(container);
    return container;
  }

  function scanTerminal(xtermEl) {
    var container = ensureOverlayContainer(xtermEl);
    if (!container) return;

    // Get all rendered rows
    var rows = xtermEl.querySelectorAll(".xterm-rows > div");
    if (!rows.length) return;

    // Build a scan key to avoid unnecessary re-scans
    var scanKey = "";
    var rowTexts = [];
    for (var i = 0; i < rows.length; i++) {
      var text = rows[i].textContent || "";
      rowTexts.push(text);
      if (PREFIX && text.indexOf(PREFIX) !== -1) {
        scanKey += i + ":" + text + "|";
      }
    }

    if (scanKey === lastScanKey) return; // nothing changed
    lastScanKey = scanKey;

    // Clear old overlays
    container.innerHTML = "";

    if (!scanKey) return; // no matches possible

    var screenRect = container.getBoundingClientRect();

    // Scan each row for matches
    for (var r = 0; r < rows.length; r++) {
      var rowText = rowTexts[r];
      if (PREFIX && rowText.indexOf(PREFIX) === -1) continue;

      REGEX.lastIndex = 0;
      var match;
      while ((match = REGEX.exec(rowText)) !== null) {
        var matchText = match[0].replace(/[.,:;!?)}\]]+$/, "");
        var startIdx = match.index;
        var endIdx = startIdx + matchText.length;

        // Use Range API to get exact pixel position of matched text
        var range = document.createRange();
        var textPos = 0;
        var startNode = null, startOffset = 0, endNode = null, endOffset = 0;
        var childNodes = rows[r].childNodes;

        for (var c = 0; c < childNodes.length; c++) {
          var node = childNodes[c];
          var nodeText = node.textContent || "";
          var nodeLen = nodeText.length;

          if (!startNode && textPos + nodeLen > startIdx) {
            startNode = node.firstChild || node;
            startOffset = startIdx - textPos;
          }
          if (!endNode && textPos + nodeLen >= endIdx) {
            endNode = node.firstChild || node;
            endOffset = endIdx - textPos;
            break;
          }
          textPos += nodeLen;
        }

        if (!startNode || !endNode) continue;

        try {
          range.setStart(startNode, startOffset);
          range.setEnd(endNode, endOffset);
        } catch (e) { continue; }

        var rects = range.getClientRects();
        if (!rects.length) continue;

        // Create overlay for each rect (handles line wrapping)
        for (var ri = 0; ri < rects.length; ri++) {
          var rect = rects[ri];
          if (rect.width < 2) continue;

          var left = rect.left - screenRect.left;
          var top = rect.top - screenRect.top;

          var overlay = document.createElement("a");
          overlay.className = "linkifier-link";
          overlay.title = matchText;
          overlay.dataset.path = matchText;
          overlay.style.cssText =
            "position:absolute;pointer-events:auto;cursor:pointer;" +
            "border-bottom:2px solid " + COLOR + ";" +
            "left:" + left + "px;" +
            "top:" + top + "px;" +
            "width:" + rect.width + "px;" +
            "height:" + rect.height + "px;" +
            "opacity:0.15;background:transparent;" +
            "transition:opacity 0.15s;display:block;";
        }

        overlay.addEventListener("mouseenter", function () {
          this.style.opacity = "0.35";
          this.style.background = COLOR;
        });
        overlay.addEventListener("mouseleave", function () {
          this.style.opacity = "0.15";
          this.style.background = "transparent";
        });
        overlay.addEventListener("click", (function (txt) {
          return function (e) {
            e.preventDefault();
            e.stopPropagation();
            handleClick(txt);
          };
        })(matchText));

        container.appendChild(overlay);
      }
    }
  }


  // ── Terminal Discovery & Scanning Loop ────────────────────────────────────

  function scanAllTerminals() {
    var terminals = document.querySelectorAll(".xterm");
    for (var i = 0; i < terminals.length; i++) {
      var term = terminals[i];
      if (!term.querySelector(".xterm-screen")) continue;
      scanTerminal(term);
    }
  }

  // Debounced scan
  function scheduleScan() {
    if (scanTimer) clearTimeout(scanTimer);
    scanTimer = setTimeout(scanAllTerminals, 200);
  }

  // ── Start observing ───────────────────────────────────────────────────────

  function init() {
    // Observe DOM for xterm containers and content changes
    var observer = new MutationObserver(function (mutations) {
      var dominated = false;
      for (var i = 0; i < mutations.length; i++) {
        var target = mutations[i].target;
        // Check if mutation is inside an xterm container
        if (target.closest && target.closest(".xterm")) {
          dominated = true;
          break;
        }
        // Check for new xterm containers
        var added = mutations[i].addedNodes;
        for (var j = 0; j < added.length; j++) {
          var node = added[j];
          if (node.nodeType !== 1) continue;
          if ((node.classList && node.classList.contains("xterm")) ||
              (node.querySelector && node.querySelector(".xterm"))) {
            dominated = true;
            break;
          }
        }
        if (dominated) break;
      }
      if (dominated) scheduleScan();
    });

    observer.observe(document.body, {
      childList: true,
      subtree: true,
      characterData: true
    });

    // Also scan periodically (catches scrolling, new output)
    setInterval(scanAllTerminals, 1500);

    // Initial scan after app loads
    setTimeout(scanAllTerminals, 2000);
    setTimeout(scanAllTerminals, 5000);

    console.log("[termix-linkifier] DOM observer active, scanning every 1.5s");
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
