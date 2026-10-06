/* desktop-resize WIDTH HEIGHT
 *
 * Resizes the Wine virtual desktop it runs in, then puts that desktop back in the state
 * Windows itself would leave it in after a resolution change - which Wine (and Kombucha's
 * virtual-desktop shell) don't, see CLAUDE.md's "Panels: Wine virtual desktop":
 *
 *   - the shell's taskbar is taken back out of the work area,
 *   - maximized windows are re-maximized to the new work area,
 *   - other windows sticking out past the new right/bottom edge are pulled back in.
 *
 * desktop-resize-service.sh runs it inside Studio's desktop (`wine explorer
 * /desktop=<name> desktop-resize.exe W H`), after putting WxH into the prefix's
 * Explorer\Desktops "Default" value - Wine only accepts a virtual-desktop size from a fixed
 * list plus that value. Exit status 0 on success, 1 if Wine refused the size. */
#include <windows.h>
#include <shellapi.h>
#include <stdlib.h>

static HWND tray_hwnd;

static BOOL CALLBACK refit(HWND hwnd, LPARAM lparam)
{
    const RECT *work = (const RECT *)lparam;
    RECT rc;
    LONG x, y;

    /* The taskbar lives outside the work area by definition; explorer places it. */
    if (hwnd == tray_hwnd || !IsWindowVisible(hwnd)) return TRUE;
    if (IsZoomed(hwnd))
    {
        /* Wine leaves a maximized window at the old desktop size. */
        ShowWindow(hwnd, SW_RESTORE);
        ShowWindow(hwnd, SW_MAXIMIZE);
        return TRUE;
    }
    if (IsIconic(hwnd) || !GetWindowRect(hwnd, &rc)) return TRUE;
    x = rc.left;
    y = rc.top;
    if (rc.right > work->right) x = max(work->left, work->right - (rc.right - rc.left));
    if (rc.bottom > work->bottom) y = max(work->top, work->bottom - (rc.bottom - rc.top));
    if (x != rc.left || y != rc.top)
        SetWindowPos(hwnd, NULL, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    return TRUE;
}

static BOOL tray_at_bottom(HWND tray, LONG bottom)
{
    RECT rc;
    return GetWindowRect(tray, &rc) && rc.bottom == bottom;
}

int wmain(int argc, wchar_t **argv)
{
    DEVMODEW dm = {.dmSize = sizeof(dm), .dmFields = DM_PELSWIDTH | DM_PELSHEIGHT};
    RECT work;

    if (argc != 3) return 2;
    dm.dmPelsWidth = wcstoul(argv[1], NULL, 10);
    dm.dmPelsHeight = wcstoul(argv[2], NULL, 10);
    if (ChangeDisplaySettingsExW(NULL, &dm, NULL, CDS_UPDATEREGISTRY, NULL) != DISP_CHANGE_SUCCESSFUL)
        return 1;

    /* The desktop process finishes its own handling of the change asynchronously and
     * resets the work area to the whole desktop when it does - measured at under a second.
     * Anything set before that is overwritten. */
    Sleep(1500);

    SetRect(&work, 0, 0, dm.dmPelsWidth, dm.dmPelsHeight);
    tray_hwnd = FindWindowW(L"Shell_TrayWnd", NULL);
    if (tray_hwnd && IsWindowVisible(tray_hwnd))
    {
        /* explorer moves its taskbar to the new bottom edge on WM_DISPLAYCHANGE. */
        for (int i = 0; i < 50 && !tray_at_bottom(tray_hwnd, work.bottom); i++) Sleep(20);

        /* Kombucha's explorer recomputes the work area (desktop minus taskbar) whenever an
         * appbar registers or unregisters; a throwaway one makes it do that now. Writing
         * the work area from here instead races explorer, which re-places its taskbar
         * against whatever the work area is at the time. */
        HWND dummy = CreateWindowExW(WS_EX_TOOLWINDOW, L"STATIC", L"", WS_POPUP, 0, 0, 1, 1,
                                     NULL, NULL, NULL, NULL);
        APPBARDATA abd = {.cbSize = sizeof(abd), .hWnd = dummy, .uCallbackMessage = WM_USER};
        SHAppBarMessage(ABM_NEW, &abd);
        SHAppBarMessage(ABM_REMOVE, &abd);
        DestroyWindow(dummy);
        for (int i = 0; i < 50; i++)
        {
            SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
            if (work.bottom < (LONG)dm.dmPelsHeight) break;
            Sleep(20);
        }
    }

    EnumWindows(refit, (LPARAM)&work);
    return 0;
}
