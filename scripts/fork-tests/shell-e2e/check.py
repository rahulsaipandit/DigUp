"""DOWNSTREAM-FORK (2026-11-17): after the shell end-to-end run, what the index says: the good file marked failed was read again (done),
and the really bad picture failed again (failed). Exit code 0 if so. See ../README.md."""
import os, sqlite3, sys

index = os.path.join(os.environ["TEST_ROOT"], "shell-e2e", "index", "index.sqlite")
import time
states = None
for attempt in range(20):   # the helpers may still be exiting and releasing the database
    try:
        db = sqlite3.connect(index)
        states = {os.path.basename(p): s for p, s in db.execute("select path,state from files")}
        db.close()
        break
    except sqlite3.OperationalError:
        time.sleep(0.5)
if states is None:
    print("FAIL: the index could not be read")
    sys.exit(1)
print(states)
ok = states.get("apple cake.txt") == "done" and states.get("holiday photo.png") == "failed" and states.get("garden notes.txt") == "done"
print("PASS" if ok else "FAIL: the index is not as it should be after the retry")
sys.exit(0 if ok else 1)
