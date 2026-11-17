"""DOWNSTREAM-FORK (2026-11-17): retrying failed files with the real model. See README.md.

1. Indexes a small folder (three text files and a truncated PNG that really fails) with the real model.
2. Marks one good file failed by hand, as a transient worker failure would leave it.
3. search-service lists the failures and `retry all` puts them back to waiting.
4. Control: index-service with background indexing OFF and NO `retry` command reads nothing.
5. index-service told `retry <ids>` reads the good file (done) and the bad picture fails again, counted once.
Needs the model files (MODELS) and the helper built. Run it through retry-e2e.bat. Exit code 0: the retry did what it should.
"""
import json, os, shutil, sqlite3, struct, subprocess, sys, threading, time, zlib

REPO = os.environ["REPO"]
ROOT = os.path.join(os.environ["TEST_ROOT"], "retry-e2e")
DOCS = os.path.join(ROOT, "docs")
IDX = os.path.join(ROOT, "index")
DIGUP = os.path.join(REPO, ".build", "debug", "digup.exe")


def png(width, height):
    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + bytes((x * 7 + y * 3) % 256 for x in range(width * 3)) for y in range(height))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


shutil.rmtree(ROOT, ignore_errors=True)
os.makedirs(DOCS)
for name, text in {"a.txt": "The garden has ferns and moss along the north wall.",
                   "b.txt": "A recipe for apple cake with cinnamon and brown sugar.",
                   "c.txt": "Notes on the history of the lighthouse at the harbor."}.items():
    open(os.path.join(DOCS, name), "w").write(text * 8)
whole = png(400, 300)
open(os.path.join(DOCS, "bad.png"), "wb").write(whole[: len(whole) // 2])   # a real PNG header, cut in half


def run(args):
    return subprocess.run([DIGUP] + args, capture_output=True, text=True, timeout=900)


def states():
    db = sqlite3.connect(os.path.join(IDX, "index.sqlite"))
    try:
        return {os.path.basename(p): s for p, s in db.execute("select path,state from files")}
    finally:
        db.close()


class Helper:
    def __init__(self, args):
        self.p = subprocess.Popen([DIGUP] + args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        self.lines = []
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.p.stdout:
            try:
                self.lines.append(json.loads(line))
            except ValueError:
                pass

    def send(self, text):
        self.p.stdin.write(text + "\n")
        self.p.stdin.flush()

    def wait_for(self, predicate, timeout=60):
        end = time.time() + timeout
        while time.time() < end:
            for event in list(self.lines):
                if predicate(event):
                    return event
            time.sleep(0.1)
        return None


failures = []


def check(name, condition):
    print(("ok   " if condition else "FAIL ") + name)
    if not condition:
        failures.append(name)


print("== 1. index with the real model")
out = run(["index", DOCS, "--index", IDX])
print((out.stdout + out.stderr).strip()[-300:])
first = states()
check("three files are done and the truncated picture failed",
      first == {"a.txt": "done", "b.txt": "done", "c.txt": "done", "bad.png": "failed"})

print("== 2. mark b.txt failed by hand")
db = sqlite3.connect(os.path.join(IDX, "index.sqlite"))
db.execute("update files set state='failed', detail='unreadable: simulated transient failure' where path like '%b.txt'")
db.commit()
db.close()

print("== 3. search-service: failures, then retry all")
search = Helper(["search-service", DOCS, "--index", IDX])
search.wait_for(lambda e: e.get("event") == "ready")
search.send(json.dumps({"id": 1, "op": "failures", "limit": 10}))
listed = search.wait_for(lambda e: e.get("id") == 1)
check("both failed files are listed", listed and listed["count"] == 2)
search.send(json.dumps({"id": 2, "op": "retry", "all": True}))
retry = search.wait_for(lambda e: e.get("id") == 2)
ids = retry["ids"]
search.send(json.dumps({"id": 3, "op": "quit"}))
check("both are waiting again", states()["b.txt"] == "pending" and states()["bad.png"] == "pending")


def index_service(commands):
    service = Helper(["index-service", DOCS, "--index", IDX, "--linger", "3"])   # no --backfill
    for command in commands:
        service.send(command)
    service.wait_for(lambda e: e.get("event") == "exit", timeout=300)
    return service


print("== 4. control: no backfill, no retry command")
index_service([])
check("nothing was read", states()["b.txt"] == "pending" and states()["bad.png"] == "pending")

print("== 5. told to retry", ids)
index_service(["retry " + ",".join(str(i) for i in ids)])
final = states()
check("the good file was read again", final["b.txt"] == "done")
check("the bad picture failed again", final["bad.png"] == "failed")

print("PASS" if not failures else "FAIL: " + ", ".join(failures))
sys.exit(1 if failures else 0)
