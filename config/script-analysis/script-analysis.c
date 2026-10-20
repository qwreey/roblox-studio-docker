/* script-analysis OUT-FILE [PLACE]
 *
 * Writes what Roblox Studio's Script Analysis window lists to OUT-FILE (UTF-8), read through
 * Qt's UI Automation provider - no keys, no clipboard, and the real pointer never moves.
 * Every Studio main window in the desktop is read in turn, or only those whose title
 * contains PLACE: the others are left untouched, since reading one clicks its tabs and
 * scrolls its list.
 * script-analysis-service.py runs it inside a Studio's desktop (`wine explorer
 * /desktop=<name> script-analysis.exe <file>`); CLAUDE.md's "script-analysis" has the
 * measurements behind each step.
 *
 *   - The window is found as the tree whose next sibling is the "Display only current
 *     script" checkbox. Other trees (Explorer, Properties) are never walked into: each row is
 *     a cross-process call, ~30 ms under Wine.
 *   - Qt only exposes rows inside the tree's viewport, and Wine's UIA client has no Grid
 *     pattern to reach the rest. So the rows are paged through with posted WM_MOUSEWHEEL
 *     messages, and the scroll position is put back afterwards.
 *   - A window collapsed to a side tab or hidden behind another dock tab isn't in the
 *     accessibility tree at all. Its "Script Analysis" tab is clicked with posted mouse
 *     messages and, after reading, clicked again (a side tab closes) or the tab that was
 *     showing is clicked back (a dock tab).
 *   - A closed window has no tab, and Studio's Window menu ignores posted input, so that
 *     case is reported rather than handled.
 *
 * Output lines, a block per Studio from its window line on:
 *                window\t<main window title>   status\t<shown|side-tab|dock-tab|closed>
 *                row\t<tree row>   summary\t<"2 of 2 Errors" ...>   note\t<problem>
 * and !done at the very end. */
#define COBJMACROS
#include <windows.h>
#include <ole2.h>
#include <uiautomationclient.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

static const CLSID clsid_cuia = {0xff48dba4, 0x60ef, 0x4201, {0xaa, 0x87, 0x54, 0x10, 0x3e, 0xef, 0x59, 0x4e}};
static const IID iid_iuia = {0x30cbe57d, 0xd9d0, 0x452a, {0xab, 0x13, 0x7a, 0xc5, 0xac, 0x48, 0x25, 0xee}};

#define PANEL_TAB L"Script Analysis"
#define TREE_SIBLING L"Display only current script"
/* Qt scrolls a wheel notch (120) by the system's 3 lines, one row each in an item view. */
#define WHEEL_PER_ROW 40
#define MAX_ROWS 20000

static FILE *out;
/* PLACE, or NULL for every Studio. */
static const WCHAR *want_place;
static IUIAutomation *uia;
static IUIAutomationTreeWalker *walker;

struct list
{
    BSTR *v;
    int n, cap;
};

struct found
{
    DWORD pid; /* the Studio process whose windows are searched */
    IUIAutomationElement *tree, *tab;
    HWND tree_hwnd, tab_hwnd;
    /* Where the rows visible_rows() last saw start and end, and where the tree does. */
    LONG rows_top, rows_bottom, tree_top, tree_bottom;
};

static void put(const char *key, const WCHAR *s)
{
    int n = WideCharToMultiByte(CP_UTF8, 0, s, -1, NULL, 0, NULL, NULL);
    char *buf = malloc(n);
    WideCharToMultiByte(CP_UTF8, 0, s, -1, buf, n, NULL, NULL);
    for (char *p = buf; *p; p++)
        if (*p == '\n' || *p == '\r' || *p == '\t') *p = ' ';
    fprintf(out, "%s\t%s\n", key, buf);
    free(buf);
}

static void note(const char *msg)
{
    fprintf(out, "note\t%s\n", msg);
}

static BSTR name_of(IUIAutomationElement *el)
{
    BSTR name = NULL;
    IUIAutomationElement_get_CurrentName(el, &name);
    return name;
}

static CONTROLTYPEID type_of(IUIAutomationElement *el)
{
    CONTROLTYPEID type = 0;
    IUIAutomationElement_get_CurrentControlType(el, &type);
    return type;
}

static IUIAutomationElement *first_child(IUIAutomationElement *el)
{
    IUIAutomationElement *child = NULL;
    IUIAutomationTreeWalker_GetFirstChildElement(walker, el, &child);
    return child;
}

static IUIAutomationElement *next_sibling(IUIAutomationElement *el)
{
    IUIAutomationElement *next = NULL;
    IUIAutomationTreeWalker_GetNextSiblingElement(walker, el, &next);
    return next;
}

static IUIAutomationElement *parent_of(IUIAutomationElement *el)
{
    IUIAutomationElement *parent = NULL;
    IUIAutomationTreeWalker_GetParentElement(walker, el, &parent);
    return parent;
}

static int name_is(IUIAutomationElement *el, const WCHAR *want)
{
    BSTR name = name_of(el);
    int same = name && !wcscmp(name, want);
    SysFreeString(name);
    return same;
}

static void list_clear(struct list *l)
{
    for (int i = 0; i < l->n; i++) SysFreeString(l->v[i]);
    l->n = 0;
}

static void list_add(struct list *l, BSTR s)
{
    if (l->n == l->cap)
    {
        l->cap = l->cap ? l->cap * 2 : 64;
        l->v = realloc(l->v, l->cap * sizeof(*l->v));
    }
    l->v[l->n++] = s;
}

static int range_equal(const struct list *a, int ai, const struct list *b, int bi, int n)
{
    for (int i = 0; i < n; i++)
        if (wcscmp(a->v[ai + i], b->v[bi + i])) return 0;
    return 1;
}

static int list_equal(const struct list *a, const struct list *b)
{
    return a->n == b->n && range_equal(a, 0, b, 0, a->n);
}

static void walk(IUIAutomationElement *el, HWND hwnd, int depth, struct found *f)
{
    CONTROLTYPEID type = type_of(el);
    if (type == UIA_TreeControlTypeId)
    {
        IUIAutomationElement *sibling = next_sibling(el);
        if (sibling && name_is(sibling, TREE_SIBLING) && !f->tree)
        {
            IUIAutomationElement_AddRef(el);
            f->tree = el;
            f->tree_hwnd = hwnd;
        }
        if (sibling) IUIAutomationElement_Release(sibling);
        return;
    }
    if (type == UIA_TabItemControlTypeId)
    {
        if (name_is(el, PANEL_TAB) && !f->tab)
        {
            IUIAutomationElement_AddRef(el);
            f->tab = el;
            f->tab_hwnd = hwnd;
        }
        return;
    }
    if (depth > 60) return;
    for (IUIAutomationElement *child = first_child(el), *next; child; child = next)
    {
        walk(child, hwnd, depth + 1, f);
        next = next_sibling(child);
        IUIAutomationElement_Release(child);
    }
}

static BOOL CALLBACK find_in_window(HWND hwnd, LPARAM lparam)
{
    struct found *f = (struct found *)lparam;
    WCHAR cls[64];
    DWORD pid = 0;
    IUIAutomationElement *el = NULL;
    if (!IsWindowVisible(hwnd)) return TRUE;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid != f->pid) return TRUE;
    GetClassNameW(hwnd, cls, 64);
    if (wcsncmp(cls, L"Qt", 2)) return TRUE;
    if (SUCCEEDED(IUIAutomation_ElementFromHandle(uia, hwnd, &el)) && el)
    {
        walk(el, hwnd, 0, f);
        IUIAutomationElement_Release(el);
    }
    return TRUE;
}

static void found_clear(struct found *f)
{
    DWORD pid = f->pid;
    if (f->tree) IUIAutomationElement_Release(f->tree);
    if (f->tab) IUIAutomationElement_Release(f->tab);
    memset(f, 0, sizeof(*f));
    f->pid = pid;
}

static void find(struct found *f)
{
    found_clear(f);
    EnumWindows(find_in_window, (LPARAM)f);
}

/* Waits up to TIMEOUT ms for the tree to (dis)appear. */
static int wait_for_tree(struct found *f, int want, int timeout)
{
    for (DWORD start = GetTickCount();;)
    {
        find(f);
        if (!!f->tree == want) return 1;
        if (GetTickCount() - start > (DWORD)timeout) return 0;
        Sleep(200);
    }
}

static POINT center_of(IUIAutomationElement *el)
{
    RECT rc = {0};
    IUIAutomationElement_get_CurrentBoundingRectangle(el, &rc);
    return (POINT){(rc.left + rc.right) / 2, (rc.top + rc.bottom) / 2};
}

/* Posted, not SendInput: Qt takes the position from the message, so the real pointer stays
 * where it is. */
static void click(HWND hwnd, IUIAutomationElement *el)
{
    POINT pt = center_of(el);
    ScreenToClient(hwnd, &pt);
    LPARAM lp = MAKELPARAM(pt.x, pt.y);
    PostMessageW(hwnd, WM_MOUSEMOVE, 0, lp);
    PostMessageW(hwnd, WM_LBUTTONDOWN, MK_LBUTTON, lp);
    PostMessageW(hwnd, WM_LBUTTONUP, 0, lp);
}

/* Scrolls the tree by ROWS (negative: down). WM_MOUSEWHEEL carries screen coordinates.
 * Qt scrolls at most a page per wheel event, so it goes in steps well under one: sent in
 * 20s, a 179-row scroll moved 63. */
#define ROWS_PER_WHEEL 3
static void scroll(struct found *f, int rows)
{
    POINT pt = center_of(f->tree);
    while (rows)
    {
        int step = rows > ROWS_PER_WHEEL ? ROWS_PER_WHEEL : rows < -ROWS_PER_WHEEL ? -ROWS_PER_WHEEL : rows;
        PostMessageW(f->tree_hwnd, WM_MOUSEWHEEL, MAKEWPARAM(0, (WORD)(short)(step * WHEEL_PER_ROW)),
                     MAKELPARAM(pt.x, pt.y));
        rows -= step;
    }
    /* A posted message is handled after the cross-process calls of the next read, which
     * Studio's thread answers as sent messages - give it time to land first. */
    Sleep(150);
}

static void visible_rows(struct found *f, struct list *rows)
{
    RECT rc = {0};
    list_clear(rows);
    IUIAutomationElement_get_CurrentBoundingRectangle(f->tree, &rc);
    f->tree_top = rc.top;
    f->tree_bottom = rc.bottom;
    f->rows_top = rc.top;
    f->rows_bottom = rc.top;
    /* Only the first and last rows are measured: each call is another ~30 ms. */
    IUIAutomationElement *last = NULL;
    for (IUIAutomationElement *row = first_child(f->tree), *next; row; row = next)
    {
        BSTR name = name_of(row);
        if (name && *name) list_add(rows, name);
        else SysFreeString(name);
        if (!last)
        {
            IUIAutomationElement_get_CurrentBoundingRectangle(row, &rc);
            f->rows_top = rc.top;
        }
        next = next_sibling(row);
        if (last) IUIAutomationElement_Release(last);
        last = row;
    }
    if (last)
    {
        IUIAutomationElement_get_CurrentBoundingRectangle(last, &rc);
        f->rows_bottom = rc.bottom;
        IUIAutomationElement_Release(last);
    }
}

/* Qt also exposes the rows cut by the viewport's edges, so a row reaching past the tree's top
 * or bottom means the list goes on that way. Measured: mid-list the last row ended 16 px
 * below the tree (437 px for a long type error), at the end 1 px inside. Text can't tell:
 * the same message at the same place can be listed several times in a row, and a page of
 * those looks the same after a scroll. */
static int at_top(struct found *f)
{
    return f->rows_top >= f->tree_top;
}

static int at_bottom(struct found *f)
{
    return f->rows_bottom <= f->tree_bottom;
}

static void scroll_to_top(struct found *f, struct list *page)
{
    visible_rows(f, page);
    for (int i = 0; i < 200 && page->n && !at_top(f); i++)
    {
        scroll(f, 60);
        visible_rows(f, page);
    }
}

/* Appends PAGE's rows that ALL doesn't end with yet. EXPECTED is the overlap the scroll
 * should have left (PREV's size minus the rows scrolled); the last page, which scrolls
 * less, falls back to the longest overlap. 0 means the pages didn't overlap at all. */
static int merge(struct list *all, struct list *page, int expected)
{
    int k = -1;
    if (expected > 0 && expected <= page->n && expected <= all->n
        && range_equal(all, all->n - expected, page, 0, expected))
        k = expected;
    for (int i = page->n < all->n ? page->n : all->n; k < 0 && i > 0; i--)
        if (range_equal(all, all->n - i, page, 0, i)) k = i;
    if (k < 0) return 0;
    for (int i = k; i < page->n && all->n < MAX_ROWS; i++) list_add(all, SysAllocString(page->v[i]));
    return 1;
}

/* Reads every row, or with SCROLL_OK 0 only those in view. */
static void read_rows(struct found *f, struct list *all, int scroll_ok)
{
    struct list page = {0}, prev = {0}, start = {0};
    visible_rows(f, &page);
    if (!page.n || !scroll_ok)
    {
        for (int i = 0; i < page.n; i++) list_add(all, page.v[i]);
        free(page.v);
        return;
    }
    for (int i = 0; i < page.n; i++) list_add(&start, SysAllocString(page.v[i]));

    scroll_to_top(f, &page);
    for (int i = 0; i < page.n; i++) list_add(all, SysAllocString(page.v[i]));
    /* Pages in a row that looked the same as the one before. */
    int unmoved = 0;
    for (int guard = 0; guard < 2000 && all->n < MAX_ROWS; guard++)
    {
        int step = page.n > 3 ? page.n - 2 : 1;
        list_clear(&prev);
        for (int i = 0; i < page.n; i++) list_add(&prev, SysAllocString(page.v[i]));
        scroll(f, -step);
        visible_rows(f, &page);
        if (!page.n)
        {
            /* A side tab's window closes when the real pointer moves over Studio. */
            note("the window was hidden during the read; rows may be missing");
            break;
        }
        if (list_equal(&prev, &page))
        {
            if (at_bottom(f)) break;
            /* Not the end: either Studio hasn't applied the scroll yet, or these rows repeat
             * and it has. Give it time, then take the page as it is. */
            Sleep(300);
            visible_rows(f, &page);
            if (list_equal(&prev, &page) && at_bottom(f)) break;
            if (list_equal(&prev, &page) && ++unmoved > 50)
            {
                note("the list stopped scrolling before its end; rows are missing");
                break;
            }
        }
        else
            unmoved = 0;
        if (!merge(all, &page, prev.n - step))
        {
            /* Scrolled further than a page: Qt's wheel setting isn't the 3 lines assumed. */
            note("rows may be missing: the tree scrolled further than expected");
            break;
        }
    }

    /* Back to where the person left it: the page they had, at the top. Found as the whole
     * page, not its first row: the same message repeats across scripts (Unknown global 'x'
     * at the same place in two copies), and the first match of one row put the list back
     * in another script. */
    int at = 0;
    for (int i = 0; i + start.n <= all->n; i++)
        if (range_equal(all, i, &start, 0, start.n))
        {
            at = i;
            break;
        }
    scroll_to_top(f, &page);
    scroll(f, -at);
    /* Then check where it landed and correct: Qt counts a row or two above the viewport as
     * visible too, so a scroll from the top falls a little short. The page is placed at the
     * match nearest to where it should be, since the list repeats itself across scripts. */
    for (int tries = 0; tries < 5; tries++)
    {
        visible_rows(f, &page);
        int landed = -1;
        for (int d = 0; page.n && landed < 0 && d < all->n; d++)
            for (int sign = 1; sign >= -1 && landed < 0; sign -= 2)
            {
                int k = at + sign * d;
                if (k >= 0 && k + page.n <= all->n && range_equal(all, k, &page, 0, page.n)) landed = k;
            }
        if (landed < 0 || landed == at) break;
        scroll(f, landed - at);
    }

    list_clear(&page);
    list_clear(&prev);
    list_clear(&start);
    free(page.v);
    free(prev.v);
    free(start.v);
}

static void summary(struct found *f)
{
    IUIAutomationElement *el = next_sibling(f->tree);
    for (IUIAutomationElement *next; el; el = next)
    {
        BSTR name = name_of(el);
        if (type_of(el) == UIA_CheckBoxControlTypeId && name && wcsstr(name, L" of "))
            put("summary", name);
        SysFreeString(name);
        next = next_sibling(el);
        IUIAutomationElement_Release(el);
    }
}

/* What a dock tab area shows: the names under the tab bar's parent, the bar itself left
 * out. Equal before and after a click when the same tab is showing. */
static void signature(IUIAutomationElement *el, int depth, struct list *sig)
{
    if (sig->n > 150 || depth > 12) return;
    for (IUIAutomationElement *child = first_child(el), *next; child; child = next)
    {
        if (type_of(child) != UIA_TabControlTypeId)
        {
            BSTR name = name_of(child);
            list_add(sig, name ? name : SysAllocString(L""));
            signature(child, depth + 1, sig);
        }
        next = next_sibling(child);
        IUIAutomationElement_Release(child);
    }
}

static IUIAutomationElement *tab_area(IUIAutomationElement *tab)
{
    IUIAutomationElement *bar = parent_of(tab), *area = NULL;
    if (bar)
    {
        area = parent_of(bar);
        IUIAutomationElement_Release(bar);
    }
    return area;
}

/* Clicks the tab back that was showing before ours: the one whose area matches BEFORE. */
static int restore_dock_tab(struct found *f, struct list *before)
{
    IUIAutomationElement *bar = parent_of(f->tab), *area = tab_area(f->tab);
    struct list now = {0};
    int restored = 0;
    if (!bar || !area) goto done;
    for (IUIAutomationElement *tab = first_child(bar), *next; tab && !restored; tab = next)
    {
        if (type_of(tab) == UIA_TabItemControlTypeId && !name_is(tab, PANEL_TAB))
        {
            click(f->tab_hwnd, tab);
            Sleep(400);
            list_clear(&now);
            signature(area, 0, &now);
            restored = list_equal(&now, before);
        }
        next = next_sibling(tab);
        IUIAutomationElement_Release(tab);
    }
done:
    if (bar) IUIAutomationElement_Release(bar);
    if (area) IUIAutomationElement_Release(area);
    list_clear(&now);
    free(now.v);
    return restored;
}

#define MAX_STUDIOS 16

struct studios
{
    HWND hwnd[MAX_STUDIOS];
    int n;
};

/* Collects Studio's main windows ("<place> - Roblox Studio"), those PLACE names if given. */
static BOOL CALLBACK main_window(HWND hwnd, LPARAM lparam)
{
    struct studios *s = (struct studios *)lparam;
    WCHAR title[512];
    if (!IsWindowVisible(hwnd) || !GetWindowTextW(hwnd, title, 512)) return TRUE;
    size_t n = wcslen(title), suffix = wcslen(L" - Roblox Studio");
    if (n > suffix && !wcscmp(title + n - suffix, L" - Roblox Studio")
        && (!want_place || wcsstr(title, want_place)) && s->n < MAX_STUDIOS)
        s->hwnd[s->n++] = hwnd;
    return TRUE;
}

static void read_studio(HWND main)
{
    struct found f = {0};
    struct list rows = {0}, before = {0};
    const char *status = "shown";
    WCHAR title[512];
    GetWindowTextW(main, title, 512);
    put("window", title);
    int enabled = IsWindowEnabled(main);
    if (!enabled)
        note("a dialog is open in this Studio, and its other windows take no input until it closes: "
             "only the rows in view could be read, and a hidden window couldn't be shown");
    /* Only this Studio's windows: another one in the same desktop has its own. */
    GetWindowThreadProcessId(main, &f.pid);

    find(&f);
    if (!f.tree && f.tab)
    {
        IUIAutomationElement *area = tab_area(f.tab);
        if (area)
        {
            signature(area, 0, &before);
            IUIAutomationElement_Release(area);
        }
        click(f.tab_hwnd, f.tab);
        if (!wait_for_tree(&f, 1, 3000))
        {
            fputs("status\tclosed\n", out);
            note("clicking its tab didn't show the Script Analysis window");
            goto done;
        }
        status = "hidden";
    }
    if (!f.tree)
    {
        fputs("status\tclosed\n", out);
        goto done;
    }

    read_rows(&f, &rows, enabled);
    for (int i = 0; i < rows.n; i++) put("row", rows.v[i]);
    summary(&f);

    if (!strcmp(status, "hidden"))
    {
        /* A side tab closes on a second click; a dock tab stays, and the one that was
         * showing has to be clicked instead. */
        click(f.tab_hwnd, f.tab);
        if (wait_for_tree(&f, 0, 1000)) status = "side-tab";
        else
        {
            status = "dock-tab";
            if (!f.tab || !restore_dock_tab(&f, &before))
                note("couldn't tell which tab was showing before; Script Analysis was left in front");
        }
    }
    fprintf(out, "status\t%s\n", status);

done:
    found_clear(&f);
    list_clear(&rows);
    list_clear(&before);
    free(rows.v);
    free(before.v);
}

static void run(void)
{
    struct studios studios = {0};
    EnumWindows(main_window, (LPARAM)&studios);
    for (int i = 0; i < studios.n; i++) read_studio(studios.hwnd[i]);
}

int wmain(int argc, WCHAR **argv)
{
    if (argc < 2) return 2;
    if (argc > 2 && *argv[2]) want_place = argv[2];
    out = _wfopen(argv[1], L"w");
    if (!out) return 3;
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    IUIAutomationCondition *all = NULL;
    if (FAILED(CoCreateInstance(&clsid_cuia, NULL, CLSCTX_INPROC_SERVER, &iid_iuia, (void **)&uia))
        || FAILED(IUIAutomation_CreateTrueCondition(uia, &all))
        || FAILED(IUIAutomation_CreateTreeWalker(uia, all, &walker)))
        note("UI Automation is unavailable in this Wine");
    else
        run();
    fputs("!done\n", out);
    fclose(out);
    return 0;
}
