#include <X11/Xlib.h>
#include <X11/keysym.h>
#include <stdio.h>
#include <unistd.h>

int main(void) {
    Display *display = XOpenDisplay(NULL);
    if (!display) return 2;
    Window root = DefaultRootWindow(display), parent, *children = NULL;
    unsigned count = 0;
    Window window = None;
    for (int attempt = 0; attempt < 100 && window == None; ++attempt) {
        if (XQueryTree(display, root, &root, &parent, &children, &count)) {
            if (count == 1) window = children[0];
            if (children) XFree(children);
        }
        usleep(50000);
    }
    if (window == None) {
        fprintf(stderr, "Expected one test window on the isolated X server\n");
        XCloseDisplay(display);
        return 1;
    }
    usleep(200000);
    KeySym symbols[] = {XK_w, XK_Up, XK_Shift_L, XK_Escape};
    for (unsigned index = 0; index < sizeof(symbols) / sizeof(symbols[0]); ++index) {
        XEvent event = {0};
        event.xkey.display = display;
        event.xkey.window = window;
        event.xkey.root = root;
        event.xkey.keycode = XKeysymToKeycode(display, symbols[index]);
        event.xkey.same_screen = True;
        for (int release = 0; release <= 1; ++release) {
            event.type = release ? KeyRelease : KeyPress;
            if (!XSendEvent(display, window, False,
                            release ? KeyReleaseMask : KeyPressMask, &event)) {
                XCloseDisplay(display);
                return 1;
            }
            XFlush(display);
            usleep(100000);
        }
    }
    for (int gained = 0; gained <= 1; ++gained) {
        XEvent event = {0};
        event.xfocus.type = gained ? FocusIn : FocusOut;
        event.xfocus.display = display;
        event.xfocus.window = window;
        if (!XSendEvent(display, window, False, FocusChangeMask, &event)) {
            XCloseDisplay(display);
            return 1;
        }
        XFlush(display);
        usleep(100000);
    }
    XCloseDisplay(display);
    return 0;
}
