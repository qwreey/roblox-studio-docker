/* desktop-resize WIDTH HEIGHT
 *
 * Resizes the Wine virtual desktop it runs in, then puts that desktop back in the state
 * Windows itself would leave it in after a resolution change - which Wine (and Kombucha's
 * virtual-desktop shell) don't, see CLAUDE.md's "Panels: Wine virtual desktop":
 *
 *   - the shell's taskbar is taken back out of the work area,
 *   - maximized windows are re-fitted to the new work area, without activating them,
 *   - other windows sticking out past the new right/bottom edge are pulled back in.
 *
 * desktop-resize-service.sh runs it inside Studio's desktop (`wine explorer
 * /desktop=<name> desktop-resize.exe W H`), after putting WxH into the prefix's
 * Explorer\Desktops "Default" value - Wine only accepts a virtual-desktop size from a fixed
 * list plus that value. */
#include <windows.h>
#include <shellapi.h>
#include <stdio.h>
#include <stdlib.h>

#define MAX_MAXIMIZED 64

/* A maximized window overhangs the work area by its sizing border, the same on every side;
 * kept per window so it can be re-fitted to the new work area with SetWindowPos.
 * ShowWindow(SW_MAXIMIZE) would do it too, but activates the window - stealing focus from
 * whatever had it on every resize, and raising Studio's main window over its floating
 * panels. */
struct maximized
{
    HWND hwnd;
    LONG border;
};

static struct maximized maximized[MAX_MAXIMIZED];
static int maximized_count;
static HWND tray_hwnd;

static BOOL CALLBACK record_maximized(HWND hwnd, LPARAM lparam)
{
    const RECT *work = (const RECT *)lparam;
    RECT rc;

    if (maximized_count == MAX_MAXIMIZED) return FALSE;
    if (!IsWindowVisible(hwnd) || !IsZoomed(hwnd) || !GetWindowRect(hwnd, &rc)) return TRUE;
    maximized[maximized_count].hwnd = hwnd;
    /* Measured on the left edge only. The shell hands the taskbar's strip back to the work
     * area some time after a resize, so a window maximized before that ends a taskbar's
     * height above the current work area's bottom - taken as an overhang, that height came
     * back as a gap under the window on every later resize. */
    maximized[maximized_count].border = max(0, work->left - rc.left);
    maximized_count++;
    return TRUE;
}

static BOOL CALLBACK pull_in(HWND hwnd, LPARAM lparam)
{
    const RECT *work = (const RECT *)lparam;
    RECT rc;
    LONG x, y;

    /* The taskbar lives outside the work area by definition; explorer places it. */
    if (hwnd == tray_hwnd || !IsWindowVisible(hwnd) || IsZoomed(hwnd) || IsIconic(hwnd)) return TRUE;
    if (!GetWindowRect(hwnd, &rc)) return TRUE;
    x = rc.left;
    y = rc.top;
    if (rc.right > work->right) x = max(work->left, work->right - (rc.right - rc.left));
    if (rc.bottom > work->bottom) y = max(work->top, work->bottom - (rc.bottom - rc.top));
    if (x != rc.left || y != rc.top)
        SetWindowPos(hwnd, NULL, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    return TRUE;
}

static void refit(const RECT *work)
{
    for (int i = 0; i < maximized_count; i++)
    {
        LONG b = maximized[i].border;
        if (!IsWindow(maximized[i].hwnd) || !IsZoomed(maximized[i].hwnd)) continue;
        SetWindowPos(maximized[i].hwnd, NULL, work->left - b, work->top - b,
                     work->right - work->left + 2 * b, work->bottom - work->top + 2 * b,
                     SWP_NOZORDER | SWP_NOACTIVATE);
    }
    EnumWindows(pull_in, (LPARAM)work);
}

/* The work area the desktop should have: all of it, minus the virtual-desktop shell's
 * taskbar when there is one. Kombucha's explorer recomputes the work area that way whenever
 * an appbar registers or unregisters, so a throwaway one makes it do that now. */
static RECT exclude_taskbar(LONG width, LONG height)
{
    RECT work = {0, 0, width, height};

    if (!tray_hwnd || !IsWindowVisible(tray_hwnd)) return work;
    HWND dummy = CreateWindowExW(WS_EX_TOOLWINDOW, L"STATIC", L"", WS_POPUP, 0, 0, 1, 1,
                                 NULL, NULL, NULL, NULL);
    APPBARDATA abd = {.cbSize = sizeof(abd), .hWnd = dummy, .uCallbackMessage = WM_USER};
    SHAppBarMessage(ABM_NEW, &abd);
    SHAppBarMessage(ABM_REMOVE, &abd);
    DestroyWindow(dummy);
    for (int i = 0; i < 50; i++)
    {
        SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
        if (work.bottom < height) break;
        Sleep(20);
    }
    return work;
}

static void write_status(const wchar_t *path, const char *status)
{
    FILE *f;
    if (!path || !(f = _wfopen(path, L"w"))) return;
    fputs(status, f);
    fclose(f);
}

/* desktop-resize WIDTH HEIGHT [STATUS-FILE] - see the header comment. STATUS-FILE gets
 * "ok" or "refused", since the `wine explorer` launcher doesn't pass the exit status on. */
int wmain(int argc, wchar_t **argv)
{
    DEVMODEW dm = {.dmSize = sizeof(dm), .dmFields = DM_PELSWIDTH | DM_PELSHEIGHT};
    const wchar_t *status_path = argc > 3 ? argv[3] : NULL;
    RECT work;

    if (argc < 3) return 2;
    dm.dmPelsWidth = wcstoul(argv[1], NULL, 10);
    dm.dmPelsHeight = wcstoul(argv[2], NULL, 10);

    SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
    EnumWindows(record_maximized, (LPARAM)&work);

    if (ChangeDisplaySettingsExW(NULL, &dm, NULL, CDS_UPDATEREGISTRY, NULL) != DISP_CHANGE_SUCCESSFUL)
    {
        write_status(status_path, "refused");
        return 1;
    }

    /* The desktop process finishes its own handling of the change asynchronously and
     * resets the work area to the whole desktop when it does - under a second when
     * measured, but not a promise, hence the re-checks below. */
    Sleep(1500);
    tray_hwnd = FindWindowW(L"Shell_TrayWnd", NULL);
    if (tray_hwnd && IsWindowVisible(tray_hwnd))
    {
        /* explorer moves its taskbar to the new bottom edge on WM_DISPLAYCHANGE. */
        RECT tray;
        for (int i = 0; i < 50; i++)
        {
            if (GetWindowRect(tray_hwnd, &tray) && tray.bottom == (LONG)dm.dmPelsHeight) break;
            Sleep(20);
        }
    }

    work = exclude_taskbar(dm.dmPelsWidth, dm.dmPelsHeight);
    refit(&work);
    /* A late reset puts the taskbar back inside the work area; do it again if so. */
    for (int i = 0; i < 3; i++)
    {
        RECT now;
        Sleep(700);
        SystemParametersInfoW(SPI_GETWORKAREA, 0, &now, 0);
        if (EqualRect(&now, &work)) break;
        work = exclude_taskbar(dm.dmPelsWidth, dm.dmPelsHeight);
        refit(&work);
    }
    write_status(status_path, "ok");
    return 0;
}
