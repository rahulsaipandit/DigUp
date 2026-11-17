"""DOWNSTREAM-FORK (2026-11-17): does the decode worker start when its helper is already inside a job object, as it is under the shell?

The shell puts every helper in a job that ends them with it (helper.rs, `mod job`). The worker is started in a job of its own
(Sandbox+Windows.swift), so it is a nested job. A first version of that failed under the shell with "assign to job failed (Windows
error 50)", which no unit test saw because a test runner is not in such a job. This puts this process in a job configured like the
shell's, runs `digup estimate` on a folder with a 7-page PDF (which reads the page count through the worker, and falls back to 1 page
quietly if the worker cannot start), and reports the page count and the decode-worker log.

  python job-nesting.py VARIANT     VARIANT: none | kill | ui | kill+ui   (what the parent job has; the shell's has kill+ui)
Run it through job-nesting.bat, which runs every variant. Exit code 0: the worker started (7 pages).
"""
import ctypes, os, re, shutil, subprocess, sys
from ctypes import wintypes

variant = sys.argv[1] if len(sys.argv) > 1 else "kill+ui"
REPO = os.environ["REPO"]
ROOT = os.path.join(os.environ["TEST_ROOT"], "job-nesting")
DOCS = os.path.join(ROOT, "docs")
DIGUP = os.path.join(REPO, ".build", "debug", "digup.exe")
PDF = os.environ.get("TEST_PDF", r"D:\Github\GoogleSearchUsingEmbeddingGemmaForRAG.pdf")   # any PDF of several pages

os.makedirs(DOCS, exist_ok=True)
shutil.copy(PDF, os.path.join(DOCS, "seven pages.pdf"))

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
kernel32.CreateJobObjectW.restype = wintypes.HANDLE
kernel32.GetCurrentProcess.restype = wintypes.HANDLE
kernel32.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
kernel32.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]


class BASIC(ctypes.Structure):
    _fields_ = [("PerProcessUserTimeLimit", ctypes.c_longlong), ("PerJobUserTimeLimit", ctypes.c_longlong), ("LimitFlags", wintypes.DWORD),
                ("MinimumWorkingSetSize", ctypes.c_size_t), ("MaximumWorkingSetSize", ctypes.c_size_t), ("ActiveProcessLimit", wintypes.DWORD),
                ("Affinity", ctypes.c_size_t), ("PriorityClass", wintypes.DWORD), ("SchedulingClass", wintypes.DWORD)]


class IO(ctypes.Structure):
    _fields_ = [(n, ctypes.c_ulonglong) for n in ("a", "b", "c", "d", "e", "f")]


class EXTENDED(ctypes.Structure):
    _fields_ = [("Basic", BASIC), ("Io", IO), ("ProcessMemoryLimit", ctypes.c_size_t), ("JobMemoryLimit", ctypes.c_size_t),
                ("PeakProcessMemoryUsed", ctypes.c_size_t), ("PeakJobMemoryUsed", ctypes.c_size_t)]


class UI(ctypes.Structure):
    _fields_ = [("UIRestrictionsClass", wintypes.DWORD)]


KILL_ON_CLOSE = 0x2000
# DESKTOP, DISPLAYSETTINGS, EXITWINDOWS, GLOBALATOMS, READCLIPBOARD, SYSTEMPARAMETERS, WRITECLIPBOARD
UI_FLAGS = 0x40 | 0x10 | 0x80 | 0x20 | 0x2 | 0x8 | 0x4

if variant != "none":
    job = kernel32.CreateJobObjectW(None, None)
    if "kill" in variant:
        limits = EXTENDED()
        limits.Basic.LimitFlags = KILL_ON_CLOSE
        assert kernel32.SetInformationJobObject(job, 9, ctypes.byref(limits), ctypes.sizeof(limits)), ctypes.get_last_error()
    if "ui" in variant:
        ui = UI(UI_FLAGS)
        assert kernel32.SetInformationJobObject(job, 4, ctypes.byref(ui), ctypes.sizeof(ui)), ctypes.get_last_error()
    assert kernel32.AssignProcessToJobObject(job, kernel32.GetCurrentProcess()), ctypes.get_last_error()

env = dict(os.environ, DIGUP_DECODE_LOG=os.path.join(ROOT, "decode.log"))
out = subprocess.run([DIGUP, "estimate", DOCS], capture_output=True, text=True, timeout=120, env=env).stdout
pages = re.search(r"\((\d+) pages", out)
count = int(pages.group(1)) if pages else None
print(f"variant {variant:8s}  pages read: {count}  ->  " + ("the worker started" if count and count > 1 else "THE WORKER DID NOT START (one page is the fallback)"))
sys.exit(0 if count and count > 1 else 1)
