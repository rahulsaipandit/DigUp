"""DOWNSTREAM-FORK (2026-11-17): the real Settings page (shell/ui) with a stand-in for the Tauri backend, so it can be looked at in
a browser. Copies shell/ui to TEST_ROOT/ui-harness and adds harness.html, which is settings.html with a mock backend put in front
of its scripts. The scenario is the query string: ?tab=folders&s=none|count|open|retried|many. See README.md; screenshots.bat takes
a picture of each scenario with headless Edge.
"""
import os, shutil

repo = os.environ["REPO"]
src = os.path.join(repo, "shell", "ui")
dst = os.path.join(os.environ["TEST_ROOT"], "ui-harness")
if os.path.exists(dst):
    shutil.rmtree(dst)
shutil.copytree(src, dst)

mock = r'''
<script>
(() => {
// A stand-in for the Tauri backend, so the real page can be looked at in a browser: ?s=none|count|open|reasons|retried|many
const scenario = new URLSearchParams(location.search).get("s") || "none";
window.onerror = (message, file, line) => { document.title = "ERROR " + message + " @" + line; document.body.insertAdjacentHTML("beforeend", "<pre style='color:red'>ERROR " + message + " line " + line + "</pre>"); };
const files = [
  { id: 1, path: "D:/Documents/Reports/Q3 budget.pdf", kind: "pdf", detail: "unreadable: PDF reader couldn't start: sandbox: make container failed (Windows error 5)", code: false },
  { id: 2, path: "D:/Documents/Reports/Q4 forecast.pdf", kind: "pdf", detail: "unreadable: PDF reader couldn't start: sandbox: make container failed (Windows error 5)", code: false },
  { id: 3, path: "D:/Documents/Thesis/chapter 3 (draft).docx", kind: "doc", detail: "unreadable: can't read word/document.xml", code: false },
  { id: 4, path: "D:/Pictures/2019/IMG_4821.jpg", kind: "image", detail: "unreadable: can't decode image", code: false },
  { id: 5, path: "D:/Pictures/2019/IMG_4822.jpg", kind: "image", detail: "unreadable: can't decode image", code: false },
];
const many = Array.from({ length: 500 }, (_, i) => ({ id: 100 + i, path: `D:/Archive/scan ${i}.pdf`, kind: "pdf", detail: "unreadable: PDF reader couldn't start: sandbox: make container failed (Windows error 5)", code: false }));
let count = { none: 0, count: 5, open: 5, reasons: 5, retried: 5, many: 4000 }[scenario];
let list = scenario === "many" ? many : files;
const info = { openAtLogin: false, canOpenAtLogin: false, centered: false, processorOnly: false, canChooseTrayClick: false, trayClick: "window",
  canCenter: false, hotkey: "Ctrl+Space", shortcut: { method: "grab", command: "" }, folders: ["D:/Documents", "D:/Pictures"], skipped: [],
  skipTypes: "", indexHours: { on: false, start: "09:00", end: "17:00" }, storage: { models: "C:/Users/me/AppData/Local/DigUp/Models", index: "C:/Users/me/AppData/Local/DigUp/index", indexBytes: 52428800 },
  code: { folders: [], skipped: [], editor: "default", editors: [] }, updateChecks: true, installsUpdates: true, version: "0.7.0",
  state: { line: "Up to date", progress: null, searchable: 1495, files: 1500, pending: 0, unfinished: 0, paused: false, leftOut: {} } };
const roots = [
  { path: "D:/Documents", missing: false, unreadable: false, indexed: 740, files: 742, pending: 0, unfinished: 0, skipped: 0, failed: 2, kinds: { doc: 700, pdf: 42 }, skipped_reasons: {} },
  { path: "D:/Pictures", missing: false, unreadable: false, indexed: 755, files: 758, pending: 0, unfinished: 0, skipped: 0, failed: 3, kinds: { image: 758 }, skipped_reasons: {} },
];
window.__TAURI__ = {
  core: { invoke: async (command, args = {}) => {
    window.__calls = (window.__calls || []).concat([[command, args]]);
    if (command === "settings_info") return info;
    if (command === "ask") {
      if (args.request.op === "summaries") return { roots };
      if (args.request.op === "failures") return { count, files: args.request.limit ? list.slice(0, args.request.limit) : [] };
    }
    if (command === "retry_failed") {
      const n = args.files ? args.files.length : count;
      if (args.files) { list = list.filter((f) => !args.files.some((x) => x.id === f.id)); count -= n; } else { list = []; count = 0; }
      return { requeued: n, started: true };
    }
    return null;
  } },
  event: { listen: async () => () => {} },
};
window.addEventListener("load", () => setTimeout(() => {
  if (["open", "reasons", "retried", "many"].includes(scenario)) document.getElementById("failures-review").click();
  if (scenario === "retried") setTimeout(() => document.querySelector("#failures-rows .row button").click(), 500);
}, 500));
})();
</script>
'''
html = open(os.path.join(dst, 'settings.html'), encoding='utf-8').read()
html = html.replace('<script src="shortcut.js"></script>', mock + '<script src="shortcut.js"></script>', 1)
open(os.path.join(dst, 'harness.html'), 'w', encoding='utf-8').write(html)
print("harness at", dst)
