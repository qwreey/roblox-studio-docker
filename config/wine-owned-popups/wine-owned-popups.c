/* wine-owned-popups - keeps a Wine virtual desktop's owned windows above their owners.
 *
 * Windows keeps an owned popup (Studio's floating panels, dialogs) above its owner at all
 * times. Wine's X11 driver breaks that inside a virtual desktop: on focus it raises the
 * focused window's X window to the top of the stack with no regard for the windows it owns
 * (winex11.drv/event.c, set_input_focus), and the Expose that follows makes the server move
 * the owner above them in the win32 z-order too (X11DRV_Expose -> update_window_zorder), a
 * path that never goes through SetWindowPos and its owned-popup handling. Clicking Studio's
 * main window therefore buries every floating panel behind it.
 *
 * The same mechanism repairs it: Wine marks an owned window's X window WM_TRANSIENT_FOR its
 * owner's, so this restacks any such window that ended up below its owner directly above
 * it again, and the resulting Expose moves it back above the owner on the win32 side as well.
 * It watches every top-level X window's children (a virtual desktop's windows are children
 * of the desktop's X window, not of the root), so it covers any desktop that comes and goes.
 * CLAUDE.md's "Panels: Wine virtual desktop" has the measurements behind this. */
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <stdio.h>
#include <stdlib.h>

static int ignore_errors(Display *display, XErrorEvent *error)
{
    /* Windows routinely vanish between a query and a request on them. */
    (void)display;
    (void)error;
    return 0;
}

static int viewable(Display *display, Window window)
{
    XWindowAttributes attributes;
    return XGetWindowAttributes(display, window, &attributes) && attributes.map_state == IsViewable;
}

static int index_of(const Window *children, unsigned int count, Window window)
{
    for (unsigned int i = 0; i < count; i++)
        if (children[i] == window) return (int)i;
    return -1;
}

/* One pass over a parent's children (bottom to top); returns whether anything moved. */
static int restack_once(Display *display, Window parent)
{
    Window root, parent_return, *children = NULL, owner;
    unsigned int count;
    int moved = 0;

    if (!XQueryTree(display, parent, &root, &parent_return, &children, &count)) return 0;
    for (unsigned int i = 0; i < count && !moved; i++)
    {
        int owner_index;
        if (!XGetTransientForHint(display, children[i], &owner)) continue;
        if ((owner_index = index_of(children, count, owner)) <= (int)i) continue;
        if (!viewable(display, children[i]) || !viewable(display, owner)) continue;

        XWindowChanges changes = {.sibling = owner, .stack_mode = Above};
        XConfigureWindow(display, children[i], CWSibling | CWStackMode, &changes);
        moved = 1;
    }
    if (children) XFree(children);
    return moved;
}

static void restack(Display *display, Window parent)
{
    /* One move per pass so the next pass sees the new order; chains (a popup owned by a
     * popup) settle in a few passes. The cap only guards against a cyclic hint. */
    for (int pass = 0; pass < 64 && restack_once(display, parent); pass++) {}
}

static void watch_children(Display *display, Window window)
{
    XSelectInput(display, window, SubstructureNotifyMask);
}

int main(void)
{
    Display *display = XOpenDisplay(NULL);
    Window root, parent_return, *children = NULL;
    unsigned int count;

    if (!display)
    {
        fprintf(stderr, "wine-owned-popups: cannot open display %s\n", XDisplayName(NULL));
        return 1;
    }
    XSetErrorHandler(ignore_errors);
    root = DefaultRootWindow(display);
    XSelectInput(display, root, SubstructureNotifyMask);
    if (XQueryTree(display, root, &root, &parent_return, &children, &count))
    {
        for (unsigned int i = 0; i < count; i++)
        {
            watch_children(display, children[i]);
            restack(display, children[i]);
        }
        if (children) XFree(children);
    }

    for (;;)
    {
        XEvent event;
        XNextEvent(display, &event);
        switch (event.type)
        {
        case CreateNotify:
            if (event.xcreatewindow.parent == root) watch_children(display, event.xcreatewindow.window);
            break;
        case ConfigureNotify:
            if (event.xconfigure.event != root) restack(display, event.xconfigure.event);
            break;
        case MapNotify:
            if (event.xmap.event != root) restack(display, event.xmap.event);
            break;
        }
    }
}
