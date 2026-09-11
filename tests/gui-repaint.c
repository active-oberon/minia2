/*
	What happens to a windowed program's picture when nobody is looking at it.

	This display has no copy of the screen: XDisplay draws straight into the X window and reads
	back out of it, so whatever the server throws away is gone. The full desktop hides that -- its
	window manager re-renders the view from its own model -- and a program built with `ob build
	--gui` has no window manager, so a window that was covered came back blank. The answer is to
	ask the server to keep the pixels (backing_store), and this is what says whether it did.

	Two things are measured, because the server is allowed to treat them differently: a window
	covered by another one, and a window unmapped and mapped again, which is what minimising is.
	The first is the one backing store is defined to cover; the second the spec lets a server
	drop, so it is reported and not required.

	Run it on a plain X server -- Xephyr will do -- and NOT on a composited desktop: there every
	window is redirected to its own pixmap and nothing is ever lost, so the check would pass on a
	build that has none of this.

	Usage: gui-repaint [expected colour, 0xRRGGBB]
	Exit: 0 the picture survived being covered, 1 it did not, 2 there was nothing to measure.
*/
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

/* The biggest viewable child of the root that is not the root: the program under test owns the
   only window on this server. */
static Window find(Display *d, Window w) {
	Window root, parent, *kids = 0; unsigned n = 0;
	XWindowAttributes a;
	if (w != DefaultRootWindow(d) && XGetWindowAttributes(d, w, &a) &&
	    a.map_state == IsViewable && a.class == InputOutput && a.width > 100 && a.height > 100)
		return w;
	if (!XQueryTree(d, w, &root, &parent, &kids, &n)) return 0;
	Window found = 0;
	for (unsigned i = 0; i < n && !found; i++) found = find(d, kids[i]);
	if (kids) XFree(kids);
	return found;
}

static unsigned long pixel(Display *d, Window w, int x, int y) {
	XImage *im = XGetImage(d, w, x, y, 1, 1, AllPlanes, ZPixmap);
	if (!im) return 0xFFFFFFFFul;
	unsigned long p = XGetPixel(im, 0, 0) & 0xFFFFFFul;
	XDestroyImage(im);
	return p;
}

int main(int argc, char **argv) {
	unsigned long want = argc > 1 ? strtoul(argv[1], 0, 0) : 0x102838;
	Display *d = XOpenDisplay(NULL);
	if (!d) { fprintf(stderr, "no display\n"); return 2; }
	Window target = find(d, DefaultRootWindow(d));
	if (!target) { fprintf(stderr, "no window on this server to measure\n"); return 2; }
	XWindowAttributes a; XGetWindowAttributes(d, target, &a);
	printf("  window %#lx %dx%d, backing_store=%d (2 = Always)\n",
	       target, a.width, a.height, a.backing_store);

	if (pixel(d, target, 5, 5) != want) {
		fprintf(stderr, "  the window did not hold %06lx to begin with -- nothing to measure\n", want);
		return 2;
	}

	XSetWindowAttributes sa; sa.override_redirect = True; sa.background_pixel = 0xFFFFFF;
	Window cover = XCreateWindow(d, DefaultRootWindow(d), a.x, a.y, a.width, a.height, 0,
		CopyFromParent, InputOutput, CopyFromParent, CWOverrideRedirect | CWBackPixel, &sa);
	XMapRaised(d, cover); XFlush(d); sleep(2);
	XDestroyWindow(d, cover); XFlush(d); sleep(2);
	unsigned long covered = pixel(d, target, 5, 5);
	printf("  covered and uncovered: %06lx %s\n", covered, covered == want ? "-- kept" : "-- LOST");

	XUnmapWindow(d, target); XFlush(d); sleep(1);
	XMapRaised(d, target); XFlush(d); sleep(2);
	unsigned long remapped = pixel(d, target, 5, 5);
	printf("  put away and back:     %06lx %s\n", remapped, remapped == want ? "-- kept" : "-- lost (the server may drop backing store on unmap; this is not required)");

	XCloseDisplay(d);
	return covered == want ? 0 : 1;
}
