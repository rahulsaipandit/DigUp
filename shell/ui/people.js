// DOWNSTREAM-FORK (2026-11-18): DigUp's People window (docs/person-recognition.md §10), after Picasa's "name this face". The index helper finds
// faces and groups the similar ones; here a group is shown as a few of its faces and the person says who it is. Everything goes to
// search-service as `faces_*` questions. Faces are cut out of the photo here: the boxes are in the coordinates of the picture the face
// program read (the photo at most 1024 px on its longer side), so a larger photo is scaled down to that before the cut.
"use strict";

const tauri = window.__TAURI__;
const ask = (request) => tauri.core.invoke("ask", { request });
const fileURL = (path) => tauri.core.convertFileSrc(path);
const $ = (id) => document.getElementById(id);

const PICTURE_SIDE = 1024;
let tab = "groups";
let people = [];

function el(tag, props = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (key === "class") node.className = value;
    else node[key] = value;   // properties, handlers (onclick…) included
  }
  for (const child of children) node.append(child);
  return node;
}

function say(text, isError = false) {
  $("message").textContent = text;
  $("message").style.color = isError ? "#c4441c" : "";
}

const plural = (n, one, many) => `${n.toLocaleString()} ${n === 1 ? one : many}`;

// MARK: Pictures

const direct = /\.(jpe?g|png|gif|webp|bmp)$/i;
const pictures = new Map();   // path -> Promise<HTMLImageElement>
let loading = 0;
const waiting = [];

function slot() {
  return new Promise((resolve) => {
    const go = () => { loading += 1; resolve(); };
    if (loading < 4) go(); else waiting.push(go);
  });
}
function release() {
  loading -= 1;
  const next = waiting.shift();
  if (next) next();
}

function picture(path) {
  if (pictures.has(path)) return pictures.get(path);
  const promise = (async () => {
    await slot();
    try {
      let source = fileURL(path);
      if (!direct.test(path)) source = fileURL((await ask({ op: "render", path, kind: "image", pixels: PICTURE_SIDE })).image);
      const image = new Image();
      image.src = source;
      await image.decode();
      return image;
    } finally {
      release();
    }
  })();
  pictures.set(path, promise);
  promise.catch(() => pictures.delete(path));
  // The window holds the pictures it is showing, not every one it has shown.
  if (pictures.size > 48) pictures.delete(pictures.keys().next().value);
  return promise;
}

/// Draws a face, with a margin, into a square canvas.
function drawFace(canvas, crop) {
  const size = 144;
  canvas.width = size;
  canvas.height = size;
  picture(crop.path).then((image) => {
    const longer = Math.max(image.naturalWidth, image.naturalHeight);
    const toPhoto = longer > PICTURE_SIDE ? longer / PICTURE_SIDE : 1;
    const side = Math.max(crop.w, crop.h) * 1.5 * toPhoto;
    const cx = (crop.x + crop.w / 2) * toPhoto, cy = (crop.y + crop.h / 2) * toPhoto;
    canvas.getContext("2d").drawImage(image, cx - side / 2, cy - side / 2, side, side, 0, 0, size, size);
  }).catch(() => {});
}

function faceCanvas(crop) {
  const canvas = el("canvas", { title: crop.path.split(/[\\/]/).pop() });
  drawFace(canvas, crop);
  return canvas;
}

// MARK: The groups to name

async function renderGroups() {
  const box = $("groups");
  const reply = await ask({ op: "faces_groups", limit: 60, sample: 6 });
  box.replaceChildren();
  if (reply.groups.length === 0) {
    const status = await ask({ op: "faces_status" });
    const [title, lines] = status.faces === 0 && status.scanned === 0
      ? ["No faces yet", ["DigUp looks for faces while it indexes, once “Recognize people in photos” is on in Settings, and groups the similar ones here for you to name."]]
      : status.groups === 0 && status.people === 0
        ? ["Still going through your photos",
           [`${status.scanned.toLocaleString()} photos looked at so far, ${plural(status.faces, "face", "faces")} found.`,
            "A group shows up here once at least 3 faces from 2 photos look alike. This list updates as more photos are scanned."]]
        : ["Nothing waiting to be named", ["New groups show up here as DigUp finds more photos."]];
    box.append(el("div", { class: "empty" }, el("div", { class: "mark" }, "☺"), el("h2", {}, title), ...lines.map((text) => el("p", {}, text))));
  }
  for (const group of reply.groups) box.append(groupCard(group));
  $("groups-count").textContent = reply.total > 0 ? String(reply.total) : "";
}

function groupCard(group) {
  const faces = el("div", { class: "faces" });
  for (const crop of group.samples) faces.append(faceCanvas(crop));
  const card = el("div", { class: "card" },
    el("div", { class: "head" }, el("span", { class: "title" }, "Who is this?"),
      el("span", { class: "sub" }, `${plural(group.faces, "face", "faces")} in ${plural(group.photos, "photo", "photos")}`)),
    faces);

  const input = el("input", { type: "text", placeholder: "Name", maxLength: 200 });
  const name = el("button", { class: "primary", disabled: true }, "Name");
  input.oninput = () => { name.disabled = input.value.trim() === ""; };
  const finish = async (work, message) => {
    try { await work(); say(message); card.remove(); await refreshCounts(); }
    catch (error) { say(String(error), true); }
  };
  name.onclick = () => finish(() => ask({ op: "faces_name", group: group.id, name: input.value.trim() }), `Named ${input.value.trim()}`);
  input.onkeydown = (event) => { if (event.key === "Enter" && !name.disabled) name.click(); };

  const actions = el("div", { class: "actions" }, input, name);
  if (people.length > 0) {
    const select = el("select", { title: "Someone already named" }, el("option", { value: "" }, "or: this is…"),
      ...people.map((person) => el("option", { value: String(person.id) }, person.name)));
    select.onchange = () => {
      if (select.value) finish(() => ask({ op: "faces_name", group: group.id, person: Number(select.value) }), `Added to ${select.selectedOptions[0].textContent}`);
    };
    actions.append(select);
  }
  const all = el("button", { class: "link" }, "Show all");
  all.onclick = async () => {
    all.remove();
    const reply = await ask({ op: "faces_group", group: group.id, limit: 80 });
    faces.replaceChildren();
    faces.classList.add("big");
    for (const crop of reply.faces) {
      const remove = el("button", { title: "Leave this face out (it is not offered or searched again)" }, "×");
      const cell = el("div", { class: "face" }, faceCanvas(crop), remove);
      remove.onclick = async () => {
        try { await ask({ op: "faces_ignore", faces: [crop.id] }); cell.remove(); await refreshCounts(); }
        catch (error) { say(String(error), true); }
      };
      faces.append(cell);
    }
  };
  const skip = el("button", { class: "link", title: "These are not faces of people to name (a poster, a pattern, a crowd)" }, "Not a person");
  skip.onclick = () => finish(() => ask({ op: "faces_ignore_group", group: group.id }), "Left out");
  actions.append(all, skip);
  card.append(actions);
  return card;
}

// MARK: The people

async function renderPeople() {
  const box = $("people");
  box.replaceChildren();
  if (people.length === 0) {
    box.append(el("p", { class: "note" }, "Nobody is named yet. Name a group under “To name”."));
    return;
  }
  for (const person of people) box.append(personCard(person));
}

function personCard(person) {
  const picture = person.sample ? faceCanvas(person.sample) : el("canvas");
  const name = el("div", { class: "name" }, person.name);
  const card = el("div", { class: "card" });
  const row = el("div", { class: "person" }, picture,
    el("div", { class: "text" }, name, el("div", { class: "sub" }, plural(person.photos, "photo", "photos"))));
  const photos = el("button", { class: "plain" }, "Photos");
  photos.onclick = () => showAlbum(person);
  const rename = el("button", { class: "plain" }, "Rename");
  rename.onclick = () => {
    const input = el("input", { type: "text", value: person.name, maxLength: 200 });
    name.replaceChildren(input);
    input.focus();
    input.select();
    const save = async () => {
      const text = input.value.trim();
      if (text && text !== person.name) {
        try { await ask({ op: "faces_rename", person: person.id, name: text }); person.name = text; say(`Renamed to ${text}`); await refreshCounts(); }
        catch (error) { say(String(error), true); }
      }
      name.textContent = person.name;
    };
    input.onkeydown = (event) => { if (event.key === "Enter") save(); if (event.key === "Escape") name.textContent = person.name; };
    input.onblur = save;
  };
  row.append(photos, rename);
  if (people.length > 1) {
    const merge = el("select", { title: "The same person as…" }, el("option", { value: "" }, "Same as…"),
      ...people.filter((other) => other.id !== person.id).map((other) => el("option", { value: String(other.id) }, other.name)));
    merge.onchange = async () => {
      if (!merge.value) return;
      const target = people.find((other) => other.id === Number(merge.value));
      try { await ask({ op: "faces_merge", from: person.id, into: target.id }); say(`${person.name} and ${target.name} are one person now`); await refreshCounts(); await show("people"); }
      catch (error) { say(String(error), true); }
    };
    row.append(merge);
  }
  card.append(row);
  return card;
}

async function showAlbum(person) {
  const box = $("album");
  for (const id of ["groups", "people"]) $(id).hidden = true;
  box.hidden = false;
  const back = el("button", { class: "plain" }, "‹ People");
  back.onclick = () => show("people");
  box.replaceChildren(el("div", { class: "actions" }, back, el("strong", {}, person.name)));
  const reply = await ask({ op: "faces_album", person: person.id, limit: 120 });
  const grid = el("div", { class: "photos" });
  for (const entry of reply.photos) {
    const image = el("img", { loading: "lazy", title: entry.path });
    if (direct.test(entry.path)) image.src = fileURL(entry.path);
    else ask({ op: "render", path: entry.path, kind: "image", pixels: 256 }).then((r) => { image.src = fileURL(r.image); }).catch(() => {});
    grid.append(image);
  }
  box.append(el("p", { class: "sub" }, `${plural(reply.total, "photo", "photos")}${reply.total > reply.photos.length ? `, the newest ${reply.photos.length} shown` : ""}`), grid);
}

// MARK: The window

async function refreshCounts() {
  const [status, list] = await Promise.all([ask({ op: "faces_status" }), ask({ op: "faces_people" })]);
  people = list.people;
  $("people-count").textContent = people.length > 0 ? String(people.length) : "";
  $("groups-count").textContent = status.groups > 0 ? String(status.groups) : "";
  const left = status.faces - status.named_faces;
  $("status").textContent = status.faces === 0 ? (status.scanned > 0 ? `${status.scanned.toLocaleString()} photos looked at so far, no faces yet` : "")
    : `${plural(status.faces, "face", "faces")} in ${plural(status.photos, "photo", "photos")}, ${left.toLocaleString()} not named yet`
      + (status.scanned > status.photos ? ` (${status.scanned.toLocaleString()} photos looked at so far)` : "");
}

async function show(name) {
  tab = name;
  for (const button of document.querySelectorAll("#tabs button")) button.setAttribute("aria-selected", String(button.dataset.tab === name));
  for (const id of ["groups", "people", "album"]) $(id).hidden = id !== name;
  try {
    await refreshCounts();
    if (name === "groups") await renderGroups(); else await renderPeople();
  } catch (error) {
    const box = $(name);
    box.replaceChildren(el("p", { class: "error" }, `Can't read the faces: ${error}`));
  }
  $("undo").disabled = false;
}

for (const button of document.querySelectorAll("#tabs button")) button.onclick = () => show(button.dataset.tab);
$("undo").onclick = async () => {
  try {
    const reply = await ask({ op: "faces_undo" });
    say(reply.undone ? `Undid: ${reply.undone}` : "Nothing to undo");
    await show(tab === "album" ? "people" : tab);
  } catch (error) { say(String(error), true); }
};
window.addEventListener("keydown", (event) => {
  if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "w") tauri.core.invoke("close_window");
});
// New groups can arrive while the window is open (indexing goes on): a look when it is brought back.
window.addEventListener("focus", () => { if (tab !== "album" && !document.activeElement?.matches("input")) show(tab); });

// DOWNSTREAM-FORK (2026-11-18): while DigUp is still going through the photos, the counts and the groups to name are looked at again every 15 seconds,
// unless a name is being typed (a refresh would clear it).
let seenGroups = -1;
setInterval(async () => {
  if (document.hidden || tab === "album" || document.activeElement?.matches("input, select")) return;
  try {
    const status = await ask({ op: "faces_status" });
    // The first look only learns the number: the window has just drawn it, and drawing again would be for nothing.
    if (seenGroups !== -1 && status.groups !== seenGroups) await show(tab); else await refreshCounts();
    seenGroups = status.groups;
  } catch { /* the next look tries again */ }
}, 15000);

show("groups");
