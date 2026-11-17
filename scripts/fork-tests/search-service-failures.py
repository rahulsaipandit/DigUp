"""DOWNSTREAM-FORK (2026-11-17): the real `digup search-service` answering the failed-files questions. See README.md.

Makes a small index with failed files in it, starts the helper as the shell does (JSON lines on stdin and stdout), and checks:
  failures with no limit    -> the count, and no files (a cheap question)
  failures with a limit     -> the files, with their reasons, by path
  retry one named file      -> that file is put back to waiting, and its id is returned
  retry all                 -> the rest are put back to waiting
It needs no model. Run it through search-service-failures.bat (which sets the environment); exit code 0 means every check held.
"""
import json, os, shutil, sqlite3, subprocess, sys

REPO = os.environ["REPO"]
ROOT = os.path.join(os.environ["TEST_ROOT"], "search-service-failures")
IDX = os.path.join(ROOT, "index")
DIGUP = os.path.join(REPO, ".build", "debug", "digup.exe")

shutil.rmtree(ROOT, ignore_errors=True)
os.makedirs(IDX)
subprocess.run([DIGUP, "status", "--index", IDX], check=True, capture_output=True)   # makes the (empty) index

REASON = "unreadable: PDF reader couldn't start: sandbox: make container failed (Windows error 5)"
rows = [("D:/docs/a.pdf", "pdf", "failed", REASON), ("D:/docs/b.pdf", "pdf", "failed", REASON),
        ("D:/pics/c.jpg", "image", "failed", "unreadable: can't decode image"),
        ("D:/docs/d.docx", "doc", "done", None), ("D:/docs/e.txt", "doc", "pending", None)]
db = sqlite3.connect(os.path.join(IDX, "index.sqlite"))
db.executemany("INSERT INTO files(path,kind,size,mtime,inode,device,state,detail) VALUES(?,?,100,1.0,?,1,?,?)",
               [(p, k, i + 1, s, d) for i, (p, k, s, d) in enumerate(rows)])
db.commit()

proc = subprocess.Popen([DIGUP, "search-service", "--index", IDX], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL, text=True)
assert json.loads(proc.stdout.readline())["event"] == "ready"
ask_id = 0

def ask(**request):
    global ask_id
    ask_id += 1
    proc.stdin.write(json.dumps({"id": ask_id, **request}) + "\n")
    proc.stdin.flush()
    while True:
        reply = json.loads(proc.stdout.readline())
        if reply.get("id") == ask_id:
            return reply

def states():
    return {os.path.basename(p): s for p, s in db.execute("select path,state from files")}

failures = []
def check(name, condition):
    print(("ok   " if condition else "FAIL ") + name)
    if not condition:
        failures.append(name)

count_only = ask(op="failures")
check("a count with no limit has no files", count_only["count"] == 3 and count_only["files"] == [])
listed = ask(op="failures", limit=10)
check("the files come with their reasons, by path",
      [f["path"] for f in listed["files"]] == ["D:/docs/a.pdf", "D:/docs/b.pdf", "D:/pics/c.jpg"]
      and listed["files"][0]["detail"] == REASON and listed["files"][2]["detail"] == "unreadable: can't decode image")
one = ask(op="retry", files=[{"id": 3, "code": False}])
check("retrying one file returns its id", one["ids"] == [3] and one["code_ids"] == [])
check("that file is waiting and the others are as they were",
      states() == {"a.pdf": "failed", "b.pdf": "failed", "c.jpg": "pending", "d.docx": "done", "e.txt": "pending"})
check("the count is now 2", ask(op="failures")["count"] == 2)
not_failed = ask(op="retry", files=[{"id": 4, "code": False}])
check("a file that is not failed (done) is left alone", not_failed["ids"] == [] and states()["d.docx"] == "done")
everything = ask(op="retry", all=True)
check("retry all returns the rest", sorted(everything["ids"]) == [1, 2])
check("nothing is failed now", ask(op="failures")["count"] == 0
      and states() == {"a.pdf": "pending", "b.pdf": "pending", "c.jpg": "pending", "d.docx": "done", "e.txt": "pending"})
ask(op="quit")
print("PASS" if not failures else "FAIL: " + ", ".join(failures))
sys.exit(1 if failures else 0)
