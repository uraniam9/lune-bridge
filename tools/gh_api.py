#!/usr/bin/env python3
"""
Small GitHub API helper that borrows the credential git already has.

There is no `gh` CLI on this machine, but Git Credential Manager holds a token
for github.com after the first push. `git credential fill` is the supported way
to ask for it, so this uses that rather than asking anyone to paste a token
somewhere.

The token is never printed, never written to disk, and never placed on a
command line where another process could read it from the process list.

  python tools/gh_api.py topics <owner/repo> <topic> [topic...]
  python tools/gh_api.py release <owner/repo> <tag> <title> <notes-file> [asset...]
"""

import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

API = "https://api.github.com"
UPLOADS = "https://uploads.github.com"


def token():
    """Ask git for the github.com credential it already stores."""
    out = subprocess.run(
        ["git", "credential", "fill"],
        input="protocol=https\nhost=github.com\n\n",
        capture_output=True, text=True, check=True,
    ).stdout
    for line in out.splitlines():
        if line.startswith("password="):
            return line.split("=", 1)[1]
    raise SystemExit("no github.com credential stored - run a git push first")


def call(method, url, tok, body=None, content_type="application/json", raw=None):
    data = raw if raw is not None else (json.dumps(body).encode() if body else None)
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + tok)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    req.add_header("User-Agent", "lune-bridge-release-script")
    if data is not None:
        req.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(req) as r:
            payload = r.read()
            return r.status, (json.loads(payload) if payload else {})
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:400]
        return e.code, {"error": detail}


def cmd_topics(repo, names):
    status, body = call("PUT", "%s/repos/%s/topics" % (API, repo), token(),
                        {"names": names})
    if status == 200:
        print("topics set: " + ", ".join(body.get("names", [])))
        return 0
    print("failed (%s): %s" % (status, body.get("error", "")))
    return 1


def cmd_release(repo, tag, title, notes_path, assets):
    tok = token()
    notes = open(notes_path, encoding="utf-8").read() if notes_path != "-" else ""

    status, body = call("POST", "%s/repos/%s/releases" % (API, repo), tok, {
        "tag_name": tag,
        "name": title,
        "body": notes,
        "draft": False,
        "prerelease": False,
    })
    if status not in (200, 201):
        # A tag that already exists is the common re-run case; reuse it rather
        # than failing, so this script is safe to run twice.
        if status == 422:
            st2, existing = call("GET", "%s/repos/%s/releases/tags/%s" % (API, repo, tag), tok)
            if st2 == 200:
                body = existing
                print("release %s already exists, reusing it" % tag)
            else:
                print("failed (%s): %s" % (status, body.get("error", "")))
                return 1
        else:
            print("failed (%s): %s" % (status, body.get("error", "")))
            return 1
    else:
        print("release created: " + body.get("html_url", tag))

    upload_base = "%s/repos/%s/releases/%s/assets" % (UPLOADS, repo, body["id"])
    for path in assets:
        name = os.path.basename(path)
        with open(path, "rb") as fh:
            blob = fh.read()
        st, res = call("POST", "%s?name=%s" % (upload_base, name), tok,
                       content_type="application/octet-stream", raw=blob)
        if st in (200, 201):
            print("uploaded %s (%d bytes)" % (name, len(blob)))
        else:
            print("asset %s failed (%s): %s" % (name, st, res.get("error", "")))
            return 1
    return 0


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    what, repo = argv[1], argv[2]
    if what == "topics":
        return cmd_topics(repo, argv[3:])
    if what == "release":
        return cmd_release(repo, argv[3], argv[4], argv[5], argv[6:])
    print("unknown command: " + what)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
