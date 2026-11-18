# Person recognition — design

Status: **draft, reviewed against the code on 2026-11-17, nothing built.** Owner: Rahul.
This is a fork-only feature (see [downstream-fork-changes.md](downstream-fork-changes.md)); upstream DigUp has no face
recognition. Each claim is one of: **checked** (read in this repository), **reported** (measured by the smart-photos project,
on its tablet, not here), or **[verify]** (an assumption a spike must settle).

## 1. Goal

Find photos by person: name someone once, then ask for "photos of Priya" or "Priya at the beach".

Out of scope for v1: videos, recognising people nobody named, searching by uploading a face, anything that leaves the
computer, cloud services. Windows first; macOS and Linux are not designed here (§5.1).

## 2. How DigUp works today (checked)

- No face detection, grouping or people index exists. The only model is EmbeddingGemma 2 on llama.cpp: one "meaning" vector
  per image (`segments.vec`, 768 × float16). Searching "man" or "boy" ranks by appearance, not by person.
- **Photos are prepared once for the embedder:** `ImageExtractor.prepare(url, maxPixel: 1024)` (screenshots 1536) decodes,
  scales to at most 1024 px on the long side and writes a temporary JPEG or PNG ([Indexer.swift:417](../Sources/DigUpKit/Indexer.swift)).
  On Windows the decode runs in the sandboxed decode worker (`image.prepare`, [DecodeIsolation+Media.swift](../Sources/DigUpKit/Platform/Portable/DecodeIsolation+Media.swift)),
  and what stb or decode-rs cannot read goes through ffmpeg.
- **Video keyframes** are sampled every 3 s at `maxPixel: 1024`, one kept per shot (Indexer.swift:456).
- The index is `index.sqlite` (schema version 5, migrations in [IndexStore.swift](../Sources/DigUpKit/IndexStore.swift)). The
  code index is **a separate file** (`code.sqlite`) so it never disturbs the main index and can be deleted alone: a precedent for §6.
- `Searcher.search(text, queryVector:, kinds:, limit:, …)` already filters by file kind through an `allowed` predicate over file ids
  ([Searcher.swift:115](../Sources/DigUpKit/Searcher.swift)). Results carry a score and a `strong` count; the shell shows 40.
- Index options that change vectors form a "fingerprint"; an index never mixes settings.
- The helper has a memory and time watchdog (`--memory-limit`, `--time-limit`) and background priority; indexing honours quiet hours.

## 3. What is known about the models (reported)

Source: `D:\Github\smart-search-extension\packages\smart-photos\docs\SmartPhotos.md` (a Fire HD photo frame; a separate project),
whose app is in `packages/smart-photos/frame/`. Its numbers come from a tablet and from two enrolled people.

| Item | Result |
|---|---|
| Detector | YuNet (MIT, 233 KB) through ONNX Runtime; also returns 5 landmarks for alignment |
| Embedder | SFace (Apache-2.0, 38.7 MB); training-data terms **not verified** there |
| Agreement with the Python reference | embedding cosine 0.985, box within ~1 px |
| Same person (5-pose enrolment, n=16) | mean 0.66, min 0.48, max 0.88 |
| Different people (n=20) | mean 0.20, max 0.34; threshold 0.363 fell in the gap |
| One enrolment frame only | same-person mean 0.43–0.46: **below the target, so single-frame enrolment is not enough** |
| Profile against profile | as low as 0.48 |
| Library scan | 1,427 photos at about 2 photos/s: 2,352 faces (1.65 per photo), four clear groups |
| Median face size | 8% of the frame width (120 album photos) |

Sample size is the weak point: two people, one skipped a pose. Treat the threshold as a starting point, not a result.

## 4. Decision: which models

**Start with YuNet + SFace, behind an interface so the embedder can be replaced.** Run on the CPU (the models are tiny; CUDA
would add a very large DLL for no gain).

Why: they are the only pair with measurements behind them; both are permissively licensed (InsightFace's pretrained ArcFace and
SCRFD weights are research-only **[verify current terms]**, which matters only if the fork is distributed); and this PC does not
have the tablet's limits, so the choice is not forced.

Why it may change: SFace was picked to fit a tablet, and this library is hard (photos from 2003, children who aged, scans, profiles,
small faces in group shots). A larger ArcFace-class embedder with permissive weights may do better **[verify one exists]**.
Decide after measuring (§9), not before.

A second reference exists: **Lap** (`D:\Github\lap`, a Tauri photo manager) runs `det_500m.onnx` (an SCRFD-style detector) and
`w600k_mbf.onnx` (MobileFaceNet, 512-d, trained on WebFace600K) through the Rust `ort` crate on the desktop
([t_face.rs](D:/Github/lap/src-tauri/src/t_face.rs), [t_common.rs](D:/Github/lap/src-tauri/src/t_common.rs)). That is the stronger-but-less-permissive
pair this section asked about: both file names match InsightFace's model packs, whose weights are research-only **[verify the terms of
exactly these files]**. Lap publishes no accuracy or speed numbers, so it shows the pair is usable, not that it is better. It is the first
candidate for F4. See §16 for the full comparison.

Rules that hold whatever the model:

1. **One detector, one alignment and one embedder per index.** Vectors from different embedders are not comparable.
2. **The face model is recorded in the faces index's metadata**, like `vector_source` in `index.sqlite`. A mismatch means "re-embed faces".
3. **Names must not depend on the embedder** (§7): a swap re-embeds faces and keeps who is who.
4. **The semantic model does not change.** EmbeddingGemma stays for "beach", "boy"; faces are a separate index beside it.
5. **Only the shipped, hash-checked model files are loaded**, never a file chosen by a user or found in a folder being indexed.

## 5. Architecture

```
 prepared picture (≤1024 px, from the sandboxed decode)
        │
        ├─▶ embedder (existing)  ─▶ index.sqlite
        └─▶ face worker (own process): detect ─▶ hard floor ─▶ align ─▶ embed ─▶ faces.sqlite
                                       (every detection above the floor is stored; "usable" is decided later)
                                                             │
        match to named people, then cluster the rest ─▶ unnamed groups ─▶ person names ◀─ People view / CLI
        query "priya at the beach" ─▶ names found ─▶ person's files ─▶ intersect with meaning + word results
```

### 5.1 Scope and runtime

- **Face runtime:** ONNX Runtime (CPU) on Windows, called from the Swift helper. It is a new native dependency; llama.cpp cannot run
  these models. Alternative to evaluate: OpenCV's `FaceDetectorYN` and `FaceRecognizerSF`, which are these exact models with alignment
  included, but OpenCV is far larger. A small Rust crate behind a C interface (as `decode-rs`) is a third option, and Lap shows it works: it uses the `ort` crate for exactly this job.
DigUp already builds Rust (`decode-rs`) and its shell is Rust, so this is now the leading option **[verify which fits `Package.swift`, `build.sh`, `scripts/package-windows.sh`]**.
- **Alignment is part of the model.** SFace needs the face warped to 112 × 112 from YuNet's five landmarks with a fixed similarity
  transform. It must match the reference exactly, or scores shift. It is tested against reference vectors (like `ReferenceVectorTests`).
- **Isolation:** the face step receives pixels that the sandboxed decode worker already produced. It parses no file format, so it adds
  no new hostile-input surface, apart from ONNX Runtime reading the shipped model files (rule 5).
- **A process of its own.** The face step runs as a worker process (`digup face-worker`), following `digup worker` for the embedder: JSON lines on
  stdin and stdout, and **paths** to the prepared pictures (checked: `embedImages` takes paths, so no pixels cross the pipe). Reasons: a native crash in
  ONNX Runtime must not take down the index service, its memory can be capped and measured on its own, and it can be stopped at once when the user
  turns faces off or the machine is busy. It runs at background priority with 2 intra-op threads so it does not starve the embedder or ffmpeg.
- **A face failure never fails a file.** If the face worker crashes, times out or a model is missing or fails its hash check, the file stays `done` in the
  main index with its meaning vector, its `scan` row says `failed` (retried a bounded number of times), and the feature shows a plain reason in the status.
  Normal indexing and search are unaffected.
- **Off by default.** Faces are biometric (§11). Until the person turns the feature on in Settings (with a short explanation of what it stores), no model is
  loaded, no face file is created and no picture is scanned.
- **Platforms:** Windows only in v1. On macOS the DigUp app uses Apple frameworks and has no ONNX Runtime in its build; Linux
  could share the Windows path but is untested.
- **Models ship in the installer** (YuNet and SFace together are under 40 MB, which adds to a 54 MB installer **[verify the real growth]**),
  with SHA-256 checks as `download-model` does for the Gemma files. They live in the models folder (`DIGUP_MODELS`).

### 5.2 Where the face step runs

Decoding is most of the cost, so **a face step must reuse the decode the embedder already did.**

- **New and changed files:** the face step runs in the same pass, on the prepared picture, before it is deleted. No second decode. (Checked: each batch's
  prepared pictures sit in a scratch folder that `Indexer` removes as soon as the batch is embedded, [Indexer.swift:238](../Sources/DigUpKit/Indexer.swift), and the
  next batch is prepared while the current one is embedded, so the face worker must be handed the paths before that removal and must not hold them after.)
- **Which files:** kind `image` only in v1. Screenshots (a separate kind, prepared at 1536 px as PNG) and PDF pages are left out: they rarely hold
  photographs of people the person wants to find, and they would add scanning time for little.
- **The existing ~49,000 photos (a backfill pass):** they must be decoded again, which is a full pass through the sandbox. It is a
  separate, resumable, low-priority pass, newest first, run after normal indexing, within quiet hours, under the existing memory and
  time watchdog. Its total time is unknown until measured (F2).
- **Resolution limit (checked):** pictures arrive at 1024 px. A face 8% of the frame wide is about 80 px: fine. A face 3% wide (a
  group shot) is about 30 px: below what SFace does well. v1 accepts losing those. There are two kinds of limit, which an earlier draft mixed up:
  a **hard floor** (a detection below about 20 px or a low confidence is not stored at all, because alignment and embedding are meaningless there), and
  **soft thresholds** for what counts as usable (size, sharpness, confidence), which are only computed from the stored numbers and can change without a rescan
  (§17 rows 5–7). A higher-resolution decode for faces would need its own `maxPixel` and is a later option.
- **Duplicate files.** The index keys files by path and has no content hash (checked: `files` has none), and a backup folder like the owner's `RP_Backup`
  very likely holds the same photo several times. Duplicates would be scanned repeatedly, appear twice in a person's album, and defeat the "at least 2 different
  photos" rule (§7). The face step records a cheap content key (size, taken date and a hash of the first 64 KB **[verify cost and collision rate on this
  library, F6]**), albums list one entry per key (the other paths are shown as copies), and clustering counts a key once.
- **Videos are out of v1.** Keyframes are 1024 px and one per shot, which suits embedding but not people; and a backfill needs ffmpeg
  re-run on ~2,000 videos. For new videos the face step could reuse the keyframes cheaply; that is a later phase.

## 6. Storage

A **separate `faces.sqlite`** in the index folder, following `code.sqlite` (no effect on the existing index, one file to delete for
"Delete all face data"). The cost is no foreign key to `files`, so rows are keyed by **file path plus size and mtime**, and:

- a file that changed or disappeared drops its `face` rows (the same sync that prunes the main index). Labels do not depend on those rows: they are
  anchored to the **path and box** with a copy of the embedding (see the tables), so they survive a rescan and can re-attach (§7);
- a moved file is found by the main index's inode tracking **[verify how moves reach faces.sqlite]**;
- **removing a folder in Settings deletes that folder's faces, labels and embedding copies** (privacy, §11). A person left with no faces keeps their name,
  with an empty album, and the number of labels removed is shown. This is the one case where labels are deleted, and it is the user's explicit action.

**Why not tables inside `index.sqlite`, as Lap does** (its `faces` table references `afiles(id)` with cascading delete, which is simpler):
the main index has one schema number (`schemaVersion`, now 5) and a linear migration chain. If upstream adds migration 6 and the fork adds its
own, they collide, and the fork's tables would need renumbering on every sync. A separate file avoids that and keeps "Delete all face data" to
one file. The price is the missing foreign key, paid with the keys above. Revisit if upstream never touches the schema again.

| Table | Fields |
|---|---|
| `meta` | detector and embedder id and revision, alignment size, **the quality and matching thresholds (the one source of truth)**, schema version |
| `scan` | path, size, mtime, **model and detector signature**, status (`faces`, `none`, `failed`), attempts, date. **Every processed file gets a row, including files with no faces**, or the backfill would decode them again on every run (Lap marks these in `afiles.has_faces`). `none` means "no detection above the floor", never "everything was filtered out" (§17 rows 5–7) |
| `face` | id, path, size, mtime, box and landmarks (in the prepared picture, with its scale and orientation), confidence, size and sharpness **with their units**, embedding (see below). **Every detection above a low confidence floor is stored**; "usable" is computed from the thresholds in `meta`, not stored |
| `content` | content key (size, taken date, first-64 KB hash), the paths that have it (duplicates, §5.2) |
| `group` | id, the face ids in it, a clustering run number: **a cache**, recomputed freely (§7) |
| `person` | id, name, aliases, private flag |
| `label` | **anchor** (path, box, embedding copy, face id when the face row exists), person id (none when ignored), **source** (`user`, `group`, `auto` or `ignored`), confidence, date |
| `rejection` | the same **anchor**, person id: "this is not that person" |
| `op_log` | operation (rename, merge, split, move, reject, dissolve, ignore, restore), what it changed (enough to reverse it), date. Kept for a bounded time (say 30 days); **undo reads this** |

**Who writes what** (the index service and the search service are separate processes and both open this file, as they do the main index; SQLite WAL and the
busy timeout the main index already uses apply): the **index service** owns `scan`, `face`, `content`, `group` and `auto` labels, because the face worker and
clustering run there at background priority; the **search service** owns `person`, `rejection`, `op_log` and every other label (user actions), because the
UI talks to it. Clustering never runs in the search service, which answers typing. After either side changes data the other is told to reload, as the shell
already does for vectors (`reload`).

**Embedding size:** SFace output is 128-d per OpenCV's documentation **[verify against the frame project's code]**, so 512 B per face
at float32. About 1.65 faces per photo over ~49,000 photos is ~81,000 faces, roughly 40 MB. (An earlier draft assumed 512-d and 200 MB.)

**Face crops are not stored for every face.** The People view needs crops: it makes them on demand for a group's representative
faces (about 12 per group) and caches them as small JPEGs in the `previews` folder, which "Delete all face data" also clears.

## 7. People, labels and learning

Problems an earlier draft had, and the design that fixes them:

- **Names anchored to faces, not vectors.** A user's confirmation is a `label` on a face instance (file + box). Exemplars and centroids
  are derived from labelled faces and are rebuilt whenever the embedder changes. Swapping models therefore re-embeds the labelled
  faces and keeps every name. (Without this, a swap would silently erase all names.)
- **Provenance, in three strengths.** `user`: the person confirmed this face (moved it, confirmed a suggestion, or enrolled it). `group`: the face was in a
  group the person named, **not checked one by one**, so it may be wrong. `auto`: a new photo matched to a person by the margin rule. The program never changes
  `user` labels. It may re-evaluate `group` labels, but only by *flagging* a face that disagrees with its person's core for review, never by moving it silently.
  `auto` labels are recomputed freely and shown as suggestions until confirmed or cleared. A named group is **not** locked in whole: naming a group of 548 faces
  must not make its few wrong faces permanent (Lap's planned anchor design has exactly this cost, §17.1).
- **No drift.** A person's reference set (the "core", at most about 20 faces) is chosen only from `user` and `group` labels. `auto` faces are never part of the
  core, or each match would widen the target and the person would slowly absorb a lookalike.
- **What the core is.** A labelled face qualifies for the core when it matches **at least 3 other** labelled faces of that person above the matching threshold.
  That drops a stray wrong face (it matches nobody) but keeps a profile that matches the three-quarter views (an average or a single "central" face would
  throw profiles away; the tablet measured profile against profile as low as 0.48). Among qualifiers, pick for **variety**: spread over head pose and over
  **date taken**, so a child's core is not only the age with the most photos. The numbers (3, 20) are starting values for F3.
- **Which faces each step touches** (replaces the earlier "clustering runs only over faces with no `user` label", which ignored `group` and `auto` labels):

  | Faces | Matching to people | Clustering | Changed by the program |
  |---|---|---|---|
  | `ignored` | no | no | never |
  | `user` label | fixed | no | never |
  | `group` label | fixed (they can be *flagged*) | no | flagged only, never moved |
  | `auto` label | re-checked each run: kept while it still matches by the margin rule, else returned to the pool | no | yes |
  | no label | tried against every person's core first | the leftovers only | yes |
- **Corrections stick.** "Not this person" writes a `rejection`; re-clustering and re-matching must respect it.
- **Person ids are permanent.** A person carrying a name or any `user` label is never deleted or renumbered by clustering or indexing; only a user
  action removes one. (Unnamed *groups* are different: their ids are carried across rebuilds by overlap, below, and nothing depends on them.)
- **Correction operations exist from the start:** rename, merge two people, split a group, move a face to another person, "not this person", remove a person's name
  ("dissolve": its faces return to the pool and may form a new unnamed group), and **ignore** a group or a face (strangers, people in the background: never
  clustered, never offered, never searchable, until the user restores them). Dissolve and ignore are different: without ignore, a person you deleted comes back
  on the next index, which Lap still does (§17.1). Each is undoable. Lap has none of the merge, split and move operations, which is why one person ends up in
  several groups there with no repair (§17 row 2).
- **A changed file does not lose its names.** When a labelled photo is edited or rotated, its faces are re-detected; a new face in the same path that matches the
  stored labelled embedding above the threshold, **and wins by the margin over any other face in that picture** (siblings look alike), inherits the label. A label that cannot re-attach goes to a review list and is never deleted silently (§17 row 11).
- **Matching a face to a person:** compare to the person's core (not one vector), accept only above the matching threshold **and** with
  a margin over the runner-up person. Faces below the quality floor are stored but never auto-labelled. The matching threshold and the (stricter)
  clustering threshold are two separate settings in `meta`; Lap's planned fix uses a single distance for both and has no runner-up margin, so two
  lookalike named people would split their faces by a hair.
- **Several samples per person:** one frame is not enough (§3); the CLI and People view ask for at least five varied faces before
  treating a person as enrolled, and say so.
- **Clustering unnamed faces** (to offer groups to name): over ~81,000 faces, all-pairs comparison of 128-d vectors is about 3.3 billion
  dot products (half of n²): feasible in blocks, but a plain single-linkage merge "chains" different people together. Lap's
  [t_cluster.rs](D:/Github/lap/src-tauri/src/t_cluster.rs) shows a workable method: build a k-nearest-neighbour graph (k = 80) from pairs closer than a
  threshold, weight edges by similarity squared so weak links count less, and run **Chinese Whispers** (each face repeatedly takes the label with the most
  weight among its neighbours, up to 20 rounds). It needs no cluster count and scales. Adopt it with these changes, each fixing something Lap's version does:
  - **Never wipe labels.** Lap's `cluster_faces` used to begin by resetting every assignment and deleting every person, and `run_face_indexing` runs it after
    each indexing pass, so a re-run discarded names. (Lap has since changed this; see §17.1.) Here clustering runs **only over the unlabelled faces
    in the table above**, after they have been tried against the existing people (matching rule); Chinese Whispers handles what is left.
  - **Groups are not people.** A cluster is an ephemeral *group*. A `person` row exists only once the user names or confirms a group, so there are no
    stored "Person N" names, no numbering to keep from colliding, and groups can be recomputed freely. Unnamed groups are labelled "Unnamed group N" for
    display only. A rebuilt group takes the id of the old group it shares the most faces with, accepted only when the shared faces cover at least half
    of the smaller side (the rule Lap now uses), matched one-to-one with a fixed tie-break.
  - **Apply atomically.** Clustering writes nothing until it has finished, then writes everything in **one transaction**. A cancelled or failed run
    leaves the data exactly as it was.
  - **Make it repeatable.** Lap shuffles the visiting order with an unseeded random generator, so two runs give different groups. Use a fixed seed, and
    when groups are rebuilt, carry person ids over to the new group with the most overlap.
  - **Keep its cannot-link rule and extend it.** Lap refuses an edge between two faces in the same photo (two people in one photo are two people).
    Keep that, also apply `rejection` rows and treat faces labelled to **different people** (`user` or `group`) as cannot-linked, and, because Chinese Whispers can still join two people through a chain, drop a merged group's faces that
    are cannot-linked to each other (or split it) before showing it.
  - **Singletons are not people.** Lap sets the minimum group size to 1, so every face becomes a "Person N". Use a minimum (start with 3 faces from at
    least 2 different photos, **counted by content key, not by path**: three copies of one photo in a backup folder are one photo); smaller groups stay unnamed faces.
  - **Build the neighbour lists efficiently.** Lap re-sorts a candidate list on every insertion. Use a bounded heap, and blocks for cache use.
  The aim is pure groups that the person merges, not one giant group they must split.
- **The tablet's threshold (0.363) is for matching a camera probe to enrolled faces.** It is a starting value for matching here and not
  for clustering.

## 8. Search integration

- **Resolving names.** The query is scanned for whole words or phrases that equal a person's name or alias (longest first, so "Mary Ann" wins over
  "Mary"; case- and accent-insensitive; a trailing "'s" is dropped: "Priya's"). Each is removed from the text; the rest goes to the usual meaning and
  word search, restricted to the files that contain **all** the named people (an `allowed` set like `kinds`). "priya at the beach" becomes person Priya
  plus "at the beach". The meaning scores keep their whole-library scale (checked: `Searcher` scores every vector before `allowed` filters), so the
  strong/weaker gate means the same thing inside a person's photos as outside.
- **Two people with one name** are allowed. The name then matches both, the panel shows one chip per person with a small sample face to tell them apart,
  and neither is chosen for the user. (Lap's `persons.name` is also non-unique.)
- **Speed.** The person-to-files sets are held in memory by the search service and rebuilt on `reload`, so a name lookup is a hash lookup and the filter
  costs the same as the kind filter.
- **Name collisions.** A person called Rose, Hunter or Bill is also a word. The person results do not replace normal results: the panel
  shows a "Photos of Rose" row or chip beside the usual hits, and the person filter applies only when the user takes it. A query that is
  exactly a person's name opens their album.
- **Person albums are not ranked by meaning.** With nothing left after removing names, there is no meaning score. A person's photos
  (the frame project had groups of 500+) are listed by date taken, newest first, with a "show all" in the window; the panel's strong/weaker
  split and z-gate do not apply.
- **Protocol:** `search-service` gets `people` (names and counts) and a `person` filter on `search`; the shell passes both through (its `ask`
  allowlist in `main.rs` needs the new ops).
- **Unnamed faces are never searchable.** Nothing says "unknown person".

## 9. Evaluation (before choosing a threshold or a second model)

1. Label about 200 photos of 5–10 people: include old photos, a child at several ages, group shots, scans, profiles.
2. Measure for the chosen detector and embedder: faces found against faces present, same- and different-person score distributions,
   precision and recall of "photos of X" at several thresholds, and how often one person is split across groups.
3. **Pass bar (proposed, to be agreed):** at the chosen threshold, at least 95% of the top 20 photos for each person are that person, and
   at least 70% of that person's labelled photos are found; no group mixes two people among its representatives.
4. **Also measure the work asked of the person:** the number of actions (naming a group, merging, moving a face) needed before 90% of the faces that can be
   recognised are named. A model that is slightly more accurate but needs three times the corrections is worse. Run it with and without duplicate collapsing (§5.2).
5. **Harness and data.** Reuse the shape of the existing evals (`evals/*.json`: a base folder, queries, expected results, `digup eval`) with a fixture that lists
   labelled faces and expected people. **No real person's photos are committed to the repository**: the fixture refers to a folder outside it
   (as the evals' `base` does), and the committed tests use generated or licensed pictures.
6. Record date, sample size and results here. If SFace misses the bar on the hard cases, repeat with a stronger embedder behind the same
   interface on the same sample.

## 10. Spikes

| # | Question | Pass |
|---|---|---|
| F1 | Do YuNet, alignment and SFace run through ONNX Runtime on Windows from the helper or a Rust crate, inside the installer? | Embeddings match the Python reference (cosine ≥ 0.98) on a fixed set; installer growth recorded |
| F2 | How long does the face step take per photo here, and so the backfill of the whole library? | Measured seconds per photo and total hours, written down |
| F3 | Does SFace meet the §9 bar on this library? | The §9 numbers |
| F4 | Is there a permissive stronger embedder, and does it beat SFace on the same sample? | Licence checked first, then §9 numbers |
| F5 | How do moved, renamed and edited files reach `faces.sqlite`? | A short note and a test |
| F6 | How many duplicate files does this library hold, and does the content key (size, taken date, first-64 KB hash) separate them without false matches? | A count and a collision check on the real library |
| F7 | Does a face worker process following `digup worker` run safely beside the embedder (memory under the watchdog, background priority, stop on demand)? | Measured memory and CPU while both run; a killed worker leaves the index service running |

(An earlier draft had a spike for "where the face step gets pixels"; the code answers it, §5.2.)

## 11. Privacy and safety

- Face embeddings are **biometric data**. They stay on this computer; faces use no network.
- **Off until turned on** (§5.1). Turning it off stops the worker and offers to delete the data; it does not delete without asking.
- **"Delete all face data"** in Settings deletes `faces.sqlite` and the cached crops. It is also the right first step when the face model changes
  and the person does not want names kept.
- Only folders the person chose are scanned. Unnamed faces are never labelled or revealed.
- At rest the faces file is as protected as the index folder (user-private folder). Encryption is **[decide]**; the frame project deferred it.
- A per-person "private" flag (shown only when that person is searched alone) is cheap to store; decide whether v1 needs the behaviour.
- Check SFace's training-data terms and the model licences before any distribution of this fork.

## 12. Phases

| Phase | Scope | Exit |
|---|---|---|
| P0 | Spikes F1–F5 and the §9 sample | Models and threshold chosen, numbers written here |
| P1 | `digup face-worker`, the face step in the indexing pass for new files, `faces.sqlite` with its table ownership (§6), status counts in the existing `status` reply, `digup faces` with **all** correction operations (name, merge, split, move a face, reject, dissolve, ignore, undo) and the §17 tests | Faces found, grouped and named on a real folder; re-indexing keeps every name |
| P2 | Backfill pass for the existing library; `search-service` person filter; "photos of X" and "X at the beach" in `digup search` | Works from the CLI |
| P3 | People view, person chip and album in the shell; Settings: "Delete all face data" | Usable from the app |
| P4 | Auto-label suggestions with confirm, private flag, a second embedder if §9 says so, videos | As needed |

Each phase's work also updates [design.md](design.md) (what is done and what was checked) and adds an entry to
[downstream-fork-changes.md](downstream-fork-changes.md), with `DOWNSTREAM-FORK` tags in the code.

## 13. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| SFace too weak on old, small, profile or aged faces | Wrong or missed people | Measure on this library first (§9); embedder behind an interface; names anchored to faces (§7) so a swap is cheap |
| ONNX Runtime does not fit the Swift build or installer | Feature cannot ship | F1 first; Rust crate or OpenCV as alternatives |
| Backfill decode of ~49,000 photos is slow | Hours of background work | F2; resumable, low priority, quiet hours, watchdog limits |
| 1024 px pictures lose small faces | Group-shot faces missing | Minimum face size, stated limit; higher-resolution decode later |
| Clustering merges different people | Bad groups, wrong names | Strict threshold, average linkage, user merges, rejections persist |
| Name equals an ordinary word | Hijacked searches | Person result beside normal results, never replacing them (§8) |
| Biometric data and model licences | Privacy and legal exposure | §11; local only; deletion control; licence check before distribution |
| Duplicate files (backup folders) | Repeated scans, doubled albums, groups that look bigger than they are | Content key and one album entry per key (§5.2); F6 |
| A native crash or runaway memory in ONNX Runtime | Index service dies | Face worker in its own process, capped and killable (§5.1); F7 |
| Two processes write one file | Lock waits or lost updates | Table ownership per process, WAL and busy timeout, reload after changes (§6) |
| Too much naming work for the person | Feature goes unused | Measure actions to reach 90% named (§9); good groups, merge and "ignore" for strangers |
| Fork drift from upstream | Merge pain | Tag changes `DOWNSTREAM-FORK` and log them |

## 14. Open questions

1. Panel: a chip, query syntax, or both, for choosing a person?
2. Is encryption at rest needed in v1?
3. Are children in scope for naming, and is the private flag needed in v1?
4. Is the fork ever distributed? If so, licence and consent become blockers (§11).
5. Windows only, or macOS and Linux later?
6. ~~On by default, or opt-in?~~ Decided: **off by default** (§5.1). Still open: opt-in per folder as well as globally?
7. How long should `op_log` (undo) be kept, and should the review list for labels that could not re-attach have a limit?
8. Do aliases need more than a list of names (for example a per-person "known as" shown in results)?

## 15. References

- `D:\Github\smart-search-extension\packages\smart-photos\docs\SmartPhotos.md` — §7.4 (face options), §12.1 (G1 results), §13.1 (library
  face pass and People flow), §10 (privacy).
- [design.md](design.md) — DigUp's plan and status, and the development environment.
- [decoder-worker.md](decoder-worker.md) — the sandboxed decode worker the face step relies on.
- [downstream-fork-changes.md](downstream-fork-changes.md) — where this change is logged once it starts.

## 16. Comparison with Lap's design

Sources: [Person_FaceRecognition.md](D:/Github/lap/docs/guide/Person_FaceRecognition.md), [t_face.rs](D:/Github/lap/src-tauri/src/t_face.rs),
[t_cluster.rs](D:/Github/lap/src-tauri/src/t_cluster.rs), constants in `t_common.rs`. Lap is a shipped feature; this document is a plan. Lap gives no accuracy
or speed figures. "Lap does X" below is what the code shows.

| Area | Lap | This design | Verdict |
|---|---|---|---|
| Detector | `det_500m` (SCRFD-style), input letterboxed to at most 640 px, confidence ≥ 0.65, NMS 0.4 | YuNet on the 1024 px prepared picture | Lap's 640 px cap loses more small faces; keep 1024 and test the detector's input size in F3 |
| Embedder | `w600k_mbf` MobileFaceNet, 512-d, L2-normalised | SFace, 128-d | Lap's is likely stronger; licence is the catch (§4). Candidate for F4 |
| **Alignment** | **None.** Landmarks are never decoded (`landmarks: None`); the embedder gets the box plus 20% padding squeezed to 112 × 112 | Five-landmark alignment is required (§5.1) | Keep ours. ArcFace-style models expect aligned faces; skipping it hurts on turned heads, which this library has. Lap's score distributions should not be trusted as a benchmark |
| Quality filter | Confidence, and **Laplacian variance ≥ 200 on the face box**; the minimum-size filters are commented out | Minimum size and sharpness (§5.2, §7) | Agree on sharpness. Its threshold depends on resolution, so calibrate on the 1024 px pictures, not copy 200 |
| Image source | Stored thumbnail first, else the file; box scaled back to the original size | The embedder's prepared picture (§5.2) | Same idea; ours is better quality than a thumbnail. Lap's scaling of boxes to original coordinates is worth copying for an image-viewer overlay |
| Storage | Same database; `faces(file_id → afiles, person_id → persons)`, cascading delete; persons keep a cover face and a thumbnail | Separate `faces.sqlite` (§6) | Keep ours for the migration reason in §6. Added from Lap: a per-file scan state, including "no faces" |
| Clustering | All faces, all pairs, k-NN graph (k = 80), Chinese Whispers, distance < 0.42, unseeded random order, minimum group 1 | Same family; changed in §7 | Adopted the method, fixed four weaknesses (labels wiped on re-run, non-repeatable, singletons, slow neighbour lists) |
| Same-photo rule | No edge between faces of one file | Same, plus rejections | Adopted |
| Names | Rename and delete person only. **No merge, split, move-face or "not this person"**: `assign_to_person` is called only by the clusterer. Names and people are erased on every re-index (§17) | `label` with source, `rejection`, merge, split, move face, all in the first phase (§7, §17) | Lap is a cautionary example here, not a model. Earlier drafts of this document credited it with merge and assign-face; that was wrong |
| Search | **None by name.** Nothing matches `persons.name`; you pick a person tile in the Person View. Names are for display and sorting | Names resolved inside normal queries, collisions handled (§8) | Our own design, with no reference implementation to copy. It needs its own tests (§17). An earlier draft said Lap searched by name; it does not |
| UI | Person view with tiles, rename, delete, boxes in the viewer, progress and cancel | People view (§12) | Add cancel and progress events (the helper's JSON events fit) and optional box overlay. Merge is not a Lap feature to copy |
| Models | ONNX through the Rust `ort` crate, models in the app's resource folder | ONNX through an `ort`-class runtime, models in the installer | Same; confirms the Rust route is viable |
| Isolation | Opens image files directly (`image::open`) | Pictures arrive from the sandboxed decode worker | Ours is safer for hostile files; Lap's face step is not isolated |

What this comparison changed (see §4, §5.1, §6, §7, §17): a Rust `ort` route, a candidate embedder, a per-file scan state, a fuller clustering
method, and, above all, a list of Lap's defects that this design must not repeat, each with a requirement and a test (§17).

What it did not settle: whether Lap's embedder beats SFace on this library (F3 and F4 still decide), and Lap's real speed.

Checked in Lap's code on 2026-11-17: faces are **not** aligned (landmarks are never decoded; the embedder gets the padded box resized to 112 × 112), and
re-scanning a changed file resets its `has_faces` to 0 (the update builds a fresh record) but the code in that path does not delete the file's old `faces` rows.
Not checked: whether orientation (EXIF or the stored `rotate`) changes the stored boxes.

## 17. Known defects (Lap's and this document's own), and what this design requires

Rows 1–18 come from Lap's own design review of its face feature, plus what I read in its code; rows 19–23 are gaps found by reviewing this document. Each
row is a requirement, and each has a test that fails if the mistake is repeated. Where this design already had the fix, the row says so.

| # | Lap's defect | Requirement here | Test |
|---|---|---|---|
| 1 | **Every index run erases names.** Re-clustering first nulls every `person_id` and deletes every person, so renames are lost and people get new ids. (Lap's untested fix keeps names by overlap matching; it can still lose one, §17.1) | Person ids are permanent. Clustering touches only unlabelled faces, and `auto` labels are re-checked (the table in §7). A person with a name or any `user` or `group` label is never deleted by the program; only the user deletes one (§7) | Name a person, add photos, re-index, re-cluster: same ids, same names, same labelled faces |
| 2 | **No way to correct a cluster** (merge, split, move a face, "not this person") | These are first-class operations in the helper protocol and the CLI from the first phase, not later: rename, merge two people, split a group, move a face, mark "not this person", dissolve a person (name removed, faces kept and returned to the pool), ignore a group or face (§7, row 15). Each is undoable | Each operation, then re-index: the correction survives |
| 3 | **Singleton people:** minimum cluster size is 1 | Minimum 3 faces from at least 2 photos to offer a group; smaller groups stay unnamed faces (§7) | A library with 100 one-off faces yields no new people |
| 4 | **O(n²) clustering on every run, in memory, repeated in full** | Incremental: new faces first join existing people by margin (§7); only the unlabelled pool is clustered, and it shrinks as people are named. Blocked, bounded-heap neighbour search; a progress and cancel path; **nothing is written until the end, then everything in one transaction, so a cancelled or failed run changes nothing** (Lap's fix does this too); a time budget so it cannot block indexing | Adding 100 photos to a 50,000-face library does not recompute every pair; a cancelled run leaves the database unchanged |
| 5 | **Blur measured on a thumbnail crop; small faces rejected; the file marked "no faces" and never retried** | Sharpness and size are measured on the same pixels the detector saw, and recorded **with their unit** (pixels of the prepared picture). A face rejected for quality is **stored**, not dropped (row 6) | A small but real face at the threshold is kept as a low-quality detection, and a file with only such faces is not marked "no faces" |
| 6 | **Rejected faces are not stored, so changing a filter needs a full rescan** | Store every detection above a low confidence floor, with confidence, size and sharpness. Whether a face is *usable* is computed from thresholds kept in `meta`, never stored. Changing a threshold needs no rescan (§6) | Change a threshold: usable faces change, no file is decoded |
| 7 | **"No faces" is final** (`has_faces = 2`) | The `scan` row records the model and the detector settings it was scanned with. A model or detector change marks files for rescan; a quality-threshold change does not (row 6). `failed` files are retried a bounded number of times, then reported | Change the detector setting: files are queued again. Change a quality threshold: they are not |
| 8 | **Non-deterministic clusters** (unseeded shuffle) | Fixed seed; rebuilt groups inherit existing person ids by overlap (§7) | Run clustering twice on the same faces: identical groups |
| 9 | **Two defaults for the threshold** (UI 0.55, Rust 0.42) | One source of truth: thresholds live in `faces.sqlite` `meta` (with the model), and the helper tells the UI the current values. The UI has no copies of defaults | A grep for threshold literals outside the one defaults table finds none |
| 10 | **Embeddings not aligned** (code checked: padded box resized to 112 × 112) | Five-landmark alignment is required (§5.1) and tested against reference vectors | Embedding of a fixed photo matches the reference within the stated cosine |
| 11 | **Stale data when a file changes:** `has_faces` resets but old face rows are not removed (not confirmed beyond the update path) | A changed file (size or mtime) drops its faces and rescans. Labels survive a change by **re-attaching**: the label keeps a copy of the labelled embedding, and a face in the same path that matches it above the threshold inherits the label. A label that cannot re-attach is listed for review and **never silently deleted** | Edit a labelled photo (crop, rotate, re-save): the new face keeps its name, or the label appears in the review list; no duplicate faces |
| 12 | **Boxes may depend on orientation** (not verified in Lap) | Boxes are stored in the coordinates of the prepared picture together with its scale and applied orientation, and tested on pictures with EXIF orientations 3, 6 and 8 (the frame project found orientation bugs in its own pipeline) | A rotated test picture gives boxes that land on the face when drawn on the displayed image |
| 13 | **Name search missing** | Our own design (§8); no reference exists, so it gets its own tests: person plus scene, two people, a name that is also a word, a name shared by two people | Each case listed |
| 14 | **Unencrypted biometric data, undocumented deletion** | §11 states it; the User-visible doc says exactly what "Delete all face data" and removing a file delete | Delete all face data, then confirm no face rows and no cached crops remain |
| 15 | **A deleted person comes back on the next index** (their faces are re-clustered; Lap says it needs an "ignored" flag) | "Dissolve" and "ignore" are separate operations (§7). Ignored faces and groups are excluded from clustering, matching and search until restored | Ignore a group, add photos, re-index: it does not return. Dissolve a person: the faces may regroup |
| 16 | **Two named people can merge into one cluster** when the threshold changes, and a one-to-one name matcher then drops one name (Lap's fix: the loser has no faces and is deleted) | A cluster never contains faces of two different people: faces labelled to different people (`user` or `group`) are cannot-linked, and labelled faces are not re-clustered at all. A person with labelled faces is never deleted for having "no cluster" | Name two similar-looking people, loosen the threshold, re-cluster: both names and all labelled faces are unchanged |
| 17 | **Naming a group makes everything in it permanent** (Lap's planned anchors lock a named cluster as it is, wrong faces included) | Three label strengths (§7). A named group's faces are `group` labels, flagged for review when they disagree with the person's core, never moved silently; "not this person" and move-face fix them. The match core is built from `user` and `group` faces only, never `auto` | Name a group that contains 5 faces of someone else: they are flagged, can be moved with one action, and do not shift the person's matches |
| 18 | **A fix shipped untested** (Lap's author could not compile it) | No item in this table is called fixed, in docs or release notes, until its test has run and passed on this machine; the result is recorded in [design.md](design.md) | The test suite, in the build, before any claim |
| 19 | *(own gap)* **Duplicate files** double albums and defeat the "2 different photos" rule | Content key; one album entry per key; clustering counts a key once (§5.2, §7) | A folder with three copies of one photo yields no group and one album entry |
| 20 | *(own gap)* **A face-step failure could fail indexing** | Face worker in its own process; its failure marks only the `scan` row `failed`; the file stays `done` (§5.1) | Kill the worker mid-run: the index service continues and the meaning vectors are intact |
| 21 | *(own gap)* **Labels tied to face rows are lost when the rows are dropped** | Labels and rejections are anchored by path, box and an embedding copy (§6) | Rescan a labelled file: the label is still attached |
| 22 | *(own gap)* **Undo had no storage; two processes both write; folder removal left biometric data behind** | `op_log`; table ownership per process; removing a folder deletes its faces, labels and copies, and says how many (§6, §11) | Undo each operation; run indexing and a rename at once; remove a folder and find no rows for it |
| 23 | *(own gap)* **A filter at detection time contradicted "store everything"** | A hard floor for meaningless detections and soft thresholds computed later (§5.2) | A threshold change alters usable faces without decoding anything; a 10 px detection is never stored |

Lap's guide also notes that its v0.1.1 release note about face merging "isn't backed by anything in this tree". For this project: **nothing is described in
user-facing docs or release notes until its test exists and passes**, and [design.md](design.md) records what was checked.

### 17.1 Lap's fix for lost names, and what it still lacks

Lap changed `cluster_faces` to write nothing until the end, collect the new clusters as lists of face ids, and hand them to `Person::apply_clusters`
([t_sqlite.rs](D:/Github/lap/src-tauri/src/t_sqlite.rs)), which in one transaction matches each new cluster to the existing person it shares the most faces
with (the shared faces must cover at least half of the smaller side), keeps that person's row, id, name and cover, creates `Person N` for the rest
(numbered above any surviving default name), and deletes persons left with no faces. I read the code and it does this. Its author could not compile it
in their environment, so **it is untested**, and nothing here depends on it working.

Taken from it: apply everything atomically, and the half-of-the-smaller-side overlap rule for carrying a group's id across a rebuild (§7).

Limits Lap lists, and one more found by reading the code, and how this design differs:

| Lap's limit | Here |
|---|---|
| One named person split into several clusters: the largest keeps the name, the others become new "Person N" | Labelled faces stay with their person and are not re-clustered; unlabelled fragments that match the person (margin rule) join it, and the rest stay unnamed groups the user can merge |
| A deleted person returns on the next index (needs an "ignored" flag) | Ignore is its own operation (§7, §17 row 15) |
| A big change to the threshold can still lose a name; named people are not fixed anchors | Labelled faces are the fixed anchors: names do not depend on cluster results at all (§7, §17 row 16) |
| *Found in the code:* matching is one-to-one, so if two named people fall into one cluster the loser has no faces and its row is deleted | Cannot-link between faces of different people, and a person with labelled faces is never deleted by the program (§17 row 16) |

**Lap's planned next steps** (its own estimate, not built; I have not read any code for them):

| Lap's plan | Assessment against this design |
|---|---|
| An `ignored` column on `faces`, set by `Person::delete`; clustering skips ignored faces; only a full reset clears it; no UI to un-ignore | Right idea, but **delete means ignore** there: removing a wrongly merged person would hide every one of its faces, including real people's, with no way back. Here dissolve and ignore are separate, ignore is restorable and undoable (§7, §17 row 15) |
| Let several clusters keep one person (many-to-one), which Lap then proposes to skip | Agree with skipping it: it would re-merge clusters the algorithm judged different. Anchors make the split case a matter of attaching fragments by margin, not of overlap |
| Anchor design: faces of named people stay assigned; only new or unassigned faces are clustered; each goes to the nearest named person if under the threshold, the rest cluster into new "Person N" | Same direction as §7, with four additions: **provenance** so naming a group does not lock its wrong faces in (row 17), a **core** chosen from confirmed faces so matches cannot drift, a **runner-up margin** and **separate thresholds**, and **correction tools in the first phase**. Lap's own caveat applies to them: with named people permanent and no merge or split, a wrong named cluster cannot be repaired |

The structural difference: Lap decides who a person is by **cluster overlap**, which is a guess repeated on each run. This design decides it by **faces the user
confirmed**, and uses clusters only to suggest groups. That is why names survive thresholds, model changes and re-indexing.

## Revision notes (2026-11-17 review)

Fixed after checking the draft against the code and the frame project's document:

1. **Decode cost and pixel source** were hand-waved. The face step now reuses the embedder's prepared picture for new files and treats
   the existing library as a separate backfill (§5.2).
2. **The 1024 px cap** was not noticed: small faces are lost, so a minimum size and a stated limit were added.
3. **Videos** were in scope; their 1024 px, one-per-shot keyframes and ffmpeg backfill make them a later phase.
4. **Names were tied to vectors**, so a model swap would have erased them. Labels now attach to faces, with provenance and rejections.
5. **Clustering at scale** and chaining were unaddressed; a method and thresholds were added. The tablet's matching threshold is no longer
   reused for clustering.
6. **Search** ignored name collisions, the person-album ranking problem and the protocol; each now has a design (§8).
7. **Storage figures** assumed a 512-d embedding; SFace is 128-d, so ~40 MB, not 200 MB. Crops are no longer stored for every face.
8. **Alignment** was missing as a component, and the spike list had a question the code already answers (replaced by F5).
9. **Platform scope, model shipping, resource limits and a pass bar** were missing and were added.

Fixed after comparing with Lap (2026-11-17, and again after Lap's guide was updated):

10. **Wrong claims about Lap corrected.** Earlier drafts said Lap can merge clusters, assign faces to people and search by name. It can do none of those
    (§16, corrected). Name search here is our own design.
11. **§17 added:** Lap's known defects as requirements with tests, including names erased on every re-index, no correction tools, singleton people, repeated full
    clustering, quality filters tied to scan status, filter changes needing a rescan, non-deterministic clusters, and two default thresholds.
12. **Our own draft had the same trap in part:** a "no faces" scan status that could mean "all faces were filtered out". Detections are now stored with their quality,
    and the status records the model and detector it was made with (§6).
13. **Correction operations moved into the first phase**, not left for later.

Fixed after Lap's change for lost names (2026-11-17):

14. **Groups are not people**: a person exists only once the user confirms it, so there are no stored "Person N" names to number or collide (§7).
15. **Atomic apply** of a clustering run in one transaction, so a cancelled run changes nothing (§7, §17 row 4).
16. **"Dissolve" and "ignore" separated**, so a person the user removed does not return on the next index (§7, §17 row 15).
17. **Label strengths (`user`, `group`, `auto`) and a core for matching** (found while reading Lap's planned anchor design): naming a group must not lock its wrong faces
    in, and automatic matches must not widen their own target (§7, §17 row 17). Matching and clustering thresholds are separate, and matching has a runner-up margin.
18. **Cannot-link between differently labelled people** so a changed threshold cannot merge two named people, and a person with labelled faces is never deleted
    for lack of a cluster (§17 row 16). Lap's overlap matcher can lose a name this way; §17.1 explains the difference.

Fixed in a second review of this document (2026-11-17), mostly its own gaps and contradictions (§17 rows 19–23):

19. **Contradictions removed:** the pipeline diagram and §5.2 filtered faces before storing them while §6 stored everything (now a hard floor plus soft thresholds);
    §7 said clustering touched faces with no `user` label while `group` and `auto` labels were undefined for it (now a table of what each step touches);
    "rebuilt groups take a person's id" mixed groups with people; the cannot-link rule named only `user` labels.
20. **Labels were tied to face rows**, so dropping rows on a rescan would have orphaned them. Labels and rejections now carry their own anchor (path, box, embedding copy).
21. **Undo had no storage** (`op_log` added), **two processes wrote one file** (table ownership added), and **removing a folder left biometric data** (it now deletes it).
22. **Duplicate files** were not considered: the library has no content hash, a backup folder likely holds copies, and copies break the "2 different photos" rule.
23. **The face step could crash the index service**; it now runs as its own process, off by default, and a failure never fails a file.
24. **The core of a person was undefined**; it is now defined (a face that matches at least 3 others, varied by pose and date) so profiles and a child's ages are not lost.
25. **Search details:** multi-word names, possessives, accents, two people with one name, and the lookup cost. **Evaluation** now measures the person's naming effort and
    says what data may be committed.
26. **Scope:** faces are scanned for kind `image` only.
