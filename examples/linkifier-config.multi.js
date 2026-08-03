// termix-linkifier v2.2 — Multi-Pattern-Config (Deployment-Beispiel CT223)
//
// Ersetzt die alte Single-Pattern-Config. Rueckwaertskompatibel: das alte
// {regex,url,prefix,color}-Format funktioniert weiter — dies hier nutzt das
// neue patterns[]-Array fuer /opt/shared/-Pfade UND anklickbare URLs.
window.__LINKIFIER_CONFIG__ = {
  patterns: [
    {
      // /opt/shared/-Pfade -> FileView (CT225). Wie bisher, single-line.
      name: "opt-shared",
      regex: "\\/opt\\/shared\\/[^\\s\"'<>)\\]\\}|,;:]+",
      url: "http://192.168.178.225:5590/?file={path}",
      prefix: "/opt/shared/",
      color: "#4fc3f7",
      multiline: false
    },
    {
      // http(s)-URLs -> im Browser oeffnen. multiline:true = ueber mehrere
      // Terminal-Zeilen gewrappte URLs (z.B. `claude login`) zusammensetzen.
      name: "url",
      regex: "https?:\\/\\/[^\\s]+",
      url: "{match}",
      color: "#81c784",
      multiline: true
    }
  ],
  maxWrapRows: 10
};
