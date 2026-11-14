// Console input with mouse support for the vmm terminal UI (Windows console API).
// Compiled at run time by Add-Type (C# 5, works in Windows PowerShell 5.1 and PowerShell 7).
using System;
using System.Runtime.InteropServices;

public static class VmmConsoleInput
{
    [StructLayout(LayoutKind.Sequential)]
    public struct COORD { public short X; public short Y; }

    [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
    public struct KEY_EVENT_RECORD
    {
        [FieldOffset(0)] public int bKeyDown;
        [FieldOffset(4)] public ushort wRepeatCount;
        [FieldOffset(6)] public ushort wVirtualKeyCode;
        [FieldOffset(8)] public ushort wVirtualScanCode;
        [FieldOffset(10)] public char UnicodeChar;
        [FieldOffset(12)] public uint dwControlKeyState;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSE_EVENT_RECORD
    {
        public COORD dwMousePosition;
        public uint dwButtonState;
        public uint dwControlKeyState;
        public uint dwEventFlags;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUT_RECORD
    {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent;
        [FieldOffset(4)] public MOUSE_EVENT_RECORD MouseEvent;
    }

    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetConsoleMode(IntPtr h, out uint mode);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetConsoleMode(IntPtr h, uint mode);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetNumberOfConsoleInputEvents(IntPtr h, out uint n);
    [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "ReadConsoleInputW")]
    static extern bool ReadConsoleInput(IntPtr h, [Out] INPUT_RECORD[] buffer, uint length, out uint read);

    const uint ENABLE_MOUSE_INPUT = 0x0010, ENABLE_QUICK_EDIT = 0x0040, ENABLE_EXTENDED_FLAGS = 0x0080;
    static IntPtr handle = IntPtr.Zero;
    static uint savedMode;
    static bool active;

    public static bool Active { get { return active; } }

    // Turns on mouse events (and off Quick Edit, which would swallow clicks). Returns false if not a real console.
    public static bool Enable()
    {
        if (active) return true;
        handle = GetStdHandle(-10);
        if (!GetConsoleMode(handle, out savedMode)) return false;
        uint mode = (savedMode | ENABLE_MOUSE_INPUT | ENABLE_EXTENDED_FLAGS) & ~ENABLE_QUICK_EDIT;
        active = SetConsoleMode(handle, mode);
        return active;
    }

    // Turns on escape-sequence colours (24-bit) on the output handle. False = old console: use the 16 colours.
    public static bool EnableVt()
    {
        IntPtr h = GetStdHandle(-11);
        uint mode;
        if (!GetConsoleMode(h, out mode)) return false;
        if ((mode & 0x0004) != 0) return true;
        return SetConsoleMode(h, mode | 0x0004);
    }

    public static void Restore()
    {
        if (!active) return;
        SetConsoleMode(handle, savedMode);
        active = false;
    }

    // null = no input waiting. Otherwise "K|vk|char|ctrl", "M|x|y" (left click), "D|x|y" (double click),
    // "W|delta" (wheel) or "" (other event, ignored).
    public static string Poll()
    {
        if (!active) return null;
        uint n;
        if (!GetNumberOfConsoleInputEvents(handle, out n) || n == 0) return null;
        INPUT_RECORD[] buf = new INPUT_RECORD[1];
        uint read;
        if (!ReadConsoleInput(handle, buf, 1, out read) || read == 0) return null;
        INPUT_RECORD r = buf[0];
        if (r.EventType == 1 && r.KeyEvent.bKeyDown != 0)
            return "K|" + r.KeyEvent.wVirtualKeyCode + "|" + (int)r.KeyEvent.UnicodeChar + "|" + r.KeyEvent.dwControlKeyState;
        if (r.EventType == 2)
        {
            MOUSE_EVENT_RECORD m = r.MouseEvent;
            if (m.dwEventFlags == 0 && (m.dwButtonState & 1) != 0) return "M|" + m.dwMousePosition.X + "|" + m.dwMousePosition.Y;
            if (m.dwEventFlags == 2 && (m.dwButtonState & 1) != 0) return "D|" + m.dwMousePosition.X + "|" + m.dwMousePosition.Y;
            if (m.dwEventFlags == 4) return "W|" + (((int)m.dwButtonState) >> 16);
        }
        return "";
    }
}
