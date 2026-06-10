#!/usr/bin/env python3
"""
fetch_test_fixtures.py   (lives in /scratch/group/p.cis260229.000/)

Some crates.io tarballs ship the test *code* (tests/*.rs) but strip the test
*data* (tests/data/**, fixtures, sample files) via `include`/`exclude`, so the
test suite fails at runtime looking for files that aren't there.

Given a list of `name-version` entries, for each crate this:
  1. looks up its repository on crates.io,
  2. resolves the GitHub/GitLab release tag for that version,
  3. fetches the source at that tag, and
  4. copies the **non-.rs** files under the crate's tests/ directory into the
     local crate folder, at the same relative paths.

It does NOT touch Cargo.toml, .rs files, or anything outside tests/. The crate
stays the (buildable) crates.io version; only the missing data files are added.
By default existing files are left alone (only missing ones are written); pass
--overwrite to replace. Archives are cached per (repo, tag) for the run, so the
members of a mono-repo are downloaded only once.

Stdlib only (no requests / jq). Set GITHUB_TOKEN to raise the API rate limit
(only the tag-listing fallback uses the API).

Usage:
    python3 fetch_test_fixtures.py [LIST_FILE] [CRATES_DIR] [options]
      LIST_FILE   default: missing_test_data.log
      CRATES_DIR  default: downloaded_crates   (where <name-version>/ folders live)
    options: --overwrite  --dry-run  --limit N  --only NAME-VER ...  --keep-cache
"""

import argparse
import csv
import os
import re
import shutil
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

USER_AGENT   = "crate-fixture-fetcher (CMU systems research; via crates.io)"
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", "").strip()
HTTP_TIMEOUT = 90
TESTS_DIRNAME = "tests"        # which directory's fixtures to restore

# per-run archive cache:  (repo_id, tag) -> extracted_root
_CACHE = {}
_CACHE_URL = {}


# ------------------------------- HTTP helpers ------------------------------ #
def _req(url, headers=None):
    h = {"User-Agent": USER_AGENT}
    if headers:
        h.update(headers)
    return urllib.request.Request(url, headers=h)


def http_json(url, github_api=False):
    import json
    headers = {"Accept": "application/json"}
    if github_api and GITHUB_TOKEN:
        headers["Authorization"] = f"Bearer {GITHUB_TOKEN}"
    try:
        with urllib.request.urlopen(_req(url, headers), timeout=HTTP_TIMEOUT) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        if e.code in (403, 429) and github_api:
            raise RuntimeError("GitHub API rate-limited; set GITHUB_TOKEN.") from e
        raise


def http_download(url, dest):
    try:
        with urllib.request.urlopen(_req(url), timeout=HTTP_TIMEOUT) as r, \
             open(dest, "wb") as f:
            shutil.copyfileobj(r, f)
        return True
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return False
        raise


# ---------------------------- parsing utilities ---------------------------- #
def split_name_version(s):
    m = re.match(r"^(.*)-(\d[^/]*)$", s.strip())
    return (m.group(1), m.group(2)) if m else (None, None)


def norm(n):
    return n.replace("-", "_").lower() if n else n


def parse_repo(url):
    if not url:
        return (None, None, None, None)
    u = re.sub(r"\.git$", "", url.strip().rstrip("/"))
    p = urllib.parse.urlparse(u if "://" in u else "https://" + u)
    host = p.netloc.lower()
    path = re.split(r"/-/(?:tree|blob)/|/tree/|/blob/", p.path)[0].strip("/")
    parts = [s for s in path.split("/") if s]
    if "github.com" in host and len(parts) >= 2:
        return ("github", parts[0], parts[1], "/".join(parts[:2]))
    if "gitlab.com" in host and len(parts) >= 2:
        return ("gitlab", parts[0], parts[-1], "/".join(parts))
    return (host or "unknown", None, None, None)


def tag_candidates(name, version):
    return [f"v{version}", f"{version}", f"{name}-v{version}", f"{name}-{version}",
            f"{name}@{version}", f"{name}/v{version}", f"{name}/{version}"]


def cargo_package_name(path):
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return None
    m = re.search(r"(?ms)^\[package\]\s*(.*?)(?=^\[|\Z)", text)
    if not m:
        return None
    nm = re.search(r'(?m)^\s*name\s*=\s*"([^"]+)"', m.group(1))
    return nm.group(1) if nm else None


def find_package_dir(root, name):
    target = norm(name)
    matches = []
    for dp, dns, fns in os.walk(root):
        dns[:] = [d for d in dns if d not in (".git", "target", "node_modules")]
        if "Cargo.toml" in fns and \
           norm(cargo_package_name(os.path.join(dp, "Cargo.toml"))) == target:
            matches.append(dp)
    matches.sort(key=lambda p: p.count(os.sep))
    return matches[0] if matches else None


def _best_tag(names, version):
    for t in names:
        if t in (version, f"v{version}"):
            return t
    v = re.escape(version)
    for t in names:
        if re.search(rf"(^|[-/v@]){v}$", t):
            return t
    return None


# --------------------------- archive acquisition --------------------------- #
def _download_tag(host, owner, repo, project_path, tag, cachedir):
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", f"{owner or project_path}_{repo}_{tag}")
    tgz = os.path.join(cachedir, safe + ".tgz")
    out = os.path.join(cachedir, safe)
    if host == "github":
        url = (f"https://codeload.github.com/{owner}/{repo}/tar.gz/refs/tags/"
               + urllib.parse.quote(tag, safe="/"))
    else:  # gitlab (written but untested here)
        enc = urllib.parse.quote(tag, safe="")
        url = f"https://gitlab.com/{project_path}/-/archive/{enc}/{repo}-{enc}.tar.gz"
    if os.path.isdir(out):
        return url, out
    if not http_download(url, tgz):
        return url, None
    os.makedirs(out, exist_ok=True)
    with tarfile.open(tgz) as tf:
        tf.extractall(out)
    os.remove(tgz)
    return url, out


def get_archive(host, owner, repo, project_path, name, version, cachedir):
    """Resolve the matching tag and return (extract_root, tag, url) or Nones,
    reusing the per-run cache so mono-repo members download once."""
    repo_id = f"{host}:{owner}/{repo}" if host == "github" else f"{host}:{project_path}"
    for tag in tag_candidates(name, version):
        if (repo_id, tag) in _CACHE:
            return _CACHE[(repo_id, tag)], tag, _CACHE_URL[(repo_id, tag)]
        url, root = _download_tag(host, owner, repo, project_path, tag, cachedir)
        if root:
            _CACHE[(repo_id, tag)] = root
            _CACHE_URL[(repo_id, tag)] = url
            return root, tag, url
    # fallback: list tags, match by version
    if host == "github":
        api = f"https://api.github.com/repos/{owner}/{repo}/tags?per_page=100"
        tags = http_json(api, github_api=True) or []
    else:
        enc = urllib.parse.quote(project_path, safe="")
        api = f"https://gitlab.com/api/v4/projects/{enc}/repository/tags?per_page=100"
        tags = http_json(api) or []
    pick = _best_tag([t.get("name", "") for t in tags], version)
    if pick:
        if (repo_id, pick) in _CACHE:
            return _CACHE[(repo_id, pick)], pick, _CACHE_URL[(repo_id, pick)]
        url, root = _download_tag(host, owner, repo, project_path, pick, cachedir)
        if root:
            _CACHE[(repo_id, pick)] = root
            _CACHE_URL[(repo_id, pick)] = url
            return root, pick, url
    return None, None, None


# --------------------------------- core ------------------------------------ #
def copy_fixtures(pkg_dir, local_dir, overwrite, dry_run):
    """Copy non-.rs files under pkg_dir/tests/ into local_dir/tests/...
    Returns (copied, skipped_existing)."""
    src_tests = os.path.join(pkg_dir, TESTS_DIRNAME)
    if not os.path.isdir(src_tests):
        return (0, 0, "no tests/ in repo")
    copied = skipped = 0
    for dp, dns, fns in os.walk(src_tests):
        dns[:] = [d for d in dns if d != ".git"]
        for fn in fns:
            if fn.endswith(".rs"):
                continue
            src = os.path.join(dp, fn)
            rel = os.path.relpath(src, pkg_dir)        # e.g. tests/data/x.zip
            dst = os.path.join(local_dir, rel)
            if os.path.exists(dst) and not overwrite:
                skipped += 1
                continue
            if not dry_run:
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copy2(src, dst)
            copied += 1
    return (copied, skipped, "ok")


def process(line, crates_dir, cachedir, args, writer, fh):
    name, version = split_name_version(line)
    row = {"crate": line, "name": name or "", "version": version or "",
           "repository": "", "host": "", "resolved_tag": "",
           "files_copied": 0, "status": ""}

    def rec(status, copied=0):
        row["status"] = status
        row["files_copied"] = copied
        writer.writerow(row)
        fh.flush()
        n = f" (+{copied})" if copied else ""
        print(f"    {line:<44} {status}{n}")

    if not name:
        return rec("skip: unparseable")
    local_dir = os.path.join(crates_dir, line)
    if not os.path.isdir(local_dir):
        return rec("skip: local folder not found")

    try:
        data = http_json(f"https://crates.io/api/v1/crates/{urllib.parse.quote(name)}")
    except Exception as e:
        return rec(f"crates.io error: {e}")
    repo_url = (data or {}).get("crate", {}).get("repository", "") or ""
    row["repository"] = repo_url
    if not repo_url:
        return rec("no repository on crates.io")
    host, owner, repo, project_path = parse_repo(repo_url)
    row["host"] = host or ""
    if host not in ("github", "gitlab"):
        return rec(f"unsupported host: {host}")

    root, tag, _url = get_archive(host, owner, repo, project_path, name, version, cachedir)
    if not root:
        return rec("no matching release tag")
    row["resolved_tag"] = tag
    pkg = find_package_dir(root, name)
    if not pkg:
        return rec(f"tag {tag}: package '{name}' not in archive")

    copied, skipped, why = copy_fixtures(pkg, local_dir, args.overwrite, args.dry_run)
    if why != "ok":
        return rec(f"tag {tag}: {why}")
    verb = "would copy" if args.dry_run else "copied"
    extra = f", {skipped} already present" if skipped else ""
    return rec(f"{verb} from {tag}{extra}", copied)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("list_file", nargs="?", default="missing_test_data.log")
    ap.add_argument("crates_dir", nargs="?", default="downloaded_crates")
    ap.add_argument("--overwrite", action="store_true",
                    help="overwrite fixtures that already exist locally")
    ap.add_argument("--dry-run", action="store_true", help="report only; copy nothing")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--only", nargs="*", default=None)
    ap.add_argument("--keep-cache", action="store_true",
                    help="don't delete the downloaded-archive cache on exit")
    ap.add_argument("--log", default="test_fixtures_fetched.csv")
    args = ap.parse_args()

    if not os.path.isfile(args.list_file):
        sys.exit(f"ERROR: list file not found: {args.list_file}")
    if not os.path.isdir(args.crates_dir):
        sys.exit(f"ERROR: crates dir not found: {args.crates_dir}")

    lines = []
    for raw in open(args.list_file, encoding="utf-8"):
        s = raw.strip()
        if s and not s.startswith("#"):
            lines.append(s)
    if args.only:
        want = set(args.only)
        lines = [l for l in lines if l in want]
    if args.limit:
        lines = lines[:args.limit]

    print(f"==> {len(lines)} crate(s); copying non-.rs {TESTS_DIRNAME}/ fixtures "
          f"into {args.crates_dir}/")
    if args.dry_run:
        print("    DRY RUN: nothing will be written")
    if not GITHUB_TOKEN:
        print("    note: GITHUB_TOKEN not set; tag-listing fallback may hit the "
              "GitHub API rate limit")
    print()

    cachedir = tempfile.mkdtemp(prefix=".fixture_cache_",
                                dir=os.path.dirname(os.path.abspath(args.crates_dir)) or ".")
    try:
        with open(args.log, "w", newline="", encoding="utf-8") as fh:
            writer = csv.DictWriter(fh, fieldnames=[
                "crate", "name", "version", "repository", "host",
                "resolved_tag", "files_copied", "status"])
            writer.writeheader()
            for line in lines:
                try:
                    process(line, args.crates_dir, cachedir, args, writer, fh)
                except Exception as e:
                    writer.writerow({"crate": line, "name": "", "version": "",
                                     "repository": "", "host": "", "resolved_tag": "",
                                     "files_copied": 0, "status": f"error: {e}"})
                    fh.flush()
                    print(f"    {line:<44} error: {e}")
                time.sleep(0.2)
    finally:
        if not args.keep_cache:
            shutil.rmtree(cachedir, ignore_errors=True)

    print(f"\n==> done. Log written to {args.log}")


if __name__ == "__main__":
    main()