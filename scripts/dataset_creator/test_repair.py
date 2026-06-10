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
  4. copies files under the crate's tests/ directory into the
     local crate folder, at the same relative paths.

It does NOT touch Cargo.toml or anything outside tests/. The crate
stays the (buildable) crates.io version; only the missing data files are added.
By default existing files are overwritten; pass --no-overwrite to preserve
existing files. Archives are cached per (repo, tag) for the run, so the
members of a mono-repo are downloaded only once.

Stdlib only (no requests / jq). Set GITHUB_TOKEN to raise the API rate limit
(only the tag-listing fallback uses the API).

Usage:
    python3 fetch_test_fixtures.py [LIST_FILE] [CRATES_DIR] [options]
      LIST_FILE   default: missing_test_data.log
      CRATES_DIR  default: downloaded_crates   (where <name-version>/ folders live)
    options: --no-overwrite  --dry-run  --limit N  --only NAME-VER ...  --keep-cache
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
# directories (relative to the crate's package root) whose files are
# treated as test fixtures and restored into the local crate folder
FIXTURE_DIRS = ["tests", "testdata", "test", "src/unicode/data", "src/tests"]

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
def _download(host, owner, repo, project_path, ref, cachedir, is_branch=False):
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", f"{owner or project_path}_{repo}_{ref}")
    tgz = os.path.join(cachedir, safe + ".tgz")
    out = os.path.join(cachedir, safe)
    if host == "github":
        kind = "heads" if is_branch else "tags"
        url = (f"https://codeload.github.com/{owner}/{repo}/tar.gz/refs/{kind}/"
               + urllib.parse.quote(ref, safe="/"))
    else:  # gitlab (written but untested here); archive endpoint takes any ref
        enc = urllib.parse.quote(ref, safe="")
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


def _take(repo_id, host, owner, repo, project_path, ref, cachedir, is_branch=False):
    """Download+extract a ref (cache-aware). Returns (root, url) or (None, url)."""
    if (repo_id, ref) in _CACHE:
        return _CACHE[(repo_id, ref)], _CACHE_URL[(repo_id, ref)]
    url, root = _download(host, owner, repo, project_path, ref, cachedir, is_branch)
    if root:
        _CACHE[(repo_id, ref)] = root
        _CACHE_URL[(repo_id, ref)] = url
    return root, url


def latest_ref(host, owner, repo, project_path):
    """(ref, is_branch) for the repo's latest release, else its default branch."""
    if host == "github":
        rel = http_json(f"https://api.github.com/repos/{owner}/{repo}/releases/latest",
                        github_api=True)
        if rel and rel.get("tag_name"):
            return rel["tag_name"], False
        info = http_json(f"https://api.github.com/repos/{owner}/{repo}", github_api=True)
        if info and info.get("default_branch"):
            return info["default_branch"], True
    else:
        enc = urllib.parse.quote(project_path, safe="")
        tags = http_json(f"https://gitlab.com/api/v4/projects/{enc}/repository/tags"
                         f"?order_by=updated&sort=desc&per_page=1") or []
        if tags and tags[0].get("name"):
            return tags[0]["name"], False
        info = http_json(f"https://gitlab.com/api/v4/projects/{enc}") or {}
        if info.get("default_branch"):
            return info["default_branch"], True
    return None, None


def get_archive(host, owner, repo, project_path, name, version, cachedir):
    """Resolve a source ref and return (extract_root, ref_label, url, kind),
    kind in {'exact','latest'}, or (None, None, None, None). Caches per ref so
    mono-repo members download once."""
    repo_id = f"{host}:{owner}/{repo}" if host == "github" else f"{host}:{project_path}"
    # 1) version-matched tag spellings
    for tag in tag_candidates(name, version):
        root, url = _take(repo_id, host, owner, repo, project_path, tag, cachedir)
        if root:
            return root, tag, url, "exact"
    # 2) list tags, match one by version
    if host == "github":
        tags = http_json(f"https://api.github.com/repos/{owner}/{repo}/tags?per_page=100",
                         github_api=True) or []
    else:
        enc = urllib.parse.quote(project_path, safe="")
        tags = http_json(f"https://gitlab.com/api/v4/projects/{enc}/repository/tags"
                         f"?per_page=100") or []
    pick = _best_tag([t.get("name", "") for t in tags], version)
    if pick:
        root, url = _take(repo_id, host, owner, repo, project_path, pick, cachedir)
        if root:
            return root, pick, url, "exact"
    # 3) fallback: latest release, else default branch
    ref, is_branch = latest_ref(host, owner, repo, project_path)
    if ref:
        root, url = _take(repo_id, host, owner, repo, project_path, ref, cachedir, is_branch)
        if root:
            return root, (f"{ref} (branch)" if is_branch else ref), url, "latest"
    return None, None, None, None


# --------------------------------- core ------------------------------------ #
def copy_fixtures(pkg_dir, local_dir, overwrite, dry_run):
    """Copy files under each FIXTURE_DIRS entry (relative to pkg_dir)
    into local_dir at the same relative path. Returns (copied, skipped, status)."""
    copied = skipped = 0
    found_any = False
    for rel_dir in FIXTURE_DIRS:
        src_root = os.path.join(pkg_dir, rel_dir)
        if not os.path.isdir(src_root):
            continue
        found_any = True
        for dp, dns, fns in os.walk(src_root):
            dns[:] = [d for d in dns if d != ".git"]
            for fn in fns:
                src = os.path.join(dp, fn)
                rel = os.path.relpath(src, pkg_dir)    # e.g. tests/data/x.zip
                dst = os.path.join(local_dir, rel)
                if os.path.exists(dst) and not overwrite:
                    skipped += 1
                    continue
                if not dry_run:
                    os.makedirs(os.path.dirname(dst), exist_ok=True)
                    shutil.copy2(src, dst)
                copied += 1
    if not found_any:
        return (0, 0, "no fixture dirs in repo")
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

    root, ref, _url, kind = get_archive(host, owner, repo, project_path,
                                        name, version, cachedir)
    if not root:
        return rec("no matching tag and no latest available")
    row["resolved_tag"] = ref
    pkg = find_package_dir(root, name)
    if not pkg:
        return rec(f"{ref}: package '{name}' not in archive")

    copied, skipped, why = copy_fixtures(pkg, local_dir, args.overwrite, args.dry_run)
    if why != "ok":
        return rec(f"{ref}: {why}")
    verb = "would copy" if args.dry_run else "copied"
    extra = f", {skipped} already present" if skipped else ""
    label = ref if kind == "exact" else f"{ref} [LATEST: v{version} not tagged]"
    return rec(f"{verb} from {label}{extra}", copied)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("list_file", nargs="?", default="missing_test_data.log")
    ap.add_argument("crates_dir", nargs="?", default="downloaded_crates")
    ap.add_argument("--no-overwrite", action="store_false", dest="overwrite",
                    help="do not overwrite fixtures that already exist locally (default: overwrite)",
                    default=True)
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

    print(f"==> {len(lines)} crate(s); copying non-.rs fixtures from "
          f"{', '.join(d + '/' for d in FIXTURE_DIRS)} into {args.crates_dir}/")
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
