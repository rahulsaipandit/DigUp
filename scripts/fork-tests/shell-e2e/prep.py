"""DOWNSTREAM-FORK (2026-11-17): prepares what the shell end-to-end run needs, in TEST_ROOT/shell-e2e: a folder with three good text
files and a truncated PNG (really bad), an index of it made with the real model, one good file marked failed by hand (as a transient
worker failure would leave it), and a settings file for the shell (set up, update checks off, an obscure hotkey). See README.md.
"""
import json, os, shutil, sqlite3, struct, subprocess, zlib

REPO = os.environ["REPO"]
ROOT = os.path.join(os.environ["TEST_ROOT"], "shell-e2e")
DOCS = os.path.join(ROOT, "docs")
IDX = os.path.join(ROOT, "index")
DIGUP = os.path.join(REPO, ".build", "debug", "digup.exe")

def png(width, height):
    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xffffffff)
    raw = b"".join(b"\x00" + bytes((x * 7 + y * 3) % 256 for x in range(width * 3)) for y in range(height))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))

shutil.rmtree(ROOT, ignore_errors=True)
os.makedirs(DOCS)
for name, text in {"garden notes.txt": "The garden has ferns and moss along the north wall.",
                   "apple cake.txt": "A recipe for apple cake with cinnamon and brown sugar.",
                   "lighthouse.txt": "Notes on the history of the lighthouse at the harbor."}.items():
    open(os.path.join(DOCS, name), "w").write(text * 8)
good = png(400, 300)
open(os.path.join(DOCS, "holiday photo.png"), "wb").write(good[: len(good) // 2])   # a real PNG header, cut in half

r = subprocess.run([DIGUP, "index", DOCS, "--index", IDX], capture_output=True, text=True, timeout=600)
print((r.stdout + r.stderr).strip()[-400:])

db = sqlite3.connect(IDX + r"\index.sqlite")
db.execute("update files set state='failed', detail='unreadable: PDF reader couldn''t start: sandbox: make container failed (Windows error 5)' where path like '%apple cake.txt'")
db.commit()
print("states:", db.execute("select path,state from files order by path").fetchall())
db.close()

settings = {"folders": [DOCS], "setUp": True, "updateChecksOff": True, "hotkey": "Ctrl+Alt+Shift+F11"}
json.dump(settings, open(ROOT + r"\settings.json", "w"), indent=2)
print("prepared", ROOT)
