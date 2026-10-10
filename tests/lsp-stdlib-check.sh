#!/usr/bin/env bash
#
# Go-to-definition into a standard-library module and through a project module.
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
		KernelLog.String("x");
		KernelLog.Ln
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

p = subprocess.run([ob, "lsp", "--live"], input=stream, capture_output=True,
                   env=dict(os.environ, TMPDIR=work), timeout=300)
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

# A project module that imports the standard library must be prepared on demand:
# only Main is opened, so Child cannot get its symbols from an earlier didOpen.
project = os.path.join(work, "proj")
child = os.path.join(project, "LspProjectChild.Mod")
main = os.path.join(project, "LspProjectMain.Mod")
with open(child, "w") as f:
    f.write('''MODULE LspProjectChild;
IMPORT Strings;
VAR greeting*: ARRAY 32 OF CHAR;
BEGIN
    greeting := "hello";
    Strings.Append(greeting, "!")
END LspProjectChild.
''')
with open(main, "w") as f:
    f.write('''MODULE LspProjectMain;
IMPORT LspProjectChild;
VAR greeting*: ARRAY 32 OF CHAR;
BEGIN
    greeting := LspProjectChild.greeting
END LspProjectMain.
''')
source = open(main).read()
# A different project in the launch directory must never shadow the editor's project.
with open(os.path.join(work, "LspProjectChild.Mod"), "w") as f:
    f.write('''MODULE LspProjectChild;
CONST wrong* = 0;
END LspProjectChild.
''')
off = source.index("LspProjectChild.greeting") + len("LspProjectChild.")
line = source[:off].count("\n")
char = off - (source.rfind("\n", 0, off) + 1)
uri = "file://" + main
stream = b"".join(frame(m) for m in [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize",
     "params": {"processId": None, "rootUri": "file://" + project, "capabilities": {}}},
    {"jsonrpc": "2.0", "method": "initialized", "params": {}},
    {"jsonrpc": "2.0", "method": "textDocument/didOpen",
     "params": {"textDocument": {"uri": uri, "languageId": "oberon", "version": 1,
                                 "text": source}}},
    {"jsonrpc": "2.0", "id": 2, "method": "textDocument/definition",
     "params": {"textDocument": {"uri": uri},
                "position": {"line": line, "character": char}}},
])
clean_env = dict(os.environ, TMPDIR=work)
for key in ("A2_PROJECT", "A2_SYMS", "A2SDK"):
    clean_env.pop(key, None)
p = subprocess.run([ob, "lsp", "--live"], input=stream, cwd=work,
                   capture_output=True, env=clean_env,
                   timeout=300)
answer = None
diagnostics = None
for part in p.stdout.decode(errors="replace").split("Content-Length:"):
    try:
        m = json.loads(part.split("\r\n\r\n", 1)[1])
    except (IndexError, ValueError):
        continue
    if m.get("method") == "textDocument/publishDiagnostics":
        diagnostics = m["params"]["diagnostics"]
    if m.get("id") == 2:
        answer = m

if diagnostics is None or diagnostics or answer is None or not answer.get("result"):
    print("[FAIL] project import through Strings: diagnostics=%r definition=%r" %
          (diagnostics, answer), file=sys.stderr)
    sys.exit(1)
result = answer["result"]
first = result if isinstance(result, dict) else result[0]
if first["uri"] != "file://" + child:
    print("[FAIL] project definition landed in %s" % first["uri"], file=sys.stderr)
    sys.exit(1)
print("[PASS] project module importing Strings resolves on first open")

from pathlib import Path

project = Path(work) / "project with % spaces"
shared = Path(work) / "shared sources"
vendor = project / ".a2pkg" / "example" / "library"
for directory in (project / "tests", shared, vendor):
    directory.mkdir(parents=True, exist_ok=True)
(project / "a2pkg.json").write_text(json.dumps({
    "name": "lsp-project", "sourcePaths": ["../shared sources"]
}))
(vendor / "a2pkg.json").write_text('{"name":"library"}')
(vendor / "LspVendorLeaf.Mod").write_text('''MODULE LspVendorLeaf;
VAR value*: SIGNED32;
BEGIN
    value := 41
END LspVendorLeaf.
''')
(shared / "LspShared.Mod").write_text('''MODULE LspShared;
IMPORT LspVendorLeaf;
VAR value*: SIGNED32;
BEGIN
    value := LspVendorLeaf.value + 1
END LspShared.
''')
(project / "LspChild.Mod").write_text('''MODULE LspChild;
IMPORT Strings, LspShared;
VAR greeting*: ARRAY 32 OF CHAR;
BEGIN
    greeting := "hello";
    Strings.Append(greeting, "!")
END LspChild.
''')
(Path(work) / "LspChild.Mod").write_text('''MODULE LspChild;
CONST wrong* = 0;
END LspChild.
''')
main = project / "tests" / "LspMain.Mod"
main.write_text('''MODULE LspMain;
IMPORT LspChild, LspShared, LspVendorLeaf, KernelLog;
VAR greeting: ARRAY 32 OF CHAR; value: SIGNED32;
PROCEDURE Do*;
BEGIN
    greeting := LspChild.greeting;
    value := LspShared.value;
    KernelLog.Int(value, 0);
    KernelLog.Ln;
    value := LspVendorLeaf.value;
    KernelLog.Int(value, 0);
    KernelLog.Ln
END Do;
END LspMain.
''')
source = main.read_text()


def check_project(label, roots):
    messages = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": dict({"processId": None, "capabilities": {}}, **roots)},
        {"jsonrpc": "2.0", "method": "initialized", "params": {}},
        {"jsonrpc": "2.0", "method": "textDocument/didOpen",
         "params": {"textDocument": {"uri": main.as_uri(), "languageId": "oberon",
                                     "version": 1, "text": source}}},
    ]
    expected = {}
    for request_id, symbol, target in [
        (2, "LspChild.greeting", project / "LspChild.Mod"),
        (3, "LspShared.value", shared / "LspShared.Mod"),
        (4, "LspVendorLeaf.value", vendor / "LspVendorLeaf.Mod"),
    ]:
        offset = source.index(symbol) + symbol.index(".") + 1
        messages.append({"jsonrpc": "2.0", "id": request_id,
            "method": "textDocument/definition", "params": {
                "textDocument": {"uri": main.as_uri()},
                "position": {"line": source[:offset].count("\n"),
                             "character": offset - source.rfind("\n", 0, offset) - 1}}})
        expected[request_id] = target
    proc = subprocess.run([ob, "lsp", "--live"], input=b"".join(map(frame, messages)),
                          cwd=work, capture_output=True, env=clean_env, timeout=30)
    if proc.returncode:
        raise AssertionError((label, proc.stderr.decode()))
    answers = {}
    diagnostics = None
    for chunk in proc.stdout.decode().split("Content-Length:"):
        try:
            reply = json.loads(chunk.split("\r\n\r\n", 1)[1])
        except (IndexError, ValueError):
            continue
        if reply.get("method") == "textDocument/publishDiagnostics":
            diagnostics = reply["params"]["diagnostics"]
        if reply.get("id") in expected:
            answers[reply["id"]] = reply.get("result")
    assert diagnostics == [], (label, diagnostics, proc.stderr.decode())
    for request_id, target in expected.items():
        answer = answers.get(request_id)
        assert answer, (label, request_id, answer)
        location = answer if isinstance(answer, dict) else answer[0]
        assert location["uri"] == target.as_uri(), (label, location, target)
    print("[PASS] %s: nested imports, local and vendored definitions" % label)


check_project("rootUri from another cwd", {"rootUri": project.as_uri()})
check_project("workspaceFolders from another cwd", {
    "rootUri": None, "workspaceFolders": [{"uri": project.as_uri(), "name": "example"}]
})
check_project("document fallback without a workspace", {"rootUri": None})

# Builds must resolve the same manifest without prebuilt symbols in dependency directories.
binary = project / "check"
proc = subprocess.run([ob, "build", str(main), "-o", str(binary)], cwd=project,
                      capture_output=True, env=clean_env, timeout=30)
assert proc.returncode == 0, (proc.stdout.decode(), proc.stderr.decode())
proc = subprocess.run([str(binary)], capture_output=True, timeout=10)
assert proc.returncode == 0 and proc.stdout.split() == [b"42", b"41"], proc
print("[PASS] ob build uses the same local and vendored dependencies")

for invalid in ("../shared sources", [42], [""], ["../missing"], ["LspChild.Mod"]):
    (project / "a2pkg.json").write_text(json.dumps({"sourcePaths": invalid}))
    proc = subprocess.run([ob, "build", str(main), "-o", str(binary)], cwd=project,
                          capture_output=True, env=clean_env, timeout=10)
    assert proc.returncode != 0 and b"sourcePaths" in proc.stderr, (invalid, proc)
print("[PASS] invalid dependency paths are rejected")
PY
