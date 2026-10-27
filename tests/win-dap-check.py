#!/usr/bin/env python3
"""Exercise the real Windows DAP executable and a separate, native debuggee.

Usage: python tests/win-dap-check.py --ob target/debugger-sdk/ob.exe
Only Python's standard library is needed by this test; the SDK needs no Python.
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time


class Adapter:
    def __init__(self, ob, directory):
        env = os.environ.copy()
        env["A2SDK"] = str(ob.parent)
        env["TMPDIR"] = str(directory)
        self.process = subprocess.Popen(
            [str(ob), "dap"], cwd=directory, env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.messages = queue.Queue()
        self.saved = []
        self.seq = 0
        self.transcript = []
        self.errors = bytearray()
        threading.Thread(target=self.read, daemon=True).start()
        threading.Thread(target=self.read_errors, daemon=True).start()

    def read_errors(self):
        self.errors.extend(self.process.stderr.read())

    def read(self):
        try:
            while True:
                headers = {}
                while True:
                    line = self.process.stdout.readline()
                    if not line:
                        raise EOFError("adapter stdout closed")
                    if line in (b"\r\n", b"\n"):
                        break
                    key, value = line.decode("ascii").split(":", 1)
                    headers[key.lower()] = value.strip()
                size = int(headers["content-length"])
                data = self.process.stdout.read(size)
                if len(data) != size:
                    raise EOFError("truncated DAP message")
                msg = json.loads(data)
                self.transcript.append(msg)
                self.messages.put(msg)
        except BaseException as error:
            self.messages.put(error)

    def wait(self, predicate, timeout=25):
        for i, msg in enumerate(self.saved):
            if predicate(msg):
                return self.saved.pop(i)
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(f"DAP timeout; messages={self.transcript!r}")
            try:
                msg = self.messages.get(timeout=remaining)
            except queue.Empty:
                raise AssertionError(f"DAP timeout; messages={self.transcript!r}") from None
            if isinstance(msg, BaseException):
                raise AssertionError(f"{msg}; stderr={self.errors.decode(errors='replace')}")
            if predicate(msg):
                return msg
            self.saved.append(msg)

    def request(self, command, arguments=None, success=True):
        self.seq += 1
        msg = {"seq": self.seq, "type": "request", "command": command, "arguments": arguments or {}}
        data = json.dumps(msg).encode()
        self.process.stdin.write(f"Content-Length: {len(data)}\r\n\r\n".encode() + data)
        self.process.stdin.flush()
        reply = self.wait(lambda x: x.get("request_seq") == self.seq)
        assert reply["success"] == success, reply
        return reply.get("body", {})

    def event(self, name):
        return self.wait(lambda x: x.get("event") == name).get("body", {})

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)


FIXTURE = """MODULE DebugFixture;
IMPORT Commands;
PROCEDURE Inner(x: SIGNED32): SIGNED32;
VAR y: SIGNED32;
BEGIN
    y := x + 1;
    INC(y);
    RETURN y
END Inner;
PROCEDURE Do*(context: Commands.Context);
VAR answer: SIGNED32;
BEGIN
    answer := Inner(41);
    context.out.Int(answer, 1); context.out.Ln
END Do;
PROCEDURE Crash*(context: Commands.Context);
BEGIN
    HALT(77)
END Crash;
PROCEDURE Spin*(context: Commands.Context);
VAR x: SIGNED32;
BEGIN
    x := 0;
    LOOP INC(x); IF x = 1000000 THEN x := 0 END END
END Spin;
END DebugFixture.
"""


def line_of(text):
    return next(i for i, line in enumerate(FIXTURE.splitlines(), 1) if text in line)


def start(ob, directory, source, procedure="Do", break_line=None):
    adapter = Adapter(ob, directory)
    adapter.request("initialize", {"adapterID": "ob"})
    adapter.event("initialized")
    if break_line is not None:
        adapter.request("setBreakpoints", {
            "source": {"path": str(source)}, "breakpoints": [{"line": break_line}],
        })
    adapter.request("launch", {"program": str(source), "procedure": procedure})
    child = adapter.event("process")["systemProcessId"]
    assert child != adapter.process.pid, "debuggee must be a different process"
    adapter.request("configurationDone")
    return adapter, child


def frames(adapter, stopped):
    return adapter.request("stackTrace", {"threadId": stopped["threadId"]})["stackFrames"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ob", type=Path, required=True)
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("this test needs native Windows")
    ob = args.ob.resolve(strict=True)
    root = Path(__file__).resolve().parents[1] / "target" / "win-dap-check"
    root.mkdir(parents=True, exist_ok=True)
    # TemporaryDirectory owns precisely this newly created directory, beneath target/.
    with tempfile.TemporaryDirectory(prefix="source with spaces-", dir=root) as temporary:
        directory = Path(temporary).resolve()
        assert directory.is_relative_to(root.resolve())
        source = directory / "DebugFixture.Mod"
        source.write_text(FIXTURE, encoding="utf-8")
        adapter, child = start(ob, directory, source, break_line=line_of("y := x + 1"))
        try:
            stopped = adapter.event("stopped")
            assert stopped["reason"] == "breakpoint", stopped
            assert stopped["allThreadsStopped"], stopped
            stack = frames(adapter, stopped)
            assert stack[0]["name"].endswith("Inner"), stack
            assert stack[0]["line"] == line_of("y := x + 1"), stack
            frame = stack[0]["id"]
            assert adapter.request("evaluate", {"frameId": frame, "expression": "x"})["result"] == "41"
            adapter.request("next", {"threadId": stopped["threadId"]})
            stopped = adapter.event("stopped")
            stack = frames(adapter, stopped)
            assert stack[0]["line"] == line_of("INC(y)"), stack
            assert adapter.request("evaluate", {"frameId": stack[0]["id"], "expression": "y"})["result"] == "42"
            adapter.request("stepOut", {"threadId": stopped["threadId"]})
            stopped = adapter.event("stopped")
            stack = frames(adapter, stopped)
            assert stack[0]["name"].endswith("Do"), stack
            adapter.request("continue", {"threadId": stopped["threadId"]})
            assert adapter.event("exited")["exitCode"] == 0
            adapter.event("terminated")
            assert any(m.get("event") == "output" and "43" in m["body"]["output"] for m in adapter.transcript)
            adapter.request("disconnect")
            adapter.process.wait(timeout=10)
            assert adapter.process.returncode == 0
            print("PASS separate process, breakpoint, parameter, next, local, stepOut, continue, output")
        finally:
            (root / "breakpoint-transcript.json").write_text(json.dumps(adapter.transcript, indent=2), encoding="utf-8")
            adapter.close()

        adapter, child = start(ob, directory, source, procedure="Crash")
        try:
            stopped = adapter.event("stopped")
            assert stopped["reason"] == "exception", stopped
            assert frames(adapter, stopped), "exception must retain a readable external stack"
            adapter.request("disconnect")
            adapter.process.wait(timeout=10)
            print("PASS target exception is inspected before the A2 trap handler")
        finally:
            adapter.close()

        adapter, child = start(ob, directory, source, procedure="Spin")
        try:
            time.sleep(0.5)
            adapter.request("pause")
            assert adapter.event("stopped")["reason"] == "pause"
            # Open before EOF so PID reuse cannot affect the lifetime assertion.
            kernel = ctypes.WinDLL("kernel32", use_last_error=True)
            kernel.OpenProcess.restype = ctypes.c_void_p
            handle = kernel.OpenProcess(0x100000, False, child)
            assert handle
            try:
                adapter.close()
                kernel.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
                assert kernel.WaitForSingleObject(handle, 5000) == 0, "EOF left the target running"
            finally:
                kernel.CloseHandle.argtypes = [ctypes.c_void_p]
                kernel.CloseHandle(handle)
            print("PASS pause, EOF cleanup, no orphaned target")
        finally:
            adapter.close()
        assert not list(directory.glob("a2-debug-*.json")), "symbol snapshots leaked"


if __name__ == "__main__":
    main()
