// Pure-logic unit tests for termix-linkifier v2.2 multi-line reassembly.
// Run: node test/reassembly.test.js   (no dependencies)
"use strict";
var assert = require("assert");
var L = require("../linkifier.js");

var URL_PATTERN = {
  name: "url",
  regex: "https?:\\/\\/[^\\s]+",
  url: "{match}",
  color: "#81c784",
  multiline: true
};
var PATH_PATTERN = {
  name: "opt-shared",
  regex: "\\/opt\\/shared\\/[^\\s\"'<>)\\]\\}|,;:]+",
  url: "http://192.168.178.225:5590/?file={path}",
  prefix: "/opt/shared/",
  color: "#4fc3f7",
  multiline: false
};

var COLS = 80;
var pass = 0;
function ok(name, fn) {
  try { fn(); pass++; console.log("  ✓ " + name); }
  catch (e) { console.error("  ✗ " + name + "\n    " + e.message); process.exitCode = 1; }
}

// Split a long string into full-width rows (simulates terminal hard-wrap):
// each row exactly COLS chars except the last (the remainder).
function hardWrap(s, cols) {
  var rows = [];
  for (var i = 0; i < s.length; i += cols) rows.push(s.slice(i, i + cols));
  return rows;
}

console.log("termix-linkifier v2.2 — reassembly tests");

// ── 1. Wrapped claude-login-style URL over several full rows ────────────────
ok("reassembles a wrapped URL into one full match", function () {
  var url = "https://claude.ai/oauth/authorize?client_id=abc123def456&response_type=code" +
            "&redirect_uri=https%3A%2F%2Fconsole.anthropic.com%2Foauth%2Fcallback&scope=org%3A" +
            "create_api_key%20user%3Aprofile&code_challenge=" + "X".repeat(43) +
            "&code_challenge_method=S256&state=" + "Y".repeat(40);
  assert.ok(url.length > 200, "fixture URL should be long (" + url.length + ")");
  var urlRows = hardWrap(url, COLS);
  assert.ok(urlRows.length >= 4, "should wrap to >=4 rows, got " + urlRows.length);
  var rows = ["stefan@popos:~$ claude login"].concat(urlRows).concat([
    "Paste code here: "
  ]);
  var matches = L.findMatches(rows, [URL_PATTERN, PATH_PATTERN], 10);
  var urls = matches.filter(function (m) { return m.name === "url"; });
  assert.strictEqual(urls.length, 1, "exactly one URL match, got " + urls.length);
  assert.strictEqual(urls[0].text, url, "full URL reassembled bit-perfect");
  assert.strictEqual(urls[0].url, url, "{match} resolves to the raw URL");
  assert.strictEqual(urls[0].segments.length, urlRows.length,
    "one segment per wrapped row");
});

// ── 2. Path pattern still matches on a single line (backward behaviour) ──────
ok("single-line path pattern still works", function () {
  var rows = ["opening /opt/shared/SYNAPSE/INBOX/CODE/msg.md now"];
  var matches = L.findMatches(rows, [URL_PATTERN, PATH_PATTERN], 10);
  var paths = matches.filter(function (m) { return m.name === "opt-shared"; });
  assert.strictEqual(paths.length, 1);
  assert.strictEqual(paths[0].text, "/opt/shared/SYNAPSE/INBOX/CODE/msg.md");
  assert.strictEqual(paths[0].segments.length, 1, "no multi-line for paths");
  assert.ok(paths[0].url.indexOf("file=http") === -1);
  assert.ok(paths[0].url.indexOf("%2Fopt%2Fshared") !== -1, "{path} url-encoded");
});

// ── 3. Legacy single-pattern config normalizes to one pattern ───────────────
ok("legacy config shape normalizes", function () {
  var pats = L.normalizePatterns({
    regex: "\\/opt\\/shared\\/\\S+", url: "http://v/?file={path}",
    prefix: "/opt/shared/", color: "#4fc3f7"
  });
  assert.strictEqual(pats.length, 1);
  assert.strictEqual(pats[0].name, "legacy");
  assert.strictEqual(pats[0].multiline, false);
});

// ── 4. URL that ends mid-row must NOT over-extend into the next line ─────────
ok("URL ending mid-row does not swallow the next line", function () {
  var rows = [
    "see https://example.com/short here",   // ends mid-row (space after)
    "https://other.example.com/second"      // independent URL
  ];
  var matches = L.findMatches(rows, [URL_PATTERN], 10);
  var urls = matches.filter(function (m) { return m.name === "url"; });
  assert.strictEqual(urls.length, 2, "two independent URLs, got " + urls.length);
  assert.strictEqual(urls[0].text, "https://example.com/short");
  assert.strictEqual(urls[0].segments.length, 1);
  assert.strictEqual(urls[1].text, "https://other.example.com/second");
});

// ── 5. Continuation row starting with a space is a new logical line → stop ───
ok("leading-space next row is not treated as wrap continuation", function () {
  var full = "https://example.com/" + "a".repeat(COLS); // forces edge on row 1
  var urlRows = hardWrap(full, COLS);                    // row0 is full width
  // Next row indented (leading space) = a new logical output line.
  var rows = [urlRows[0], "   indented note after the url"];
  var matches = L.findMatches(rows, [URL_PATTERN], 10);
  var urls = matches.filter(function (m) { return m.name === "url"; });
  assert.strictEqual(urls.length, 1);
  assert.strictEqual(urls[0].text, urlRows[0].replace(/[.,:;!?)}\]]+$/, ""),
    "only the first full row, no bogus continuation");
});

// ── 6. maxWrapRows caps runaway reassembly ──────────────────────────────────
ok("maxWrapRows bounds the reassembly", function () {
  // 10 full-width rows all URL-valid → cap at 3.
  var rows = [];
  for (var i = 0; i < 10; i++) rows.push("https://a.example/" .slice(0,0) + "x".repeat(COLS));
  rows[0] = "https://a.example/" + "x".repeat(COLS - "https://a.example/".length);
  var matches = L.findMatches(rows, [URL_PATTERN], 3);
  var urls = matches.filter(function (m) { return m.name === "url"; });
  assert.ok(urls.length >= 1);
  assert.ok(urls[0].segments.length <= 3, "segments capped at 3, got " + urls[0].segments.length);
});

console.log("\n" + pass + " assertions passed" +
  (process.exitCode ? " — WITH FAILURES" : " — all green"));
