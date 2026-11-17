// DOWNSTREAM-FORK (2026-11-17): drives the real DigUp shell's Settings window over WebView2's remote debugging port (9333), the way a
// person would: opens Settings from the main window, Folders, reads the "N files couldn't be read" line, opens Review, clicks
// Retry all, waits for the helpers to read the files again, and reads the line and the list once more. Screenshots of the real page
// go to the folder given as the first argument. Prints a JSON summary and exits 1 if what it saw is not what it expects. See README.md.
import fs from "node:fs";

const PORT = 9333;
const OUT = process.argv[2];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (...a) => console.log(...a);

async function pages() {
  try { return (await (await fetch(`http://127.0.0.1:${PORT}/json`)).json()).filter((t) => t.type === "page"); } catch { return []; }
}
async function waitForPage(match, timeout = 90000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    const found = (await pages()).find((t) => match(t.url));
    if (found) return found;
    await sleep(500);
  }
  throw new Error("no page matching " + match);
}
async function connect(target) {
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
  let id = 0;
  const pending = new Map();
  ws.onmessage = (m) => { const d = JSON.parse(m.data); if (d.id && pending.has(d.id)) { pending.get(d.id)(d); pending.delete(d.id); } };
  const send = (method, params = {}) => new Promise((res) => { const i = ++id; pending.set(i, res); ws.send(JSON.stringify({ id: i, method, params })); });
  const evaluate = async (expression) => {
    const r = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
    if (r.result?.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails).slice(0, 400));
    return r.result?.result?.value;
  };
  const shot = async (name) => {
    const r = await send("Page.captureScreenshot", { format: "png" });
    fs.writeFileSync(`${OUT}/real-${name}.png`, Buffer.from(r.result.data, "base64"));
  };
  return { evaluate, shot, close: () => ws.close() };
}
async function until(fn, timeout, what) {
  const end = Date.now() + timeout;
  let last;
  while (Date.now() < end) { last = await fn(); if (last) return last; await sleep(500); }
  throw new Error("timed out waiting for " + what);
}

const summary = {};
const main = await connect(await waitForPage((u) => /window\.html/.test(u)));
log("main window page is up");
await main.evaluate(`window.__TAURI__.core.invoke("open_settings")`);
const settingsTarget = await waitForPage((u) => /settings\.html/.test(u), 30000);
const page = await connect(settingsTarget);
await until(() => page.evaluate(`document.readyState === "complete" && !!document.getElementById("failures-note")`), 20000, "settings page");
await page.evaluate(`document.querySelector('#tabs button[data-tab="folders"]').click()`);

const read = (expr) => page.evaluate(expr);
const note = await until(async () => {
  const v = await read(`(() => { const n = document.getElementById("failures-note"); return n.hidden ? "" : document.getElementById("failures-text").textContent; })()`);
  return v || null;
}, 60000, "the failures line");
summary.noteBefore = note;
await page.shot("1-closed");

await page.evaluate(`document.getElementById("failures-review").click()`);
await until(() => read(`!document.getElementById("failures-panel").hidden`), 10000, "the panel");
await sleep(600);
summary.panelBefore = await read(`({ title: document.getElementById("failures-title").textContent,
  reasons: document.getElementById("failures-reasons").innerText,
  rows: [...document.querySelectorAll("#failures-rows .row")].map((r) => [r.querySelector(".name").textContent, r.querySelector(".reason").textContent]) })`);
await page.shot("2-open");

await page.evaluate(`document.getElementById("failures-retry-all").click()`);
await sleep(800);
// Everything is waiting again, so the count is 0 and the panel closes; the line says what is happening.
summary.afterClick = await read(`(() => { const n = document.getElementById("failures-note"); return { noteHidden: n.hidden, text: document.getElementById("failures-text").textContent,
  panelHidden: document.getElementById("failures-panel").hidden }; })()`);
await page.shot("3-after-retry-click");

// The shell starts the index helper, which reads what was put back; the picture that is really bad fails again, and the line returns.
summary.noteAfter = await until(async () => {
  const v = await read(`(() => { const n = document.getElementById("failures-note"); return n.hidden ? "" : document.getElementById("failures-text").textContent; })()`);
  return /1 file couldn't be read/.test(v) ? v : null;
}, 120000, "the line to come back with the one file that is really bad");
await page.evaluate(`document.getElementById("failures-review").click()`);
await until(() => read(`!document.getElementById("failures-panel").hidden`), 10000, "the panel again");
await sleep(600);
summary.panelAfter = await read(`({ title: document.getElementById("failures-title").textContent,
  reasons: document.getElementById("failures-reasons").innerText,
  rows: [...document.querySelectorAll("#failures-rows .row")].map((r) => [r.querySelector(".name").textContent, r.querySelector(".reason").textContent]) })`);
await page.shot("4-after-retry-done");
log(JSON.stringify(summary, null, 2));

// What a person should have seen.
const problems = [];
const expect = (name, ok) => { log((ok ? "ok   " : "FAIL ") + name); if (!ok) problems.push(name); };
const names = (rows) => rows.map((r) => r[0]).sort();
expect("the line said 2 files couldn't be read", /^2 files couldn't be read/.test(summary.noteBefore));
expect("the list had the two files, with reasons",
  JSON.stringify(names(summary.panelBefore.rows)) === JSON.stringify(["apple cake.txt", "holiday photo.png"])
  && summary.panelBefore.rows.every((r) => r[1].length > 0));
expect("the reasons were grouped above the list", /PDF reader couldn't start/.test(summary.panelBefore.reasons) && /Can't decode image/.test(summary.panelBefore.reasons));
expect("after Retry all the panel closed and the line said they were being read again",
  summary.afterClick.panelHidden && /(Reading 2 files again|will be read again)/.test(summary.afterClick.text));
expect("then the line came back with only the really bad file", /1 file couldn't be read/.test(summary.noteAfter));
expect("and the list had only that file", JSON.stringify(names(summary.panelAfter.rows)) === JSON.stringify(["holiday photo.png"]));
// A retry under the real shell once failed because the decode worker's sandbox could not start inside the shell's job object
// (scripts/fork-tests/job-nesting.bat): the picture then "failed" for that reason, not its own.
expect("the picture failed again for its own reason, not because the worker could not start",
  /Can't decode image/.test(summary.panelAfter.rows[0][1]) && !/couldn't start|sandbox/i.test(summary.panelAfter.rows[0][1]));
page.close(); main.close();
process.exit(problems.length ? 1 : 0);
