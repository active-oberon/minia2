#!/usr/bin/env bash
#
# The three Windows twins, run: the terminal, starting a program, and a socket named by a path.
#
# It is the same question tests/terminal-check.sh asks of the Unix module, and it is asked the
# same way -- through script(1), because a console is what a pipe is not, and a program with its
# output redirected must answer that it has no terminal. The difference is wine: what runs here
# is ob.exe from the Windows bundle, and wine's console is a real console as far as
# GetConsoleMode is concerned, which is what this can check. What it cannot check is the console
# of a Windows 10 machine actually drawing the sequences -- that needs Windows.
#
# Usage: tests/win-twins-check.sh [Windows SDK directory]   (default: target/bundle-win64)
set -eo pipefail
export LC_ALL=C

root="$(cd "$(dirname "$0")/.." && pwd)"
sdk="${1:-$root/target/bundle-win64}"
case "$sdk" in /*) ;; *) sdk="$PWD/$sdk" ;; esac

[ -f "$sdk/ob.exe" ] || { echo "no Windows SDK in $sdk; run 'task win-bundle' first" >&2; exit 2; }
command -v wine >/dev/null 2>&1 || { echo "no wine here, and nothing else runs an .exe" >&2; exit 2; }
command -v script >/dev/null 2>&1 || { echo "no 'script' here, and nothing else makes a terminal" >&2; exit 2; }

# The module is written into the SDK directory itself and run from there: ob.exe resolves a
# relative path against its own working directory, and giving it a Windows path for a directory
# somewhere else is a second thing to get right for no gain.
work="$sdk"
trap 'rm -f "$work"/WinTerm.Mod "$work"/WinTerm.GofWw "$work"/WinTerm.SymWw "$work"/WinProc.Mod "$work"/WinProc.GofWw "$work"/WinProc.SymWw "$work"/WinSock.Mod "$work"/WinSock.GofWw "$work"/WinSock.SymWw' EXIT

cat > "$work/WinTerm.Mod" <<'MOD'
MODULE WinTerm;	(** what the check reads: one line per question *)
IMPORT Out := KernelLog, Terminal;
VAR h, w: SIGNED32;
BEGIN
	Out.String("isterminal=");
	IF Terminal.IsTerminal() THEN Out.String("yes") ELSE Out.String("no") END; Out.Ln;
	Out.String("open=");
	IF Terminal.Open() THEN Out.String("yes") ELSE Out.String("no") END; Out.Ln;
	Out.String("size=");
	IF Terminal.Size(h, w) THEN Out.Int(h, 0); Out.String("x"); Out.Int(w, 0) ELSE Out.String("no") END;
	Out.Ln;
	Terminal.Clear; Terminal.MoveTo(1, 1); Terminal.Write("drawn"); Terminal.Flush;
	Terminal.Close;
	Out.String("closed"); Out.Ln
END WinTerm.
MOD

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=1; }

# wine's console hides and shows the cursor around every single character it writes, so the
# transcript of a pty run has an escape sequence between every two letters of it. Strip them,
# and what is left is the lines the program printed.
clean() { sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g; s/\x1b[()][A-Za-z0-9]//g' | tr -d '\r'; }

echo "=== with its output redirected, the Windows twin says it has no terminal"
piped="$( cd "$work" && WINEDEBUG=-all timeout 300 wine "$sdk/ob.exe" run WinTerm.Mod 2>&1 | tr -d '\r' || true )"
case "$piped" in
	*"isterminal=no"*) ok "a pipe is not a console, and it says so" ;;
	*) bad "redirected: $(printf '%s' "$piped" | tr '\n' ' ')" ;;
esac
case "$piped" in
	*"open=no"*) ok "and refuses raw mode instead of drawing into a file" ;;
	*) bad "redirected open: $(printf '%s' "$piped" | tr '\n' ' ')" ;;
esac
case "$piped" in
	*closed*) ok "and comes back out of it without trapping" ;;
	*) bad "redirected did not finish" ;;
esac

echo "=== on a console, it goes into raw mode, knows the size and comes back"
tty="$( cd "$work" && WINEDEBUG=-all timeout 300 script -qec "wine '$sdk/ob.exe' run WinTerm.Mod" /dev/null 2>&1 | clean || true )"
case "$tty" in
	*"isterminal=yes"*) ok "the console is a console" ;;
	*) bad "console: $(printf '%s' "$tty" | tr '\n' ' ' | cut -c1-200)" ;;
esac
case "$tty" in
	*"open=yes"*) ok "raw mode and virtual terminal processing were accepted" ;;
	*) bad "console open: $(printf '%s' "$tty" | tr '\n' ' ' | cut -c1-200)" ;;
esac
if printf '%s' "$tty" | grep -qE 'size=[1-9][0-9]*x[1-9][0-9]*'; then
	ok "the window has a size, and both halves of it are positive"
else
	bad "console size: $(printf '%s' "$tty" | tr '\n' ' ' | cut -c1-200)"
fi
case "$tty" in
	*closed*) ok "and the console modes were put back" ;;
	*) bad "console did not finish" ;;
esac

cat > "$work/WinProc.Mod" <<'MOD'
MODULE WinProc;	(** what the check reads: one line per question *)
IMPORT Out := KernelLog, Processes, Strings;
VAR p: Processes.Process; text: Strings.String; code: SIGNED32; ok: BOOLEAN;
	value: ARRAY 1024 OF CHAR;
BEGIN
	ok := Processes.Run("cmd.exe", Processes.Arguments("cmd.exe", "/c", "echo hello", ""), text, code);
	Out.String("ran="); IF ok THEN Out.String("yes") ELSE Out.String("no") END;
	Out.String(" code="); Out.Int(code, 0);
	Out.String(" said="); IF text # NIL THEN Out.String(text^) END; Out.Ln;
	ok := Processes.Run("cmd.exe", Processes.Arguments("cmd.exe", "/c", "exit 3", ""), text, code);
	Out.String("failed-code="); Out.Int(code, 0); Out.Ln;
	ok := Processes.Run("no-such-program-at-all.exe",
		Processes.Arguments("no-such-program-at-all.exe", "", "", ""), text, code);
	Out.String("missing="); IF ok THEN Out.String("started") ELSE Out.String("refused") END; Out.Ln;
	p := Processes.Start("cmd.exe", Processes.Arguments("cmd.exe", "/c", "sort", ""));
	IF p = NIL THEN Out.String("pipes=none"); Out.Ln
	ELSE
		p.WriteLine("b"); p.WriteLine("a"); p.CloseInput;
		text := p.ReadAll(); code := p.Wait(); p.Close;
		Out.String("sorted=");
		IF (text # NIL) & (text[0] = "a") THEN Out.String("yes") ELSE Out.String("no") END; Out.Ln
	END;
	IF Processes.Environment("PATH", value) & (Strings.Length(value) > 0) THEN
		Out.String("environment=yes")
	ELSE Out.String("environment=no") END;
	Out.Ln
END WinProc.
MOD

echo "=== a program is started, spoken to, and its exit code comes back"
proc="$( cd "$work" && WINEDEBUG=-all timeout 300 wine "$sdk/ob.exe" run WinProc.Mod 2>&1 | clean || true )"
for want in "ran=yes code=0 said=hello" "failed-code=3" "missing=refused" "sorted=yes" "environment=yes"; do
	case "$proc" in
		*"$want"*) ok "$want" ;;
		*) bad "$want -- got: $(printf '%s' "$proc" | tr '\n' ' ' | cut -c1-200)" ;;
	esac
done

cat > "$work/WinSock.Mod" <<'MOD'
MODULE WinSock;	(** two ends of a named pipe, in one process *)
IMPORT Out := KernelLog, LocalSockets, Kernel;
VAR l: LocalSockets.Listener; c: LocalSockets.Connection; ok: BOOLEAN;

	TYPE Answering = OBJECT
	VAR done: BOOLEAN; heard-: ARRAY 64 OF CHAR;
		PROCEDURE &Init*;
		BEGIN done := FALSE; heard := ""
		END Init;
		(*	The wait belongs here, inside this object's own monitor. Waiting on server.done from
			a module-level EXCLUSIVE block waits on the module's monitor instead, and the
			condition is then never re-examined -- which reads as the check hanging after the
			answer has already come back. *)
		PROCEDURE Wait*;
		BEGIN {EXCLUSIVE} AWAIT(done)
		END Wait;
	BEGIN {ACTIVE}
		c := l.Accept();
		IF c # NIL THEN
			IF c.ReadLine(heard) THEN c.WriteLine("pong") END;
			c.Close
		END;
		BEGIN {EXCLUSIVE} done := TRUE END
	END Answering;

VAR server: Answering; client: LocalSockets.Connection; got: ARRAY 64 OF CHAR; timer: Kernel.Timer;
BEGIN
	l := LocalSockets.Listen("/tmp/a2-win-twins-check");
	IF l = NIL THEN Out.String("listening=no"); Out.Ln
	ELSE
		Out.String("listening=yes"); Out.Ln;
		NEW(server);
		NEW(timer); timer.Sleep(50);
		client := LocalSockets.Connect("/tmp/a2-win-twins-check");
		IF client = NIL THEN Out.String("connected=no"); Out.Ln
		ELSE
			Out.String("connected=yes"); Out.Ln;
			client.WriteLine("ping");
			ok := client.ReadLine(got);
			Out.String("answer="); IF ok THEN Out.String(got) ELSE Out.String("none") END; Out.Ln;
			client.Close
		END;
		server.Wait;
		Out.String("heard="); Out.String(server.heard); Out.Ln;
		l.Close
	END
END WinSock.
MOD

echo "=== a socket named by a path, which on this host is a named pipe"
sock="$( cd "$work" && WINEDEBUG=-all timeout 300 wine "$sdk/ob.exe" run WinSock.Mod 2>&1 | clean || true )"
for want in "listening=yes" "connected=yes" "answer=pong" "heard=ping"; do
	case "$sock" in
		*"$want"*) ok "$want" ;;
		*) bad "$want -- got: $(printf '%s' "$sock" | tr '\n' ' ' | cut -c1-200)" ;;
	esac
done

if [ "$fail" -eq 0 ]; then echo "win-twins-check: OK"; else echo "win-twins-check: FAILED"; fi
exit "$fail"
