#!/usr/bin/env bash
#
# The Windows twin of the terminal, run: does the console go into raw mode, give its size back
# and come out of it again.
#
# It is the same question tests/terminal-check.sh asks of the Unix module, and it is asked the
# same way -- through script(1), because a console is what a pipe is not, and a program with its
# output redirected must answer that it has no terminal. The difference is wine: what runs here
# is ob.exe from the Windows bundle, and wine's console is a real console as far as
# GetConsoleMode is concerned, which is what this can check. What it cannot check is the console
# of a Windows 10 machine actually drawing the sequences -- that needs Windows.
#
# Usage: tests/win-terminal-check.sh [Windows SDK directory]   (default: target/bundle-win64)
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
trap 'rm -f "$work/WinTerm.Mod" "$work/WinTerm.GofWw" "$work/WinTerm.SymWw"' EXIT

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

if [ "$fail" -eq 0 ]; then echo "win-terminal-check: OK"; else echo "win-terminal-check: FAILED"; fi
exit "$fail"
