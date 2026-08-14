// The same three sources, in Go: the keyboard, mpv's output, and the window's size.
//
// This is the other half of a measurement, not a program to use: it plays a station from the
// same catalogue as examples/Radio.Mod and takes the same keys, but it draws nothing -- the
// comparison is about how three things that happen at once reach one loop, and a screen full of
// frames would only add the same amount of drawing to both sides.
//
// Standard library only, Linux only, as the Active Oberon side is: raw mode through an ioctl,
// mpv started as a child, its control socket spoken to over a unix socket.
//
//	go run radio.go      -- s stops, p or space pauses, +/- volume, q leaves.
package main

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"unsafe"
)

// ---- the plumbing: three sources, one loop ------------------------------------------------

type event struct {
	kind byte // 'k' a key, 'l' a line from mpv, 'r' a resize
	key  byte
	line string
}

// keyboard hands over what was typed until standard input ends or the context is done.
func keyboard(ctx context.Context, out chan<- event) {
	buf := make([]byte, 1)
	for {
		n, err := os.Stdin.Read(buf)
		if err != nil || n == 0 {
			return
		}
		select {
		case out <- event{kind: 'k', key: buf[0]}:
		case <-ctx.Done():
			return
		}
	}
}

// mpvLines hands over what the child says, line by line, and ends when the child does.
func mpvLines(ctx context.Context, r *os.File, out chan<- event) {
	scanner := bufio.NewScanner(r)
	scanner.Split(scanLinesOrCR)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		select {
		case out <- event{kind: 'l', line: line}:
		case <-ctx.Done():
			return
		}
	}
}

// resizes turns SIGWINCH into events. This is the one source Go gets for nothing.
func resizes(ctx context.Context, out chan<- event) {
	sigwinch := make(chan os.Signal, 1)
	signal.Notify(sigwinch, syscall.SIGWINCH)
	defer signal.Stop(sigwinch)
	for {
		select {
		case <-sigwinch:
			select {
			case out <- event{kind: 'r'}:
			case <-ctx.Done():
				return
			}
		case <-ctx.Done():
			return
		}
	}
}

// ---- everything below is the program, and is not what is being measured -------------------

type station struct{ genre, name, url string }

func catalogue() ([]station, string, error) {
	dir := os.Getenv("XDG_CONFIG_HOME")
	if dir == "" {
		dir = os.Getenv("HOME") + "/.config"
	}
	dir += "/radio/"
	text, err := os.ReadFile(dir + "stations.tsv")
	if err != nil {
		return nil, dir, err
	}
	var out []station
	for _, line := range strings.Split(string(text), "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		field := strings.Split(line, "\t")
		if len(field) < 3 {
			continue
		}
		out = append(out, station{field[0], field[1], field[2]})
	}
	return out, dir, nil
}

func scanLinesOrCR(data []byte, atEOF bool) (int, []byte, error) {
	for i, b := range data {
		if b == '\n' || b == '\r' {
			return i + 1, data[:i], nil
		}
	}
	if atEOF && len(data) > 0 {
		return len(data), data, nil
	}
	return 0, nil, nil
}

type termios struct {
	Iflag, Oflag, Cflag, Lflag uint32
	Line                       byte
	Cc                         [32]byte
	Ispeed, Ospeed             uint32
}

func raw() (func(), error) {
	var was termios
	fd := os.Stdin.Fd()
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, fd, 0x5401 /*TCGETS*/, uintptr(unsafe.Pointer(&was))); e != 0 {
		return nil, e
	}
	now := was
	now.Lflag &^= 0x8 | 0x2 | 0x8000 | 0x1 // ECHO ICANON IEXTEN ISIG
	now.Iflag &^= 0x400 | 0x100 | 0x2      // IXON ICRNL BRKINT
	now.Oflag &^= 0x1                      // OPOST
	now.Cc[6], now.Cc[5] = 1, 0            // VMIN, VTIME
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, fd, 0x5402 /*TCSETS*/, uintptr(unsafe.Pointer(&now))); e != 0 {
		return nil, e
	}
	return func() {
		syscall.Syscall(syscall.SYS_IOCTL, fd, 0x5402, uintptr(unsafe.Pointer(&was)))
	}, nil
}

type player struct {
	cmd     *exec.Cmd
	control *os.File
	socket  string
}

func play(ctx context.Context, s station, dir string, events chan<- event) (*player, error) {
	socket := fmt.Sprintf("/tmp/go-radio-%d.sock", os.Getpid())
	os.Remove(socket)
	cmd := exec.Command("mpv", "--include="+dir+"mpv.conf", "--input-ipc-server="+socket, "--no-video", s.url)
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	cmd.Stderr = cmd.Stdout.(*os.File)
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	go mpvLines(ctx, out.(*os.File), events)
	p := &player{cmd: cmd, socket: socket}
	for i := 0; i < 50 && p.control == nil; i++ {
		if c, err := os.OpenFile(socket, os.O_RDWR, 0); err == nil {
			p.control = c
		} else {
			syscall.Nanosleep(&syscall.Timespec{Nsec: 100e6}, nil)
		}
	}
	return p, nil
}

func (p *player) command(json string) {
	if p != nil && p.control != nil {
		p.control.WriteString(json + "\n")
	}
}

func (p *player) stop() {
	if p == nil {
		return
	}
	p.command(`{"command": ["quit"]}`)
	if p.control != nil {
		p.control.Close()
	}
	if p.cmd != nil && p.cmd.Process != nil {
		p.cmd.Process.Kill()
		p.cmd.Wait()
	}
	os.Remove(p.socket)
}

func main() {
	list, dir, err := catalogue()
	if err != nil {
		fmt.Fprintln(os.Stderr, "radio:", err)
		os.Exit(1)
	}
	restore, err := raw()
	if err != nil {
		fmt.Fprintln(os.Stderr, "radio: standard input is not a terminal")
		os.Exit(1)
	}
	defer restore()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	events := make(chan event, 32)
	go keyboard(ctx, events)
	go resizes(ctx, events)

	var current *player
	defer func() { current.stop() }()

	chosen, volume, paused := 0, 70, false
	say := func(format string, a ...any) { fmt.Printf("\r"+format+"\r\n", a...) }
	say("%d stations; Enter plays #%d, s stops, p pauses, +/- volume, q leaves", len(list), chosen+1)

	for e := range events {
		switch e.kind {
		case 'r':
			say("the window changed size")
		case 'l':
			say("%s", e.line)
		case 'k':
			switch e.key {
			case 'q', 17: // q, Ctrl-Q
				return
			case 13, 10: // Enter
				current.stop()
				current, err = play(ctx, list[chosen], dir, events)
				if err != nil {
					say("mpv: %v", err)
				} else {
					say("playing: %s", list[chosen].name)
					current.command(fmt.Sprintf(`{"command": ["set_property", "volume", %d]}`, volume))
				}
			case 'n':
				chosen = (chosen + 1) % len(list)
				say("chosen: %s", list[chosen].name)
			case 's':
				current.stop()
				current = nil
				say("stopped")
			case 'p', ' ':
				paused = !paused
				current.command(fmt.Sprintf(`{"command": ["set_property", "pause", %v]}`, paused))
				say("paused: %v", paused)
			case '+', '=', '-':
				if e.key == '-' {
					volume -= 5
				} else {
					volume += 5
				}
				current.command(fmt.Sprintf(`{"command": ["set_property", "volume", %d]}`, volume))
				say("volume %d", volume)
			}
		}
	}
}
