/* camprobe.exe - stands in for a 3D viewport's right-drag camera (Roblox Studio's):
 * on right-button down it records the cursor position as an anchor and swaps in a
 * near-blank cursor; after every move it reads the cursor's distance from the anchor
 * as that move's delta and warps the cursor back (SetCursorPos). On button up it
 * appends the summed delta to Z:\tmp\camprobe.log.
 *
 * Build: x86_64-w64-mingw32-gcc -mwindows -O2 -o camprobe.exe camprobe.c -luser32
 * Run:   wine explorer /desktop=probe,1920x1048 camprobe.exe [frame] [nullcursor]
 *   frame       sample on a 16 ms timer instead of on every WM_MOUSEMOVE
 *   nullcursor  hide the cursor completely (Xwayland then keeps its pointer lock up)
 * A drag of N pixels should sum to a multiple of N however many events carry it; with
 * an absolute pointer and an unpatched Xwayland it grows with the square of N. */
#include <windows.h>
#include <stdio.h>
#include <string.h>

static POINT anchor;
static BOOL capturing, frame_mode, cursor_mode;
static long total_x, total_y, samples;
static HCURSOR blank; /* not NULL, see nullcursor above */

/* A delta only counts once the warp back to the anchor took: Wine refuses some
 * SetCursorPos calls (the cursor stays put), and the next read then sees the same
 * offset again, which a real viewport would also just read once more. */
static long refused;
static void sample(void)
{
    POINT p, q;
    GetCursorPos(&p);
    if (p.x == anchor.x && p.y == anchor.y)
        return;
    SetCursorPos(anchor.x, anchor.y);
    GetCursorPos(&q);
    if (q.x != anchor.x || q.y != anchor.y) {
        refused++;
        return;
    }
    total_x += p.x - anchor.x;
    total_y += p.y - anchor.y;
    samples++;
}

static LRESULT CALLBACK wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    switch (msg) {
    case WM_RBUTTONDOWN:
        GetCursorPos(&anchor);
        total_x = total_y = samples = refused = 0;
        capturing = TRUE;
        SetCapture(hwnd);
        SetCursor(cursor_mode ? blank : NULL);
        if (frame_mode)
            SetTimer(hwnd, 1, 16, NULL);
        return 0;
    case WM_MOUSEMOVE:
        if (capturing && !frame_mode)
            sample();
        if (capturing)
            SetCursor(cursor_mode ? blank : NULL);
        return 0;
    case WM_TIMER:
        if (capturing)
            sample();
        return 0;
    case WM_RBUTTONUP:
        if (capturing) {
            FILE *f;
            sample();
            capturing = FALSE;
            KillTimer(hwnd, 1);
            ReleaseCapture();
            f = fopen("Z:\\tmp\\camprobe.log", "a");
            if (f) {
                fprintf(f, "total_dx=%ld total_dy=%ld samples=%ld refused=%ld\n", total_x, total_y, samples, refused);
                fclose(f);
            }
        }
        return 0;
    case WM_SETCURSOR:
        if (capturing) {
            SetCursor(cursor_mode ? blank : NULL);
            return TRUE;
        }
        break;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmd, int show)
{
    WNDCLASSW wc = {0};
    MSG m;
    (void)prev;
    frame_mode = cmd && strstr(cmd, "frame") != NULL;
    cursor_mode = !(cmd && strstr(cmd, "nullcursor") != NULL);
    {
        BYTE and_mask[128], xor_mask[128];
        memset(and_mask, 0xff, sizeof(and_mask));
        memset(xor_mask, 0, sizeof(xor_mask));
        and_mask[0] = 0x7f; /* one black pixel: Wine turns an all-transparent cursor into
                               no cursor at all, which Studio's drag cursor isn't */
        blank = CreateCursor(inst, 0, 0, 32, 32, and_mask, xor_mask);
    }
    wc.lpfnWndProc = wndproc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszClassName = L"camprobe";
    RegisterClassW(&wc);
    CreateWindowW(L"camprobe", L"camprobe", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                  100, 100, 1200, 700, NULL, NULL, inst, NULL);
    (void)show;
    while (GetMessageW(&m, NULL, 0, 0) > 0) {
        TranslateMessage(&m);
        DispatchMessageW(&m);
    }
    return 0;
}
