// ============================================================================
// termix-linkifier v2.2.0 — DOM-based Terminal Link Injector
//
// Scans rendered xterm.js terminal output and makes matching text patterns
// clickable by adding overlay elements. Works with any xterm.js version
// without needing access to the Terminal API.
//
// v2.2.0:
//   - Multi-pattern support (config.patterns[]) alongside legacy single-pattern.
//   - Multi-line reassembly for wrapped URLs: a URL that hits the right edge and
//     continues on the next row is rejoined into one clickable/copyable link.
//     Fixes long `claude login` OAuth URLs truncated by Termix' own handler.
//   - Click on a URL opens it AND copies the full URL to the clipboard (fallback
//     when the popup is blocked).
//
// Configuration is read from window.__LINKIFIER_CONFIG__ (see normalizePatterns).
//
// Public Domain — The Unlicense
// https://github.com/stlas/termix-linkifier
// ============================================================================
(function () {
  "use strict";

  // ══════════════════════════════════════════════════════════════════════════
  //  PURE LOGIC (no DOM) — exported for node tests, see test/reassembly.test.js
  // ══════════════════════════════════════════════════════════════════════════

  // Charset a URL/path may continue with on a wrapped row (no whitespace, no
  // typical terminators). Used to grab the continuation run on the next row.
  var CONT_CHARS = /^[^\s"'<>)\]}|,;]+/;
  // Trailing punctuation stripped from a match before use (sentence-end etc.).
  var TRAILING = /[.,:;!?)}\]]+$/;

  function cleanTrail(s) {
    return s.replace(TRAILING, "");
  }

  // Normalize either the legacy single-pattern config or the new patterns[]
  // array into a uniform list of {name, regex, url, color, prefix, multiline}.
  function normalizePatterns(cfg) {
    if (cfg && cfg.patterns && cfg.patterns.length) {
      return cfg.patterns.map(function (p) {
        return {
          name: p.name || "pattern",
          regex: p.regex,
          url: p.url || null,
          color: p.color || "#4fc3f7",
          prefix: p.prefix || "",
          multiline: !!p.multiline
        };
      });
    }
    // Legacy: single {regex, url, prefix, color}
    return [{
      name: "legacy",
      regex: cfg.regex,
      url: cfg.url || null,
      color: cfg.color || "#4fc3f7",
      prefix: cfg.prefix || "",
      multiline: !!cfg.multiline
    }];
  }

  function contentLen(text) {
    return text.replace(/\s+$/, "").length; // length ignoring trailing spaces
  }

  // Terminal column count, inferred as the widest row's content. Hard-wrapped
  // rows fill to this width; the final row of a wrapped line is shorter.
  function inferCols(rowTexts) {
    var cols = 0;
    for (var i = 0; i < rowTexts.length; i++) {
      var n = contentLen(rowTexts[i]);
      if (n > cols) cols = n;
    }
    return cols;
  }

  // A row is hard-wrapped (its logical line continues below) iff its content
  // reaches the terminal's last column. The final row of a wrapped URL is
  // shorter than `cols` — that's what stops the reassembly.
  function isFullRow(text, cols) {
    return cols > 0 && contentLen(text) >= cols;
  }

  // Build the resolved target URL for a pattern + matched text.
  //   {match} → raw cleaned match (for URL patterns: the URL itself)
  //   {path}  → encodeURIComponent(cleaned match) (for viewer/tracker patterns)
  function resolveUrl(pattern, cleaned) {
    if (!pattern.url) return null;
    return pattern.url
      .replace("{match}", cleaned)
      .replace("{path}", encodeURIComponent(cleaned));
  }

  // Core: given the visible rendered row texts (array of strings, top→bottom),
  // the normalized patterns and a wrap-row cap, return all matches with the
  // exact per-row column segments they cover (for overlay positioning).
  //
  // Returns: [{ patternIndex, name, color, text, url, segments:[{row,start,end}] }]
  function findMatches(rowTexts, patterns, maxWrapRows) {
    maxWrapRows = maxWrapRows || 10;
    var cols = inferCols(rowTexts);
    var out = [];
    for (var r = 0; r < rowTexts.length; r++) {
      var rowText = rowTexts[r];
      if (!rowText) continue;
      for (var p = 0; p < patterns.length; p++) {
        var pat = patterns[p];
        // Cheap prefix pre-filter (skip rows that can't contain this pattern).
        if (pat.prefix && rowText.indexOf(pat.prefix) === -1) continue;
        var re = new RegExp(pat.regex, "g");
        var m;
        while ((m = re.exec(rowText)) !== null) {
          if (m[0].length === 0) { re.lastIndex++; continue; }
          var startCol = m.index;
          var endCol = startCol + m[0].length;
          var full = m[0];
          var segments = [{ row: r, start: startCol, end: endCol }];

          // ── Multi-line reassembly (URL-style patterns) ──────────────────
          // Only extend if THIS row is hard-wrapped (fills to the terminal
          // edge) and the match runs to that edge — i.e. the URL was cut by the
          // wrap, not ended by a space.
          if (pat.multiline && isFullRow(rowText, cols) && endCol >= contentLen(rowText)) {
            var cur = r;
            while (segments.length < maxWrapRows && cur + 1 < rowTexts.length) {
              var next = rowTexts[cur + 1];
              // A wrap continuation starts flush-left with URL-valid chars.
              // Leading space / empty row = a new logical line → stop.
              if (!next || /^\s/.test(next)) break;
              var cm = next.match(CONT_CHARS);
              if (!cm) break;
              var cont = cm[0];
              // A genuine continuation IS the whole row content. If there is
              // more text after the URL run (e.g. "Paste code here:"), this row
              // is a new logical line that merely starts URL-ish → stop, don't
              // swallow it. (Guards the exact-multiple-of-cols ambiguity.)
              if (cont.length !== contentLen(next)) break;
              full += cont;
              segments.push({ row: cur + 1, start: 0, end: cont.length });
              cur++;
              // If this continuation row is not itself full-width, the URL ended
              // here (last row of the wrap) → stop.
              if (!isFullRow(next, cols)) break;
            }
          }

          var cleaned = cleanTrail(full);
          out.push({
            patternIndex: p,
            name: pat.name,
            color: pat.color,
            text: cleaned,
            url: resolveUrl(pat, cleaned),
            segments: segments
          });
          // Advance regex past this row-match to avoid overlap loops.
          re.lastIndex = endCol;
        }
      }
    }
    return out;
  }

  // Export pure logic for node-based unit tests.
  if (typeof module !== "undefined" && module.exports) {
    module.exports = {
      normalizePatterns: normalizePatterns,
      inferCols: inferCols,
      isFullRow: isFullRow,
      resolveUrl: resolveUrl,
      cleanTrail: cleanTrail,
      findMatches: findMatches
    };
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  DOM INTEGRATION (browser only)
  // ══════════════════════════════════════════════════════════════════════════

  if (typeof window === "undefined" || typeof document === "undefined") return;

  var CFG = window.__LINKIFIER_CONFIG__;
  if (!CFG) {
    console.warn("[termix-linkifier] No config found. Skipping.");
    return;
  }

  var PATTERNS = normalizePatterns(CFG);
  var MAX_WRAP = CFG.maxWrapRows || 10;

  console.log(
    "[termix-linkifier] v2.2.0 loaded — " + PATTERNS.length + " pattern(s): " +
    PATTERNS.map(function (p) { return p.name; }).join(", ")
  );

  // ── Activation (click) ────────────────────────────────────────────────────
  function activate(pattern, text) {
    var cleaned = cleanTrail(text);
    if (pattern.url) {
      var u = resolveUrl(pattern, cleaned);
      // Open in a new tab; ALSO copy so a blocked popup still leaves the link
      // in the clipboard (fixes truncated Strg+C on wrapped URLs).
      var opened = window.open(u, "_blank", "noopener");
      copy(cleaned, opened ? "Link geöffnet + kopiert" : "Link kopiert (Popup blockiert)");
    } else {
      copy(cleaned, "Kopiert: " + cleaned);
    }
  }

  function copy(text, toastMsg) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(function () {
        showToast(toastMsg);
      }, function () {
        showToast("Kopieren fehlgeschlagen");
      });
    } else {
      showToast(toastMsg);
    }
  }

  function showToast(msg) {
    var el = document.createElement("div");
    el.textContent = msg;
    el.style.cssText =
      "position:fixed;bottom:20px;right:20px;background:#333;color:#fff;" +
      "padding:8px 16px;border-radius:6px;font-size:13px;z-index:99999;" +
      "opacity:0;transition:opacity 0.3s;max-width:60vw;overflow:hidden;" +
      "text-overflow:ellipsis;white-space:nowrap;";
    document.body.appendChild(el);
    setTimeout(function () { el.style.opacity = "1"; }, 10);
    setTimeout(function () {
      el.style.opacity = "0";
      setTimeout(function () { el.remove(); }, 300);
    }, 2000);
  }

  // ── Overlay Manager ───────────────────────────────────────────────────────
  var scanTimer = null;
  var lastScanKey = "";

  function ensureOverlayContainer(xtermEl) {
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

  // Position one overlay rect over rows[rowDiv] chars [startIdx, endIdx).
  function placeSegment(rowDiv, startIdx, endIdx, screenRect, container, res) {
    var range = document.createRange();
    var textPos = 0, startNode = null, startOffset = 0, endNode = null, endOffset = 0;
    var childNodes = rowDiv.childNodes;
    for (var c = 0; c < childNodes.length; c++) {
      var node = childNodes[c];
      var nodeLen = (node.textContent || "").length;
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
    if (!startNode || !endNode) return;
    try {
      range.setStart(startNode, startOffset);
      range.setEnd(endNode, endOffset);
    } catch (e) { return; }

    var rects = range.getClientRects();
    for (var ri = 0; ri < rects.length; ri++) {
      var rect = rects[ri];
      if (rect.width < 2) continue;
      var overlay = document.createElement("a");
      overlay.className = "linkifier-link";
      overlay.title = res.text;
      overlay.dataset.linkifierText = res.text;
      overlay.style.cssText =
        "position:absolute;pointer-events:auto;cursor:pointer;" +
        "border-bottom:2px solid " + res.color + ";" +
        "left:" + (rect.left - screenRect.left) + "px;" +
        "top:" + (rect.top - screenRect.top) + "px;" +
        "width:" + rect.width + "px;" +
        "height:" + rect.height + "px;" +
        "opacity:0.15;background:transparent;" +
        "transition:opacity 0.15s;display:block;";
      overlay.addEventListener("mouseenter", (function (color) {
        return function () { this.style.opacity = "0.35"; this.style.background = color; };
      })(res.color));
      overlay.addEventListener("mouseleave", function () {
        this.style.opacity = "0.15"; this.style.background = "transparent";
      });
      overlay.addEventListener("click", (function (r2) {
        return function (e) {
          e.preventDefault(); e.stopPropagation();
          activate(PATTERNS[r2.patternIndex], r2.text);
        };
      })(res));
      container.appendChild(overlay);
    }
  }

  function scanTerminal(xtermEl) {
    var container = ensureOverlayContainer(xtermEl);
    if (!container) return;
    var rows = xtermEl.querySelectorAll(".xterm-rows > div");
    if (!rows.length) return;

    var rowTexts = [];
    for (var i = 0; i < rows.length; i++) rowTexts.push(rows[i].textContent || "");

    var scanKey = rowTexts.join("\n");
    if (scanKey === lastScanKey) return;
    lastScanKey = scanKey;

    container.innerHTML = "";
    var matches = findMatches(rowTexts, PATTERNS, MAX_WRAP);
    if (!matches.length) return;

    var screenRect = container.getBoundingClientRect();
    for (var mi = 0; mi < matches.length; mi++) {
      var res = matches[mi];
      for (var si = 0; si < res.segments.length; si++) {
        var seg = res.segments[si];
        if (seg.row >= rows.length) continue;
        placeSegment(rows[seg.row], seg.start, seg.end, screenRect, container, res);
      }
    }
  }

  // ── Terminal Discovery & Scanning Loop ────────────────────────────────────
  function scanAllTerminals() {
    var terminals = document.querySelectorAll(".xterm");
    for (var i = 0; i < terminals.length; i++) {
      if (!terminals[i].querySelector(".xterm-screen")) continue;
      scanTerminal(terminals[i]);
    }
  }

  function scheduleScan() {
    if (scanTimer) clearTimeout(scanTimer);
    scanTimer = setTimeout(scanAllTerminals, 200);
  }

  function init() {
    var observer = new MutationObserver(function (mutations) {
      for (var i = 0; i < mutations.length; i++) {
        var target = mutations[i].target;
        if (target.closest && target.closest(".xterm")) { scheduleScan(); return; }
        var added = mutations[i].addedNodes;
        for (var j = 0; j < added.length; j++) {
          var node = added[j];
          if (node.nodeType !== 1) continue;
          if ((node.classList && node.classList.contains("xterm")) ||
              (node.querySelector && node.querySelector(".xterm"))) {
            scheduleScan(); return;
          }
        }
      }
    });
    observer.observe(document.body, { childList: true, subtree: true, characterData: true });
    setInterval(scanAllTerminals, 1500);
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
