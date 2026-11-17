#!/usr/bin/env python3
# DOWNSTREAM-FORK (2026-11-17, security): new in the fork. Checks the C libraries this repository pins against the National
# Vulnerability Database, so a new advisory against FFmpeg, dav1d or SQLite shows up in CI and not by chance. (The Rust packages
# are checked by `cargo audit`, see .github/workflows/security.yml.)
#
#   FFmpeg, dav1d, SQLite: the pinned version is read from scripts/build-ffmpeg.sh and scripts/fetch-vendor.sh, and NVD is asked for
#     the CVEs whose configuration matches exactly that version. Each CVE not listed in scripts/advisories-acknowledged.txt fails
#     the check, so that every one is looked at once (does a decoder DigUp enables reach it? is the fix in a newer release?) and
#     then written down, with the reason, in that file.
#   PDFium: pdfium-binaries is pinned by Chromium's build number (chromium/NNNN), which NVD has no product version for. NVD's
#     PDFium entries say "in Google Chrome prior to 157.0.8103.38", so the check reads that build number (8103) and fails for every
#     CVE of the last year that was fixed in a later build than the pin's. Update the pin (scripts/fetch-vendor.sh and
#     scripts/vendor-checksums.json together) or, with a reason, list the CVE in the acknowledged file.
#
# Needs only Python 3 and the network. NVD allows 5 requests in 30 seconds without a key: set NVD_API_KEY for more.
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
API = "https://services.nvd.nist.gov/rest/json/cves/2.0"


def pinned(path, pattern):
    match = re.search(pattern, (ROOT / path).read_text(encoding="utf-8"), re.M)
    if not match:
        sys.exit(f"check-advisories: no pin found in {path} for {pattern!r}")
    return match.group(1)


def get(params):
    url = API + "?" + urllib.parse.urlencode(params)
    request = urllib.request.Request(url, headers={"User-Agent": "digup-advisory-check"})
    if os.environ.get("NVD_API_KEY"):
        request.add_header("apiKey", os.environ["NVD_API_KEY"])
    for attempt in range(5):
        try:
            with urllib.request.urlopen(request, timeout=60) as reply:
                return json.load(reply)
        except urllib.error.HTTPError as error:
            if error.code not in (403, 429, 503) or attempt == 4:
                raise
        except (TimeoutError, urllib.error.URLError):  # NVD is slow and drops requests at times
            if attempt == 4:
                raise
        time.sleep(35)  # the rate limit's window
    raise RuntimeError("unreachable")


def cves(params):
    found = []
    start = 0
    while True:
        page = get({**params, "startIndex": start})
        found += [item["cve"] for item in page.get("vulnerabilities", [])]
        start += page.get("resultsPerPage", 0)
        if start >= page.get("totalResults", 0) or not page.get("resultsPerPage"):
            return found
        time.sleep(7)


def describe(cve):
    text = next((d["value"] for d in cve.get("descriptions", []) if d["lang"] == "en"), "")
    score = ""
    for key in ("cvssMetricV40", "cvssMetricV31", "cvssMetricV30"):
        for metric in cve.get("metrics", {}).get(key, []):
            score = f" CVSS {metric['cvssData']['baseScore']}"
            break
        if score:
            break
    return f"{cve['id']}{score}: {text[:200]}"


def acknowledged():
    path = ROOT / "scripts" / "advisories-acknowledged.txt"
    ids = set()
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.split("#", 1)[0].strip()
            if line:
                ids.add(line.split()[0])
    return ids


def main():
    libraries = [
        ("FFmpeg", "cpe:2.3:a:ffmpeg:ffmpeg:{}:*:*:*:*:*:*:*", pinned("scripts/build-ffmpeg.sh", r"^FFMPEG_VERSION=(\S+)")),
        ("dav1d", "cpe:2.3:a:videolan:dav1d:{}:*:*:*:*:*:*:*", pinned("scripts/build-ffmpeg.sh", r"^DAV1D_VERSION=(\S+)")),
        # SQLITE_ZIP=2026/sqlite-amalgamation-3540000.zip -> 3.54.0
        ("SQLite", "cpe:2.3:a:sqlite:sqlite:{}:*:*:*:*:*:*:*", None),
    ]
    zipname = pinned("scripts/fetch-vendor.sh", r"^SQLITE_ZIP=\S*sqlite-amalgamation-(\d+)\.zip")
    libraries[2] = (libraries[2][0], libraries[2][1], f"{int(zipname[0])}.{int(zipname[1:3])}.{int(zipname[3:5])}")

    known = acknowledged()
    failed = False
    for name, cpe, version in libraries:
        found = cves({"cpeName": cpe.format(version), "isVulnerable": ""})
        new = [c for c in found if c["id"] not in known]
        print(f"{name} {version}: {len(found)} CVE(s) in NVD, {len(found) - len(new)} acknowledged, {len(new)} not yet looked at")
        for cve in new:
            print(f"  ::error::{name} {version} {describe(cve)}")
            failed = True
        time.sleep(7)

    # PDFium. pdfium-binaries' tag is Chromium's build number (chromium/8086 is the third part of a version like 156.0.8086.x), and
    # Chrome's advisories say "prior to 157.0.8103.38": a fix in a later build than the pin's is one the pin does not have.
    tag = pinned("scripts/fetch-vendor.sh", r"^PDFIUM_TAG=chromium/(\d+)")
    # NVD takes a publication range of at most 120 days, so the last year goes in windows.
    now = datetime.now(timezone.utc)
    recent = []
    for window in range(4):
        end, start = now - timedelta(days=120 * window), now - timedelta(days=120 * (window + 1))
        recent += cves({"keywordSearch": "pdfium", "pubStartDate": start.strftime("%Y-%m-%dT%H:%M:%S.000"),
                        "pubEndDate": end.strftime("%Y-%m-%dT%H:%M:%S.000")})
        time.sleep(7)
    missing, other = [], []
    for cve in recent:
        text = next((d["value"] for d in cve.get("descriptions", []) if d["lang"] == "en"), "")
        fixed = re.search(r"prior to \d+\.\d+\.(\d+)\.\d+", text)
        if "PDFium" not in text and "pdfium" not in text:
            continue
        if fixed and int(fixed.group(1)) > int(tag) and cve["id"] not in known:
            missing.append(cve)
        else:
            other.append(cve)
    print(f"PDFium (chromium/{tag}): {len(missing)} CVE(s) of the last year fixed in a later build than the pin, {len(other)} fixed "
          "in it or earlier (or acknowledged)")
    for cve in missing:
        print(f"  ::error::PDFium chromium/{tag} {describe(cve)}")
        failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
