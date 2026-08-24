#!/usr/bin/env bash
#
# Go-to-definition into a standard-library module, with the SDK run natively.
#
# The server is handed the host path of a source tree in initializationOptions.stdlibSrc. It used
# to look for that tree at /libsrc only -- a mount that exists inside the image and nowhere else --
# so with the tarball SDK every jump into a library module stayed in the open file, landing on the
# IMPORT line, with no error anywhere. This runs the real binary against a real directory layout
# and fails if the answer does not point into the tree that was named.
#
# Exit 2: could not run (no SDK, no python3). Exit 1: the jump does not leave the file.
#
# Usage: tests/lsp-stdlib-check.sh [bundle directory]

set -eo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
bundle="${1:-$root/target/bundle}"
case "$bundle" in /*) ;; *) bundle="$PWD/$bundle" ;; esac

[ -x "$bundle/ob" ] || { echo "[SKIP] no SDK in $bundle (run 'task bundle')"; exit 2; }
command -v python3 >/dev/null || { echo "[SKIP] no python3"; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The document and the library source deliberately live in different directories: the point of the
# check is the tree named by stdlibSrc, not a sibling of the open file.
mkdir -p "$work/proj" "$work/libsrc"
cat > "$work/proj/StdlibJump.Mod" <<'MOD'
MODULE StdlibJump;
IMPORT KernelLog;

	PROCEDURE Do*;
	BEGIN
		KernelLog.String("x"); KernelLog.Ln
	END Do;

END StdlibJump.
MOD

# A stub, not the real KernelLog: what is checked is which file the server answers with, and a stub
# keeps the check independent of a library module's own contents.
cat > "$work/libsrc/KernelLog.Mod" <<'MOD'
MODULE KernelLog;

	PROCEDURE String* (CONST s: ARRAY OF CHAR);
	BEGIN
	END String;

	PROCEDURE Ln*;
	BEGIN
	END Ln;

END KernelLog.
MOD

python3 - "$bundle/ob" "$work" <<'PY'
import json, os, subprocess, sys

ob, work = sys.argv[1], sys.argv[2]
doc = os.path.join(work, "proj", "StdlibJump.Mod")
libsrc = os.path.join(work, "libsrc")
text = open(doc).read()

# The cursor: the `String` of `KernelLog.String`, which is a symbol of another module.
off = text.index("KernelLog.String") + len("KernelLog.")
line = text[:off].count("\n")
char = off - (text.rfind("\n", 0, off) + 1)

uri = "file://" + doc


def frame(m):
    b = json.dumps(m).encode()
    return b"Content-Length: %d\r\n\r\n" % len(b) + b


stream = b"".join(frame(m) for m in [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize",
     "params": {"processId": None, "rootUri": "file://" + os.path.dirname(doc),
                "capabilities": {}, "initializationOptions": {"stdlibSrc": libsrc}}},
    {"jsonrpc": "2.0", "method": "initialized", "params": {}},
    {"jsonrpc": "2.0", "method": "textDocument/didOpen",
     "params": {"textDocument": {"uri": uri, "languageId": "oberon", "version": 1, "text": text}}},
    {"jsonrpc": "2.0", "id": 2, "method": "textDocument/definition",
     "params": {"textDocument": {"uri": uri}, "position": {"line": line, "character": char}}},
])

p = subprocess.run([ob, "lsp", "--live"], input=stream, capture_output=True, timeout=300)
answer = None
for part in p.stdout.decode(errors="replace").split("Content-Length:"):
    body = part.split("\r\n\r\n", 1)[-1]
    try:
        m = json.loads(body)
    except Exception:
        continue
    if m.get("id") == 2:
        answer = m

if answer is None:
    print("[FAIL] the server never answered textDocument/definition", file=sys.stderr)
    print(p.stderr.decode(errors="replace")[:400], file=sys.stderr)
    sys.exit(1)

result = answer.get("result")
if not result:
    print("[FAIL] the jump answered null -- the library source was not found", file=sys.stderr)
    sys.exit(1)

first = result if isinstance(result, dict) else result[0]
got = first["uri"]
want = "file://" + os.path.join(libsrc, "KernelLog.Mod")
if got != want:
    print("[FAIL] the jump landed in %s, and the source named by stdlibSrc is %s" % (got, want),
          file=sys.stderr)
    sys.exit(1)

print("[PASS] the jump lands in the tree stdlibSrc names (line %d)" % first["range"]["start"]["line"])
PY
