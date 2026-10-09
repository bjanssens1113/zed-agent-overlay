# Zed Thread Colors v3.0
# Puts a small clickable box next to each thread in Zed's Threads Sidebar.
#   Left-click a bar  : pick a color (9 Ayu Mirage colors, or None)
#   Right-click a bar : clear color
#   Each thread's "box" is a tall color bar beside its row in the sidebar.
#   Ring around the thread's row: blue (pulsing) = agent working, green = finished since you
#   last opened the thread (or a five-second green flash if already open).
#   Clicks pass straight through the ring to Zed.
#   Blue dashes below a ring show active helper agents (up to six dashes, then +).
#   Rest the mouse on a thread in the sidebar for a card with its status, your last prompt, and usage.
# Needs you: an amber (pulsing) ring when an agent asks you a question; a Windows notification when a
#   thread asks you something or finishes while you're not looking at it. The bell button under the
#   magnifier (or Ctrl+Alt+Shift+N, or the tray) lists finished threads whose reply asks you for
#   something in its text, pulling out just those sentences.
# Peek: Ctrl+click a thread's color bar (or "Peek" in Needs you) to keep its latest reply open live.
# GitHub status in the sidebar hover card: the newest Actions run for that thread's repo(s)
#   (progress % while running, passed/failed after). Uses the signed-in gh tool, read-only.
#   Click it to open the run on GitHub.
# Look: colors from Zed's Ayu Mirage theme, so the overlay matches Zed.
# Last prompt, turn summary, and usage appear in the sidebar hover card, with no floating panels.
# Thread search (v3.0): searches your prompts and the agents' replies across every thread.
#   Open it with the magnifier box above the color boxes, the tray menu, or Ctrl+Alt+Shift+F.
#   Picking a result flashes that thread's box; open the thread yourself from Zed's sidebar.
# Usage meter (v3.0): sidebar hover text or tray menu > Usage summary.
#   Shows only what the agents record in their own files:
#   Codex's limit % and reset time, Claude's token counts, Copilot's premium requests and prompts.
# How it works: Zed doesn't tell Windows where its thread rows are, so this app reads the sidebar
# text with Windows' built-in text recognition (OCR) and lines the boxes up with the thread names.
# Colors are remembered per project + thread name in %LOCALAPPDATA%\ZedThreadColors\colors.tsv
# Log: %LOCALAPPDATA%\ZedThreadColors\log.txt
# Requirements: Windows 10/11, Zed Threads Sidebar on the LEFT side.

$ErrorActionPreference = 'Stop'

$source = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace ZedColors
{
    public class Row { public string Key, Project, Title; public int CenterY, RowTop, RowBottom; }

    public class Word { public int Line; public string Text; public double X, Y, W, H; }

    public class OLine
    {
        public string Text; public double Left, Top, Bottom;
        public bool IsSub;
        public double Height { get { return Bottom - Top; } }
    }

    public static class Native
    {
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
        [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
        [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
        [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr h, int id);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetWindowLongPtr64(IntPtr h, int i, IntPtr v);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongW")] static extern int SetWindowLong32(IntPtr h, int i, int v);

        [StructLayout(LayoutKind.Sequential)] public struct SIZE { public int CX, CY; }
        [StructLayout(LayoutKind.Sequential, Pack = 1)] public struct BLEND { public byte Op, Flags, Alpha, Format; }
        [DllImport("user32.dll")] static extern bool UpdateLayeredWindow(IntPtr h, IntPtr dstDc, ref POINT dst, ref SIZE size, IntPtr srcDc, ref POINT src, int key, ref BLEND blend, int flags);
        [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
        [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
        [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
        [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
        [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
        [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int value, int size);

        // Puts a bitmap with per-pixel transparency on a layered window (smooth edges over Zed).
        public static void ApplyLayered(IntPtr h, Bitmap bmp, int x, int y)
        {
            IntPtr screen = GetDC(IntPtr.Zero), mem = CreateCompatibleDC(screen), hb = IntPtr.Zero, old = IntPtr.Zero;
            try
            {
                hb = bmp.GetHbitmap(Color.FromArgb(0));
                old = SelectObject(mem, hb);
                SIZE sz = new SIZE(); sz.CX = bmp.Width; sz.CY = bmp.Height;
                POINT dst = new POINT(); dst.X = x; dst.Y = y;
                POINT src = new POINT();
                BLEND b = new BLEND(); b.Op = 0; b.Flags = 0; b.Alpha = 255; b.Format = 1; // AC_SRC_ALPHA
                UpdateLayeredWindow(h, screen, ref dst, ref sz, mem, ref src, 0, ref b, 2);   // ULW_ALPHA
            }
            finally
            {
                if (old != IntPtr.Zero) SelectObject(mem, old);
                if (hb != IntPtr.Zero) DeleteObject(hb);
                DeleteDC(mem);
                ReleaseDC(IntPtr.Zero, screen);
            }
        }

        [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);

        // True when window 'h' is behind window 'other' in the stack.
        public static bool IsBehind(IntPtr h, IntPtr other)
        {
            for (IntPtr w = GetWindow(h, 3); w != IntPtr.Zero; w = GetWindow(w, 3)) // GW_HWNDPREV: walk toward the front
                if (w == other) return true;
            return false;
        }

        // Puts an overlay window back in front (without taking focus). Only used while Zed is the
        // active window, so "in front" means just above Zed.
        public static void BringToFront(IntPtr h)
        {
            SetWindowPos(h, IntPtr.Zero, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010); // HWND_TOP; NOSIZE | NOMOVE | NOACTIVATE
        }

        // Presses a key combination (e.g. Ctrl+Alt+Shift+PageUp) in whatever window is in front.
        public static void SendCombo(byte[] mods, byte key, bool extended)
        {
            uint ext = extended ? 1u : 0u;
            foreach (byte m in mods) keybd_event(m, 0, 0, UIntPtr.Zero);
            keybd_event(key, 0, ext, UIntPtr.Zero);
            keybd_event(key, 0, ext | 2u, UIntPtr.Zero); // KEYEVENTF_KEYUP
            for (int i = mods.Length - 1; i >= 0; i--) keybd_event(mods[i], 0, 2u, UIntPtr.Zero);
        }

        // Windows 11 rounded corners, like Zed's panels (ignored on Windows 10).
        public static void RoundCorners(IntPtr h)
        {
            try { int pref = 3; DwmSetWindowAttribute(h, 33, ref pref, 4); } catch { } // DWMWA_WINDOW_CORNER_PREFERENCE = small round
        }

        // Makes 'owner' the owner window: our boxes then sit just above Zed in the stack,
        // stay behind any other app you bring in front of Zed, and hide when Zed is minimized.
        public static void SetOwner(IntPtr h, IntPtr owner)
        {
            if (IntPtr.Size == 8) SetWindowLongPtr64(h, -8, owner);
            else SetWindowLong32(h, -8, owner.ToInt32());
        }

        public static void InitDpi()
        {
            try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return; } catch { }
            try { SetProcessDPIAware(); } catch { }
        }

        public static float ScaleFor(IntPtr h)
        {
            try { uint d = GetDpiForWindow(h); if (d > 0) return d / 96f; } catch { }
            using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) { return g.DpiY / 96f; }
        }
    }

    // A window drawn with per-pixel transparency, so rounded shapes and glows have smooth edges
    // over Zed. Subclasses draw in Draw(); Invalidate() redraws it.
    public class AlphaWindow : Form
    {
        protected bool ClickThrough = false; // true = every click goes through to Zed
        public float UiScale = 1f;

        public AlphaWindow()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
        }

        protected int Px(float v) { return (int)Math.Round(v * UiScale); }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x80000 | 0x80 | 0x08000000; // LAYERED | TOOLWINDOW | NOACTIVATE (never takes focus from Zed)
                if (ClickThrough) cp.ExStyle |= 0x20;       // TRANSPARENT
                return cp;
            }
        }

        protected virtual void Draw(Graphics g) { }

        public new void Invalidate() { Render(); }

        public void Render()
        {
            if (!IsHandleCreated || Width <= 0 || Height <= 0) return;
            using (Bitmap bmp = new Bitmap(Width, Height, PixelFormat.Format32bppArgb))
            {
                using (Graphics g = Graphics.FromImage(bmp))
                {
                    g.Clear(Color.Transparent);
                    Draw(g);
                }
                Native.ApplyLayered(Handle, bmp, Left, Top);
            }
        }

        protected override void OnPaint(PaintEventArgs e) { }
        protected override void OnPaintBackground(PaintEventArgs e) { }

        public static GraphicsPath RoundRect(RectangleF r, float radius)
        {
            GraphicsPath p = new GraphicsPath();
            float d = Math.Max(1f, Math.Min(radius * 2, Math.Min(r.Width, r.Height)));
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }
    }

    // The strip just right of the sidebar: one tall color bar per thread (click to change color),
    // plus the magnifier button that opens thread search.
    public class BoxForm : AlphaWindow
    {
        public List<Row> Rows = new List<Row>();
        public App Host;
        public string HoverKey = null;   // bar under the mouse (drawn a little brighter)
        public bool HoverSearch = false;

        public BoxForm()
        {
            Cursor = Cursors.Hand;
        }

        public int StripWidth { get { return Px(22); } }
        public int ButtonSize { get { return Px(20); } }
        int BarW { get { return Math.Max(6, Px(7)); } }

        public Rectangle BarRect(Row r)
        {
            int top = r.RowTop - Top + Px(4), bottom = r.RowBottom - Top - Px(4);
            if (bottom - top < Px(14)) { int c = r.CenterY - Top; top = c - Px(7); bottom = c + Px(7); }
            return new Rectangle((Width - BarW) / 2, top, BarW, bottom - top);
        }

        // The clickable area for a row: the whole strip width, the row's full height.
        public Rectangle HitRect(Row r)
        {
            return new Rectangle(0, r.RowTop - Top + 1, Width, Math.Max(Px(16), r.RowBottom - r.RowTop - 2));
        }

        // The row whose bar is under this screen point, or null.
        public Row RowAtScreen(Point p)
        {
            if (!Visible) return null;
            Point c = PointToClient(p);
            foreach (Row r in Rows) if (HitRect(r).Contains(c)) return r;
            return null;
        }

        // The magnifier button that opens thread search (screen y of its center; -1 = hidden).
        public int SearchCenterY = -1;

        public Rectangle SearchRect()
        {
            if (SearchCenterY < 0) return Rectangle.Empty;
            int s = ButtonSize;
            return new Rectangle((Width - s) / 2, SearchCenterY - Top - s / 2, s, s);
        }

        // The "Needs you" button: shows how many finished threads are asking you something.
        public int NeedsCenterY = -1;
        public int NeedsCount = 0;

        public Rectangle NeedsRect()
        {
            if (NeedsCenterY < 0) return Rectangle.Empty;
            int s = ButtonSize;
            return new Rectangle((Width - s) / 2, NeedsCenterY - Top - s / 2, s, s);
        }

        // Flashes one thread's bar three times (used when you pick a search result).
        string flashKey = null;
        int flashLeft = 0;
        System.Windows.Forms.Timer flashTimer;

        public void Flash(string key)
        {
            flashKey = key;
            flashLeft = 6;
            if (flashTimer == null)
            {
                flashTimer = new System.Windows.Forms.Timer();
                flashTimer.Interval = 220;
                flashTimer.Tick += delegate
                {
                    flashLeft--;
                    if (flashLeft <= 0) { flashTimer.Stop(); flashKey = null; }
                    Invalidate();
                };
            }
            flashTimer.Stop();
            flashTimer.Start();
            Invalidate();
        }

        protected override void Draw(Graphics g)
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (SolidBrush hit = new SolidBrush(Color.FromArgb(1, 0, 0, 0))) // invisible, but catches clicks
            {
                foreach (Row r in Rows) g.FillRectangle(hit, HitRect(r));
            }
            foreach (Row r in Rows)
            {
                Rectangle b = BarRect(r);
                int idx = Host.ColorIndex(r.Key);
                bool hover = r.Key == HoverKey;
                Color fill = idx == 0 ? (hover ? Theme.Sel : Theme.Line) : App.Palette[idx];
                if (r.Key == flashKey && flashLeft % 2 == 0) fill = Color.White;
                using (GraphicsPath p = RoundRect(b, b.Width / 2f))
                {
                    using (SolidBrush br = new SolidBrush(fill)) g.FillPath(br, p);
                    if (idx == 0 || hover)
                        using (Pen pen = new Pen(hover ? Theme.Fg : Theme.Sel, 1f)) g.DrawPath(pen, p);
                }
            }

            Rectangle s = SearchRect();
            if (!s.IsEmpty)
            {
                using (GraphicsPath p = RoundRect(new RectangleF(s.X + 0.5f, s.Y + 0.5f, s.Width - 1, s.Height - 1), Px(4)))
                {
                    using (SolidBrush br = new SolidBrush(HoverSearch ? Theme.Line : Theme.Panel)) g.FillPath(br, p);
                    using (Pen pen = new Pen(Theme.Sel, 1f)) g.DrawPath(pen, p);
                }
                float w = Math.Max(1.4f, s.Width / 12f);
                float d = s.Width * 0.38f;
                float cx = s.X + s.Width * 0.45f, cy = s.Y + s.Height * 0.45f;
                using (Pen pen = new Pen(Theme.Fg, w))
                {
                    pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round;
                    g.DrawEllipse(pen, cx - d / 2, cy - d / 2, d, d);
                    g.DrawLine(pen, cx + d * 0.36f, cy + d * 0.36f, s.Right - s.Width * 0.27f, s.Bottom - s.Height * 0.27f);
                }
            }

            Rectangle nr = NeedsRect();
            if (!nr.IsEmpty)
            {
                bool any = NeedsCount > 0;
                using (GraphicsPath p = RoundRect(new RectangleF(nr.X + 0.5f, nr.Y + 0.5f, nr.Width - 1, nr.Height - 1), Px(4)))
                {
                    using (SolidBrush br = new SolidBrush(Theme.Panel)) g.FillPath(br, p);
                    using (Pen pen = new Pen(any ? Theme.Accent : Theme.Sel, any ? 1.5f : 1f)) g.DrawPath(pen, p);
                }
                if (any)
                {
                    // The count, in amber.
                    using (Font f = new Font(Theme.UiFont, 11.5f * UiScale, FontStyle.Bold, GraphicsUnit.Pixel))
                    using (SolidBrush tb = new SolidBrush(Theme.Accent))
                    using (StringFormat sf = new StringFormat())
                    {
                        sf.Alignment = StringAlignment.Center; sf.LineAlignment = StringAlignment.Center;
                        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                        g.DrawString(NeedsCount > 9 ? "9+" : NeedsCount.ToString(), f, tb, new RectangleF(nr.X, nr.Y + 0.5f, nr.Width, nr.Height), sf);
                    }
                }
                else
                {
                    // A small bell.
                    float u = nr.Width / 20f, cx = nr.X + nr.Width / 2f, top = nr.Y + 4.5f * u;
                    using (Pen pen = new Pen(Theme.Dim, Math.Max(1.2f, 1.4f * u)))
                    {
                        pen.LineJoin = LineJoin.Round; pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round;
                        using (GraphicsPath bell = new GraphicsPath())
                        {
                            bell.AddArc(cx - 4.5f * u, top, 9 * u, 9 * u, 180, 180);
                            bell.AddLine(cx + 4.5f * u, top + 4.5f * u, cx + 5.5f * u, top + 9.5f * u);
                            bell.AddLine(cx - 5.5f * u, top + 9.5f * u, cx - 4.5f * u, top + 4.5f * u);
                            bell.CloseFigure();
                            g.DrawPath(pen, bell);
                        }
                        g.DrawLine(pen, cx - 1.5f * u, top + 11.5f * u, cx + 1.5f * u, top + 11.5f * u);
                    }
                }
            }
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            Rectangle s = SearchRect();
            if (!s.IsEmpty && s.Contains(e.Location) && e.Button == MouseButtons.Left)
            {
                Host.OpenSearch();
                return;
            }
            Rectangle nb = NeedsRect();
            if (!nb.IsEmpty && nb.Contains(e.Location) && e.Button == MouseButtons.Left)
            {
                Host.OpenNeeds();
                return;
            }
            foreach (Row r in Rows)
            {
                if (HitRect(r).Contains(e.Location))
                {
                    if (e.Button == MouseButtons.Left && (Control.ModifierKeys & Keys.Control) != 0) { Host.PeekRow(r); return; } // Ctrl+click: Peek
                    if (e.Button == MouseButtons.Right) Host.SetColor(r.Key, 0); // right-click clears
                    else { Host.PickColor(r); return; }                         // left-click opens the picker
                    break;
                }
            }
            Host.RefocusZed();
        }
    }

    // Status rings drawn around whole threads inside Zed's sidebar: blue (gently pulsing) while the
    // agent works, amber (pulsing) while it waits on your answer, green when it finished since you
    // last opened the thread. Clicks pass through.
    public class RingForm : AlphaWindow
    {
        public List<Row> Rows = new List<Row>();
        public Dictionary<string, int> Dots = new Dictionary<string, int>(); // row key -> 1 working, 2 done
        public Dictionary<string, int> ActiveHelpers = new Dictionary<string, int>();
        public const int MaxHelperDashes = 6;
        System.Windows.Forms.Timer pulse;
        DateTime t0 = DateTime.Now;

        public RingForm()
        {
            ClickThrough = true;
            pulse = new System.Windows.Forms.Timer();
            pulse.Interval = 70;
            pulse.Tick += delegate { if (Visible) Render(); else pulse.Stop(); };
        }

        float PenW { get { return Math.Max(1.5f, 1.6f * UiScale); } }
        float GlowW { get { return Math.Max(2f, 3f * UiScale); } }

        public RectangleF RingRect(Row r)
        {
            return new RectangleF(Px(3) + 0.5f, r.RowTop - Top + 0.5f, Width - Px(6) - 1, r.RowBottom - r.RowTop - 1);
        }

        public RectangleF[] HelperRects(Row r)
        {
            int count;
            if (!ActiveHelpers.TryGetValue(r.Key, out count) || count <= 0) return new RectangleF[0];
            int n = Math.Min(count, MaxHelperDashes), gap = Px(6);
            RectangleF ring = RingRect(r);
            float available = ring.Width - Px(8) - (count > MaxHelperDashes ? Px(12) : 0);
            float width = Math.Min(Px(30), (available - gap * (n - 1)) / n);
            if (width <= 0) return new RectangleF[0];
            RectangleF[] bars = new RectangleF[n];
            for (int i = 0; i < n; i++)
                bars[i] = new RectangleF(ring.X + Px(4) + i * (width + gap), ring.Bottom + Px(3), width, Math.Max(2, Px(3)));
            return bars;
        }

        public Rectangle HelperBand(Row r)
        {
            RectangleF ring = RingRect(r);
            return Rectangle.Ceiling(new RectangleF(ring.X, ring.Bottom + Px(2), ring.Width, Px(12)));
        }

        public bool AnyRings()
        {
            foreach (Row r in Rows) { int d; if (Dots.TryGetValue(r.Key, out d) && d > 0) return true; }
            return false;
        }

        protected override void Draw(Graphics g)
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            bool working = false;
            double t = (DateTime.Now - t0).TotalSeconds;
            foreach (Row r in Rows)
            {
                int dot;
                if (!Dots.TryGetValue(r.Key, out dot) || dot <= 0) continue;
                Color c = dot == 1 ? Theme.Working : dot == 3 ? Theme.Accent : Theme.Done;
                bool live = dot == 1 || dot == 3; // working, or waiting on you: these breathe
                float breathe = live ? (float)(0.5 + 0.5 * Math.Sin(t * 2 * Math.PI / 1.8)) : 0.55f;
                if (live) working = true;
                RectangleF rr = RingRect(r);
                using (GraphicsPath p = RoundRect(rr, Px(6)))
                {
                    // Soft glow outside the ring only (never over the thread's text).
                    using (Region outside = new Region(new Rectangle(0, 0, Width, Height)))
                    {
                        outside.Exclude(p);
                        g.Clip = outside;
                        for (int k = 3; k >= 1; k--)
                        {
                            int a = (int)((20 + 45 * breathe) / k);
                            using (Pen gp = new Pen(Color.FromArgb(a, c), PenW + GlowW * k * 2 / 3f)) g.DrawPath(gp, p);
                        }
                        g.ResetClip();
                    }
                    using (Pen pen = new Pen(Color.FromArgb(live ? (int)(170 + 85 * breathe) : 235, c), PenW)) g.DrawPath(pen, p);
                }
                RectangleF[] bars = HelperRects(r);
                using (SolidBrush brush = new SolidBrush(Theme.Working))
                    foreach (RectangleF b in bars) g.FillRectangle(brush, b);
                int helpers;
                if (bars.Length > 0 && ActiveHelpers.TryGetValue(r.Key, out helpers) && helpers > MaxHelperDashes)
                    using (Font font = new Font(Theme.UiFont, 11f * UiScale, FontStyle.Bold, GraphicsUnit.Pixel))
                        using (SolidBrush brush = new SolidBrush(Theme.Working))
                            g.DrawString("+", font, brush, bars[bars.Length - 1].Right + Px(3), bars[0].Top - Px(4));
            }
            if (working && !pulse.Enabled) pulse.Start();
            if (!working && pulse.Enabled) pulse.Stop();
        }

        // The bands of screen the rings cover (outer, inner). The screen reader paints these over
        // with the surrounding pixels so the rings never affect reading the thread names.
        public List<Rectangle[]> Bands()
        {
            List<Rectangle[]> l = new List<Rectangle[]>();
            if (!Visible) return l;
            foreach (Row r in Rows)
            {
                int dot;
                if (!Dots.TryGetValue(r.Key, out dot) || dot <= 0) continue;
                Rectangle ring = Rectangle.Round(RingRect(r));
                ring.Offset(Left, Top);
                Rectangle outer = ring, inner = ring;
                int o = (int)Math.Ceiling(PenW / 2 + GlowW + 2), i = (int)Math.Ceiling(PenW / 2 + 2);
                outer.Inflate(o, o);
                inner.Inflate(-i, -i);
                int helpers;
                if (ActiveHelpers.TryGetValue(r.Key, out helpers) && helpers > 0)
                {
                    Rectangle band = HelperBand(r);
                    band.Offset(Left, Top);
                    outer = Rectangle.Union(outer, band);
                }
                l.Add(new Rectangle[] { outer, inner });
            }
            return l;
        }
    }

    // ---------- Read-only access to Zed's thread list (uses SQLite built into Windows) ----------
    public static class Sqlite
    {
        const string Dll = "winsqlite3.dll";
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_open_v2(byte[] filename, out IntPtr db, int flags, IntPtr vfs);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_close(IntPtr db);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_busy_timeout(IntPtr db, int ms);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int n, out IntPtr stmt, IntPtr tail);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_step(IntPtr stmt);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern IntPtr sqlite3_column_text(IntPtr stmt, int i);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_column_bytes(IntPtr stmt, int i);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_column_count(IntPtr stmt);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_finalize(IntPtr stmt);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern IntPtr sqlite3_errmsg(IntPtr db);

        static byte[] U(string s) { return Encoding.UTF8.GetBytes(s + "\0"); }

        static string Err(IntPtr db)
        {
            try { return Marshal.PtrToStringAnsi(sqlite3_errmsg(db)); } catch { return "?"; }
        }

        public static List<string[]> Query(string path, string sql)
        {
            IntPtr db;
            int rc = sqlite3_open_v2(U(path), out db, 1 /* READONLY */, IntPtr.Zero);
            if (rc != 0)
            {
                string m = db != IntPtr.Zero ? Err(db) : "";
                if (db != IntPtr.Zero) sqlite3_close(db);
                throw new Exception("open failed (" + rc + ") " + m);
            }
            try
            {
                sqlite3_busy_timeout(db, 1000);
                IntPtr st;
                rc = sqlite3_prepare_v2(db, U(sql), -1, out st, IntPtr.Zero);
                if (rc != 0) throw new Exception("query failed (" + rc + ") " + Err(db));
                try
                {
                    List<string[]> rows = new List<string[]>();
                    int n = sqlite3_column_count(st);
                    while ((rc = sqlite3_step(st)) == 100)
                    {
                        string[] r = new string[n];
                        for (int i = 0; i < n; i++)
                        {
                            IntPtr p = sqlite3_column_text(st, i);
                            int len = sqlite3_column_bytes(st, i);
                            if (p == IntPtr.Zero) { r[i] = null; continue; }
                            byte[] b = new byte[len];
                            Marshal.Copy(p, b, 0, len);
                            r[i] = Encoding.UTF8.GetString(b);
                        }
                        rows.Add(r);
                    }
                    if (rc != 101) throw new Exception("read failed (" + rc + ") " + Err(db));
                    return rows;
                }
                finally { sqlite3_finalize(st); }
            }
            finally { sqlite3_close(db); }
        }
    }

    public class ThreadInfo
    {
        public string Agent, Session, Display, Folders, Updated;
        public string AgentName
        {
            get
            {
                string a = (Agent ?? "").ToLowerInvariant();
                if (a.Contains("claude")) return "Claude";
                if (a.Contains("codex")) return "Codex";
                if (a.Contains("copilot")) return "Copilot";
                return Agent;
            }
        }
    }

    // ---------- Finds each agent's saved conversation and pulls your last message ----------
    public static class Transcripts
    {
        static Dictionary<string, string> cache = new Dictionary<string, string>();
        static readonly object findLock = new object(); // the search indexer also looks files up, on its own thread
        public static Action<string> Report;

        static void ReadWarning(string path, Exception ex)
        {
            if (Report != null) Report("history lookup failed for " + path + ": " + ex.Message);
        }

        static void ParseWarning(string path, Exception ex)
        {
            if (Report != null) Report("history entry could not be parsed in " + path + " (" + ex.GetType().Name + ")");
        }

        static string Env(string name)
        {
            string v = Environment.GetEnvironmentVariable(name);
            return string.IsNullOrEmpty(v) ? null : v;
        }

        public static string Find(string agent, string sid)
        {
            lock (findLock) { return FindLocked(agent, sid); }
        }

        static string FindLocked(string agent, string sid)
        {
            string cached;
            if (cache.TryGetValue(sid, out cached) && cached != null && File.Exists(cached)) return cached;
            string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            string a = (agent ?? "").ToLowerInvariant();
            List<string> roots = new List<string>();
            List<string> found = new List<string>();

            if (a.Contains("claude"))
            {
                if (Env("CLAUDE_CONFIG_DIR") != null) roots.Add(Path.Combine(Env("CLAUDE_CONFIG_DIR"), "projects"));
                roots.Add(Path.Combine(home, ".claude", "projects"));
                foreach (string r in roots) Search(r, sid + ".jsonl", 3, found);
            }
            else if (a.Contains("codex"))
            {
                string ch = Env("CODEX_HOME") ?? Path.Combine(home, ".codex");
                Search(Path.Combine(ch, "sessions"), "*" + sid + "*.jsonl", 5, found);
                if (found.Count == 0) Search(Path.Combine(ch, "archived_sessions"), "*" + sid + "*.jsonl", 5, found);
            }
            else if (a.Contains("copilot"))
            {
                string ch = Env("COPILOT_HOME") ?? Path.Combine(home, ".copilot");
                string direct = Path.Combine(Path.Combine(ch, "session-state"), sid);
                if (Directory.Exists(direct)) Search(direct, "*.jsonl", 1, found);
                if (found.Count == 0) Search(ch, "*" + sid + "*", 4, found);
                if (found.Count == 0) SearchDirs(ch, sid, 4, found);
            }

            string best = null;
            DateTime bestT = DateTime.MinValue;
            foreach (string f in found)
            {
                string ext = Path.GetExtension(f).ToLowerInvariant();
                if (ext != ".jsonl" && ext != ".json") continue;
                DateTime t = File.GetLastWriteTimeUtc(f);
                if (t > bestT) { bestT = t; best = f; }
            }
            cache[sid] = best;
            return best;
        }

        static void Search(string dir, string pattern, int depth, List<string> found)
        {
            if (depth < 0 || !Directory.Exists(dir)) return;
            try { found.AddRange(Directory.GetFiles(dir, pattern)); }
            catch (IOException ex) { ReadWarning(dir, ex); }
            catch (UnauthorizedAccessException ex) { ReadWarning(dir, ex); }
            if (depth == 0) return;
            string[] subs;
            try { subs = Directory.GetDirectories(dir); }
            catch (IOException ex) { ReadWarning(dir, ex); return; }
            catch (UnauthorizedAccessException ex) { ReadWarning(dir, ex); return; }
            foreach (string s in subs) Search(s, pattern, depth - 1, found);
        }

        static void SearchDirs(string dir, string name, int depth, List<string> found)
        {
            if (depth < 0 || !Directory.Exists(dir)) return;
            string[] subs;
            try { subs = Directory.GetDirectories(dir); }
            catch (IOException ex) { ReadWarning(dir, ex); return; }
            catch (UnauthorizedAccessException ex) { ReadWarning(dir, ex); return; }
            foreach (string s in subs)
            {
                if (string.Equals(Path.GetFileName(s), name, StringComparison.OrdinalIgnoreCase)) Search(s, "*.json*", 1, found);
                else SearchDirs(s, name, depth - 1, found);
            }
        }

        public static string LastPrompt(string path)
        {
            string text;
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                long len = fs.Length;
                long start = Math.Max(0, len - 8L * 1024 * 1024);
                fs.Seek(start, SeekOrigin.Begin);
                byte[] buf = new byte[len - start];
                int read = 0;
                while (read < buf.Length) { int n = fs.Read(buf, read, buf.Length - read); if (n <= 0) break; read += n; }
                text = Encoding.UTF8.GetString(buf, 0, read);
                if (start > 0) { int nl = text.IndexOf('\n'); text = nl >= 0 ? text.Substring(nl + 1) : ""; }
            }

            System.Web.Script.Serialization.JavaScriptSerializer js = new System.Web.Script.Serialization.JavaScriptSerializer();
            js.MaxJsonLength = int.MaxValue;
            js.RecursionLimit = 200;

            if (path.EndsWith(".json", StringComparison.OrdinalIgnoreCase))
            {
                return Generic(js.DeserializeObject(text));
            }

            string[] lines = text.Split('\n');
            for (int i = lines.Length - 1; i >= 0; i--)
            {
                string line = lines[i].Trim();
                if (line.Length < 2 || line[0] != '{') continue;
                if (i == lines.Length - 1 && !text.EndsWith("\n") && !line.EndsWith("}")) continue;
                object o;
                try { o = js.DeserializeObject(line); }
                catch (ArgumentException ex) { ParseWarning(path, ex); continue; }
                catch (InvalidOperationException ex) { ParseWarning(path, ex); continue; }
                string p = FromLine(o as Dictionary<string, object>);
                if (p != null) return p;
            }
            return null;
        }

        static string FromLine(Dictionary<string, object> d) { return FromLine(d, 6000); }

        // Your message on one history line, or null. 'max' caps the length (search keeps more).
        public static string FromLine(Dictionary<string, object> d, int max)
        {
            if (d == null) return null;
            string type = S(d, "type");

            // Claude Code
            if (type == "user" && d.ContainsKey("message"))
            {
                if (B(d, "isMeta") || B(d, "isCompactSummary") || B(d, "isSidechain")) return null;
                Dictionary<string, object> m = D(d, "message");
                if (m == null || S(m, "role") != "user" || !m.ContainsKey("content")) return null;
                return Clean(ContentText(m["content"]), max);
            }
            // Codex
            if (type == "event_msg")
            {
                Dictionary<string, object> p = D(d, "payload");
                if (p != null && S(p, "type") == "user_message") return Clean(S(p, "message"), max);
                return null;
            }
            if (type == "response_item")
            {
                Dictionary<string, object> p = D(d, "payload");
                if (p != null && S(p, "type") == "message" && S(p, "role") == "user" && p.ContainsKey("content"))
                    return Clean(ContentText(p["content"]), max);
                return null;
            }
            // GitHub Copilot CLI
            if (type != null && (type == "user.message" || type == "user_message" || type.EndsWith(".user_message")))
            {
                Dictionary<string, object> data = D(d, "data") ?? d;
                string source = S(data, "source");
                if (!string.IsNullOrEmpty(S(data, "parentToolCallId")) || (source != null && source.StartsWith("agent-", StringComparison.OrdinalIgnoreCase))) return null;
                return Clean(S(data, "content") ?? S(data, "message") ?? S(data, "text"), max);
            }
            // Anything else shaped like {"role":"user","content":...}
            if (S(d, "role") == "user" && d.ContainsKey("content")) return Clean(ContentText(d["content"]), max);
            return null;
        }

        // The agent's visible reply text: plain text blocks only (no thinking, tool calls or tool output).
        public static string AgentText(object c, int max)
        {
            string s = c as string;
            if (s == null)
            {
                object[] arr = c as object[];
                if (arr == null) return null;
                StringBuilder sb = new StringBuilder();
                foreach (object item in arr)
                {
                    Dictionary<string, object> it = item as Dictionary<string, object>;
                    if (it == null) continue;
                    string t = S(it, "type");
                    if (t != "text" && t != "output_text") continue;
                    string tx = S(it, "text");
                    if (string.IsNullOrEmpty(tx)) continue;
                    if (sb.Length > 0) sb.Append("\n");
                    sb.Append(tx);
                }
                s = sb.ToString();
            }
            s = s.Trim();
            if (s.Length == 0) return null;
            if (s.Length > max) s = s.Substring(0, max) + " ...";
            return s;
        }

        // For single-file JSON histories: the last {"role":"user"} message anywhere in the document.
        static string Generic(object o)
        {
            string last = null;
            Walk(o, ref last);
            return last;
        }

        static void Walk(object o, ref string last)
        {
            Dictionary<string, object> d = o as Dictionary<string, object>;
            if (d != null)
            {
                string p = FromLine(d);
                if (p != null) last = p;
                foreach (object v in d.Values) Walk(v, ref last);
                return;
            }
            object[] arr = o as object[];
            if (arr != null) foreach (object v in arr) Walk(v, ref last);
        }

        static string ContentText(object c)
        {
            string s = c as string;
            if (s != null) return s;
            object[] arr = c as object[];
            if (arr == null) return null;
            StringBuilder sb = new StringBuilder();
            foreach (object item in arr)
            {
                Dictionary<string, object> it = item as Dictionary<string, object>;
                if (it == null) continue;
                string t = S(it, "type");
                if (t == "tool_result") return null;
                if (t == "text" || t == "input_text")
                {
                    string tx = S(it, "text");
                    if (tx == null || IsInjected(tx.Trim())) continue;
                    if (sb.Length > 0) sb.Append("\n");
                    sb.Append(tx);
                }
            }
            return sb.ToString();
        }

        static bool IsInjected(string t)
        {
            string[] prefixes = new string[] {
                "<environment_context", "<user_instructions", "# AGENTS.md", "<permissions", "<user_shell_command",
                "<system-reminder", "<local-command", "Caveat: The messages below", "[Request interrupted",
                "<turn_aborted", "<ide_", "<current_datetime", "<reminder",
                "<task-notification", "<artifact-view-context", "<system_notification", "<system_reminder"
            };
            foreach (string p in prefixes) if (t.StartsWith(p, StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        static readonly Regex CmdRx = new Regex(@"<command-name>\s*(.*?)\s*</command-name>(?:.*?<command-args>\s*(.*?)\s*</command-args>)?", RegexOptions.Singleline);

        static string Clean(string s, int max)
        {
            if (s == null) return null;
            s = s.Trim();
            if (s.Length == 0) return null;
            Match m = CmdRx.Match(s);
            if (m.Success) s = (m.Groups[1].Value + " " + m.Groups[2].Value).Trim();
            if (IsInjected(s)) return null;
            if (s.Length > max) s = s.Substring(0, max) + " ...";
            return s;
        }

        static string S(Dictionary<string, object> d, string k) { object v; return d.TryGetValue(k, out v) ? v as string : null; }
        static bool B(Dictionary<string, object> d, string k) { object v; return d.TryGetValue(k, out v) && v is bool && (bool)v; }
        static Dictionary<string, object> D(Dictionary<string, object> d, string k) { object v; return d.TryGetValue(k, out v) ? v as Dictionary<string, object> : null; }
    }

    // =====================================================================
    // v3.0: thread search + usage meter
    // =====================================================================

    // Colors and font for everything the overlay draws: Zed's "Ayu Mirage" theme
    // (from Zed's assets/themes/ayu/ayu.json), so the overlay looks like part of Zed.
    public static class Theme
    {
        public static readonly Color Bg = Color.FromArgb(0x24, 0x28, 0x35);      // editor.background
        public static readonly Color Panel = Color.FromArgb(0x35, 0x39, 0x44);   // panel / element background
        public static readonly Color Line = Color.FromArgb(0x43, 0x46, 0x4f);    // border.variant / element.hover
        public static readonly Color Sel = Color.FromArgb(0x53, 0x56, 0x5d);     // border / element.selected
        public static readonly Color Fg = Color.FromArgb(0xcc, 0xca, 0xc2);      // text
        public static readonly Color Dim = Color.FromArgb(0x9a, 0x9a, 0x98);     // text.muted
        public static readonly Color Accent = Color.FromArgb(0xfe, 0xcf, 0x72);  // warning (Ayu amber)
        public static readonly Color Working = Color.FromArgb(0x72, 0xcf, 0xfe); // info / text.accent (Zed blue)
        public static readonly Color Done = Color.FromArgb(0x87, 0xd9, 0x6c);    // Ayu's "added" green (its lime reads as amber)
        public static readonly Color Error = Color.FromArgb(0xf1, 0x87, 0x79);   // error (Ayu coral)

        // Zed's own UI font is bundled inside Zed, so use the closest Windows font.
        public static readonly string UiFont = PickFont("Segoe UI Variable Text", "Segoe UI");

        static string PickFont(string want, string fallback)
        {
            try
            {
                using (FontFamily f = new FontFamily(want)) return f.Name == want ? want : fallback;
            }
            catch { return fallback; }
        }

        // 45s / 12m / 3h 5m / 2d
        public static string Ago(TimeSpan s)
        {
            if (s.TotalSeconds < 0) s = TimeSpan.Zero;
            if (s.TotalSeconds < 60) return (int)s.TotalSeconds + "s";
            if (s.TotalMinutes < 60) return (int)s.TotalMinutes + "m";
            if (s.TotalHours < 24) return (int)s.TotalHours + "h " + s.Minutes + "m";
            return (int)s.TotalDays + "d";
        }

        // 3m 12s / 1h 4m (a running timer)
        public static string Dur(TimeSpan s)
        {
            if (s.TotalSeconds < 0) s = TimeSpan.Zero;
            if (s.TotalHours >= 1) return (int)s.TotalHours + "h " + s.Minutes + "m";
            if (s.TotalMinutes >= 1) return (int)s.TotalMinutes + "m " + s.Seconds + "s";
            return (int)s.TotalSeconds + "s";
        }

        // Under 60% green, 60-85% yellow, over 85% red (the color-box colors).
        public static Color ForPercent(double p)
        {
            if (p > 85) return App.Palette[1];
            if (p >= 60) return App.Palette[3];
            return App.Palette[2];
        }

        // 850 / 8.5K / 850K / 1.2M / 3.4B
        public static string Num(long n)
        {
            if (n < 1000) return n.ToString(CultureInfo.InvariantCulture);
            if (n < 1000000) return One(n / 1000.0) + "K";
            if (n < 1000000000) return One(n / 1000000.0) + "M";
            return One(n / 1000000000.0) + "B";
        }

        static string One(double v)
        {
            return v >= 100 ? Math.Round(v).ToString("0", CultureInfo.InvariantCulture) : v.ToString("0.#", CultureInfo.InvariantCulture);
        }

        public static string When(DateTime t)
        {
            return t == DateTime.MinValue ? "" : t.ToString("ddd MMM d, yyyy h:mm tt", CultureInfo.CurrentCulture);
        }
    }

    public class Msg { public bool You; public string Text; public DateTime Time; }

    // One Codex limit window, e.g. weekly: 6% used, resets Tue.
    public class RateWin
    {
        public double Pct;
        public int Minutes;
        public DateTime Resets = DateTime.MinValue;

        public bool HasReset { get { return Resets != DateTime.MinValue && Resets <= DateTime.Now; } }
        public double Effective { get { return HasReset ? 0 : Pct; } }

        public static string Label(int m, bool longForm)
        {
            if (m == 10080) return longForm ? "Weekly" : "wk";
            if (m == 1440) return longForm ? "Daily" : "day";
            if (m > 0 && m % 60 == 0) return longForm ? (m / 60) + "-hour" : (m / 60) + "h";
            return longForm ? m + "-minute" : m + "m";
        }
    }

    // What has been read from one history file so far. Only new bytes are read on each pass.
    public class FileScan
    {
        public string Path, Kind;          // Kind: claude | codex | copilot
        public bool WantText;              // false = usage numbers only (not a Zed thread)
        public long Offset, Len;
        public DateTime Write = DateTime.MinValue;
        public bool Skipping, Dirty;
        public string ReadError, ParseError;
        public List<Msg> Msgs = new List<Msg>();
        public Msg[] Frozen = new Msg[0];  // copy handed to the search thread
        public Dictionary<string, bool> Seen = new Dictionary<string, bool>();
        // Claude: tokens per API reply (a reply is split over several lines that share one id)
        public Dictionary<string, long> IdTok = new Dictionary<string, long>();
        public Dictionary<string, DateTime> IdDay = new Dictionary<string, DateTime>();
        // Codex
        public long CodexTotal = -1;
        public RateWin Primary, Secondary;
        public string Plan;
        public DateTime RateTime = DateTime.MinValue;
        // Copilot
        public int PremiumMax, Prompts;
        public Dictionary<DateTime, int> PremDay = new Dictionary<DateTime, int>();
        public Dictionary<DateTime, int> PromptDay = new Dictionary<DateTime, int>();
        // Turn state: is the agent working on your last prompt, or done?
        public bool HasTurn, Working;
        public DateTime TurnStart = DateTime.MinValue, TurnEnd = DateTime.MinValue;
        public int LastTools;              // Copilot: tool calls in the agent's last message

        // What the agent did this turn, in plain words (counts reset when a new turn starts).
        public int Reads, Commands, Searches, Helpers;
        public HashSet<string> HelperTasks = new HashSet<string>();
        public Dictionary<string, string> HelperTools = new Dictionary<string, string>();
        public Dictionary<string, string> HelperDescriptions = new Dictionary<string, string>();
        public bool WaitingForBackground;
        public int ActiveHelpers { get { return HelperTasks.Count; } }
        public List<string> Edited = new List<string>();
        public string Step = "";            // the latest step, e.g. "Editing App.jsx"

        // A question the agent asked you through its question tool, still unanswered.
        public string AskText;
        public DateTime AskTime = DateTime.MinValue;
        bool askClearsOnStep;               // Claude/Copilot wait for the answer; Codex's question doesn't block

        public void Ask(string text, DateTime t, bool clearsOnNextStep)
        {
            if (string.IsNullOrEmpty(text)) return;
            AskText = text;
            AskTime = t == DateTime.MinValue ? DateTime.Now : t;
            askClearsOnStep = clearsOnNextStep;
        }

        public void StartTurn(DateTime t)
        {
            WaitingForBackground = false;
            AskText = null; // you replied
            if (!Working || TurnStart == DateTime.MinValue)
            {
                TurnStart = t;
                Reads = 0; Commands = 0; Searches = 0; Helpers = 0; Edited = new List<string>(); Step = "";
            }
            HasTurn = true; Working = true;
        }

        public void Did(string kind, string target, string label)
        {
            WaitingForBackground = false;
            if (askClearsOnStep) AskText = null; // the agent moved on, so the question was answered
            if (kind == "read") Reads++;
            else if (kind == "command") Commands++;
            else if (kind == "search") Searches++;
            else if (kind == "helper") Helpers++;
            else if (kind == "edit" && !string.IsNullOrEmpty(target) && !Edited.Contains(target)) Edited.Add(target);
            if (!string.IsNullOrEmpty(label)) Step = label;
        }

        // "Read 4 files - ran 3 commands - edited 2 files (a.ps1, b.md)"
        public string Summary()
        {
            List<string> p = new List<string>();
            if (Reads > 0) p.Add("read " + Reads + (Reads == 1 ? " file" : " files"));
            if (Commands > 0) p.Add("ran " + Commands + (Commands == 1 ? " command" : " commands"));
            if (Searches > 0) p.Add(Searches + (Searches == 1 ? " search" : " searches"));
            if (Helpers > 0) p.Add(Helpers + (Helpers == 1 ? " helper agent" : " helper agents"));
            if (Edited.Count > 0)
            {
                string names = string.Join(", ", Edited.GetRange(0, Math.Min(3, Edited.Count)).ToArray()) + (Edited.Count > 3 ? ", ..." : "");
                p.Add("edited " + Edited.Count + (Edited.Count == 1 ? " file" : " files") + " (" + names + ")");
            }
            if (p.Count == 0) return "";
            string s = string.Join(" \u00B7 ", p.ToArray());
            return char.ToUpper(s[0]) + s.Substring(1);
        }

        // Background work can outlive the main agent's turn.
        public HashSet<string> BackgroundTasks = new HashSet<string>();
        public Dictionary<string, string> BackgroundTools = new Dictionary<string, string>();
        public Dictionary<string, string> BackgroundStops = new Dictionary<string, string>();
        public int Background { get { return BackgroundTasks.Count; } }

        public void HelperStarted(string tool)
        {
            HelperStarted(tool, null);
        }

        public void HelperStarted(string tool, string description)
        {
            if (string.IsNullOrEmpty(tool) || HelperTools.ContainsKey(tool)) return;
            HelperTools[tool] = tool;
            HelperTasks.Add(tool);
            if (!string.IsNullOrWhiteSpace(description))
            {
                string text = Regex.Replace(description, @"\s+", " ").Trim();
                HelperDescriptions[tool] = text.Length > 240 ? text.Substring(0, 237) + "..." : text;
            }
        }

        public string[] ActiveHelperDescriptions()
        {
            List<string> descriptions = new List<string>();
            foreach (string task in HelperTasks)
            {
                string text;
                if (HelperDescriptions.TryGetValue(task, out text)) descriptions.Add(text);
            }
            descriptions.Sort(StringComparer.OrdinalIgnoreCase);
            return descriptions.ToArray();
        }

        public void HelperLaunched(string tool, string task)
        {
            string old;
            if (string.IsNullOrEmpty(task) || !HelperTools.TryGetValue(tool, out old) || !HelperTasks.Remove(old)) return;
            HelperTools[tool] = task;
            HelperTasks.Add(task);
            string description;
            if (HelperDescriptions.TryGetValue(old, out description)) HelperDescriptions[task] = description;
        }

        public void HelperFinished(string task)
        {
            if (string.IsNullOrEmpty(task)) return;
            string id;
            if (HelperTools.TryGetValue(task, out id)) task = id;
            HelperTasks.Remove(task);
        }

        public void BackgroundStarted(string tool)
        {
            if (string.IsNullOrEmpty(tool) || BackgroundTools.ContainsKey(tool)) return;
            BackgroundTools[tool] = tool;
            BackgroundTasks.Add(tool);
        }

        public void BackgroundLaunched(string tool, string task)
        {
            string old;
            if (string.IsNullOrEmpty(task) || !BackgroundTools.TryGetValue(tool, out old)) return;
            if (!BackgroundTasks.Remove(old)) return;
            BackgroundTools[tool] = task;
            BackgroundTasks.Add(task);
            HelperLaunched(tool, task);
        }

        public bool BackgroundFinished(string task)
        {
            if (string.IsNullOrEmpty(task)) return false;
            string id;
            if (BackgroundTools.TryGetValue(task, out id)) task = id;
            HelperFinished(task);
            return BackgroundTasks.Remove(task);
        }

        public bool BackgroundResumed(string tool, string task)
        {
            if (string.IsNullOrEmpty(tool) || string.IsNullOrEmpty(task) || BackgroundTools.ContainsKey(tool)) return false;
            HelperStarted(tool);
            BackgroundStarted(tool);
            BackgroundLaunched(tool, task);
            return true;
        }

        // The agent picked up again without a new prompt from you (e.g. a background task reported back).
        public void Resume(DateTime t)
        {
            WaitingForBackground = false;
            if (Working) return;
            Working = true; HasTurn = true;
            if (TurnStart == DateTime.MinValue) TurnStart = t;
        }

        public void EndTurn(DateTime t)
        {
            if (t == DateTime.MinValue) return;
            WaitingForBackground = false;
            if (Background == 0) HelperTasks.Clear();
            if (askClearsOnStep) AskText = null;
            HasTurn = true; Working = false; TurnEnd = t;
        }

        public void Reset()
        {
            ReadError = null; ParseError = null;
            HasTurn = false; Working = false; TurnStart = DateTime.MinValue; TurnEnd = DateTime.MinValue; LastTools = 0;
            Reads = 0; Commands = 0; Searches = 0; Helpers = 0; Edited = new List<string>(); Step = "";
            Offset = 0; Len = 0; Write = DateTime.MinValue; Skipping = false; Dirty = true;
            Msgs = new List<Msg>(); Seen = new Dictionary<string, bool>();
            IdTok = new Dictionary<string, long>(); IdDay = new Dictionary<string, DateTime>();
            CodexTotal = -1; Primary = null; Secondary = null; Plan = null; RateTime = DateTime.MinValue;
            PremiumMax = 0; Prompts = 0;
            AskText = null; AskTime = DateTime.MinValue;
            BackgroundTasks.Clear(); BackgroundTools.Clear(); BackgroundStops.Clear();
            HelperTasks.Clear(); HelperTools.Clear(); WaitingForBackground = false;
            HelperDescriptions.Clear();
            PremDay = new Dictionary<DateTime, int>(); PromptDay = new Dictionary<DateTime, int>();
        }
    }

    public class ThreadDoc
    {
        public ThreadInfo Info;
        public bool Archived;
        public string Project = "";
        public string File;
        public Msg[] Msgs;
        public string Prompt, Problem;
    }

    public class IndexSnapshot
    {
        public List<ThreadDoc> Docs;
        public bool Building;
        public int Done, Total, Unavailable;
        public string Problem;
    }

    public class ThreadUsage
    {
        public long Tokens = -1; public int Premium = -1; public int Prompts;
        public bool HasTurn, Working;
        public int ActiveHelpers;
        public string[] HelperDescriptions = new string[0];
        public bool WaitingForHelpers;
        public DateTime TurnStart = DateTime.MinValue, TurnEnd = DateTime.MinValue, LastWrite = DateTime.MinValue;
        public string Summary = "", Step = "";
        public string AskText;                       // open question to you, or null
        public DateTime AskTime = DateTime.MinValue;
    }

    public class UsageSnapshot
    {
        public Dictionary<string, ThreadUsage> BySession = new Dictionary<string, ThreadUsage>();
        public bool ClaudeFound, CopilotFound;
        public long ClaudeToday, Claude7;
        public RateWin CodexPrimary, CodexSecondary;
        public string CodexPlan;
        public DateTime CodexAsOf = DateTime.MinValue;
        public int CopilotPromptsToday, CopilotPremiumToday;
    }

    // Background worker: reads every thread's history (read-only) for search, and the usage numbers.
    public class Indexer
    {
        const int MaxText = 50000;
        App host;
        Thread th;
        AutoResetEvent wake = new AutoResetEvent(false);
        volatile bool stop;
        bool firstPass = true;
        Dictionary<string, FileScan> scans = new Dictionary<string, FileScan>(StringComparer.OrdinalIgnoreCase);
        Dictionary<string, string> files = new Dictionary<string, string>();
        Dictionary<string, DateTime> missing = new Dictionary<string, DateTime>();
        class PromptCache
        {
            public long Length;
            public DateTime Write;
            public string Text;
        }
        Dictionary<string, PromptCache> prompts = new Dictionary<string, PromptCache>(StringComparer.OrdinalIgnoreCase);
        List<ThreadDoc> lastDocs = new List<ThreadDoc>();
        string dbProblem;
        System.Web.Script.Serialization.JavaScriptSerializer js;

        public volatile IndexSnapshot Index;
        public volatile UsageSnapshot Usage;

        public Indexer(App h) { host = h; }

        public void Start()
        {
            th = new Thread(Run);
            th.IsBackground = true;
            th.Priority = ThreadPriority.BelowNormal;
            th.Name = "ZedThreadColors indexer";
            th.Start();
        }

        public void Stop() { stop = true; wake.Set(); }
        public void Wake() { wake.Set(); }

        void Run()
        {
            js = new System.Web.Script.Serialization.JavaScriptSerializer();
            js.MaxJsonLength = int.MaxValue;
            js.RecursionLimit = 200;
            wake.WaitOne(2000);
            DateTime lastFull = DateTime.MinValue;
            while (!stop)
            {
                DateTime t0 = DateTime.Now;
                // Thread files are checked every 1.5 s (only new bytes are read, so this is cheap);
                // the wider usage-only files every 30 s.
                bool full = firstPass || (t0 - lastFull).TotalSeconds >= 30;
                bool succeeded = false;
                try { Pass(full); succeeded = true; }
                catch (Exception ex)
                {
                    host.LogOnce("indexer", "indexer error: " + ex.Message);
                    IndexSnapshot old = Index;
                    Index = new IndexSnapshot { Docs = old == null ? new List<ThreadDoc>() : old.Docs,
                        Done = old == null ? 0 : old.Done, Total = old == null ? 0 : old.Total,
                        Unavailable = old == null ? 0 : old.Unavailable,
                        Problem = "History refresh failed; showing any cached results. Open log for details." };
                    host.Post(host.OnIndex);
                }
                if (full && succeeded) lastFull = t0;
                if (firstPass && succeeded)
                {
                    firstPass = false;
                    host.Log("search index built in " + (int)(DateTime.Now - t0).TotalSeconds + " s (" + scans.Count + " history files)");
                }
                wake.WaitOne(1500);
            }
        }

        void Pass(bool full)
        {
            List<ThreadDoc> docs = LoadDocs();
            string act = host.ActiveSession;
            docs.Sort(delegate (ThreadDoc a, ThreadDoc b)
            {
                bool aa = a.Info.Session == act, ba = b.Info.Session == act;
                if (aa != ba) return aa ? -1 : 1;
                if (a.Archived != b.Archived) return a.Archived ? 1 : -1;
                return string.CompareOrdinal(b.Info.Updated, a.Info.Updated);
            });

            if (firstPass) Publish(docs, 0, true);
            int done = 0;
            foreach (ThreadDoc d in docs)
            {
                if (stop) return;
                IndexDoc(d);
                done++;
                if (firstPass && (done == 1 || done % 10 == 0))
                {
                    Publish(docs, done, true);
                    PublishUsage(docs);
                }
            }
            Publish(docs, docs.Count, false);
            PublishUsage(docs);
            // Thread status must not wait for the wider, usage-only file scan.
            if (full) { ScanUsageFiles(); PublishUsage(docs); }
        }

        void Publish(List<ThreadDoc> docs, int done, bool building)
        {
            IndexSnapshot s = new IndexSnapshot();
            s.Docs = new List<ThreadDoc>(docs);
            s.Building = building; s.Done = done; s.Total = docs.Count;
            s.Problem = dbProblem;
            foreach (ThreadDoc d in docs) if (d.Problem != null) s.Unavailable++;
            Index = s;
            host.Post(host.OnIndex);
        }

        List<ThreadDoc> LoadDocs()
        {
            List<ThreadDoc> list = new List<ThreadDoc>();
            List<string[]> rows;
            try
            {
                string db = App.ZedDbPath();
                if (db == null) throw new FileNotFoundException("Zed database not found");
                rows = Sqlite.Query(db,
                    "SELECT agent_id, session_id, COALESCE(NULLIF(title_override,''), title), folder_paths, updated_at, COALESCE(archived,0) " +
                    "FROM sidebar_threads WHERE session_id IS NOT NULL AND session_id <> ''");
            }
            catch (Exception ex)
            {
                dbProblem = "Thread list unavailable; showing any cached results. Open log for details.";
                host.LogOnce("thread-list", "indexer: reading Zed's thread list failed: " + ex.Message);
                return lastDocs;
            }
            dbProblem = null;
            foreach (string[] r in rows)
            {
                ThreadInfo t = new ThreadInfo();
                t.Agent = r[0]; t.Session = r[1]; t.Display = r[2] ?? ""; t.Folders = r[3] ?? ""; t.Updated = r[4] ?? "";
                ThreadDoc d = new ThreadDoc();
                d.Info = t;
                d.Archived = r[5] != null && r[5] != "0";
                d.Project = ProjectName(t.Folders);
                list.Add(d);
            }
            lastDocs = list;
            return list;
        }

        static string ProjectName(string folders)
        {
            List<string> names = new List<string>();
            foreach (string f in folders.Split('\n'))
            {
                string s = f.Trim().TrimEnd('\\', '/');
                if (s.Length == 0) continue;
                try { s = Path.GetFileName(s); } catch { }
                if (s.Length > 0 && !names.Contains(s)) names.Add(s);
            }
            return string.Join(", ", names.ToArray());
        }

        static string KindOf(string agent)
        {
            string a = (agent ?? "").ToLowerInvariant();
            if (a.Contains("claude")) return "claude";
            if (a.Contains("codex")) return "codex";
            if (a.Contains("copilot")) return "copilot";
            return null;
        }

        void IndexDoc(ThreadDoc d)
        {
            string kind = KindOf(d.Info.Agent);
            if (kind == null) { d.Problem = "This agent's history format is not supported."; return; }
            string path = Resolve(d.Info);
            if (path == null) { d.Problem = "Saved history unavailable. Open log for details."; return; }
            d.File = path;
            if (path.EndsWith(".jsonl", StringComparison.OrdinalIgnoreCase))
            {
                FileScan f = Scan(path, kind, true);
                d.Msgs = f.Frozen;
                d.Problem = f.ReadError ?? f.ParseError;
            }
            else d.Problem = "Search is unavailable for this JSON history; the last prompt is still shown.";
            try
            {
                FileInfo fi = new FileInfo(path);
                PromptCache p;
                if (!prompts.TryGetValue(path, out p) || p.Length != fi.Length || p.Write != fi.LastWriteTimeUtc)
                {
                    string text = Transcripts.LastPrompt(path);
                    p = new PromptCache { Length = fi.Length, Write = fi.LastWriteTimeUtc, Text = text };
                    prompts[path] = p;
                }
                d.Prompt = p.Text;
            }
            catch (Exception ex)
            {
                d.Prompt = null;
                d.Problem = "Saved history could not be read. Open log for details.";
                host.LogOnce("prompt:" + path, "prompt read failed for " + path + " (" + ex.GetType().Name + ")");
            }
        }

        string Resolve(ThreadInfo t)
        {
            string p;
            if (files.TryGetValue(t.Session, out p) && File.Exists(p)) return p;
            DateTime until;
            // A new active thread can appear in Zed before its history file is created.
            if (missing.TryGetValue(t.Session, out until) && DateTime.Now < until && t.Session != host.ActiveSession) return null;
            p = null;
            try { p = Transcripts.Find(t.Agent, t.Session); }
            catch (Exception ex) { host.LogOnce("resolve:" + t.Session, "history lookup failed: " + ex.Message); }
            if (p == null)
            {
                host.LogOnce("missing:" + t.Session, "no saved history found for " + t.Agent + " session " + t.Session);
                missing[t.Session] = DateTime.Now.AddSeconds(30);
                return null;
            }
            p = Path.GetFullPath(p);
            files[t.Session] = p;
            missing.Remove(t.Session);
            return p;
        }

        static string Env(string name)
        {
            string v = Environment.GetEnvironmentVariable(name);
            return string.IsNullOrEmpty(v) ? null : v;
        }

        // History files that only feed the usage numbers: recent Claude sessions (any app),
        // the newest Codex sessions (limit %), recent Copilot sessions (prompts, premium requests).
        void ScanUsageFiles()
        {
            string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            DateTime since = DateTime.Now.AddDays(-8);

            List<string> roots = new List<string>();
            if (Env("CLAUDE_CONFIG_DIR") != null) roots.Add(Path.Combine(Env("CLAUDE_CONFIG_DIR"), "projects"));
            roots.Add(Path.Combine(home, ".claude", "projects"));
            List<string> found = new List<string>();
            foreach (string r in roots) Collect(r, "*.jsonl", 3, found);
            foreach (string f in found) if (Recent(f, since)) Scan(Path.GetFullPath(f), "claude", false);

            string ch = Env("CODEX_HOME") ?? Path.Combine(home, ".codex");
            found = new List<string>();
            Collect(Path.Combine(ch, "sessions"), "*.jsonl", 5, found);
            found.Sort(delegate (string a, string b) { return Mtime(b).CompareTo(Mtime(a)); });
            for (int i = 0; i < found.Count && i < 3; i++) Scan(Path.GetFullPath(found[i]), "codex", false);

            string cp = Env("COPILOT_HOME") ?? Path.Combine(home, ".copilot");
            found = new List<string>();
            Collect(Path.Combine(cp, "session-state"), "events.jsonl", 1, found);
            foreach (string f in found) if (Recent(f, since)) Scan(Path.GetFullPath(f), "copilot", false);
        }

        DateTime Mtime(string f)
        {
            try { return File.GetLastWriteTime(f); }
            catch (Exception ex) { host.LogOnce("mtime:" + f, "history timestamp failed for " + f + ": " + ex.Message); return DateTime.MinValue; }
        }
        bool Recent(string f, DateTime since) { return Mtime(f) >= since; }

        void Collect(string dir, string pattern, int depth, List<string> found)
        {
            if (depth < 0 || !Directory.Exists(dir)) return;
            try { found.AddRange(Directory.GetFiles(dir, pattern)); }
            catch (IOException ex) { host.LogOnce("collect:" + dir, "history scan failed for " + dir + ": " + ex.Message); }
            catch (UnauthorizedAccessException ex) { host.LogOnce("collect:" + dir, "history scan failed for " + dir + ": " + ex.Message); }
            if (depth == 0) return;
            string[] subs;
            try { subs = Directory.GetDirectories(dir); }
            catch (IOException ex) { host.LogOnce("collect:" + dir, "history scan failed for " + dir + ": " + ex.Message); return; }
            catch (UnauthorizedAccessException ex) { host.LogOnce("collect:" + dir, "history scan failed for " + dir + ": " + ex.Message); return; }
            foreach (string s in subs) Collect(s, pattern, depth - 1, found);
        }

        FileScan Scan(string path, string kind, bool wantText)
        {
            bool changed;
            return Scan(path, kind, wantText, out changed);
        }

        FileScan Scan(string path, string kind, bool wantText, out bool changed)
        {
            changed = false;
            FileScan f;
            if (!scans.TryGetValue(path, out f))
            {
                f = new FileScan();
                f.Path = path; f.Kind = kind; f.WantText = wantText;
                scans[path] = f;
            }
            else if (wantText && !f.WantText)
            {
                f.WantText = true; // first read skipped the text; read it again with text
                f.Reset();
            }
            try { ReadNew(f); f.ReadError = null; }
            catch (Exception ex)
            {
                f.ReadError = "Saved history could not be read. Open log for details.";
                host.LogOnce("read:" + path, "indexer: could not read " + path + ": " + ex.Message);
            }
            if (f.Dirty) { f.Frozen = f.Msgs.ToArray(); f.Dirty = false; changed = true; }
            return f;
        }

        // Reads only what was added since last time (cached by length + last-write time).
        void ReadNew(FileScan f)
        {
            FileInfo fi = new FileInfo(f.Path);
            if (!fi.Exists) throw new FileNotFoundException("History file no longer exists", f.Path);
            DateTime w = fi.LastWriteTimeUtc;
            if (fi.Length == f.Len && w == f.Write) return;
            if (fi.Length < f.Offset) f.Reset(); // file was rewritten
            using (FileStream fs = new FileStream(f.Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                long end = fs.Length;
                long pos = f.Offset;
                fs.Seek(pos, SeekOrigin.Begin);
                byte[] buf = new byte[1 << 20];
                int have = 0;
                while (pos < end && !stop)
                {
                    if (have == buf.Length)
                    {
                        if (buf.Length >= (32 << 20)) { have = 0; f.Skipping = true; } // one giant line (image/file dump): skip it
                        else { byte[] nb = new byte[buf.Length * 2]; Buffer.BlockCopy(buf, 0, nb, 0, have); buf = nb; }
                    }
                    int n = fs.Read(buf, have, (int)Math.Min((long)(buf.Length - have), end - pos));
                    if (n <= 0) break;
                    pos += n; have += n;
                    int start = 0;
                    while (true)
                    {
                        int nl = Array.IndexOf(buf, (byte)10, start, have - start);
                        if (nl < 0) break;
                        if (f.Skipping) f.Skipping = false;
                        else if (nl > start) Line(f, Encoding.UTF8.GetString(buf, start, nl - start));
                        start = nl + 1;
                    }
                    if (start > 0) { Buffer.BlockCopy(buf, start, buf, 0, have - start); have -= start; }
                    f.Offset = pos - have; // an unfinished last line is read again next time
                }
                if (pos >= end) { f.Len = end; f.Write = w; }
            }
        }

        static bool Has(string s, string x) { return s.IndexOf(x, StringComparison.Ordinal) >= 0; }

        Dictionary<string, object> Parse(string s)
        {
            return js.DeserializeObject(s) as Dictionary<string, object>;
        }

        void Line(FileScan f, string s)
        {
            if (s.Length < 2 || s[0] != '{') return;
            try
            {
                if (f.Kind == "claude") Claude(f, s);
                else if (f.Kind == "codex") Codex(f, s);
                else Copilot(f, s);
            }
            catch (Exception ex)
            {
                f.ParseError = "Some history entries could not be read. Open log for details.";
                host.LogOnce("parse:" + f.Path, "history entry could not be parsed in " + f.Path + " (" + ex.GetType().Name + ")");
            }
        }

        void Claude(FileScan f, string s)
        {
            bool asst = Has(s, "\"assistant\"");
            bool intr = Has(s, "[Request interrupted");
            bool user = f.WantText && Has(s, "\"user\"") && (!Has(s, "\"tool_result\"") || intr);
            bool background = f.WantText && (Has(s, "\"tool_result\"") || (Has(s, "task-notification") && Has(s, "\"queued_command\"")));
            if (!asst && !user && !background) return;
            Dictionary<string, object> d = Parse(s);
            if (d == null) return;
            string type = J.S(d, "type");
            DateTime t = Ts(d);
            if (f.WantText && !J.B(d, "isSidechain"))
            {
                string notification = null;
                if (type == "attachment")
                {
                    Dictionary<string, object> a = J.D(d, "attachment");
                    if (a != null && J.S(a, "type") == "queued_command") notification = J.S(a, "prompt");
                }
                else if (type == "user")
                {
                    Dictionary<string, object> m = J.D(d, "message");
                    object c;
                    if (m != null && m.TryGetValue("content", out c)) notification = Transcripts.AgentText(c, MaxText);
                    Dictionary<string, object> result = J.D(d, "toolUseResult");
                    object[] items = m == null ? null : J.A(m, "content");
                    if (items != null)
                        foreach (object o in items)
                        {
                            Dictionary<string, object> item = o as Dictionary<string, object>;
                            if (item == null || J.S(item, "type") != "tool_result") continue;
                            string tool = J.S(item, "tool_use_id");
                            if (tool == null) continue;
                            string stopped;
                            if (f.BackgroundStops.TryGetValue(tool, out stopped))
                            {
                                if (!J.B(item, "is_error") && (result == null || !result.ContainsKey("success") || J.B(result, "success")))
                                    f.BackgroundFinished(stopped);
                            }
                            else if (J.B(item, "is_error")) f.BackgroundFinished(tool);
                            else if (result != null)
                            {
                                string task = J.S(result, "agentId") ?? J.S(result, "backgroundTaskId") ?? J.S(result, "taskId");
                                if (J.B(result, "isAsync") && f.HelperTools.ContainsKey(tool)) f.BackgroundStarted(tool);
                                f.BackgroundLaunched(tool, task);
                                if (J.B(result, "success") && f.BackgroundResumed(tool, J.S(result, "resumedAgentId"))) f.Resume(t);
                            }
                            if (J.B(item, "is_error") || (result == null && !f.BackgroundTools.ContainsKey(tool))
                                || (result != null && !J.B(result, "isAsync") && J.S(result, "resumedAgentId") == null))
                                f.HelperFinished(tool);
                        }
                }
                if (notification != null && notification.IndexOf("<task-notification", StringComparison.Ordinal) >= 0)
                {
                    Match id = Regex.Match(notification, @"<task-id>\s*([^<]+)\s*</task-id>");
                    Match status = Regex.Match(notification, @"<status>\s*(completed|failed|killed|cancelled|stopped)\s*</status>", RegexOptions.IgnoreCase);
                    if (id.Success && status.Success && f.BackgroundFinished(id.Groups[1].Value.Trim())) f.Resume(t);
                    return;
                }
            }
            if (type == "assistant")
            {
                Dictionary<string, object> m = J.D(d, "message");
                if (m == null) return;
                if (!J.B(d, "isSidechain"))
                {
                    // end_turn = finished; tool_use = still working on it
                    string stopReason = J.S(m, "stop_reason");
                    if (stopReason == "end_turn" || stopReason == "stop_sequence")
                    {
                        // Claude pauses here while background work it started is still running.
                        if (f.Background > 0) { f.Resume(t); f.Did("", null, "Waiting for background work"); f.WaitingForBackground = true; }
                        else f.EndTurn(t);
                    }
                    else if (stopReason == "tool_use" && !f.Working) f.StartTurn(t);
                    object[] items = J.A(m, "content");
                    if (items != null && f.WantText)
                        foreach (object o in items)
                        {
                            Dictionary<string, object> it = o as Dictionary<string, object>;
                            if (it != null && J.S(it, "type") == "tool_use") ClaudeStep(f, J.S(it, "id"), J.S(it, "name"), J.D(it, "input"), t);
                        }
                }
                Dictionary<string, object> u = J.D(m, "usage");
                if (u != null)
                {
                    long tok = J.L(u, "input_tokens") + J.L(u, "output_tokens") + J.L(u, "cache_creation_input_tokens") + J.L(u, "cache_read_input_tokens");
                    string id = J.S(m, "id") ?? J.S(d, "requestId") ?? J.S(d, "uuid");
                    if (id != null)
                    {
                        f.IdTok[id] = tok;
                        if (!f.IdDay.ContainsKey(id) && t != DateTime.MinValue) f.IdDay[id] = t.Date;
                    }
                }
                object c;
                if (f.WantText && !J.B(d, "isSidechain") && m.TryGetValue("content", out c)) AddMsg(f, false, Transcripts.AgentText(c, MaxText), t);
            }
            else if (type == "user" && f.WantText)
            {
                if (intr) { f.BackgroundTasks.Clear(); f.EndTurn(t); return; } // you pressed stop
                string p = Transcripts.FromLine(d, MaxText);
                if (p == null) return;
                if (!J.B(d, "isSidechain")) f.StartTurn(t);
                AddMsg(f, true, p, t);
            }
        }

        // ---------- Turning tool calls into plain-language steps ----------

        static string FileName(string p)
        {
            if (string.IsNullOrEmpty(p)) return null;
            try { string n = Path.GetFileName(p.Trim().TrimEnd('/', '\\')); return n.Length > 0 ? n : p; } catch { return p; }
        }

        // "Question?\n    Options: A  /  B" for each question an agent asked through its question tool.
        static string FormatQuestions(object[] qs, string textKey, string optKey)
        {
            if (qs == null) return null;
            StringBuilder sb = new StringBuilder();
            foreach (object o in qs)
            {
                Dictionary<string, object> q = o as Dictionary<string, object>;
                if (q == null) continue;
                string text = J.S(q, textKey);
                if (string.IsNullOrEmpty(text)) continue;
                if (sb.Length > 0) sb.Append("\n");
                sb.Append(text.Trim());
                object[] opts = J.A(q, optKey);
                if (opts == null || opts.Length == 0) continue;
                List<string> labels = new List<string>();
                foreach (object op in opts)
                {
                    string s = op as string;
                    Dictionary<string, object> od = op as Dictionary<string, object>;
                    if (s == null && od != null) s = J.S(od, "label");
                    if (!string.IsNullOrEmpty(s)) labels.Add(s.Trim());
                }
                if (labels.Count > 0) sb.Append("\n    Options: " + string.Join("  /  ", labels.ToArray()));
            }
            return sb.Length == 0 ? null : sb.ToString();
        }

        static string Friendly(string tool)
        {
            if (string.IsNullOrEmpty(tool)) return "a tool";
            int i = tool.LastIndexOf("__", StringComparison.Ordinal); // mcp__server__tool -> tool
            if (i >= 0) tool = tool.Substring(i + 2);
            return tool.Replace('_', ' ');
        }

        static void ClaudeStep(FileScan f, string tool, string name, Dictionary<string, object> input, DateTime t)
        {
            if (name == null) return;
            if (input == null) input = new Dictionary<string, object>();
            // Background work Claude will wait for (it reports back later as a task notification).
            if (J.B(input, "run_in_background") || name == "Monitor") f.BackgroundStarted(tool);
            else if (name == "TaskStop" && tool != null)
            {
                string task = J.S(input, "task_id");
                if (task != null) f.BackgroundStops[tool] = task;
            }
            string fn = FileName(J.S(input, "file_path") ?? J.S(input, "notebook_path"));
            string desc = J.S(input, "description");
            switch (name)
            {
                case "Read": case "NotebookRead": f.Did("read", fn, "Reading " + (fn ?? "a file")); break;
                case "Edit": case "MultiEdit": case "Write": case "NotebookEdit": f.Did("edit", fn, "Editing " + (fn ?? "a file")); break;
                case "Bash": case "PowerShell": f.Did("command", null, desc ?? "Running a command"); break;
                case "Grep": case "Glob": case "ToolSearch": f.Did("search", null, "Searching the files"); break;
                case "WebSearch": case "WebFetch": f.Did("search", null, "Looking things up online"); break;
                case "Agent": case "Task": f.HelperStarted(tool, desc); f.Did("helper", null, "Calling a helper agent" + (desc != null ? ": " + desc : "")); break;
                case "AskUserQuestion": f.Did("", null, "Waiting for your answer"); f.Ask(FormatQuestions(J.A(input, "questions"), "question", "options"), t, true); break;
                case "TodoWrite": case "TaskStop": case "Monitor": break;
                default: f.Did("", null, "Using " + Friendly(name)); break;
            }
        }

        static readonly Regex PatchFileRx = new Regex(@"\*\*\* (?:Update|Add|Delete) File: ([^\r\n]+)");

        static void CopilotStep(FileScan f, Dictionary<string, object> data, DateTime t)
        {
            string tool = J.S(data, "toolName") ?? "";
            string title = J.S(data, "toolTitle");
            Dictionary<string, object> a = J.D(data, "arguments");
            string raw = J.S(data, "arguments");
            switch (tool)
            {
                case "view": { string fn = a == null ? null : FileName(J.S(a, "path")); f.Did("read", fn, "Reading " + (fn ?? "a file")); break; }
                case "apply_patch":
                case "edit": case "create":
                {
                    string text = raw ?? (a == null ? null : (J.S(a, "str") ?? J.S(a, "patch") ?? J.S(a, "path")));
                    bool any = false;
                    if (text != null)
                        foreach (Match mt in PatchFileRx.Matches(text)) { string fn = FileName(mt.Groups[1].Value); f.Did("edit", fn, "Editing " + fn); any = true; }
                    if (!any) { string fn = a == null ? null : FileName(J.S(a, "path")); f.Did("edit", fn, "Editing " + (fn ?? "files")); }
                    break;
                }
                case "powershell": case "bash": f.Did("command", null, (a == null ? null : J.S(a, "description")) ?? title ?? "Running a command"); break;
                case "read_powershell": case "write_powershell": case "stop_powershell": break; // follow-ups to a command already counted
                case "rg": case "grep": case "glob": case "file_search": f.Did("search", null, "Searching the files"); break;
                case "web_fetch": case "web_search": f.Did("search", null, "Looking things up online"); break;
                case "task":
                    if (J.S(data, "parentToolCallId") == null)
                    {
                        string id = J.S(data, "toolCallId");
                        string description = a == null ? null : J.S(a, "description");
                        string helperName = a == null ? null : J.S(a, "name");
                        f.HelperStarted(id, helperName == null ? description : helperName + (description == null ? "" : ": " + description));
                        if (id != null && a != null && J.S(a, "mode") == "background")
                        {
                            f.BackgroundStarted(id);
                        }
                    }
                    f.Did("helper", null, "Calling a helper agent" + (a != null && J.S(a, "description") != null ? ": " + J.S(a, "description") : ""));
                    break;
                case "ask_user": f.Did("", null, "Waiting for your answer"); if (a != null) f.Ask(FormatQuestions(new object[] { a }, "question", "choices"), t, true); break;
                default: f.Did("", null, title ?? ("Using " + Friendly(tool))); break;
            }
        }

        static void CodexStep(FileScan f, Dictionary<string, object> item)
        {
            string type = J.S(item, "type");
            if (type == "CommandExecution")
            {
                // Codex sorts its own commands into reads, searches, and the rest.
                object[] pcs = J.A(item, "parsed_cmd");
                Dictionary<string, object> pc = pcs != null && pcs.Length > 0 ? pcs[0] as Dictionary<string, object> : null;
                string pt = pc == null ? null : J.S(pc, "type");
                if (pt == "read") { string fn = FileName(J.S(pc, "name") ?? J.S(pc, "path")); f.Did("read", fn, "Reading " + (fn ?? "a file")); }
                else if (pt == "search" || pt == "list_files") f.Did("search", null, "Searching the files");
                else f.Did("command", null, "Running a command");
            }
            else if (type == "FileChange")
            {
                Dictionary<string, object> ch = J.D(item, "changes");
                if (ch != null) foreach (string k in ch.Keys) { string fn = FileName(k); f.Did("edit", fn, "Editing " + fn); }
            }
            else if (type == "Extension") f.Did("search", null, "Looking things up online");
            else if (type == "McpToolCall") f.Did("", null, "Using " + Friendly(J.S(item, "tool")));
        }

        void Codex(FileScan f, string s)
        {
            bool tok = Has(s, "token_count");
            bool msg = f.WantText && (Has(s, "\"message\"") || Has(s, "user_message"));
            bool turn = Has(s, "task_started") || Has(s, "task_complete") || Has(s, "turn_aborted");
            bool step = f.WantText && (Has(s, "item_completed") || Has(s, "request_user_input"));
            if (!tok && !msg && !turn && !step) return;
            Dictionary<string, object> d = Parse(s);
            if (d == null) return;
            string type = J.S(d, "type");
            Dictionary<string, object> p = J.D(d, "payload");
            if (p == null) return;
            string pt = J.S(p, "type");
            DateTime t = Ts(d);

            if (type == "event_msg" && pt == "task_started") { f.StartTurn(t); return; }
            if (type == "event_msg" && (pt == "task_complete" || pt == "turn_aborted")) { f.EndTurn(t); return; }
            if (type == "event_msg" && pt == "item_completed")
            {
                Dictionary<string, object> item = J.D(p, "item");
                if (item != null && f.WantText && f.Working) CodexStep(f, item);
                return;
            }
            if (type == "response_item" && pt == "function_call" && J.S(p, "name") == "request_user_input_async")
            {
                // Codex's question tool doesn't wait: it answers itself ("accepted") and keeps working,
                // so it isn't "waiting on you". Anything Codex really needs shows up in its final reply,
                // which the Needs-you window reads.
                return;
            }

            if (type == "event_msg" && pt == "token_count")
            {
                Dictionary<string, object> info = J.D(p, "info");
                Dictionary<string, object> tu = info == null ? null : J.D(info, "total_token_usage");
                if (tu != null) f.CodexTotal = J.L(tu, "total_tokens");
                Dictionary<string, object> rl = J.D(p, "rate_limits");
                if (rl != null && t >= f.RateTime)
                {
                    RateWin a = Win(J.D(rl, "primary"), t), b = Win(J.D(rl, "secondary"), t);
                    if (a != null || b != null)
                    {
                        f.RateTime = t; f.Primary = a; f.Secondary = b; f.Plan = J.S(rl, "plan_type");
                    }
                }
                return;
            }
            if (!f.WantText) return;
            if (type == "response_item" && pt == "message")
            {
                string role = J.S(p, "role");
                object c;
                if (role == "user") AddMsg(f, true, Transcripts.FromLine(d, MaxText), t);
                else if (role == "assistant" && p.TryGetValue("content", out c)) AddMsg(f, false, Transcripts.AgentText(c, MaxText), t);
            }
            else if (type == "event_msg" && pt == "user_message")
            {
                AddMsg(f, true, Transcripts.FromLine(d, MaxText), t);
            }
        }

        static RateWin Win(Dictionary<string, object> w, DateTime lineTime)
        {
            if (w == null) return null;
            RateWin r = new RateWin();
            r.Pct = J.Dbl(w, "used_percent");
            r.Minutes = (int)J.Dbl(w, "window_minutes");
            object v;
            if (w.TryGetValue("resets_at", out v) && v != null)
            {
                string sv = v as string;
                DateTime dt;
                if (sv != null)
                {
                    if (DateTime.TryParse(sv, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out dt)) r.Resets = dt.ToLocalTime();
                }
                else r.Resets = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(J.Dbl(w, "resets_at")).ToLocalTime();
            }
            else if (w.TryGetValue("resets_in_seconds", out v) && v != null && lineTime != DateTime.MinValue)
            {
                r.Resets = lineTime.AddSeconds(J.Dbl(w, "resets_in_seconds"));
            }
            return r;
        }

        void Copilot(FileScan f, string s)
        {
            bool um = Has(s, "\"user.message\"");
            bool am = f.WantText && Has(s, "\"assistant.message\"");
            bool pr = Has(s, "totalPremiumRequests");
            bool turn = f.WantText && (Has(s, "\"assistant.turn_") || Has(s, "\"tool.execution_start\"") || Has(s, "\"tool.execution_complete\"")
                        || Has(s, "\"subagent.completed\"")
                        || Has(s, "\"session.shutdown\"") || Has(s, "\"session.error\"") || Has(s, "abort"));
            if (!um && !am && !pr && !turn) return;
            Dictionary<string, object> d = Parse(s);
            if (d == null) return;
            string type = J.S(d, "type");
            Dictionary<string, object> data = J.D(d, "data");
            DateTime t = Ts(d);
            if (type == "user.message")
            {
                string prompt = Transcripts.FromLine(d, MaxText);
                if (prompt != null)
                {
                    f.Prompts++;
                    if (t != DateTime.MinValue) Inc(f.PromptDay, t.Date, 1);
                    if (f.WantText)
                    {
                        f.StartTurn(t);
                        f.LastTools = 0;
                        AddMsg(f, true, prompt, t);
                    }
                }
            }
            else if (type == "assistant.message" && f.WantText && data != null && J.S(data, "parentToolCallId") == null)
            {
                // Only the main agent's messages decide "done" (helper sub-agents report separately).
                object tr;
                object[] reqs = data.TryGetValue("toolRequests", out tr) ? tr as object[] : null;
                f.LastTools = reqs == null ? 0 : reqs.Length;
                object c;
                if (data.TryGetValue("content", out c)) AddMsg(f, false, Transcripts.AgentText(c, MaxText), t);
            }
            else if (f.WantText && type != null)
            {
                // A turn ends when the agent's last message asked for no tools; stop/shutdown/error also end it.
                if (type == "assistant.turn_start") { if (!f.Working) f.StartTurn(t); }
                else if (type == "tool.execution_start")
                {
                    if (!f.Working) f.StartTurn(t);
                    if (data != null) CopilotStep(f, data, t);
                }
                else if (type == "tool.execution_complete" && data != null) CopilotHelperResult(f, data);
                else if (type == "subagent.completed" && data != null)
                {
                    f.BackgroundFinished(J.S(data, "toolCallId"));
                    if (f.Background == 0) f.WaitingForBackground = false;
                }
                else if (type == "assistant.turn_end")
                {
                    if (f.LastTools == 0)
                    {
                        if (f.Background > 0) { f.Resume(t); f.WaitingForBackground = true; }
                        else f.EndTurn(t);
                    }
                }
                else if (type == "session.shutdown" || type == "session.error" || type.Contains("abort")) { if (f.Working) f.EndTurn(t); }
            }
            if (data != null && data.ContainsKey("totalPremiumRequests"))
            {
                // A running total for the whole session (it carries over when a session is resumed).
                int v = (int)J.Dbl(data, "totalPremiumRequests");
                if (v > f.PremiumMax)
                {
                    if (t != DateTime.MinValue) Inc(f.PremDay, t.Date, v - f.PremiumMax);
                    f.PremiumMax = v;
                }
            }
        }

        static void CopilotHelperResult(FileScan f, Dictionary<string, object> data)
        {
            string tool = J.S(data, "toolCallId");
            if (tool == null) return;
            if (f.BackgroundTools.ContainsKey(tool))
            {
                if (!J.B(data, "success")) f.BackgroundFinished(tool);
                return;
            }
            f.HelperFinished(tool);
        }

        static void Inc(Dictionary<DateTime, int> d, DateTime k, int n)
        {
            int v;
            d.TryGetValue(k, out v);
            d[k] = v + n;
        }

        static DateTime Ts(Dictionary<string, object> d)
        {
            string s = J.S(d, "timestamp");
            DateTime v;
            if (s != null && DateTime.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out v))
                return v.ToLocalTime();
            return DateTime.MinValue;
        }

        static void AddMsg(FileScan f, bool you, string text, DateTime t)
        {
            if (string.IsNullOrEmpty(text)) return;
            if (text.Length > 20000 && text.IndexOf(' ') < 0) return; // base64 or similar
            string key = (you ? "u" : "a") + text.Length + ":" + text.GetHashCode();
            if (f.Seen.ContainsKey(key)) return; // same message written twice
            f.Seen[key] = true;
            Msg m = new Msg();
            m.You = you; m.Text = text; m.Time = t;
            f.Msgs.Add(m);
            f.Dirty = true;
        }

        void PublishUsage(List<ThreadDoc> docs)
        {
            UsageSnapshot u = new UsageSnapshot();
            DateTime today = DateTime.Today, week = today.AddDays(-6);
            foreach (FileScan f in scans.Values)
            {
                if (f.Kind == "claude")
                {
                    if (f.IdTok.Count > 0) u.ClaudeFound = true;
                    foreach (KeyValuePair<string, long> kv in f.IdTok)
                    {
                        DateTime day;
                        if (!f.IdDay.TryGetValue(kv.Key, out day)) continue;
                        if (day == today) u.ClaudeToday += kv.Value;
                        if (day >= week) u.Claude7 += kv.Value;
                    }
                }
                else if (f.Kind == "codex")
                {
                    if (f.RateTime > u.CodexAsOf)
                    {
                        u.CodexAsOf = f.RateTime; u.CodexPrimary = f.Primary; u.CodexSecondary = f.Secondary; u.CodexPlan = f.Plan;
                    }
                }
                else if (f.Kind == "copilot")
                {
                    if (f.Prompts > 0 || f.PremiumMax > 0) u.CopilotFound = true;
                    int n;
                    if (f.PromptDay.TryGetValue(today, out n)) u.CopilotPromptsToday += n;
                    if (f.PremDay.TryGetValue(today, out n)) u.CopilotPremiumToday += n;
                }
            }
            foreach (ThreadDoc d in docs)
            {
                FileScan f;
                if (d.File == null || !scans.TryGetValue(d.File, out f)) continue;
                ThreadUsage tu = new ThreadUsage();
                tu.HasTurn = f.HasTurn; tu.Working = f.Working; tu.TurnStart = f.TurnStart; tu.TurnEnd = f.TurnEnd;
                tu.ActiveHelpers = f.ActiveHelpers;
                tu.HelperDescriptions = f.ActiveHelperDescriptions();
                tu.WaitingForHelpers = f.WaitingForBackground && f.ActiveHelpers > 0;
                tu.Summary = f.Summary(); tu.Step = f.Step;
                tu.AskText = f.AskText; tu.AskTime = f.AskTime;
                tu.LastWrite = f.Write == DateTime.MinValue ? DateTime.MinValue : f.Write.ToLocalTime();
                if (f.Kind == "claude")
                {
                    long sum = 0;
                    foreach (long v in f.IdTok.Values) sum += v;
                    if (f.IdTok.Count > 0) tu.Tokens = sum;
                }
                else if (f.Kind == "codex") tu.Tokens = f.CodexTotal;
                else { tu.Premium = f.PremiumMax; tu.Prompts = f.Prompts; }
                u.BySession[d.Info.Session] = tu;
            }
            Usage = u;
            host.Post(host.OnUsage);
        }
    }

    // Small JSON helpers for the indexer.
    public static class J
    {
        public static string S(Dictionary<string, object> d, string k) { object v; return d.TryGetValue(k, out v) ? v as string : null; }
        public static bool B(Dictionary<string, object> d, string k) { object v; return d.TryGetValue(k, out v) && v is bool && (bool)v; }
        public static Dictionary<string, object> D(Dictionary<string, object> d, string k) { object v; return d.TryGetValue(k, out v) ? v as Dictionary<string, object> : null; }
        public static object[] A(Dictionary<string, object> d, string k) { object v; return d.TryGetValue(k, out v) ? v as object[] : null; }
        public static double Dbl(Dictionary<string, object> d, string k)
        {
            object v;
            if (!d.TryGetValue(k, out v) || v == null || v is bool) return 0;
            try { return Convert.ToDouble(v, CultureInfo.InvariantCulture); } catch { return 0; }
        }
        public static long L(Dictionary<string, object> d, string k) { return (long)Dbl(d, k); }
    }

    public class ResultItem
    {
        public bool IsHeader;
        public ThreadDoc Doc;
        public Msg M;                     // header: the newest match
        public int More;                  // header: matches beyond the 3 shown
        public DateTime Newest;
        public string Pre = "", Hit = "", Post = "";
        public override string ToString() { return IsHeader ? Doc.Info.Display : Pre + Hit + Post; }
    }

    public static class Searcher
    {
        class Hits { public ThreadDoc Doc; public List<Msg> Ms = new List<Msg>(); public DateTime Newest = DateTime.MinValue; }

        public static string[] Words(string q)
        {
            return q.Split(new char[] { ' ', '\t', '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
        }

        // Every word must appear in the same message (any case). Newest first.
        public static List<ResultItem> Run(IndexSnapshot snap, string query, bool archived, out int threadCount)
        {
            string[] words = Words(query);
            CompareInfo ci = CultureInfo.InvariantCulture.CompareInfo;
            List<Hits> all = new List<Hits>();
            foreach (ThreadDoc d in snap.Docs)
            {
                Msg[] ms = d.Msgs;
                if (ms == null || (d.Archived && !archived)) continue;
                Hits h = null;
                foreach (Msg m in ms)
                {
                    bool ok = true;
                    foreach (string w in words) if (ci.IndexOf(m.Text, w, CompareOptions.IgnoreCase) < 0) { ok = false; break; }
                    if (!ok) continue;
                    if (h == null) { h = new Hits(); h.Doc = d; }
                    h.Ms.Add(m);
                    if (m.Time > h.Newest) h.Newest = m.Time;
                }
                if (h != null) all.Add(h);
            }
            all.Sort(delegate (Hits a, Hits b) { return b.Newest.CompareTo(a.Newest); });
            threadCount = all.Count;

            List<ResultItem> items = new List<ResultItem>();
            for (int k = 0; k < all.Count && k < 200; k++)
            {
                Hits h = all[k];
                h.Ms.Sort(delegate (Msg a, Msg b) { return b.Time.CompareTo(a.Time); });
                ResultItem head = new ResultItem();
                head.IsHeader = true; head.Doc = h.Doc; head.M = h.Ms[0]; head.Newest = h.Newest;
                head.More = Math.Max(0, h.Ms.Count - 3);
                items.Add(head);
                for (int i = 0; i < h.Ms.Count && i < 3; i++) items.Add(Snip(h.Doc, h.Ms[i], words[0], ci));
            }
            return items;
        }

        // About 60 characters either side of the first word's first hit.
        static ResultItem Snip(ThreadDoc d, Msg m, string w, CompareInfo ci)
        {
            ResultItem r = new ResultItem();
            r.Doc = d; r.M = m; r.Newest = m.Time;
            string t = m.Text;
            int i = ci.IndexOf(t, w, CompareOptions.IgnoreCase);
            if (i < 0) i = 0;
            int hl = Math.Min(w.Length, t.Length - i);
            int s = Math.Max(0, i - 60), e = Math.Min(t.Length, i + hl + 60);
            r.Pre = (s > 0 ? "..." : "") + Flat(t.Substring(s, i - s));
            r.Hit = Flat(t.Substring(i, hl));
            r.Post = Flat(t.Substring(i + hl, e - i - hl)) + (e < t.Length ? "..." : "");
            return r;
        }

        static string Flat(string s)
        {
            StringBuilder sb = new StringBuilder(s.Length);
            bool space = false;
            foreach (char c in s)
            {
                if (char.IsWhiteSpace(c)) { if (!space) sb.Append(' '); space = true; }
                else { sb.Append(c); space = false; }
            }
            return sb.ToString();
        }
    }

    // ---------- The "Search threads" window ----------
    public class SearchForm : Form
    {
        App host;
        float sc;
        TextBox box, preview;
        CheckBox arch;
        Label status, meta, hint;
        ListBox list;
        Button copy;
        System.Windows.Forms.Timer debounce;
        Font fBody, fBold, fSmall, fBox;
        int seq = 0;
        bool partial = false, placed = false;
        string previewRaw = "";
        string resultStatus;
        string[] words = new string[0];

        int Px(float v) { return (int)Math.Round(v * sc); }

        protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); Native.RoundCorners(Handle); }

        public SearchForm(App h, float scale)
        {
            host = h;
            sc = Math.Max(1f, scale);
            Text = "Search threads - Zed Thread Colors";
            StartPosition = FormStartPosition.Manual;
            ShowInTaskbar = false;
            AutoScaleMode = AutoScaleMode.None;
            BackColor = Theme.Bg;
            ForeColor = Theme.Fg;
            MinimumSize = new Size(Px(460), Px(380));
            fBody = new Font(Theme.UiFont, 13f * sc, FontStyle.Regular, GraphicsUnit.Pixel);
            fBold = new Font(Theme.UiFont, 13f * sc, FontStyle.Bold, GraphicsUnit.Pixel);
            fSmall = new Font(Theme.UiFont, 12f * sc, FontStyle.Regular, GraphicsUnit.Pixel);
            fBox = new Font(Theme.UiFont, 15f * sc, FontStyle.Regular, GraphicsUnit.Pixel);
            Font = fBody;

            box = new TextBox();
            box.Font = fBox; box.BorderStyle = BorderStyle.FixedSingle; box.BackColor = Theme.Panel; box.ForeColor = Theme.Fg;
            arch = new CheckBox();
            arch.Text = "Include archived threads"; arch.Font = fSmall; arch.ForeColor = Theme.Dim; arch.BackColor = Theme.Bg; arch.FlatStyle = FlatStyle.Flat;
            status = MakeLabel(Theme.Dim); status.TextAlign = ContentAlignment.MiddleRight;
            list = new ListBox();
            list.DrawMode = DrawMode.OwnerDrawVariable; list.BorderStyle = BorderStyle.None; list.IntegralHeight = false;
            list.BackColor = Theme.Panel; list.ForeColor = Theme.Fg; list.Font = fBody;
            meta = MakeLabel(Theme.Dim);
            hint = MakeLabel(Theme.Accent);
            copy = new Button();
            copy.Text = "Copy"; copy.Font = fSmall; copy.FlatStyle = FlatStyle.Flat; copy.BackColor = Theme.Panel; copy.ForeColor = Theme.Fg;
            copy.FlatAppearance.BorderColor = Theme.Line; copy.Enabled = false;
            preview = new TextBox();
            preview.Multiline = true; preview.ReadOnly = true; preview.WordWrap = true; preview.ScrollBars = ScrollBars.Vertical;
            preview.BorderStyle = BorderStyle.None; preview.BackColor = Theme.Panel; preview.ForeColor = Theme.Fg; preview.Font = fBody;
            preview.HideSelection = false;
            Controls.AddRange(new Control[] { box, arch, status, list, meta, copy, hint, preview });

            debounce = new System.Windows.Forms.Timer();
            debounce.Interval = 250;
            debounce.Tick += delegate { debounce.Stop(); RunSearch(); };
            box.TextChanged += delegate { debounce.Stop(); debounce.Start(); };
            box.KeyDown += BoxKeyDown;
            arch.CheckedChanged += delegate { RunSearch(); };
            list.MeasureItem += ListMeasure;
            list.DrawItem += ListDraw;
            list.SelectedIndexChanged += delegate { ShowSelected(); };
            copy.Click += delegate { try { if (previewRaw.Length > 0) Clipboard.SetText(previewRaw); } catch { } };
            Resize += delegate { DoLayout(); };
            DoLayout();
            ShowStatus();
        }

        Label MakeLabel(Color c)
        {
            Label l = new Label();
            l.AutoSize = false; l.AutoEllipsis = true; l.Font = fSmall; l.ForeColor = c; l.BackColor = Theme.Bg;
            l.TextAlign = ContentAlignment.MiddleLeft; l.UseMnemonic = false;
            return l;
        }

        void DoLayout()
        {
            int pad = Px(10), w = ClientSize.Width - 2 * pad, y = pad;
            if (w < Px(100)) return;
            box.SetBounds(pad, y, w, box.PreferredHeight);
            y = box.Bottom + Px(6);
            int aw = Px(230);
            arch.SetBounds(pad, y, aw, Px(22));
            status.SetBounds(pad + aw, y, w - aw, Px(22));
            y += Px(28);
            int rest = ClientSize.Height - y - pad;
            int lh = Math.Max(Px(80), (int)(rest * 0.55));
            list.SetBounds(pad, y, w, lh);
            y = list.Bottom + Px(8);
            int cw = Px(70);
            copy.SetBounds(pad + w - cw, y, cw, Px(26));
            meta.SetBounds(pad, y, w - cw - Px(8), Px(26));
            y += Px(28);
            hint.SetBounds(pad, y, w, Px(22));
            y += Px(24);
            preview.SetBounds(pad, y, w, Math.Max(Px(40), ClientSize.Height - y - pad));
        }

        public void Open(Rectangle zed, IntPtr owner)
        {
            if (!placed)
            {
                placed = true;
                Rectangle area = zed.Width > 0 ? zed : Screen.PrimaryScreen.WorkingArea;
                int w = Math.Min(Px(900), (int)(area.Width * 0.75));
                int hgt = Math.Min(Px(720), (int)(area.Height * 0.8));
                Bounds = new Rectangle(area.Left + (area.Width - w) / 2, area.Top + (area.Height - hgt) / 2, w, hgt);
            }
            if (owner != IntPtr.Zero) Native.SetOwner(Handle, owner);
            if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
            Show();
            Activate();
            box.Focus();
            box.SelectAll();
            if (box.Text.Trim().Length > 0) RunSearch(); else ShowStatus();
        }

        protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
        {
            if (keyData == Keys.Escape) { Hide(); return true; }
            return base.ProcessCmdKey(ref msg, keyData);
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); return; }
            base.OnFormClosing(e);
        }

        void BoxKeyDown(object sender, KeyEventArgs e)
        {
            if ((e.KeyCode == Keys.Down || e.KeyCode == Keys.Enter) && list.Items.Count > 0)
            {
                e.Handled = true; e.SuppressKeyPress = true;
                list.Focus();
                if (list.SelectedIndex < 0) list.SelectedIndex = list.Items.Count > 1 ? 1 : 0;
            }
        }

        void ShowStatus()
        {
            IndexSnapshot s = host.IndexSnap;
            if (s == null) status.Text = "Building the search index...";
            else if (s.Building) status.Text = "Indexing: " + s.Done + " of " + s.Total + " threads";
            else status.Text = s.Problem ?? (s.Total + " threads indexed" + Availability(s));
        }

        static string Availability(IndexSnapshot s)
        {
            return s.Unavailable > 0 ? " - " + s.Unavailable + " histories unavailable or incomplete (see log)" : "";
        }

        public void OnIndexUpdated()
        {
            if (!Visible) return;
            if (partial && box.Text.Trim().Length > 0) RunSearch();
            else if (box.Text.Trim().Length == 0) ShowStatus();
            else
            {
                IndexSnapshot s = host.IndexSnap;
                if (s != null && resultStatus != null) status.Text = s.Problem ?? (resultStatus + Availability(s));
            }
        }

        void ClearPreview()
        {
            previewRaw = ""; preview.Text = ""; meta.Text = ""; hint.Text = ""; copy.Enabled = false;
        }

        void RunSearch()
        {
            string q = box.Text.Trim();
            int my = ++seq;
            if (q.Length == 0)
            {
                list.Items.Clear(); ClearPreview(); partial = false; resultStatus = null; ShowStatus();
                return;
            }
            IndexSnapshot snap = host.IndexSnap;
            if (snap == null) { status.Text = "Building the search index..."; partial = true; return; }
            partial = snap.Building;
            bool inc = arch.Checked;
            status.Text = "Searching...";
            ThreadPool.QueueUserWorkItem(delegate
            {
                List<ResultItem> res;
                int count = 0;
                string error = null;
                try { res = Searcher.Run(snap, q, inc, out count); }
                catch (Exception ex) { res = null; error = "Search failed. Open log for details."; host.Log("search error: " + ex.Message); }
                try
                {
                    BeginInvoke((MethodInvoker)delegate
                    {
                        if (my != seq || IsDisposed) return;
                        if (error != null) { list.Items.Clear(); ClearPreview(); resultStatus = error; status.Text = error; return; }
                        ShowResults(res, count, snap, q);
                    });
                }
                catch { }
            });
        }

        void ShowResults(List<ResultItem> res, int count, IndexSnapshot snap, string q)
        {
            words = Searcher.Words(q);
            list.BeginUpdate();
            list.Items.Clear();
            foreach (ResultItem r in res) list.Items.Add(r);
            list.EndUpdate();
            ClearPreview();
            string s = count == 0 ? "No matches" : count == 1 ? "1 thread" : count + " threads";
            if (count > 200) s += " (showing the newest 200)";
            if (snap.Building) s += "  - still indexing (" + snap.Done + " of " + snap.Total + ")";
            resultStatus = s;
            status.Text = snap.Problem ?? (s + Availability(snap));
        }

        void ShowSelected()
        {
            ResultItem it = list.SelectedItem as ResultItem;
            if (it == null) return;
            Msg m = it.M;
            previewRaw = m.Text;
            string shown = m.Text.Replace("\r\n", "\n").Replace("\n", "\r\n");
            preview.Text = shown;
            int at = -1, len = 0;
            if (words.Length > 0)
            {
                at = CultureInfo.InvariantCulture.CompareInfo.IndexOf(shown, words[0], CompareOptions.IgnoreCase);
                len = words[0].Length;
            }
            if (at >= 0) { preview.Select(at, Math.Min(len, shown.Length - at)); preview.ScrollToCaret(); }
            else { preview.Select(0, 0); preview.ScrollToCaret(); }
            meta.Text = (m.You ? "You" : "Agent (" + it.Doc.Info.AgentName + ")") + "    " + Theme.When(m.Time);
            copy.Enabled = true;

            bool flashed = !it.Doc.Archived && host.FlashSession(it.Doc.Info.Session);
            string where = "Open it from the sidebar: " + (it.Doc.Project.Length > 0 ? it.Doc.Project : "(no project)") + " > " + it.Doc.Info.Display;
            if (it.Doc.Archived) where += "    (archived thread)";
            else if (!flashed) where += "    (not on screen in the sidebar right now)";
            hint.Text = where;
        }

        void ListMeasure(object sender, MeasureItemEventArgs e)
        {
            ResultItem it = e.Index >= 0 && e.Index < list.Items.Count ? list.Items[e.Index] as ResultItem : null;
            e.ItemHeight = Math.Min(255, it != null && it.IsHeader ? Px(30) : Px(22));
        }

        void ListDraw(object sender, DrawItemEventArgs e)
        {
            if (e.Index < 0 || e.Index >= list.Items.Count) return;
            ResultItem it = list.Items[e.Index] as ResultItem;
            if (it == null) return;
            Graphics g = e.Graphics;
            Rectangle r = e.Bounds;
            bool sel = (e.State & DrawItemState.Selected) != 0;
            using (SolidBrush b = new SolidBrush(sel ? Theme.Sel : Theme.Panel)) g.FillRectangle(b, r);
            TextFormatFlags f = TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding | TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter;
            if (it.IsHeader)
            {
                if (e.Index > 0) using (Pen p = new Pen(Theme.Line)) g.DrawLine(p, r.Left, r.Top, r.Right, r.Top);
                int x = Seg(g, it.Doc.Info.Display, fBold, Theme.Fg, r.Left + Px(8), r, f, Px(12));
                string info = it.Doc.Info.AgentName
                    + "   |   " + (it.Doc.Project.Length > 0 ? it.Doc.Project : "(no project)")
                    + "   |   " + Theme.When(it.Newest)
                    + (it.Doc.Archived ? "   |   archived" : "")
                    + (it.More > 0 ? "   |   +" + it.More + " more" : "");
                Seg(g, info, fSmall, Theme.Dim, x, r, f, 0);
            }
            else
            {
                int x = Seg(g, it.M.You ? "You:" : "Agent:", fSmall, Theme.Dim, r.Left + Px(24), r, f, Px(6));
                x = Seg(g, it.Pre, fBody, Theme.Fg, x, r, f, it.Pre.EndsWith(" ") ? Px(4) : 0);
                x = Seg(g, it.Hit, fBold, Theme.Fg, x, r, f, it.Post.StartsWith(" ") ? Px(4) : 0);
                Seg(g, it.Post.TrimStart(), fBody, Theme.Fg, x, r, f, 0);
            }
        }

        // Draws one piece of text and returns where the next one starts.
        int Seg(Graphics g, string t, Font font, Color c, int x, Rectangle r, TextFormatFlags f, int gap)
        {
            if (string.IsNullOrEmpty(t) || x >= r.Right - Px(6)) return x;
            Size sz = TextRenderer.MeasureText(g, t, font, new Size(int.MaxValue, r.Height), f);
            Rectangle rr = new Rectangle(x, r.Top, Math.Min(sz.Width, r.Right - Px(6) - x), r.Height);
            TextRenderer.DrawText(g, t, font, rr, c, f | (sz.Width > rr.Width ? TextFormatFlags.EndEllipsis : TextFormatFlags.Default));
            return x + sz.Width + gap;
        }
    }

    // ---------- The "Usage summary" window ----------
    public class ULine
    {
        public string Text; public Color Color; public bool Bold;
        public string Url;
        public ULine(string t, Color c, bool b) { Text = t; Color = c; Bold = b; }
        public ULine(string t, Color c, bool b, string url) : this(t, c, b) { Url = url; }
    }

    public class UsageForm : Form
    {
        float sc;
        List<ULine> lines = new List<ULine>();
        Font fBody, fBold;
        bool placed = false;

        int Px(float v) { return (int)Math.Round(v * sc); }

        protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); Native.RoundCorners(Handle); }

        public UsageForm(float scale)
        {
            sc = Math.Max(1f, scale);
            Text = "Usage summary - Zed Thread Colors";
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false; MinimizeBox = false;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            AutoScaleMode = AutoScaleMode.None;
            BackColor = Theme.Bg; ForeColor = Theme.Fg;
            DoubleBuffered = true;
            fBody = new Font(Theme.UiFont, 13f * sc, FontStyle.Regular, GraphicsUnit.Pixel);
            fBold = new Font(Theme.UiFont, 14f * sc, FontStyle.Bold, GraphicsUnit.Pixel);
        }

        public void SetLines(List<ULine> l)
        {
            lines = l;
            int w = Px(360), h = Px(12);
            foreach (ULine u in lines)
            {
                if (u.Text.Length == 0) { h += Px(8); continue; }
                Size s = TextRenderer.MeasureText(u.Text, u.Bold ? fBold : fBody);
                w = Math.Max(w, s.Width + Px(32));
                h += s.Height + Px(3);
            }
            ClientSize = new Size(w, h + Px(12));
            Invalidate();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            int y = Px(12);
            foreach (ULine u in lines)
            {
                if (u.Text.Length == 0) { y += Px(8); continue; }
                Font f = u.Bold ? fBold : fBody;
                Size s = TextRenderer.MeasureText(e.Graphics, u.Text, f);
                TextRenderer.DrawText(e.Graphics, u.Text, f, new Point(Px(16), y), u.Color, TextFormatFlags.NoPrefix);
                y += s.Height + Px(3);
            }
        }

        public void Open(Rectangle zed, IntPtr owner)
        {
            if (!placed)
            {
                placed = true;
                Rectangle area = zed.Width > 0 ? zed : Screen.PrimaryScreen.WorkingArea;
                Location = new Point(Math.Max(area.Left, area.Right - Width - Px(30)), area.Top + Px(100));
            }
            if (owner != IntPtr.Zero) Native.SetOwner(Handle, owner);
            Show();
            Activate();
        }

        protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
        {
            if (keyData == Keys.Escape) { Hide(); return true; }
            return base.ProcessCmdKey(ref msg, keyData);
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); return; }
            base.OnFormClosing(e);
        }
    }

    // ---------- The color menu that opens when you click a thread's bar ----------
    public class ColorPicker : Form
    {
        App host;
        float sc = 1f;
        string key;
        int current, hover = -1;
        Font fName;

        int Px(float v) { return (int)Math.Round(v * sc); }
        int N { get { return App.PickerOrder.Length; } }

        protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); Native.RoundCorners(Handle); }

        public ColorPicker(App h)
        {
            host = h;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            BackColor = Theme.Panel;
            DoubleBuffered = true;
            Cursor = Cursors.Hand;
            Deactivate += delegate { Hide(); }; // click anywhere else to close it
        }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x80; // WS_EX_TOOLWINDOW
                return cp;
            }
        }

        Rectangle Swatch(int i)
        {
            int s = Px(22), g = Px(8);
            return new Rectangle(Px(12) + i * (s + g), Px(10), s, s);
        }

        int SwatchAt(Point p)
        {
            for (int i = 0; i < N; i++) { Rectangle r = Swatch(i); r.Inflate(Px(3), Px(3)); if (r.Contains(p)) return i; }
            return -1;
        }

        public void Open(string k, int cur, Point at, float scale, IntPtr owner)
        {
            key = k; current = cur; hover = -1;
            if (fName == null || Math.Abs(Math.Max(1f, scale) - sc) > 0.01f)
            {
                sc = Math.Max(1f, scale);
                fName = new Font(Theme.UiFont, 12f * sc, FontStyle.Regular, GraphicsUnit.Pixel);
            }
            int s = Px(22), g = Px(8);
            ClientSize = new Size(Px(24) + N * s + (N - 1) * g, Px(10) + s + Px(6) + Px(18) + Px(6));
            Rectangle wa = Screen.FromPoint(at).WorkingArea;
            Location = new Point(Math.Max(wa.Left, Math.Min(at.X, wa.Right - Width)), Math.Max(wa.Top, Math.Min(at.Y, wa.Bottom - Height)));
            if (owner != IntPtr.Zero) Native.SetOwner(Handle, owner);
            Show();
            Activate();
            Invalidate();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (Pen bp = new Pen(Theme.Sel)) g.DrawRectangle(bp, 0, 0, Width - 1, Height - 1);
            for (int i = 0; i < N; i++)
            {
                int idx = App.PickerOrder[i];
                Rectangle r = Swatch(i);
                if (idx == 0)
                {
                    // "None": an empty circle with a slash
                    using (Pen p = new Pen(Theme.Dim, Math.Max(1.4f, 1.5f * sc)))
                    {
                        g.DrawEllipse(p, r.X + 1, r.Y + 1, r.Width - 2, r.Height - 2);
                        g.DrawLine(p, r.X + r.Width * 0.25f, r.Bottom - r.Height * 0.25f, r.Right - r.Width * 0.25f, r.Y + r.Height * 0.25f);
                    }
                }
                else using (SolidBrush b = new SolidBrush(App.Palette[idx])) g.FillEllipse(b, r);

                Rectangle o = r;
                o.Inflate(Px(3), Px(3));
                if (idx == current) using (Pen p = new Pen(Theme.Fg, Math.Max(1.5f, 2f * sc))) g.DrawEllipse(p, o);
                else if (i == hover) using (Pen p = new Pen(Theme.Dim, Math.Max(1f, 1.2f * sc))) g.DrawEllipse(p, o);
            }
            string label = hover >= 0 ? App.ColorNames[App.PickerOrder[hover]]
                         : (current > 0 ? App.ColorNames[current] + " (current)  -  Esc to close" : "Pick a color  -  Esc to close");
            TextRenderer.DrawText(g, label, fName, new Rectangle(Px(12), Px(10) + Px(22) + Px(6), Width - Px(24), Px(18)), Theme.Dim,
                TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            int h = SwatchAt(e.Location);
            if (h != hover) { hover = h; Invalidate(); }
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            base.OnMouseLeave(e);
            if (hover != -1) { hover = -1; Invalidate(); }
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            int i = SwatchAt(e.Location);
            if (i < 0) return;
            host.SetColor(key, App.PickerOrder[i]);
            Hide();
            host.RefocusZed();
        }

        protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
        {
            if (keyData == Keys.Escape) { Hide(); host.RefocusZed(); return true; }
            return base.ProcessCmdKey(ref msg, keyData);
        }
    }

    // ---------- The card that appears when you hover a thread's box ----------
    public class HoverCard : Form
    {
        public App Host;
        float sc = 1f;
        List<ULine> lines = new List<ULine>();
        List<int> heights = new List<int>();
        Font fBody, fBold;
        int textW;

        int Px(float v) { return (int)Math.Round(v * sc); }

        protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); Native.RoundCorners(Handle); }

        public HoverCard()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            BackColor = Theme.Panel;
            DoubleBuffered = true;
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x80 | 0x08000000; // WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE: never takes focus from Zed
                return cp;
            }
        }

        // Lays out the lines; long lines wrap at about 420 px (at 100% scaling).
        public void SetContent(List<ULine> l, float scale)
        {
            if (fBody == null || Math.Abs(scale - sc) > 0.01f)
            {
                if (fBody != null) { fBody.Dispose(); fBold.Dispose(); }
                sc = Math.Max(1f, scale);
                fBody = new Font(Theme.UiFont, 12.5f * sc, FontStyle.Regular, GraphicsUnit.Pixel);
                fBold = new Font(Theme.UiFont, 13.5f * sc, FontStyle.Bold, GraphicsUnit.Pixel);
            }
            lines = l;
            heights = new List<int>();
            int maxW = Px(420), w = Px(200), h = Px(10);
            foreach (ULine u in lines)
            {
                Size s = TextRenderer.MeasureText(u.Text.Length == 0 ? " " : u.Text, u.Bold ? fBold : fBody, new Size(maxW, int.MaxValue),
                    TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix | TextFormatFlags.TextBoxControl);
                int lh = u.Text.Length == 0 ? Px(4) : s.Height;
                heights.Add(lh);
                w = Math.Max(w, Math.Min(maxW, s.Width));
                h += lh + Px(3);
            }
            textW = w;
            Size = new Size(w + Px(24), h + Px(8));
            Invalidate();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            using (Pen p = new Pen(Theme.Line)) g.DrawRectangle(p, 0, 0, Width - 1, Height - 1);
            using (SolidBrush a = new SolidBrush(Theme.Accent)) g.FillRectangle(a, 0, 0, Px(3), Height);
            int y = Px(10);
            for (int i = 0; i < lines.Count; i++)
            {
                ULine u = lines[i];
                if (u.Text.Length > 0)
                    TextRenderer.DrawText(g, u.Text, u.Bold ? fBold : fBody, new Rectangle(Px(14), y, textW + Px(2), heights[i]), u.Color,
                        TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix | TextFormatFlags.TextBoxControl);
                y += heights[i] + Px(3);
            }
        }

        string LinkAt(Point p)
        {
            int y = Px(10);
            for (int i = 0; i < lines.Count; i++)
            {
                if (new Rectangle(Px(14), y, textW + Px(2), heights[i]).Contains(p)) return lines[i].Url;
                y += heights[i] + Px(3);
            }
            return null;
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            Cursor = LinkAt(e.Location) == null ? Cursors.Default : Cursors.Hand;
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            if (e.Button != MouseButtons.Left) return;
            string link = LinkAt(e.Location);
            Uri url;
            if (link == null || !Uri.TryCreate(link, UriKind.Absolute, out url)
                || url.Scheme != "https" || url.Host != "github.com") return;
            try { Process.Start(url.AbsoluteUri); }
            catch (Exception ex)
            {
                if (Host != null) Host.Log("opening GitHub run failed: " + ex.Message);
                MessageBox.Show("Could not open the GitHub run. Open log for details.",
                    "Zed Thread Colors", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing && fBody != null) { fBody.Dispose(); fBold.Dispose(); fBody = null; }
            base.Dispose(disposing);
        }
    }

    // ---------- GitHub Actions status for the open thread's repo ----------
    public class CiInfo
    {
        public string Repo, Workflow, Title, Status, Conclusion, Url, Branch;
        public DateTime Created = DateTime.MinValue, Updated = DateTime.MinValue;
        public int StepsDone, StepsTotal;
        public bool Running { get { return Status != "completed"; } }
        public int Percent { get { return StepsTotal > 0 ? (int)Math.Round(100.0 * StepsDone / StepsTotal) : 0; } }
        public string StatusText
        {
            get
            {
                if (Running)
                    return Status == "queued" || Status == "waiting" || Status == "pending" ? "Queued"
                        : "Running" + (StepsTotal > 0 ? " \u00B7 " + Percent + "% (" + StepsDone + " of " + StepsTotal + " steps)" : "");
                string c = Conclusion ?? "";
                return c == "success" ? "Passed" : c == "failure" ? "Failed" : c == "cancelled" ? "Cancelled"
                    : c == "skipped" ? "Skipped" : c == "timed_out" ? "Timed out"
                    : c.Length > 0 ? char.ToUpper(c[0]) + c.Substring(1).Replace('_', ' ') : "Finished";
            }
        }
        public Color StatusColor
        {
            get
            {
                return Running ? Theme.Working : Conclusion == "success" ? Color.FromArgb(0x87, 0xd9, 0x6c)
                    : Conclusion == "failure" || Conclusion == "timed_out" || Conclusion == "startup_failure"
                    ? Color.FromArgb(0xff, 0x66, 0x66) : Theme.Dim;
            }
        }
    }

    public class CiSnapshot
    {
        public CiInfo Run;
        public string Message;
    }

    // Asks GitHub (through the gh command-line tool, already signed in) for the newest Actions run in
    // the git repos of the open thread's project folders. Read-only; runs on its own background thread.
    public class CiWatcher
    {
        App host;
        Thread th;
        AutoResetEvent wake = new AutoResetEvent(false);
        volatile bool stop;
        volatile string folders;
        Dictionary<string, CiSnapshot> snapshots = new Dictionary<string, CiSnapshot>();
        Dictionary<string, List<string>> repoCache = new Dictionary<string, List<string>>();
        DateTime repoCacheTime = DateTime.MinValue;
        Dictionary<string, bool> logged = new Dictionary<string, bool>();
        System.Web.Script.Serialization.JavaScriptSerializer js = new System.Web.Script.Serialization.JavaScriptSerializer();

        public CiWatcher(App h) { host = h; }

        public void Start()
        {
            th = new Thread(Run);
            th.IsBackground = true;
            th.Priority = ThreadPriority.BelowNormal;
            th.Name = "ZedThreadColors CI";
            th.Start();
        }

        public void Stop() { stop = true; wake.Set(); }

        public void SetFolders(string f)
        {
            if (f == folders) return;
            folders = f;
            wake.Set();
        }

        public CiSnapshot SnapshotFor(string f)
        {
            if (string.IsNullOrEmpty(f)) return null;
            lock (snapshots)
            {
                CiSnapshot s;
                return snapshots.TryGetValue(f, out s) ? s : null;
            }
        }

        void Publish(string f, CiSnapshot s)
        {
            lock (snapshots) snapshots[f] = s;
        }

        void Run()
        {
            wake.WaitOne(3000);
            while (!stop)
            {
                string f = folders;
                if (!string.IsNullOrEmpty(f))
                {
                    try { Poll(f); }
                    catch (Exception ex)
                    {
                        LogOnce("CI check failed: " + ex.Message);
                        Publish(f, new CiSnapshot { Message = "GitHub status unavailable. Open log for details." });
                    }
                }
                CiSnapshot s = SnapshotFor(folders);
                CiInfo c = s == null ? null : s.Run;
                wake.WaitOne(c != null && c.Running ? 8000 : 45000); // faster while a run is going
            }
        }

        void LogOnce(string m)
        {
            if (logged.ContainsKey(m)) return;
            logged[m] = true;
            host.Log(m);
        }

        void Poll(string f)
        {
            List<string> repos = ReposFor(f);
            if (repos.Count == 0) { Publish(f, new CiSnapshot { Message = "No GitHub repository found for this thread." }); return; }

            CiInfo best = null;
            foreach (string repo in repos)
            {
                string json = Gh("run list -R " + repo + " --limit 1 --json databaseId,status,conclusion,workflowName,displayTitle,createdAt,updatedAt,headBranch,url");
                if (json == null) { Publish(f, new CiSnapshot { Message = "GitHub status unavailable. Open log for details." }); return; }
                object[] arr = Parse(json) as object[];
                if (arr == null) throw new InvalidDataException("Unexpected GitHub Actions run list");
                if (arr.Length == 0) continue;
                Dictionary<string, object> r = arr[0] as Dictionary<string, object>;
                if (r == null) throw new InvalidDataException("Unexpected GitHub Actions run");
                CiInfo c = new CiInfo();
                c.Repo = repo; c.Status = J.S(r, "status"); c.Conclusion = J.S(r, "conclusion"); c.Workflow = J.S(r, "workflowName");
                c.Title = J.S(r, "displayTitle"); c.Url = J.S(r, "url"); c.Branch = J.S(r, "headBranch");
                c.Created = When(J.S(r, "createdAt")); c.Updated = When(J.S(r, "updatedAt"));
                if (c.Running)
                {
                    // Progress = finished steps / all steps across the run's jobs.
                    string jobs = Gh("run view " + (long)J.Dbl(r, "databaseId") + " -R " + repo + " --json jobs");
                    if (jobs == null) { Publish(f, new CiSnapshot { Message = "GitHub progress unavailable. Open log for details." }); return; }
                    Dictionary<string, object> jd = jobs == null ? null : Parse(jobs) as Dictionary<string, object>;
                    object[] ja = jd == null ? null : J.A(jd, "jobs");
                    if (ja == null) throw new InvalidDataException("Unexpected GitHub Actions jobs");
                    if (ja != null)
                        foreach (object jo in ja)
                        {
                            Dictionary<string, object> job = jo as Dictionary<string, object>;
                            object[] steps = job == null ? null : J.A(job, "steps");
                            if (steps == null || steps.Length == 0) { c.StepsTotal++; if (job != null && J.S(job, "status") == "completed") c.StepsDone++; continue; }
                            foreach (object so in steps)
                            {
                                Dictionary<string, object> st = so as Dictionary<string, object>;
                                c.StepsTotal++;
                                if (st != null && J.S(st, "status") == "completed") c.StepsDone++;
                            }
                        }
                }
                if (best == null || c.Created > best.Created) best = c;
            }
            Publish(f, new CiSnapshot { Run = best, Message = best == null ? "No GitHub Actions runs found." : null });
        }

        object Parse(string s) { return js.DeserializeObject(s); }

        static DateTime When(string s)
        {
            DateTime v;
            if (s != null && DateTime.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out v)) return v.ToLocalTime();
            return DateTime.MinValue;
        }

        string Gh(string args)
        {
            ProcessStartInfo si = new ProcessStartInfo("gh", args);
            si.UseShellExecute = false;
            si.CreateNoWindow = true;
            si.RedirectStandardOutput = true;
            si.RedirectStandardError = true;
            si.StandardOutputEncoding = Encoding.UTF8;
            using (Process p = Process.Start(si))
            {
                System.Threading.Tasks.Task<string> outT = p.StandardOutput.ReadToEndAsync();
                System.Threading.Tasks.Task<string> errT = p.StandardError.ReadToEndAsync();
                if (!p.WaitForExit(20000)) { try { p.Kill(); } catch { } LogOnce("CI: gh took too long"); return null; }
                if (p.ExitCode != 0) { LogOnce("CI: gh " + args.Split(' ')[0] + " " + args.Split(' ')[1] + " failed: " + errT.Result.Trim()); return null; }
                return outT.Result;
            }
        }

        // GitHub repos (owner/name) in the thread's folders and the folders directly inside them.
        List<string> ReposFor(string f)
        {
            if ((DateTime.Now - repoCacheTime).TotalMinutes > 5) { repoCache.Clear(); repoCacheTime = DateTime.Now; }
            List<string> l;
            if (repoCache.TryGetValue(f, out l)) return l;
            l = new List<string>();
            foreach (string line in f.Split('\n'))
            {
                string dir = line.Trim();
                if (dir.Length == 0 || !Directory.Exists(dir)) continue;
                List<string> dirs = new List<string>();
                dirs.Add(dir);
                try { dirs.AddRange(Directory.GetDirectories(dir)); } catch { }
                foreach (string d in dirs)
                {
                    string r = GitHubRepo(d);
                    if (r != null && !l.Contains(r)) l.Add(r);
                }
            }
            repoCache[f] = l;
            if (l.Count > 0) host.Log("CI: watching " + string.Join(", ", l.ToArray()));
            return l;
        }

        static readonly Regex OriginRx = new Regex(@"\[remote ""origin""\][^\[]*?url\s*=\s*(\S+)", RegexOptions.Singleline);
        static readonly Regex GitHubRx = new Regex(@"github\.com[:/]([^/\s]+)/([^/\s]+?)(?:\.git)?/?$", RegexOptions.IgnoreCase);

        // Reads origin's URL straight from .git/config (also works for worktrees).
        static string GitHubRepo(string dir)
        {
            try
            {
                string git = Path.Combine(dir, ".git"), cfg = null;
                if (Directory.Exists(git)) cfg = Path.Combine(git, "config");
                else if (File.Exists(git))
                {
                    string line = File.ReadAllText(git).Trim();
                    if (!line.StartsWith("gitdir:")) return null;
                    string gd = line.Substring(7).Trim();
                    if (!Path.IsPathRooted(gd)) gd = Path.GetFullPath(Path.Combine(dir, gd));
                    string common = Path.Combine(gd, "commondir");
                    if (File.Exists(common))
                    {
                        string cd = File.ReadAllText(common).Trim();
                        gd = Path.IsPathRooted(cd) ? cd : Path.GetFullPath(Path.Combine(gd, cd));
                    }
                    cfg = Path.Combine(gd, "config");
                }
                if (cfg == null || !File.Exists(cfg)) return null;
                Match m = OriginRx.Match(File.ReadAllText(cfg));
                if (!m.Success) return null;
                Match g = GitHubRx.Match(m.Groups[1].Value.Trim());
                return g.Success ? g.Groups[1].Value + "/" + g.Groups[2].Value : null;
            }
            catch { return null; }
        }
    }

    // ---------- "What's needed from me": pulling the asks out of an agent's reply ----------
    public static class Asks
    {
        // Sentences that ask you for something: questions, requests, "your call" phrases.
        static readonly Regex Lead = new Regex(@"^(please|can you|could you|would you|let me know|tell me|confirm|approve|choose|pick|decide|send|run|click|open|try|reply|answer|go ahead|restart|review|test|check|look at|press|paste|sign in|log in)\b", RegexOptions.IgnoreCase);
        static readonly Regex Phrase = new Regex(@"\b(your (go|call|approval|answer|decision|review|ok|okay|say-so|input)|needs? your|need(s)? you to|waiting (on|for) you|from you|do you want|should i|would you like|want me to|shall i|is that ok|okay to|over to you|up to you|let me know)\b", RegexOptions.IgnoreCase);
        static readonly Regex ListItem = new Regex(@"^\s*(?:[-*?]|\d+[.)])\s+");
        static readonly Regex Sentence = new Regex(@"(?<=[.!?])\s+(?=[A-Z""'(*])");

        public static List<string> FromReply(string text)
        {
            List<string> found = new List<string>();
            if (string.IsNullOrEmpty(text)) return found;
            bool code = false, afterQuestion = false;
            int options = 0;
            foreach (string raw in text.Replace("\r", "").Split('\n'))
            {
                string line = raw.Trim();
                if (line.StartsWith("```")) { code = !code; continue; }
                if (code) continue;
                if (line.Length == 0) { afterQuestion = false; continue; }
                bool item = ListItem.IsMatch(line);
                string clean = Clean(line);
                if (clean.Length == 0) continue;
                if (afterQuestion && item && options < 6) { Add(found, "    " + clean); options++; continue; } // the options under a question
                afterQuestion = false;
                string[] parts = item ? new string[] { clean } : Sentence.Split(clean);
                foreach (string s in parts)
                {
                    string st = s.Trim();
                    if (st.Length < 4) continue;
                    bool q = st.EndsWith("?");
                    if (q || Lead.IsMatch(st) || Phrase.IsMatch(st))
                    {
                        Add(found, st);
                        if (q) { afterQuestion = true; options = 0; }
                    }
                }
                if (found.Count >= 10) break;
            }
            return found;
        }

        // The reply's last paragraph (usually the conclusion), for replies that ask nothing.
        public static string LastParagraph(string text)
        {
            if (string.IsNullOrEmpty(text)) return "";
            bool code = false;
            string last = "";
            StringBuilder para = new StringBuilder();
            foreach (string raw in text.Replace("\r", "").Split('\n'))
            {
                string line = raw.Trim();
                if (line.StartsWith("```")) { code = !code; continue; }
                if (code) continue;
                if (line.Length == 0) { if (para.Length > 0) { last = para.ToString(); para.Length = 0; } continue; }
                if (para.Length > 0) para.Append(' ');
                para.Append(Clean(line));
            }
            if (para.Length > 0) last = para.ToString();
            return last.Length > 300 ? last.Substring(0, 297) + "..." : last;
        }

        static string Clean(string s)
        {
            s = ListItem.Replace(s, "");
            s = s.Replace("**", "").Replace("__", "").Replace("`", "");
            s = Regex.Replace(s, @"\s+", " ").Trim();
            return s.Length > 240 ? s.Substring(0, 237) + "..." : s;
        }

        static void Add(List<string> l, string s) { if (!l.Contains(s)) l.Add(s); }
    }

    // A finished thread whose last reply asks you for something in its text.
    // (Questions asked through the agent's question box already show in Zed with buttons.)
    public class NeedItem
    {
        public ThreadDoc Doc;
        public DateTime When;
        public List<string> Asks;        // asks pulled from its last reply
        public string Summary = "";
        public string Key { get { return Doc.Info.Session + "|" + When.Ticks; } }
    }

    // ---------- The "Needs you" window ----------
    public class NeedsForm : Form
    {
        App host;
        float sc = 1f;
        FlowLayoutPanel list;
        Label empty;
        Font fTitle, fMeta, fBody;
        string signature = "";

        int Px(float v) { return (int)Math.Round(v * sc); }

        protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); Native.RoundCorners(Handle); }

        public NeedsForm(App h, float scale)
        {
            host = h;
            sc = Math.Max(1f, scale);
            Text = "Needs you - Zed Thread Colors";
            StartPosition = FormStartPosition.Manual;
            ShowInTaskbar = false;
            AutoScaleMode = AutoScaleMode.None;
            BackColor = Theme.Bg;
            ForeColor = Theme.Fg;
            MinimumSize = new Size(Px(380), Px(240));
            fTitle = new Font(Theme.UiFont, 14f * sc, FontStyle.Bold, GraphicsUnit.Pixel);
            fMeta = new Font(Theme.UiFont, 12f * sc, FontStyle.Regular, GraphicsUnit.Pixel);
            fBody = new Font(Theme.UiFont, 13.5f * sc, FontStyle.Regular, GraphicsUnit.Pixel);
            list = new FlowLayoutPanel();
            list.Dock = DockStyle.Fill;
            list.FlowDirection = FlowDirection.TopDown;
            list.WrapContents = false;
            list.AutoScroll = true;
            list.BackColor = Theme.Bg;
            list.Padding = new Padding(Px(10));
            empty = new Label();
            empty.Text = "Nothing needs you right now.";
            empty.Font = fBody; empty.ForeColor = Theme.Dim; empty.AutoSize = true; empty.Margin = new Padding(Px(4));
            Controls.Add(list);
            Resize += delegate { signature = ""; Rebuild(lastItems); };
        }

        List<NeedItem> lastItems = new List<NeedItem>();

        public void Open(List<NeedItem> items, Rectangle zed, IntPtr owner)
        {
            if (!Visible)
            {
                Rectangle area = zed.Width > 0 ? zed : Screen.PrimaryScreen.WorkingArea;
                int w = Math.Min(Px(560), (int)(area.Width * 0.5)), hgt = Math.Min(Px(640), (int)(area.Height * 0.8));
                Bounds = new Rectangle(area.Left + (area.Width - w) / 2, area.Top + Px(90), w, hgt);
            }
            if (owner != IntPtr.Zero) Native.SetOwner(Handle, owner);
            signature = "";
            Rebuild(items);
            Show();
            Activate();
        }

        public void Rebuild(List<NeedItem> items)
        {
            lastItems = items;
            StringBuilder sig = new StringBuilder();
            foreach (NeedItem n in items) sig.Append(n.Key).Append(';');
            if (sig.ToString() == signature) return;
            signature = sig.ToString();

            list.SuspendLayout();
            foreach (Control c in list.Controls) if (c != empty) c.Dispose();
            list.Controls.Clear();
            int w = Math.Max(Px(200), list.ClientSize.Width - list.Padding.Horizontal - SystemInformation.VerticalScrollBarWidth - Px(4));
            if (items.Count == 0) list.Controls.Add(empty);
            foreach (NeedItem n in items) list.Controls.Add(MakeItem(n, w));
            list.ResumeLayout();
        }

        Label L(string text, Font f, Color c, int w)
        {
            Label l = new Label();
            l.Text = text; l.Font = f; l.ForeColor = c; l.BackColor = Theme.Panel;
            l.AutoSize = true; l.MaximumSize = new Size(w, 0); l.UseMnemonic = false;
            l.Margin = new Padding(0, 0, 0, Px(4));
            return l;
        }

        LinkLabel Link(string text, EventHandler onClick)
        {
            LinkLabel l = new LinkLabel();
            l.Text = text; l.Font = fMeta; l.AutoSize = true;
            l.LinkColor = Theme.Working; l.ActiveLinkColor = Theme.Fg; l.BackColor = Theme.Panel;
            l.LinkBehavior = LinkBehavior.HoverUnderline;
            l.Margin = new Padding(0, 0, Px(14), 0);
            l.LinkClicked += delegate { onClick(l, EventArgs.Empty); };
            return l;
        }

        Control MakeItem(NeedItem n, int w)
        {
            Color mark = Theme.Accent;
            Panel card = new Panel();
            card.BackColor = Theme.Panel;
            card.Margin = new Padding(0, 0, 0, Px(10));
            card.Padding = new Padding(Px(14), Px(10), Px(10), Px(8));
            card.Width = w;
            Panel stripe = new Panel(); stripe.BackColor = mark; stripe.Dock = DockStyle.Left; stripe.Width = Px(4);

            FlowLayoutPanel inner = new FlowLayoutPanel();
            inner.FlowDirection = FlowDirection.TopDown; inner.WrapContents = false; inner.AutoSize = true;
            inner.BackColor = Theme.Panel; inner.Location = new Point(Px(16), Px(8));
            int tw = w - Px(30);

            inner.Controls.Add(L(n.Doc.Info.Display, fTitle, Theme.Fg, tw));
            string what = "finished " + Theme.Ago(DateTime.Now - n.When) + " ago";
            inner.Controls.Add(L(n.Doc.Info.AgentName + "  ?  " + (n.Doc.Project.Length > 0 ? n.Doc.Project : "(no project)") + "  ?  " + what, fMeta, mark, tw));

            StringBuilder sb = new StringBuilder();
            foreach (string a in n.Asks) sb.Append(a.StartsWith("    ") ? "      " + a.Trim() : "?  " + a).Append('\n');
            string body = sb.ToString().TrimEnd();
            inner.Controls.Add(L(body, fBody, Theme.Fg, tw));
            if (n.Summary.Length > 0) inner.Controls.Add(L("Last turn: " + n.Summary, fMeta, Theme.Dim, tw));

            FlowLayoutPanel links = new FlowLayoutPanel();
            links.FlowDirection = FlowDirection.LeftToRight; links.AutoSize = true; links.BackColor = Theme.Panel;
            links.Margin = new Padding(0, Px(2), 0, 0);
            string session = n.Doc.Info.Session;
            string copyText = n.Doc.Info.Display + "\n" + body;
            links.Controls.Add(Link("Peek", delegate { host.Peek(session); }));
            links.Controls.Add(Link("Flash in sidebar", delegate { host.FlashSession(session); host.RefocusZed(); }));
            links.Controls.Add(Link("Mark as seen", delegate { host.MarkSeenPublic(session); }));
            links.Controls.Add(Link("Copy", delegate { try { Clipboard.SetText(copyText); } catch { } }));
            inner.Controls.Add(links);

            card.Controls.Add(inner);
            card.Controls.Add(stripe);
            card.Height = inner.PreferredSize.Height + Px(18);
            return card;
        }

        protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
        {
            if (keyData == Keys.Escape) { Hide(); return true; }
            return base.ProcessCmdKey(ref msg, keyData);
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); return; }
            base.OnFormClosing(e);
        }
    }

    // ---------- The Peek window: one thread's latest reply, live, beside your work ----------
    public class PeekForm : Form
    {
        App host;
        float sc = 1f;
        public string Session;
        Label title, status, asks, promptLbl;
        TextBox reply;
        string lastReply = null;
        bool placed = false;

        int Px(float v) { return (int)Math.Round(v * sc); }

        protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); Native.RoundCorners(Handle); }

        public PeekForm(App h, float scale)
        {
            host = h;
            sc = Math.Max(1f, scale);
            Text = "Peek - Zed Thread Colors";
            StartPosition = FormStartPosition.Manual;
            ShowInTaskbar = false;
            AutoScaleMode = AutoScaleMode.None;
            BackColor = Theme.Bg;
            ForeColor = Theme.Fg;
            MinimumSize = new Size(Px(360), Px(260));
            Padding = new Padding(Px(12));

            title = Lbl(new Font(Theme.UiFont, 15f * sc, FontStyle.Bold, GraphicsUnit.Pixel), Theme.Fg);
            status = Lbl(new Font(Theme.UiFont, 12.5f * sc, FontStyle.Regular, GraphicsUnit.Pixel), Theme.Dim);
            asks = Lbl(new Font(Theme.UiFont, 13f * sc, FontStyle.Regular, GraphicsUnit.Pixel), Theme.Accent);
            promptLbl = Lbl(new Font(Theme.UiFont, 12f * sc, FontStyle.Regular, GraphicsUnit.Pixel), Theme.Dim);
            reply = new TextBox();
            reply.Multiline = true; reply.ReadOnly = true; reply.WordWrap = true; reply.ScrollBars = ScrollBars.Vertical;
            reply.BorderStyle = BorderStyle.None; reply.BackColor = Theme.Panel; reply.ForeColor = Theme.Fg;
            reply.Font = new Font(Theme.UiFont, 13.5f * sc, FontStyle.Regular, GraphicsUnit.Pixel);
            reply.Dock = DockStyle.Fill;
            promptLbl.Dock = DockStyle.Bottom;
            // Docking order: the last added docks first.
            Controls.Add(reply);
            Controls.Add(asks);
            Controls.Add(status);
            Controls.Add(title);
            Controls.Add(promptLbl);
            title.Dock = DockStyle.Top; status.Dock = DockStyle.Top; asks.Dock = DockStyle.Top;
            Resize += delegate { FitLabels(); };
        }

        Label Lbl(Font f, Color c)
        {
            Label l = new Label();
            l.Font = f; l.ForeColor = c; l.BackColor = Theme.Bg; l.AutoSize = false; l.UseMnemonic = false;
            l.Padding = new Padding(0, 0, 0, Px(6));
            return l;
        }

        void FitLabels()
        {
            int w = ClientSize.Width - Padding.Horizontal;
            foreach (Label l in new Label[] { title, status, asks, promptLbl })
            {
                if (l.Text.Length == 0) { l.Height = 0; continue; }
                Size s = TextRenderer.MeasureText(l.Text, l.Font, new Size(w, int.MaxValue), TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix);
                l.Height = s.Height + l.Padding.Vertical + Px(2);
            }
        }

        public void Open(string session, Rectangle zed, IntPtr owner)
        {
            if (Session != session) { Session = session; lastReply = null; }
            if (!placed)
            {
                placed = true;
                Rectangle area = zed.Width > 0 ? zed : Screen.PrimaryScreen.WorkingArea;
                int w = Math.Min(Px(520), (int)(area.Width * 0.4)), hgt = Math.Min(Px(620), (int)(area.Height * 0.8));
                Bounds = new Rectangle(area.Right - w - Px(30), area.Top + Px(110), w, hgt);
            }
            if (owner != IntPtr.Zero) Native.SetOwner(Handle, owner);
            UpdateContent();
            Show();
            Activate();
        }

        // Called whenever new data arrives; leaves your scroll position alone unless the reply changed.
        public void UpdateContent()
        {
            if (Session == null) return;
            ThreadDoc doc;
            ThreadUsage tu;
            Msg lastAgent, lastYou;
            host.PeekData(Session, out doc, out tu, out lastAgent, out lastYou);
            title.Text = doc != null ? doc.Info.Display + "   ?   " + doc.Info.AgentName : "(thread not found)";
            Color c;
            string st = App.StatusTextPublic(tu, out c);
            string sum = tu != null && !string.IsNullOrEmpty(tu.Summary) ? (tu.Working ? "This turn: " : "Last turn: ") + tu.Summary : "";
            status.Text = (st ?? "") + (st != null && tu != null && tu.Working && !tu.WaitingForHelpers && !string.IsNullOrEmpty(tu.Step) ? "  ?  " + tu.Step : "") + (sum.Length > 0 ? "\n" + sum : "");
            status.ForeColor = c;
            asks.Text = tu != null && !string.IsNullOrEmpty(tu.AskText) ? "Asking you:\n" + tu.AskText : "";
            promptLbl.Text = lastYou != null ? "Your last prompt: " + Flat(lastYou.Text, 260) : "";
            string r = lastAgent != null ? lastAgent.Text.Replace("\r\n", "\n").Replace("\n", "\r\n") : "(no reply yet)";
            if (r != lastReply)
            {
                lastReply = r;
                reply.Text = r;
                reply.SelectionStart = reply.TextLength; // newest text in view
                reply.ScrollToCaret();
            }
            FitLabels();
        }

        static string Flat(string s, int max)
        {
            s = Regex.Replace(s ?? "", @"\s+", " ").Trim();
            return s.Length > max ? s.Substring(0, max - 3) + "..." : s;
        }

        protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
        {
            if (keyData == Keys.Escape) { Hide(); return true; }
            return base.ProcessCmdKey(ref msg, keyData);
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); return; }
            base.OnFormClosing(e);
        }
    }

    // Receives the Ctrl+Alt+Shift+F hotkey (one registered key combination; no keyboard monitoring).
    public class HotkeyWindow : NativeWindow
    {
        public MethodInvoker Pressed, Pressed2;
        public int SecondId = -1;

        public HotkeyWindow()
        {
            CreateParams cp = new CreateParams();
            cp.Parent = new IntPtr(-3); // HWND_MESSAGE: an invisible message-only window
            CreateHandle(cp);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x0312) // WM_HOTKEY
            {
                if (m.WParam.ToInt32() == SecondId) { if (Pressed2 != null) Pressed2(); }
                else if (Pressed != null) Pressed();
            }
            base.WndProc(ref m);
        }
    }

    public class App : ApplicationContext
    {
        // Bar colors: Ayu Mirage's accent colors (Zed's collaborator colors) plus a gray.
        // Indexes are what colors.tsv saves, so existing ones never change; add new ones at the end.
        public static Color[] Palette = new Color[] {
            Color.Empty,
            Theme.Error,                          // 1 red    - Ayu coral
            Theme.Done,                           // 2 green  - Ayu "added" green
            Theme.Accent,                         // 3 yellow - Ayu amber
            Color.FromArgb(0x72, 0xcf, 0xfe),     // 4 blue
            Color.FromArgb(0x5b, 0xcd, 0xe5),     // 5 cyan
            Color.FromArgb(0xfe, 0xad, 0x66),     // 6 orange
            Color.FromArgb(0xde, 0xbf, 0xfe),     // 7 purple
            Color.FromArgb(0x95, 0xe5, 0xcb),     // 8 mint
            Color.FromArgb(0x9a, 0x9a, 0x98)      // 9 gray
        };
        public static readonly string[] ColorNames = new string[] { "None", "Red", "Green", "Yellow", "Blue", "Cyan", "Orange", "Purple", "Mint", "Gray" };
        // The order the picker shows them in.
        public static readonly int[] PickerOrder = new int[] { 2, 3, 1, 6, 4, 5, 8, 7, 9, 0 };
        const double OcrScale = 2.0;
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string RunName = "ZedThreadColors";
        static Mutex single;

        NotifyIcon tray;
        BoxForm form;
        RingForm rings;
        MenuItem pauseItem, startupItem;
        Dictionary<string, int> colors = new Dictionary<string, int>();
        Dictionary<string, string> aliases = new Dictionary<string, string>();
        List<Word> words = new List<Word>();
        string dir, dataPath, logPath, scriptPath, lastRowsSig = "";
        bool paused = false;
        IntPtr zedMain = IntPtr.Zero;
        IntPtr ownerSet = IntPtr.Zero;
        Rectangle lastClient = Rectangle.Empty;
        uint myPid;
        long lastHash = 0;
        float scale = 1f;
        Rectangle sidebar = Rectangle.Empty;
        int[] lastPx; int lastCapW, lastCh;

        // Selected thread and background history.
        List<ThreadInfo> threads = new List<ThreadInfo>();
        string activeRowKey = null;
        ThreadInfo active = null;
        public byte[] PngBytes;
        public int OcrRevision;

        // v3.0: thread search + usage meter
        Indexer indexer;
        SearchForm search;
        UsageForm usageForm;
        HotkeyWindow hotkey;
        Control ui;                      // lets the background indexer hand results to this thread
        public volatile string ActiveSession;
        const int HotkeyId = 0x5A43;
        const int HotkeyId2 = 0x5A44;
        static readonly object logLock = new object();
        Dictionary<string, string> logWarnings = new Dictionary<string, string>();

        // Status dots, hover card, working timer
        Dictionary<string, DateTime> seen = new Dictionary<string, DateTime>(); // session -> when you last had it open
        string seenPath;
        bool seenDirty = false;
        DateTime nextSeenSave = DateTime.MinValue;
        HoverCard card;
        ColorPicker picker;
        CiWatcher ci;
        System.Windows.Forms.Timer hoverTimer;
        string hoverKey = null;
        DateTime hoverSince = DateTime.MinValue;

        public static bool AcquireSingle()
        {
            bool created;
            single = new Mutex(true, "Local\\ZedThreadColorsSingle", out created);
            return created;
        }

        public App(string script)
        {
            scriptPath = script;
            myPid = (uint)Process.GetCurrentProcess().Id;
            dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ZedThreadColors");
            Directory.CreateDirectory(dir);
            dataPath = Path.Combine(dir, "colors.tsv");
            logPath = Path.Combine(dir, "log.txt");
            Transcripts.Report = delegate (string message) { LogOnce(message, message); };
            Load();

            form = new BoxForm();
            form.Host = this;
            rings = new RingForm();
            ui = new Control();
            IntPtr uiHandle = ui.Handle;

            ContextMenu menu = new ContextMenu();
            menu.MenuItems.Add("Search threads...\tCtrl+Alt+Shift+F", delegate { OpenSearch(); });
            menu.MenuItems.Add("Needs you...\tCtrl+Alt+Shift+N", delegate { OpenNeeds(); });
            menu.MenuItems.Add("Usage summary...", delegate { ShowUsage(); });
            menu.MenuItems.Add("-");
            pauseItem = new MenuItem("Hide boxes", delegate { paused = !paused; pauseItem.Checked = paused; if (paused) HideForm(); });
            menu.MenuItems.Add(pauseItem);
            startupItem = new MenuItem("Start with Windows", delegate { ToggleStartup(); });
            menu.MenuItems.Add(startupItem);
            menu.MenuItems.Add("Clear all colors...", delegate { ClearAll(); });
            menu.MenuItems.Add("Open log", delegate { try { Process.Start("notepad.exe", "\"" + logPath + "\""); } catch { } });
            menu.MenuItems.Add("-");
            menu.MenuItems.Add("Quit", delegate { Quit(); });
            startupItem.Checked = IsStartup();

            tray = new NotifyIcon();
            tray.Icon = MakeIcon();
            tray.Text = "Zed Thread Colors";
            tray.ContextMenu = menu;
            tray.Visible = true;
            tray.ShowBalloonTip(4000, "Zed Thread Colors is running",
                "Hover a thread for your last prompt, activity, usage, and GitHub status. Right-click this icon for more options.",
                ToolTipIcon.Info);
            Log("started. script=" + scriptPath);

            hotkey = new HotkeyWindow();
            hotkey.Pressed = delegate { OpenSearch(); };
            hotkey.SecondId = HotkeyId2;
            hotkey.Pressed2 = delegate { OpenNeeds(); };
            // MOD_ALT | MOD_CONTROL | MOD_SHIFT | MOD_NOREPEAT, key F
            if (!Native.RegisterHotKey(hotkey.Handle, HotkeyId, 0x1 | 0x2 | 0x4 | 0x4000, 0x46))
                Log("could not register Ctrl+Alt+Shift+F (another app may already use it); use the tray menu instead");
            if (!Native.RegisterHotKey(hotkey.Handle, HotkeyId2, 0x1 | 0x2 | 0x4 | 0x4000, 0x4E)) // key N
                Log("could not register Ctrl+Alt+Shift+N (another app may already use it); use the tray menu instead");
            tray.BalloonTipClicked += delegate { BalloonClicked(); };

            seenPath = Path.Combine(dir, "seen.tsv");
            LoadSeen();
            card = new HoverCard();
            card.Host = this;
            hoverTimer = new System.Windows.Forms.Timer();
            hoverTimer.Interval = 150;
            hoverTimer.Tick += delegate { HoverTick(); };
            hoverTimer.Start();

            indexer = new Indexer(this);
            indexer.Start();

            ci = new CiWatcher(this);
            ci.Start();
        }

        static Icon MakeIcon()
        {
            Bitmap b = new Bitmap(16, 16);
            using (Graphics g = Graphics.FromImage(b))
            {
                g.Clear(Color.Transparent);
                using (SolidBrush r = new SolidBrush(Palette[1])) g.FillRectangle(r, 1, 1, 6, 6);
                using (SolidBrush y = new SolidBrush(Palette[2])) g.FillRectangle(y, 9, 1, 6, 6);
                using (SolidBrush gr = new SolidBrush(Palette[3])) g.FillRectangle(gr, 1, 9, 6, 6);
            }
            return Icon.FromHandle(b.GetHicon());
        }

        // ---------- Called by the PowerShell timer ----------

        // Returns true when the sidebar changed and PngBytes is ready for OCR.
        public bool Prepare()
        {
            if (paused) { HideForm(); return false; }
            RepaintIfNeeded();

            IntPtr fg = Native.GetForegroundWindow();
            uint fgPid;
            Native.GetWindowThreadProcessId(fg, out fgPid);
            bool zedActive = false;
            if (fgPid == myPid)
            {
                // You just clicked one of our color bars. Our other windows (search, usage,
                // menus) may cover the sidebar, so treat those like any other app in front of Zed.
                zedActive = form.IsHandleCreated && fg == form.Handle;
            }
            else if (IsZedPid(fgPid))
            {
                zedActive = true;
                IntPtr root = Native.GetAncestor(fg, 2); // GA_ROOT
                Native.RECT rr;
                Native.GetClientRect(root, out rr);
                if (rr.R >= 500 && rr.B >= 300) zedMain = root; // ignore small Zed popups/menus
            }
            lastZedActive = zedActive; // notifications skip the thread you're looking at
            if (zedMain == IntPtr.Zero || !Native.IsWindow(zedMain) || !Native.IsWindowVisible(zedMain) || Native.IsIconic(zedMain))
            {
                HideForm(); return false;
            }
            EnsureOwner();

            scale = Native.ScaleFor(zedMain);
            Native.RECT cr;
            Native.GetClientRect(zedMain, out cr);
            Native.POINT p = new Native.POINT();
            Native.ClientToScreen(zedMain, ref p);
            int cw = cr.R, ch = cr.B;
            if (cw < 500 || ch < 300) { HideForm(); return false; }
            Rectangle client = new Rectangle(p.X, p.Y, cw, ch);

            // When Zed isn't the active window it may be partly covered, so the screen can't be read
            // reliably. Keep showing the last boxes as long as the Zed window hasn't moved or resized.
            if (!zedActive)
            {
                if (client == lastClient) ShowForm(); else HideForm();
                return false;
            }
            if (client != lastClient) { lastClient = client; lastHash = 0; }
            if (active != null) MarkSeen(active.Session); // you're looking at this thread in Zed now
            KeepInFront();

            int capW = (int)(cw * 0.6);
            int[] px;
            using (Bitmap bmp = new Bitmap(capW, ch, PixelFormat.Format32bppArgb))
            {
                using (Graphics g = Graphics.FromImage(bmp)) g.CopyFromScreen(p.X, p.Y, 0, 0, bmp.Size);
                px = GetPixels(bmp);
            }
            ScrubRings(px, capW, ch, p.X, p.Y);

            int edge = FindEdge(px, capW, ch);
            if (edge < 0)
            {
                LogOnce("sidebar-edge", "could not locate Zed's left threads sidebar; make sure it is open");
                HideForm(); lastHash = 0; lastClient = Rectangle.Empty; return false;
            }

            sidebar = new Rectangle(p.X, p.Y, edge, ch);
            lastPx = px; lastCapW = capW; lastCh = ch;
            PositionForm();

            long hash = 17;
            for (int y = 0; y < ch; y += 3)
                for (int x = 0; x < edge; x += 3)
                    hash = unchecked(hash * 31 + px[y * capW + x]);
            hash = unchecked(hash * 31 + edge * 7919 + p.X * 131 + p.Y * 17 + ch);

            if (hash == lastHash) { ShowForm(); return false; }
            lastHash = hash;
            PngBytes = MakeOcrImage(px, capW, ch, edge);
            OcrRevision++;
            return true;
        }

        public bool CanApplyOcr(int revision)
        {
            if (revision != OcrRevision || paused || lastClient.IsEmpty || !Native.IsWindow(zedMain)
                || !Native.IsWindowVisible(zedMain) || Native.IsIconic(zedMain)) return false;
            IntPtr fg = Native.GetForegroundWindow();
            bool overlay = form.IsHandleCreated && fg == form.Handle;
            if (!overlay && Native.GetAncestor(fg, 2) != zedMain) return false;
            Native.RECT cr;
            Native.POINT p = new Native.POINT();
            if (!Native.GetClientRect(zedMain, out cr) || !Native.ClientToScreen(zedMain, ref p)) return false;
            return lastClient == new Rectangle(p.X, p.Y, cr.R, cr.B);
        }

        public void RetryOcr() { lastHash = 0; }

        public void BeginOcr() { words.Clear(); }

        public void AddWord(int line, string text, double x, double y, double w, double h)
        {
            Word wd = new Word();
            wd.Line = line; wd.Text = text ?? "";
            wd.X = sidebar.X + x / OcrScale; wd.Y = sidebar.Y + y / OcrScale;
            wd.W = w / OcrScale; wd.H = h / OcrScale;
            words.Add(wd);
        }

        public void EndOcr()
        {
            // Group words into lines.
            SortedDictionary<int, List<Word>> byLine = new SortedDictionary<int, List<Word>>();
            foreach (Word w in words)
            {
                if (!byLine.ContainsKey(w.Line)) byLine[w.Line] = new List<Word>();
                byLine[w.Line].Add(w);
            }

            List<OLine> lines = new List<OLine>();
            foreach (List<Word> ws in byLine.Values)
            {
                ws.Sort(delegate (Word a, Word b) { return a.X.CompareTo(b.X); });
                // Drop a leading icon glyph that OCR read as a stray character (e.g. the agent logo).
                if (ws.Count >= 2 && (ws[0].Text.Length == 1 || (ws[0].Text.Length <= 2 && !IsWordy(ws[0].Text)))) ws.RemoveAt(0);
                OLine l = new OLine();
                StringBuilder sb = new StringBuilder();
                l.Left = double.MaxValue; l.Top = double.MaxValue; l.Bottom = double.MinValue;
                foreach (Word w in ws)
                {
                    if (sb.Length > 0) sb.Append(' ');
                    sb.Append(w.Text);
                    l.Left = Math.Min(l.Left, w.X);
                    l.Top = Math.Min(l.Top, w.Y);
                    l.Bottom = Math.Max(l.Bottom, w.Y + w.H);
                }
                l.Text = sb.ToString().Trim();
                if (l.Text.Length > 0) lines.Add(l);
            }
            lines.Sort(delegate (OLine a, OLine b) { return a.Top.CompareTo(b.Top); });

            List<OLine> content = new List<OLine>();
            foreach (OLine l in lines)
            {
                string lt = l.Text.ToLowerInvariant();
                if (lt.Contains("search thread")) continue;
                if (lt.Contains("no threads yet")) continue;
                l.IsSub = IsSubtitle(l.Text);
                content.Add(l);
            }

            double headerLeft = double.MaxValue;
            foreach (OLine l in content) if (!l.IsSub) headerLeft = Math.Min(headerLeft, l.Left);

            List<Row> rows = new List<Row>();
            string project = "";
            for (int i = 0; i < content.Count; i++)
            {
                OLine l = content[i];
                if (l.IsSub) continue;
                bool subBelow = i + 1 < content.Count && content[i + 1].IsSub
                                && content[i + 1].Top - l.Bottom < Math.Max(l.Height, 8) * 1.6;
                bool indented = l.Left > headerLeft + 10 * scale;
                if (indented || subBelow)
                {
                    string title = Norm(l.Text);
                    if (title.Length < 3) continue; // stray icon or button read as text
                    double bottom = subBelow ? content[i + 1].Bottom : l.Bottom;
                    Row r = new Row();
                    r.Key = Norm(project) + "|" + title;
                    r.CenterY = (int)Math.Round((l.Top + bottom) / 2.0);
                    // The thread's whole row in the sidebar: its text plus Zed's padding, but never
                    // past halfway to the line above or below.
                    double pad = 9 * scale;
                    double prevBottom = i > 0 ? content[i - 1].Bottom : sidebar.Top;
                    int ni = subBelow ? i + 2 : i + 1;
                    double nextTop = ni < content.Count ? content[ni].Top : sidebar.Bottom;
                    r.RowTop = (int)Math.Round(Math.Max(l.Top - pad, (prevBottom + l.Top) / 2));
                    r.RowBottom = (int)Math.Round(Math.Min(bottom + pad, (bottom + nextTop) / 2));
                    r.Project = project;
                    r.Title = l.Text;
                    rows.Add(r);
                }
                else
                {
                    project = l.Text;
                }
            }

            // If OCR read only part of a title (e.g. "Build" for "Visio Build"), use the full
            // title from Zed's list so the box keeps its color and the open thread stays put.
            LoadThreads();
            foreach (Row r in rows)
            {
                ThreadInfo t = MatchThread(r.Project, r.Title);
                if (t == null) continue;
                string dn = Norm(t.Display), tn = Norm(r.Title);
                if (dn.Length > tn.Length && dn.Contains(tn))
                {
                    r.Title = t.Display;
                    r.Key = Norm(r.Project) + "|" + dn;
                }
            }

            string sig = "";
            foreach (Row r in rows) sig += r.Key + ";";
            if (sig != lastRowsSig) { Log("threads seen: " + (sig.Length > 0 ? sig : "(none)")); lastRowsSig = sig; }

            form.Rows = rows;
            rings.Rows = rows;
            PlaceSearchBox(rows);
            UpdateDots();
            if (rows.Count == 0) { HideForm(); return; }
            form.Invalidate();
            rings.Invalidate();
            ShowForm();
            DetectActive(rows);
        }

        // ---------- Selected thread ----------

        // The open thread is the highlighted row in the sidebar.
        void DetectActive(List<Row> rows)
        {
            if (lastPx == null) return;
            int sx = sidebar.Width - Math.Max(6, (int)(12 * scale));
            if (sx <= 0 || sx >= lastCapW) return;
            int[] hist = new int[256];
            for (int y = 0; y < lastCh; y += 2) hist[Lum(lastPx[y * lastCapW + sx])]++;
            int bg = 0;
            for (int i = 1; i < 256; i++) if (hist[i] > hist[bg]) bg = i;

            List<int> hi = new List<int>();
            List<int> diffs = new List<int>();
            for (int i = 0; i < rows.Count; i++)
            {
                int y = rows[i].CenterY - sidebar.Top;
                if (y < 0 || y >= lastCh) continue;
                int d = Math.Abs(Lum(lastPx[y * lastCapW + sx]) - bg);
                if (d >= 6) { hi.Add(i); diffs.Add(d); }
            }
            int pick = -1;
            if (hi.Count == 1) pick = hi[0];
            else if (hi.Count > 1)
            {
                // A second highlight is usually the row under the mouse; ignore that one.
                Point c = Cursor.Position;
                List<int> rest = new List<int>();
                foreach (int i in hi)
                {
                    bool underMouse = sidebar.Contains(c) && Math.Abs(rows[i].CenterY - c.Y) < 22 * scale;
                    if (!underMouse) rest.Add(i);
                }
                if (rest.Count == 1) pick = rest[0];
                else foreach (int i in hi) if (rows[i].Key == activeRowKey) pick = i;
            }
            if (pick < 0) return; // keep what we had
            Row r = rows[pick];
            if (r.Key == activeRowKey && active != null) return;
            activeRowKey = r.Key;
            ThreadInfo t = FindThread(r.Project, r.Title);
            if (t == null) LogOnce("unmatched:" + r.Key, "open thread '" + r.Title + "' (" + r.Project + ") not found in Zed's thread list");
            else Log("open thread: '" + t.Display + "' agent=" + t.Agent + " session=" + t.Session);
            SetActive(t);
        }

        void SetActive(ThreadInfo t)
        {
            bool same = active != null && t != null && active.Session == t.Session;
            active = t;
            ActiveSession = t == null ? null : t.Session;
            if (ci != null) ci.SetFolders(t == null ? null : t.Folders);
            if (!same)
            {
                if (indexer != null) indexer.Wake();
            }
        }

        void LoadThreads()
        {
            IndexSnapshot s = IndexSnap;
            if (s == null) return;
            List<ThreadInfo> list = new List<ThreadInfo>();
            foreach (ThreadDoc d in s.Docs) if (!d.Archived) list.Add(d.Info);
            threads = list;
        }

        public static string ZedDbPath()
        {
            string root = Path.Combine(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Zed"), "db");
            if (!Directory.Exists(root)) return null;
            string best = null; DateTime bestT = DateTime.MinValue;
            foreach (string d in Directory.GetDirectories(root))
            {
                string f = Path.Combine(d, "db.sqlite");
                if (!File.Exists(f)) continue;
                DateTime t = File.GetLastWriteTimeUtc(f);
                string wal = f + "-wal";
                if (File.Exists(wal) && File.GetLastWriteTimeUtc(wal) > t) t = File.GetLastWriteTimeUtc(wal);
                if (t > bestT) { bestT = t; best = f; }
            }
            return best;
        }

        ThreadInfo FindThread(string project, string title)
        {
            LoadThreads();
            return MatchThread(project, title);
        }

        // Matches a sidebar row to Zed's thread list (already loaded).
        ThreadInfo MatchThread(string project, string title)
        {
            string tn = Norm(title), pn = Norm(project ?? "");
            if (tn.Length == 0) return null;
            ThreadInfo best = null; int bestScore = -1; string bestUpd = "";
            foreach (ThreadInfo t in threads)
            {
                string dn = Norm(t.Display);
                if (dn.Length == 0) continue;
                bool titleOk = dn == tn || Lev(dn, tn) <= Math.Max(1, tn.Length / 8)
                               || (tn.Length >= 8 && dn.StartsWith(tn.Substring(0, tn.Length - 1)));
                if (!titleOk) continue;
                int score = dn == tn ? 2 : 1;
                if (pn.Length > 0 && InProject(t, pn)) score += 2;
                if (score > bestScore || (score == bestScore && string.CompareOrdinal(t.Updated, bestUpd) > 0))
                {
                    best = t; bestScore = score; bestUpd = t.Updated;
                }
            }
            if (best != null) return best;

            // OCR sometimes drops a word next to a moving icon (e.g. "Visio Build" read as "Build").
            // Accept a partial title only if exactly one thread in that project contains it.
            if (tn.Length < 4 || pn.Length == 0) return null;
            ThreadInfo only = null;
            foreach (ThreadInfo t in threads)
            {
                string dn = Norm(t.Display);
                if (dn.Length <= tn.Length || !dn.Contains(tn) || !InProject(t, pn)) continue;
                if (only != null && only.Session != t.Session) return null; // ambiguous
                only = t;
            }
            return only;
        }

        static bool InProject(ThreadInfo t, string pn)
        {
            foreach (string f in t.Folders.Split('\n'))
            {
                string seg = Norm(Path.GetFileName(f.Trim().TrimEnd('\\', '/')) ?? "");
                if (seg.Length > 0 && (seg == pn || Lev(seg, pn) <= 1 + pn.Length / 6)) return true;
            }
            return false;
        }

        // ---------- Thread search + usage meter (v3.0) ----------

        public IndexSnapshot IndexSnap { get { return indexer == null ? null : indexer.Index; } }

        // Runs 'm' on this (UI) thread; called from the background indexer.
        public void Post(MethodInvoker m)
        {
            try { if (ui != null && ui.IsHandleCreated) ui.BeginInvoke(m); } catch { }
        }

        public void OnIndex()
        {
            LoadThreads();
            if (form.Rows.Count > 0) DetectActive(form.Rows);
            if (search != null && !search.IsDisposed) search.OnIndexUpdated();
            if (peek != null && !peek.IsDisposed && peek.Visible) peek.UpdateContent();
        }

        public void OnUsage()
        {
            UpdateDots();
            UpdateNeeds();
            if (usageForm != null && !usageForm.IsDisposed && usageForm.Visible) usageForm.SetLines(UsageLines());
        }

        float WindowScale() { return zedMain != IntPtr.Zero ? scale : Native.ScaleFor(IntPtr.Zero); }
        IntPtr OwnerForPopups() { return zedMain != IntPtr.Zero && Native.IsWindow(zedMain) ? zedMain : IntPtr.Zero; }

        public void OpenSearch()
        {
            try
            {
                if (search == null || search.IsDisposed) search = new SearchForm(this, WindowScale());
                search.Open(lastClient, OwnerForPopups());
            }
            catch (Exception ex) { Log("search window error: " + ex.Message); }
        }

        public void ShowUsage()
        {
            try
            {
                if (usageForm == null || usageForm.IsDisposed) usageForm = new UsageForm(WindowScale());
                usageForm.SetLines(UsageLines());
                usageForm.Open(lastClient, OwnerForPopups());
                if (indexer != null) indexer.Wake();
            }
            catch (Exception ex) { Log("usage window error: " + ex.Message); }
        }

        // Flashes the color box of the thread with this session id, if its row is on screen.
        public bool FlashSession(string session)
        {
            if (session == null || !form.Visible) return false;
            foreach (Row r in form.Rows)
            {
                ThreadInfo t = MatchThread(r.Project, r.Title);
                if (t != null && t.Session == session) { form.Flash(r.Key); return true; }
            }
            return false;
        }

        // The magnifier box sits at the top of the strip,
        // nudged up if a thread's box is already there.
        void PlaceSearchBox(List<Row> rows)
        {
            int cy = lastClient.Top + (int)(81 * scale);
            int half = form.ButtonSize / 2 + (int)(3 * scale);
            foreach (Row r in rows)
                if (cy + half > r.RowTop && cy - half < r.RowBottom) cy = r.RowTop - half; // would overlap a thread's bar
            if (cy - form.ButtonSize / 2 < sidebar.Top) cy = -1;

            // The Needs-you button goes just below the magnifier, or just above it if a thread's bar is there.
            int ny = -1;
            if (cy >= 0)
            {
                int step = form.ButtonSize + (int)(6 * scale);
                ny = cy + step;
                foreach (Row r in rows) if (ny + half > r.RowTop && ny - half < r.RowBottom) { ny = cy - step; break; }
                if (ny - form.ButtonSize / 2 < sidebar.Top) ny = -1;
            }
            if (cy != form.SearchCenterY || ny != form.NeedsCenterY) { form.SearchCenterY = cy; form.NeedsCenterY = ny; form.Invalidate(); }
        }

        static List<RateWin> CodexWindows(UsageSnapshot u)
        {
            List<RateWin> l = new List<RateWin>();
            if (u.CodexPrimary != null) l.Add(u.CodexPrimary);
            if (u.CodexSecondary != null) l.Add(u.CodexSecondary);
            l.Sort(delegate (RateWin a, RateWin b) { return a.Minutes.CompareTo(b.Minutes); });
            return l;
        }

        static string Pct(double p) { return Math.Round(p).ToString(CultureInfo.InvariantCulture) + "%"; }

        static ULine CodexLimitLine(RateWin w)
        {
            string s = "  " + RateWin.Label(w.Minutes, true) + " limit: " + Pct(w.Effective) + " used";
            if (w.HasReset) s += "  (the window has reset since Codex last reported)";
            else if (w.Resets != DateTime.MinValue) s += ", resets " + w.Resets.ToString("ddd MMM d, h:mm tt", CultureInfo.CurrentCulture);
            return new ULine(s, Theme.ForPercent(w.Effective), false);
        }

        List<ULine> UsageLines()
        {
            List<ULine> l = new List<ULine>();
            UsageSnapshot u = indexer == null ? null : indexer.Usage;
            if (u == null) { l.Add(new ULine("Reading usage from the agents' own files...", Theme.Dim, false)); return l; }
            string an = active == null ? "" : active.AgentName;
            ThreadUsage tu = null;
            if (active != null) u.BySession.TryGetValue(active.Session, out tu);

            l.Add(new ULine("Codex", Theme.Fg, true));
            List<RateWin> ws = CodexWindows(u);
            if (ws.Count == 0) l.Add(new ULine("  No limit data found in Codex's session files.", Theme.Dim, false));
            else
            {
                foreach (RateWin w in ws)
                    l.Add(CodexLimitLine(w));
                if (ws.Count == 1)
                    l.Add(new ULine("  Only one limit window is recorded" + (string.IsNullOrEmpty(u.CodexPlan) ? "" : " for your plan (" + u.CodexPlan + ")") + ".", Theme.Dim, false));
                l.Add(new ULine("  As of your last Codex activity: " + Theme.When(u.CodexAsOf), Theme.Dim, false));
            }
            if (an == "Codex")
                l.Add(new ULine("  This thread: " + (tu != null && tu.Tokens >= 0 ? Theme.Num(tu.Tokens) + " tokens (includes cached input)" : "--"), Theme.Dim, false));

            l.Add(new ULine("", Theme.Dim, false));
            l.Add(new ULine("Claude", Theme.Fg, true));
            if (!u.ClaudeFound) l.Add(new ULine("  No Claude token counts found.", Theme.Dim, false));
            else
            {
                if (an == "Claude")
                    l.Add(new ULine("  This thread: " + (tu != null && tu.Tokens >= 0 ? Theme.Num(tu.Tokens) + " tokens" : "--"), Theme.Dim, false));
                l.Add(new ULine("  Today, all Claude sessions: " + Theme.Num(u.ClaudeToday) + " tokens", Theme.Dim, false));
                l.Add(new ULine("  Last 7 days: " + Theme.Num(u.Claude7) + " tokens", Theme.Dim, false));
                l.Add(new ULine("  Counts include cached input, which is most of the total.", Theme.Dim, false));
            }
            l.Add(new ULine("  Claude's plan limit isn't recorded in these files.", Theme.Dim, false));

            l.Add(new ULine("", Theme.Dim, false));
            l.Add(new ULine("Copilot", Theme.Fg, true));
            if (!u.CopilotFound) l.Add(new ULine("  No Copilot session events found.", Theme.Dim, false));
            else
            {
                if (an == "Copilot" && tu != null)
                    l.Add(new ULine("  This thread: " + Math.Max(0, tu.Premium) + " premium requests, " + tu.Prompts + " prompts", Theme.Dim, false));
                l.Add(new ULine("  Today, all Copilot sessions: " + u.CopilotPromptsToday + " prompts, " + u.CopilotPremiumToday + " premium requests", Theme.Dim, false));
            }
            l.Add(new ULine("  Copilot's monthly allowance isn't recorded in these files.", Theme.Dim, false));
            l.Add(new ULine("", Theme.Dim, false));
            l.Add(new ULine("Updates about every 30 seconds. Esc closes this window.", Theme.Dim, false));
            return l;
        }

        // ---------- Needs you: alerts, the "what's needed from me" list, Peek ----------

        NeedsForm needsForm;
        PeekForm peek;
        List<NeedItem> needs = new List<NeedItem>();
        Dictionary<string, bool> notified = new Dictionary<string, bool>();
        Dictionary<string, Msg> askMsg = new Dictionary<string, Msg>();
        Dictionary<string, List<string>> askList = new Dictionary<string, List<string>>();
        DateTime appStart = DateTime.Now;
        bool lastZedActive = false;
        string balloonSession = null;
        bool balloonOpensNeeds = false;

        public static string StatusTextPublic(ThreadUsage tu, out Color c) { return StatusText(tu, out c); }

        public void MarkSeenPublic(string session) { MarkSeen(session); UpdateNeeds(); UpdateDots(); }

        static Msg LastReply(ThreadDoc d)
        {
            if (d == null || d.Msgs == null || d.Msgs.Length == 0) return null;
            Msg m = d.Msgs[d.Msgs.Length - 1];
            return m.You ? null : m; // nothing after your latest prompt yet
        }

        ThreadDoc DocFor(string session)
        {
            IndexSnapshot ix = IndexSnap;
            if (ix != null) foreach (ThreadDoc d in ix.Docs) if (d.Info.Session == session) return d;
            return null;
        }

        // The asks in a thread's last reply (cached until the reply changes).
        List<string> AsksFor(string session, Msg reply)
        {
            Msg m;
            if (askMsg.TryGetValue(session, out m) && m == reply) return askList[session];
            List<string> l = Asks.FromReply(reply.Text);
            askMsg[session] = reply;
            askList[session] = l;
            return l;
        }

        // Finished threads (since you last opened them) whose last reply asks you something in its text.
        List<NeedItem> BuildNeeds()
        {
            List<NeedItem> l = new List<NeedItem>();
            IndexSnapshot ix = IndexSnap;
            if (ix == null || indexer == null || indexer.Usage == null) return l;
            foreach (ThreadDoc d in ix.Docs)
            {
                if (d.Archived) continue;
                ThreadUsage tu = UsageFor(d.Info.Session);
                if (tu == null || !tu.HasTurn || tu.Working || tu.TurnEnd == DateTime.MinValue) continue;
                if (tu.TurnEnd <= SeenAt(d.Info.Session)) continue;
                Msg reply = LastReply(d);
                if (reply == null) continue;
                List<string> asks = AsksFor(d.Info.Session, reply);
                if (asks.Count == 0) continue;
                NeedItem n = new NeedItem();
                n.Doc = d; n.When = tu.TurnEnd; n.Asks = asks; n.Summary = tu.Summary ?? "";
                l.Add(n);
            }
            l.Sort(delegate (NeedItem a, NeedItem b) { return b.When.CompareTo(a.When); });
            return l;
        }

        void UpdateNeeds()
        {
            needs = BuildNeeds();
            if (form.NeedsCount != needs.Count) { form.NeedsCount = needs.Count; form.Invalidate(); }
            if (needsForm != null && !needsForm.IsDisposed && needsForm.Visible) needsForm.Rebuild(needs);
            if (peek != null && !peek.IsDisposed && peek.Visible) peek.UpdateContent();
            Notify();
        }

        // A Windows notification when a thread asks you a question or finishes while you're not looking at it.
        void Notify()
        {
            IndexSnapshot ix = IndexSnap;
            if (ix == null) return;
            List<string> lines = new List<string>();
            string firstSession = null, firstTitle = null;
            bool anyNeeds = false;
            foreach (ThreadDoc d in ix.Docs)
            {
                if (d.Archived) continue;
                string s = d.Info.Session;
                ThreadUsage tu = UsageFor(s);
                if (tu == null || !tu.HasTurn) continue;
                string key, line;
                if (!string.IsNullOrEmpty(tu.AskText))
                {
                    key = s + "|ask|" + tu.AskTime.Ticks;
                    string q = tu.AskText.Split('\n')[0];
                    line = "is asking you: " + (q.Length > 110 ? q.Substring(0, 107) + "..." : q);
                    if (tu.AskTime < appStart) { notified[key] = true; continue; }
                }
                else if (!tu.Working && tu.TurnEnd != DateTime.MinValue && tu.TurnEnd > SeenAt(s))
                {
                    key = s + "|done|" + tu.TurnEnd.Ticks;
                    if (tu.TurnEnd < appStart) { notified[key] = true; continue; }
                    bool asks = false;
                    foreach (NeedItem n in needs) if (n.Doc.Info.Session == s) asks = true;
                    line = "finished" + (tu.TurnStart != DateTime.MinValue ? " after " + Theme.Dur(tu.TurnEnd - tu.TurnStart) : "")
                         + (asks ? " and needs something from you." : ".");
                    if (asks) anyNeeds = true;
                }
                else continue;
                if (notified.ContainsKey(key)) continue;
                notified[key] = true;
                bool looking = lastZedActive && active != null && active.Session == s;
                if (looking) continue;
                lines.Add(d.Info.Display + " (" + d.Info.AgentName + ") " + line);
                if (firstSession == null) { firstSession = s; firstTitle = d.Info.Display; }
            }
            if (lines.Count == 0) return;
            balloonSession = firstSession;
            balloonOpensNeeds = anyNeeds;
            string title = lines.Count == 1 ? firstTitle : lines.Count + " threads need you";
            string text = string.Join("\n", lines.ToArray());
            if (text.Length > 250) text = text.Substring(0, 247) + "...";
            tray.ShowBalloonTip(8000, title, text, ToolTipIcon.Info);
        }

        void BalloonClicked()
        {
            if (balloonOpensNeeds) { OpenNeeds(); return; }
            RefocusZed();
            if (balloonSession != null) FlashSession(balloonSession);
        }

        public void OpenNeeds()
        {
            try
            {
                if (needsForm == null || needsForm.IsDisposed) needsForm = new NeedsForm(this, WindowScale());
                needs = BuildNeeds();
                needsForm.Open(needs, lastClient, OwnerForPopups());
            }
            catch (Exception ex) { Log("needs window error: " + ex.Message); }
        }

        public void Peek(string session)
        {
            try
            {
                if (session == null) return;
                if (peek == null || peek.IsDisposed) peek = new PeekForm(this, WindowScale());
                peek.Open(session, lastClient, OwnerForPopups());
            }
            catch (Exception ex) { Log("peek window error: " + ex.Message); }
        }

        public void PeekRow(Row r)
        {
            ThreadInfo t = MatchThread(r.Project, r.Title);
            if (t != null) Peek(t.Session);
        }

        public void PeekData(string session, out ThreadDoc doc, out ThreadUsage tu, out Msg lastAgent, out Msg lastYou)
        {
            doc = DocFor(session);
            tu = UsageFor(session);
            lastAgent = null; lastYou = null;
            if (doc == null || doc.Msgs == null) return;
            for (int i = doc.Msgs.Length - 1; i >= 0 && (lastAgent == null || lastYou == null); i--)
            {
                if (doc.Msgs[i].You) { if (lastYou == null) lastYou = doc.Msgs[i]; }
                else if (lastAgent == null) lastAgent = doc.Msgs[i];
            }
        }

        // ---------- Status dots, working timer, hover card ----------

        void LoadSeen()
        {
            try
            {
                if (!File.Exists(seenPath)) return;
                foreach (string line in File.ReadAllLines(seenPath))
                {
                    string[] p = line.Split('\t');
                    long ticks;
                    if (p.Length == 2 && long.TryParse(p[1], out ticks)) seen[p[0]] = new DateTime(ticks, DateTimeKind.Local);
                }
            }
            catch (Exception ex) { Log("loading seen.tsv failed: " + ex.Message); }
        }

        void SaveSeen(bool force)
        {
            if (!seenDirty || (!force && DateTime.Now < nextSeenSave)) return;
            nextSeenSave = DateTime.Now.AddSeconds(30);
            try
            {
                List<string> lines = new List<string>();
                foreach (KeyValuePair<string, DateTime> kv in seen) lines.Add(kv.Key + "\t" + kv.Value.Ticks);
                File.WriteAllLines(seenPath, lines.ToArray());
                seenDirty = false;
            }
            catch (Exception ex) { Log("saving seen.tsv failed: " + ex.Message); }
        }

        void MarkSeen(string session)
        {
            seen[session] = DateTime.Now;
            seenDirty = true;
            SaveSeen(false);
        }

        // When you last had this thread open. A thread never seen before counts as seen now,
        // so old finished threads don't all light up green the first time.
        DateTime SeenAt(string session)
        {
            DateTime t;
            if (seen.TryGetValue(session, out t)) return t;
            t = DateTime.Now;
            seen[session] = t;
            seenDirty = true;
            return t;
        }

        const double StaleMinutes = 30; // "working" with no file activity this long = probably stopped
        const double CompletionFlashSeconds = 5;

        // "Working 3m 12s" / "Done 2m ago" for a thread, or null when unknown.
        static string StatusText(ThreadUsage tu, out Color c)
        {
            c = Theme.Dim;
            if (tu == null || !tu.HasTurn) return null;
            if (!string.IsNullOrEmpty(tu.AskText))
            {
                c = Theme.Accent;
                return "Waiting for your answer" + (tu.ActiveHelpers > 0 ? " \u00B7 " + tu.ActiveHelpers
                    + (tu.ActiveHelpers == 1 ? " helper agent working" : " helper agents working") : "");
            }
            DateTime now = DateTime.Now;
            if (tu.Working)
            {
                TimeSpan quiet = tu.LastWrite == DateTime.MinValue ? TimeSpan.Zero : now - tu.LastWrite;
                if (quiet.TotalMinutes >= StaleMinutes) return "No activity for " + Theme.Ago(quiet);
                c = Theme.Working;
                string s = "Working";
                if (tu.ActiveHelpers > 0)
                    s = (tu.WaitingForHelpers ? "Waiting for " : "Working with ") + tu.ActiveHelpers
                        + (tu.ActiveHelpers == 1 ? " helper agent" : " helper agents");
                if (tu.TurnStart != DateTime.MinValue) s += " " + Theme.Dur(now - tu.TurnStart);
                if (quiet.TotalMinutes >= 2) s += " (quiet " + Theme.Ago(quiet) + ")";
                return s;
            }
            if (tu.TurnEnd == DateTime.MinValue) return null;
            return "Done " + Theme.Ago(now - tu.TurnEnd) + " ago";
        }

        ThreadUsage UsageFor(string session)
        {
            UsageSnapshot u = indexer == null ? null : indexer.Usage;
            ThreadUsage tu = null;
            if (u != null && session != null) u.BySession.TryGetValue(session, out tu);
            return tu;
        }

        void UpdateDots()
        {
            Dictionary<string, int> d = new Dictionary<string, int>();
            Dictionary<string, int> helpers = new Dictionary<string, int>();
            DateTime now = DateTime.Now;
            foreach (Row r in form.Rows)
            {
                ThreadInfo t = MatchThread(r.Project, r.Title);
                if (t == null) continue;
                ThreadUsage tu = UsageFor(t.Session);
                if (tu == null || !tu.HasTurn) continue;

                bool stale = tu.LastWrite != DateTime.MinValue && (now - tu.LastWrite).TotalMinutes >= StaleMinutes;
                if (!string.IsNullOrEmpty(tu.AskText)) d[r.Key] = 3; // asked you a question
                else if (tu.Working && !stale) d[r.Key] = 1;
                else if (!tu.Working && tu.TurnEnd != DateTime.MinValue)
                {
                    double ago = (now - tu.TurnEnd).TotalSeconds;
                    if (tu.TurnEnd > SeenAt(t.Session) || (ago >= 0 && ago < CompletionFlashSeconds)) d[r.Key] = 2;
                }
                if (tu.Working && !stale && tu.ActiveHelpers > 0 && d.ContainsKey(r.Key)) helpers[r.Key] = tu.ActiveHelpers;
            }
            bool same = d.Count == rings.Dots.Count;
            if (same) foreach (KeyValuePair<string, int> kv in d) { int v; if (!rings.Dots.TryGetValue(kv.Key, out v) || v != kv.Value) { same = false; break; } }
            if (same) same = helpers.Count == rings.ActiveHelpers.Count;
            if (same) foreach (KeyValuePair<string, int> kv in helpers) { int v; if (!rings.ActiveHelpers.TryGetValue(kv.Key, out v) || v != kv.Value) { same = false; break; } }
            if (!same) { rings.Dots = d; rings.ActiveHelpers = helpers; rings.Invalidate(); }
        }

        Row RowForHover(Point p)
        {
            if (!form.Visible) return null;
            if (sidebar.Contains(p))
                foreach (Row r in form.Rows) if (p.Y >= r.RowTop && p.Y < r.RowBottom) return r;
            if (card != null && card.Visible)
            {
                Rectangle passage = Rectangle.FromLTRB(sidebar.Right, card.Top, card.Right, card.Bottom);
                if (passage.Contains(p)) return form.Rows.Find(delegate (Row row) { return row.Key == hoverKey; });
            }
            return null;
        }

        // Shows the hover card after the mouse rests on a thread in the sidebar for a moment.
        void HoverTick()
        {
            try
            {
                Row r = form.Visible ? form.RowAtScreen(Cursor.Position) : null;

                // Brighten the bar or magnifier under the mouse, like Zed's hover state.
                string hk = r == null ? null : r.Key;
                Rectangle sr = form.SearchRect();
                bool hs = form.Visible && !sr.IsEmpty && sr.Contains(form.PointToClient(Cursor.Position));
                if (hk != form.HoverKey || hs != form.HoverSearch) { form.HoverKey = hk; form.HoverSearch = hs; form.Invalidate(); }

                // The card follows the mouse over the thread's row in Zed's sidebar (we only read the
                // mouse position; nothing of ours sits there to click). Never while picking a color.
                r = RowForHover(Cursor.Position);
                if (picker != null && picker.Visible) r = null;

                if (r == null)
                {
                    hoverKey = null;
                    if (card.Visible) card.Hide();
                    if (ci != null) ci.SetFolders(active == null ? null : active.Folders);
                    return;
                }
                if (r.Key != hoverKey) { hoverKey = r.Key; hoverSince = DateTime.Now; if (card.Visible) card.Hide(); return; }
                if ((DateTime.Now - hoverSince).TotalMilliseconds < 600) return;
                ThreadInfo hovered = MatchThread(r.Project, r.Title);
                if (ci != null) ci.SetFolders(hovered == null ? null : hovered.Folders);
                card.SetContent(CardLines(r), scale);
                int x = form.Bounds.Right + (int)(8 * scale);
                int y = r.CenterY - (int)(14 * scale);
                if (lastClient.Width > 0) y = Math.Max(lastClient.Top, Math.Min(y, lastClient.Bottom - card.Height));
                card.Location = new Point(x, y);
                if (!card.Visible)
                {
                    if (zedMain != IntPtr.Zero) Native.SetOwner(card.Handle, zedMain);
                    card.Show();
                }
            }
            catch (Exception ex) { Log("hover card error: " + ex.Message); hoverKey = null; }
        }

        List<ULine> CardLines(Row r)
        {
            List<ULine> l = new List<ULine>();
            ThreadInfo t = MatchThread(r.Project, r.Title);
            l.Add(new ULine(t != null ? t.Display : r.Title, Theme.Fg, true));
            if (t == null) { l.Add(new ULine("Not in Zed's thread list yet.", Theme.Dim, false)); return l; }

            ThreadDoc doc = null;
            IndexSnapshot ix = IndexSnap;
            if (ix != null) foreach (ThreadDoc d in ix.Docs) if (d.Info.Session == t.Session) { doc = d; break; }
            string project = doc != null && doc.Project.Length > 0 ? doc.Project : r.Project;
            l.Add(new ULine(t.AgentName + "   |   " + project, Theme.Dim, false));

            ThreadUsage tu = UsageFor(t.Session);
            Color sc;
            string st = StatusText(tu, out sc);
            if (st != null) l.Add(new ULine(st + (tu.Working && !tu.WaitingForHelpers && !string.IsNullOrEmpty(tu.Step) && sc == Theme.Working ? " \u00B7 " + tu.Step : ""), sc, false));
            if (tu != null && !string.IsNullOrEmpty(tu.Summary)) l.Add(new ULine((tu.Working ? "This turn: " : "Last turn: ") + tu.Summary, Theme.Dim, false));
            if (tu != null && tu.LastWrite != DateTime.MinValue)
                l.Add(new ULine("Last activity: " + Theme.Ago(DateTime.Now - tu.LastWrite) + " ago", Theme.Dim, false));

            Msg last = null;
            if (doc != null && doc.Msgs != null)
                for (int i = doc.Msgs.Length - 1; i >= 0; i--) if (doc.Msgs[i].You) { last = doc.Msgs[i]; break; }
            string prompt = doc == null ? (ix == null || ix.Building ? "Loading saved history..." : ix.Problem ?? "This thread is not in the saved thread list.")
                : doc.Prompt ?? (last == null ? null : last.Text) ?? doc.Problem
                ?? (ix.Building ? "Loading saved history..." : "No user prompt found in saved history.");
            if (!string.IsNullOrEmpty(prompt))
            {
                string p = prompt.Replace("\r", " ").Replace("\n", " ");
                if (p.Length > 220) p = p.Substring(0, 220) + "...";
                l.Add(new ULine("", Theme.Dim, false));
                l.Add(new ULine("Your last prompt" + (last != null && last.Time != DateTime.MinValue ? " (" + Theme.Ago(DateTime.Now - last.Time) + " ago)" : "") + ":", Theme.Dim, false));
                l.Add(new ULine(p, Theme.Fg, false));
            }
            if (doc != null && doc.Problem != null && doc.Problem != prompt)
                l.Add(new ULine(doc.Problem, Theme.Accent, false));

            if (tu != null)
            {
                string use = null;
                if (t.AgentName == "Copilot") use = Math.Max(0, tu.Premium) + " premium requests, " + tu.Prompts + " prompts";
                else if (tu.Tokens >= 0) use = Theme.Num(tu.Tokens) + " tokens (includes cached input)";
                if (use != null) { l.Add(new ULine("", Theme.Dim, false)); l.Add(new ULine("Usage: " + use, Theme.Dim, false)); }
            }
            if (t.AgentName == "Codex" && indexer != null && indexer.Usage != null)
                foreach (RateWin w in CodexWindows(indexer.Usage)) l.Add(CodexLimitLine(w));
            if (ci != null)
            {
                CiSnapshot snapshot = ci.SnapshotFor(t.Folders);
                CiInfo run = snapshot == null ? null : snapshot.Run;
                l.Add(new ULine("", Theme.Dim, false));
                l.Add(new ULine("GitHub" + (run == null ? "" : " \u00B7 " + run.Repo + " \u00B7 " + run.Workflow), Theme.Dim, true));
                if (run == null)
                    l.Add(new ULine(snapshot == null ? "Checking GitHub Actions..." : snapshot.Message, Theme.Dim, false));
                else
                {
                    string when = run.Updated == DateTime.MinValue ? "" : " \u00B7 " + Theme.Ago(DateTime.Now - run.Updated) + " ago";
                    string branch = string.IsNullOrEmpty(run.Branch) ? "" : " \u00B7 " + run.Branch;
                    l.Add(new ULine(run.StatusText + branch + when, run.StatusColor, false, run.Url));
                    if (!string.IsNullOrEmpty(run.Title))
                        l.Add(new ULine(run.Title.Length > 220 ? run.Title.Substring(0, 220) + "..." : run.Title, Theme.Fg, false, run.Url));
                    if (!string.IsNullOrEmpty(run.Url)) l.Add(new ULine("Open GitHub run", Theme.Working, false, run.Url));
                }
            }
            return l;
        }

        // ---------- Colors ----------

        public int ColorIndex(string key)
        {
            string k = Resolve(key);
            int idx;
            if (k != null && colors.TryGetValue(k, out idx)) return idx;
            return 0;
        }

        public void SetColor(string key, int idx)
        {
            string k = Resolve(key) ?? key;
            if (idx <= 0 || idx >= Palette.Length) colors.Remove(k); else colors[k] = idx;
            aliases.Clear();
            Save();
            form.Invalidate();
        }

        // Left-click a bar: pick a color from a small menu beside it.
        public void PickColor(Row r)
        {
            try
            {
                if (picker == null || picker.IsDisposed) picker = new ColorPicker(this);
                Rectangle b = form.RectangleToScreen(form.BarRect(r));
                picker.Open(r.Key, ColorIndex(r.Key), new Point(form.Bounds.Right + (int)(6 * scale), b.Top), scale, zedMain);
            }
            catch (Exception ex) { Log("color picker error: " + ex.Message); }
        }

        // Tolerate small OCR misreads (e.g. "Visio BuiId" vs "Visio Build").
        string Resolve(string key)
        {
            if (colors.ContainsKey(key)) return key;
            string a;
            if (aliases.TryGetValue(key, out a)) return a;
            string best = null;
            int bestD = int.MaxValue;
            int allowed = Math.Max(1, key.Length / 8);
            foreach (string k in colors.Keys)
            {
                if (Math.Abs(k.Length - key.Length) > allowed) continue;
                int d = Lev(k, key);
                if (d <= allowed && d < bestD) { bestD = d; best = k; }
            }
            aliases[key] = best;
            return best;
        }

        void ClearAll()
        {
            if (MessageBox.Show("Remove the color from every thread?", "Zed Thread Colors", MessageBoxButtons.YesNo) == DialogResult.Yes)
            {
                colors.Clear(); aliases.Clear(); Save(); form.Invalidate();
            }
        }

        void Load()
        {
            try
            {
                if (!File.Exists(dataPath)) return;
                foreach (string line in File.ReadAllLines(dataPath))
                {
                    string[] parts = line.Split('\t');
                    int idx;
                    if (parts.Length == 2 && int.TryParse(parts[1], out idx) && idx > 0 && idx < Palette.Length) colors[parts[0]] = idx;
                }
            }
            catch (Exception ex) { Log("load failed: " + ex.Message); }
        }

        void Save()
        {
            try
            {
                List<string> lines = new List<string>();
                foreach (KeyValuePair<string, int> kv in colors) lines.Add(kv.Key + "\t" + kv.Value);
                File.WriteAllLines(dataPath, lines.ToArray());
            }
            catch (Exception ex) { Log("save failed: " + ex.Message); }
        }

        // ---------- Screen helpers ----------

        bool IsZedPid(uint pid)
        {
            try
            {
                using (Process pr = Process.GetProcessById((int)pid))
                    return string.Equals(pr.ProcessName, "zed", StringComparison.OrdinalIgnoreCase);
            }
            catch { return false; }
        }

        static int[] GetPixels(Bitmap bmp)
        {
            Rectangle r = new Rectangle(0, 0, bmp.Width, bmp.Height);
            BitmapData d = bmp.LockBits(r, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            int[] px = new int[bmp.Width * bmp.Height];
            Marshal.Copy(d.Scan0, px, 0, px.Length);
            bmp.UnlockBits(d);
            return px;
        }

        static int Diff(int a, int b)
        {
            return Math.Abs(((a >> 16) & 255) - ((b >> 16) & 255))
                 + Math.Abs(((a >> 8) & 255) - ((b >> 8) & 255))
                 + Math.Abs((a & 255) - (b & 255));
        }

        // The sidebar's right edge is the leftmost column where the color changes on most rows top-to-bottom.
        int FindEdge(int[] px, int w, int h)
        {
            int samples = 48;
            Rectangle[] panels = new Rectangle[] {
                card != null && card.Visible ? card.Bounds : Rectangle.Empty
            };
            for (int i = 0; i < panels.Length; i++)
            {
                if (panels[i].IsEmpty) continue;
                panels[i].Offset(-lastClient.Left, -lastClient.Top);
                panels[i].Inflate(2, 2);
            }
            int y0 = (int)(h * 0.08), y1 = (int)(h * 0.97);
            int start = Math.Max(2, (int)(150 * scale));
            for (int x = start; x < w - 1; x++)
            {
                int count = 0, tested = 0;
                for (int i = 0; i < samples; i++)
                {
                    int y = y0 + (y1 - y0) * i / (samples - 1);
                    // A panel may briefly overlap the sidebar when Zed's panes change.
                    bool covered = false;
                    foreach (Rectangle panel in panels) if (panel.Contains(x, y) || panel.Contains(x - 1, y)) { covered = true; break; }
                    if (covered) continue;
                    tested++;
                    if (Diff(px[y * w + x - 1], px[y * w + x]) > 30) count++;
                }
                if (tested >= samples * 0.7 && count >= tested * 0.7) return x;
            }
            return -1;
        }

        static byte[] MakeOcrImage(int[] px, int w, int h, int edge)
        {
            long sum = 0;
            for (int y = 0; y < h; y += 4) for (int x = 0; x < edge; x += 4) sum += Lum(px[y * w + x]);
            long n = ((h + 3) / 4) * (long)((edge + 3) / 4);
            bool dark = n > 0 && sum / n < 128;

            int[] outp = new int[edge * h];
            for (int y = 0; y < h; y++)
            {
                for (int x = 0; x < edge; x++)
                {
                    int v = Lum(px[y * w + x]);
                    if (dark) v = 255 - v; // OCR reads dark text on light background best
                    outp[y * edge + x] = unchecked((int)0xFF000000) | (v << 16) | (v << 8) | v;
                }
            }
            using (Bitmap g = new Bitmap(edge, h, PixelFormat.Format32bppArgb))
            {
                BitmapData d = g.LockBits(new Rectangle(0, 0, edge, h), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
                Marshal.Copy(outp, 0, d.Scan0, outp.Length);
                g.UnlockBits(d);
                int bw = (int)(edge * OcrScale), bh = (int)(h * OcrScale);
                using (Bitmap big = new Bitmap(bw, bh, PixelFormat.Format32bppArgb))
                {
                    using (Graphics gr = Graphics.FromImage(big))
                    {
                        gr.InterpolationMode = InterpolationMode.HighQualityBicubic;
                        gr.DrawImage(g, 0, 0, bw, bh);
                    }
                    using (MemoryStream ms = new MemoryStream())
                    {
                        big.Save(ms, ImageFormat.Png);
                        return ms.ToArray();
                    }
                }
            }
        }

        static int Lum(int c)
        {
            return (((c >> 16) & 255) * 299 + ((c >> 8) & 255) * 587 + (c & 255) * 114) / 1000;
        }

        void PositionForm()
        {
            bool rescale = Math.Abs(form.UiScale - scale) > 0.01f;
            form.UiScale = scale;
            rings.UiScale = scale;
            Rectangle b = new Rectangle(sidebar.Right + (int)(3 * scale), sidebar.Top, form.StripWidth, sidebar.Height);
            if (form.Bounds != b || rescale) { form.Bounds = b; form.Invalidate(); }
            if (rings.Bounds != sidebar || rescale) { rings.Bounds = sidebar; rings.Invalidate(); }
        }

        void ShowForm()
        {
            if (form.Rows.Count > 0 && !form.Visible)
            {
                form.Show();
                rings.Show();
                // Draw again on the next few ticks in case a window came back blank.
                repaintTicks = 3;
            }
        }

        int repaintTicks = 0;

        void RepaintIfNeeded()
        {
            if (repaintTicks <= 0) return;
            repaintTicks--;
            if (form.Visible) { form.Invalidate(); rings.Invalidate(); }
        }

        // Windows sometimes slips an overlay behind Zed (seen with the color strip). While Zed is the
        // active window, put any overlay that ended up behind it back in front.
        void KeepInFront()
        {
            if (zedMain == IntPtr.Zero) return;
            Form[] wins = new Form[] { form, rings, card };
            foreach (Form w in wins)
                if (w != null && w.Visible && w.IsHandleCreated && Native.IsBehind(w.Handle, zedMain)) Native.BringToFront(w.Handle);
        }

        void HideForm()
        {
            if (form != null && form.Visible) form.Hide();
            if (rings != null && rings.Visible) rings.Hide();
            if (card != null && card.Visible) card.Hide();
        }

        // Our rings sit inside the sidebar and the screen capture sees them. Paint each ring's band
        // over with the pixels just outside it, so the rings never affect reading the thread names.
        void ScrubRings(int[] px, int w, int h, int ox, int oy)
        {
            foreach (Rectangle[] band in rings.Bands())
            {
                Rectangle o = band[0], n = band[1];
                o.Offset(-ox, -oy); n.Offset(-ox, -oy);
                int x0 = Math.Max(1, o.Left), x1 = Math.Min(w - 1, o.Right);
                int y0 = Math.Max(1, o.Top), y1 = Math.Min(h - 1, o.Bottom);
                if (x1 <= x0 || y1 <= y0) continue;
                for (int y = y0; y < y1; y++)
                {
                    bool topBand = y < n.Top, bottomBand = y >= n.Bottom;
                    for (int x = x0; x < x1; x++)
                    {
                        if (topBand) px[y * w + x] = px[(y0 - 1) * w + x];
                        else if (bottomBand) px[y * w + x] = px[y1 * w + x];
                        else if (x < n.Left) px[y * w + x] = px[y * w + x0 - 1];
                        else if (x >= n.Right) px[y * w + x] = px[y * w + Math.Min(w - 1, x1)];
                    }
                }
            }
        }

        public void RefocusZed()
        {
            if (zedMain != IntPtr.Zero) Native.SetForegroundWindow(zedMain);
        }

        void EnsureOwner()
        {
            if (ownerSet == zedMain) return;
            IntPtr h = form.Handle; // forces the window to exist
            Native.SetOwner(h, zedMain);
            Native.SetOwner(rings.Handle, zedMain);
            if (card != null && card.IsHandleCreated) Native.SetOwner(card.Handle, zedMain);
            ownerSet = zedMain;
            Log("attached to Zed window " + zedMain);
        }

        // ---------- Text helpers ----------

        static readonly Regex SubRx = new Regex(
            @"^([0-9lIOo|]{1,3}\s?(s|m|h|d|w|mo|y|min|mins|hr|hrs|day|days|wk|wks)(\s?ago)?|now|just now)$",
            RegexOptions.IgnoreCase);

        static bool IsSubtitle(string t) { return SubRx.IsMatch(t.Trim()); }

        static bool IsWordy(string t)
        {
            foreach (char c in t) if (!char.IsLetterOrDigit(c)) return false;
            return true;
        }

        static string Norm(string s)
        {
            StringBuilder sb = new StringBuilder();
            foreach (char c in s.ToLowerInvariant()) if (char.IsLetterOrDigit(c)) sb.Append(c);
            return sb.ToString();
        }

        static int Lev(string a, string b)
        {
            int[,] d = new int[a.Length + 1, b.Length + 1];
            for (int i = 0; i <= a.Length; i++) d[i, 0] = i;
            for (int j = 0; j <= b.Length; j++) d[0, j] = j;
            for (int i = 1; i <= a.Length; i++)
                for (int j = 1; j <= b.Length; j++)
                    d[i, j] = Math.Min(Math.Min(d[i - 1, j] + 1, d[i, j - 1] + 1), d[i - 1, j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1));
            return d[a.Length, b.Length];
        }

        // ---------- Startup / misc ----------

        bool IsStartup()
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(RunKey))
                    return k != null && k.GetValue(RunName) != null;
            }
            catch (Exception ex) { LogOnce("startup-read", "could not read Windows startup setting: " + ex.Message); return false; }
        }

        void ToggleStartup()
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.CreateSubKey(RunKey))
                {
                    if (k == null) throw new IOException("Windows startup registry key is unavailable");
                    if (k.GetValue(RunName) != null) k.DeleteValue(RunName, false);
                    else k.SetValue(RunName, "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + scriptPath + "\"");
                }
            }
            catch (Exception ex)
            {
                Log("startup toggle failed: " + ex.Message);
                MessageBox.Show("Could not change Start with Windows. Open the log for details.",
                    "Zed Thread Colors", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            if (startupItem != null) startupItem.Checked = IsStartup();
        }

        public void LogOnce(string key, string msg)
        {
            lock (logLock)
            {
                string old;
                if (logWarnings.TryGetValue(key, out old) && old == msg) return;
                logWarnings[key] = msg;
                Log(msg);
            }
        }

        public void Log(string msg)
        {
            lock (logLock) // the indexer logs from its own thread
            {
                try
                {
                    if (File.Exists(logPath) && new FileInfo(logPath).Length > 1000000) File.Delete(logPath);
                    File.AppendAllText(logPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + msg + Environment.NewLine);
                }
                catch { }
            }
        }

        void Quit()
        {
            SaveSeen(true);
            if (hoverTimer != null) hoverTimer.Stop();
            if (card != null) card.Hide();
            if (indexer != null) indexer.Stop();
            if (ci != null) ci.Stop();
            if (hotkey != null) { Native.UnregisterHotKey(hotkey.Handle, HotkeyId); Native.UnregisterHotKey(hotkey.Handle, HotkeyId2); hotkey.DestroyHandle(); }
            if (needsForm != null && !needsForm.IsDisposed) needsForm.Hide();
            if (peek != null && !peek.IsDisposed) peek.Hide();
            if (search != null && !search.IsDisposed) search.Hide();
            if (usageForm != null && !usageForm.IsDisposed) usageForm.Hide();
            HideForm();
            tray.Visible = false;
            tray.Dispose();
            Log("stopped.");
            ExitThread();
        }
    }
}
'@

function Show-Error([string]$msg) {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show($msg, 'Zed Thread Colors') | Out-Null
}

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    Add-Type -TypeDefinition $source -ReferencedAssemblies System.Windows.Forms, System.Drawing, System.Web.Extensions

    if (-not [ZedColors.App]::AcquireSingle()) {
        Show-Error 'Zed Thread Colors is already running. Look for the four-color icon in your system tray.'
        return
    }
    [ZedColors.Native]::InitDpi()

    # Windows built-in OCR (WinRT)
    $null = [Windows.Foundation.IAsyncOperation`1, Windows.Foundation, ContentType = WindowsRuntime]
    $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
    $null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Foundation, ContentType = WindowsRuntime]
    $null = [Windows.Storage.Streams.RandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
    $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]

    if ($null -eq [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()) {
        Show-Error 'Windows text recognition is not available. Add an English language pack in Windows Settings > Time & language > Language.'
        return
    }

    $ocrSource = @'
param([byte[]]$bytes)
$ErrorActionPreference = 'Stop'
[System.Threading.Thread]::CurrentThread.Priority = [System.Threading.ThreadPriority]::BelowNormal
if ($null -eq $script:ocr) {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Foundation.IAsyncOperation`1, Windows.Foundation, ContentType = WindowsRuntime]
    $null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Foundation, ContentType = WindowsRuntime]
    $null = [Windows.Storage.Streams.RandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
    $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
    $script:awaiter = [System.WindowsRuntimeSystemExtensions].GetMember('GetAwaiter') |
        Where-Object { $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } |
        Select-Object -First 1
    $script:ocr = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]::TryCreateFromUserProfileLanguages()
    if ($null -eq $script:ocr) { throw 'Windows text recognition is unavailable. Check your Windows language pack.' }
    $script:tempPng = Join-Path $env:TEMP ('zed-thread-colors-ocr-' + $PID + '.png')
    $script:useFile = $false
}
$script:warning = $null

function Await($op, [Type]$type) {
    $script:awaiter.MakeGenericMethod($type).Invoke($null, @($op)).GetResult()
}

function Get-Bitmap([byte[]]$bytes) {
    if (-not $script:useFile) {
        $ms = $null; $ras = $null
        try {
            $ms = New-Object System.IO.MemoryStream(, $bytes)
            $ras = [System.IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream($ms)
            $dec = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($ras)) ([Windows.Graphics.Imaging.BitmapDecoder])
            return Await ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        } catch {
            $script:warning = 'memory-stream OCR input failed, switching to temp file: ' + $_.Exception.Message
            $script:useFile = $true
        } finally {
            if ($null -ne $ras) { $ras.Dispose() }
            if ($null -ne $ms) { $ms.Dispose() }
        }
    }
    $stream = $null
    try {
        [System.IO.File]::WriteAllBytes($script:tempPng, $bytes)
        $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($script:tempPng)) ([Windows.Storage.StorageFile])
        $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
        $dec = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        return Await ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ([System.IO.File]::Exists($script:tempPng)) { [System.IO.File]::Delete($script:tempPng) }
    }
}

$bmp = $null
try {
    $bmp = Get-Bitmap $bytes
    $res = Await ($script:ocr.RecognizeAsync($bmp)) ([Windows.Media.Ocr.OcrResult])
    $words = New-Object 'System.Collections.Generic.List[ZedColors.Word]'
    $li = 0
    foreach ($line in $res.Lines) {
        foreach ($w in $line.Words) {
            $r = $w.BoundingRect
            $word = New-Object ZedColors.Word
            $word.Line = $li; $word.Text = $w.Text
            $word.X = $r.X; $word.Y = $r.Y; $word.W = $r.Width; $word.H = $r.Height
            $words.Add($word)
        }
        $li++
    }
    [pscustomobject]@{ Words = $words; Warning = $script:warning }
} finally {
    if ($null -ne $bmp) { $bmp.Dispose() }
}
'@

    $script:ocrRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $script:ocrRunspace.ApartmentState = [System.Threading.ApartmentState]::MTA
    $script:ocrRunspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $script:ocrRunspace.Open()
    $script:ocrWorker = [System.Management.Automation.PowerShell]::Create()
    $script:ocrWorker.Runspace = $script:ocrRunspace
    $script:ocrJob = $null
    $script:ocrPending = $false
    $script:app = New-Object ZedColors.App($PSCommandPath)
    $script:busy = $false
    $script:errors = 0

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 700
    $timer.Add_Tick({
        if ($script:busy) { return }
        $script:busy = $true
        try {
            # Do not replace the capture while OCR is reading it: animated sidebar icons
            # otherwise invalidate every result before it can be drawn.
            if ($null -ne $script:ocrJob -and -not $script:ocrJob.IsCompleted) { return }
            if ($null -ne $script:ocrJob -and $script:ocrJob.IsCompleted) {
                try {
                    $results = $script:ocrWorker.EndInvoke($script:ocrJob)
                    if ($script:ocrWorker.Streams.Error.Count -gt 0) {
                        throw $script:ocrWorker.Streams.Error[0].Exception
                    }
                    if ($results.Count -ne 1) { throw 'Text recognition returned an unexpected result.' }
                    $result = $results[0]
                    $script:app.LogOnce('ocr-ready', 'sidebar text recognition ready')
                    if ($null -ne $result.Warning) { $script:app.LogOnce('ocr-input', $result.Warning) }
                    if ($script:app.CanApplyOcr($script:ocrRevision)) {
                        $script:app.BeginOcr()
                        foreach ($w in $result.Words) {
                            $script:app.AddWord($w.Line, $w.Text, $w.X, $w.Y, $w.W, $w.H)
                        }
                        $script:app.EndOcr()
                    } elseif (-not $script:ocrPending) { $script:app.RetryOcr() }
                } catch {
                    $script:app.LogOnce('ocr-worker', 'text recognition failed: ' + $_.Exception.Message)
                    if (-not $script:ocrPending) { $script:app.RetryOcr() }
                } finally { $script:ocrJob = $null }
            }
            if ($script:app.Prepare()) { $script:ocrPending = $true }
            if ($null -eq $script:ocrJob -and $script:ocrPending) {
                $script:ocrWorker.Commands.Clear()
                $script:ocrWorker.Streams.Error.Clear()
                $null = $script:ocrWorker.AddScript($ocrSource).AddArgument($script:app.PngBytes)
                $script:ocrRevision = $script:app.OcrRevision
                $script:ocrJob = $script:ocrWorker.BeginInvoke()
                $script:app.LogOnce('ocr-started', 'sidebar text recognition started on background worker')
                $script:ocrPending = $false
            }
        } catch {
            $script:errors++
            if ($script:errors -le 50) { $script:app.Log('tick error: ' + $_.Exception.Message) }
        } finally {
            $script:busy = $false
        }
    })
    $timer.Start()

    [System.Windows.Forms.Application]::Run($script:app)
}
catch {
    Show-Error ("Zed Thread Colors could not start:`n`n" + $_.Exception.Message)
}
finally {
    if ($null -ne $timer) { $timer.Stop(); $timer.Dispose() }
    if ($null -ne $script:ocrWorker) { $script:ocrWorker.Stop(); $script:ocrWorker.Dispose() }
    if ($null -ne $script:ocrRunspace) { $script:ocrRunspace.Dispose() }
}
