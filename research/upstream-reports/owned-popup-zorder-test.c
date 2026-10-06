/* Owner + owned popup; logs z-order of the two every 500ms to Z:\tmp\ztest.log. */
#include <windows.h>
#include <stdio.h>

static HWND owner, popup;
static FILE *logf;

static const char *order(void)
{
    for (HWND w = GetTopWindow(NULL); w; w = GetWindow(w, GW_HWNDNEXT))
    {
        if (w == owner) return "OWNER-above-popup (BAD)";
        if (w == popup) return "popup-above-owner (ok)";
    }
    return "?";
}

static LRESULT CALLBACK proc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    if (m == WM_TIMER) { fprintf(logf, "%lu %s fg=%s\n", GetTickCount(), order(),
                                 GetForegroundWindow() == owner ? "owner" : GetForegroundWindow() == popup ? "popup" : "other");
                         fflush(logf); return 0; }
    if (m == WM_DESTROY && h == owner) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(h, m, w, l);
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, PWSTR cmd, int show)
{
    WNDCLASSW wc = {.lpfnWndProc = proc, .hInstance = inst, .lpszClassName = L"ztest",
                    .hbrBackground = (HBRUSH)(COLOR_WINDOW + 1), .hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW)};
    RegisterClassW(&wc);
    logf = _wfopen(L"Z:\\tmp\\ztest.log", L"w");
    owner = CreateWindowExW(0, L"ztest", L"ZTEST OWNER", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                            100, 100, 900, 600, NULL, NULL, inst, NULL);
    popup = CreateWindowExW(WS_EX_TOOLWINDOW, L"ztest", L"ZTEST POPUP", WS_POPUP | WS_CAPTION | WS_THICKFRAME | WS_VISIBLE,
                            300, 250, 300, 200, owner, NULL, inst, NULL);
    SetTimer(owner, 1, 500, NULL);
    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) { TranslateMessage(&msg); DispatchMessageW(&msg); }
    return 0;
}
