using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace Seam.WindowsHost.Gui
{
    /// <summary>
    /// Colours, fonts and small drawing helpers. One place for the visual language so the
    /// window, the dialogs and the custom controls cannot drift apart.
    /// </summary>
    internal static class Theme
    {
        // ---- surfaces ----
        public static readonly Color Background = Color.FromArgb(0xF3, 0xF3, 0xF3);
        public static readonly Color Surface = Color.White;
        public static readonly Color SurfaceMuted = Color.FromArgb(0xFA, 0xFA, 0xFA);
        public static readonly Color Border = Color.FromArgb(0xE3, 0xE3, 0xE3);
        public static readonly Color BorderStrong = Color.FromArgb(0xD0, 0xD0, 0xD0);

        // ---- text ----
        public static readonly Color TextPrimary = Color.FromArgb(0x1B, 0x1B, 0x1B);
        public static readonly Color TextSecondary = Color.FromArgb(0x5D, 0x5D, 0x5D);
        public static readonly Color TextTertiary = Color.FromArgb(0x86, 0x86, 0x86);

        // ---- accent ----
        public static readonly Color Accent = Color.FromArgb(0x0F, 0x6C, 0xBD);
        public static readonly Color AccentHover = Color.FromArgb(0x11, 0x5E, 0xA3);
        public static readonly Color AccentPressed = Color.FromArgb(0x0C, 0x3E, 0x6E);
        public static readonly Color AccentSoft = Color.FromArgb(0xE7, 0xF1, 0xFB);

        // ---- status ----
        public static readonly Color StatusConnected = Color.FromArgb(0x0F, 0x7B, 0x0F);
        public static readonly Color StatusConnectedSoft = Color.FromArgb(0xDF, 0xF6, 0xDD);
        public static readonly Color StatusBusy = Color.FromArgb(0x9D, 0x5D, 0x00);
        public static readonly Color StatusBusySoft = Color.FromArgb(0xFF, 0xF4, 0xCE);
        public static readonly Color StatusError = Color.FromArgb(0xC4, 0x2B, 0x1C);
        public static readonly Color StatusErrorSoft = Color.FromArgb(0xFD, 0xE7, 0xE9);
        public static readonly Color StatusIdle = Color.FromArgb(0x6B, 0x6B, 0x6B);
        public static readonly Color StatusIdleSoft = Color.FromArgb(0xEE, 0xEE, 0xEE);

        // ---- fonts (created once, live for the process) ----
        public static readonly Font Body = new Font("Segoe UI", 9F, FontStyle.Regular, GraphicsUnit.Point);
        public static readonly Font BodyStrong = new Font("Segoe UI", 9F, FontStyle.Bold, GraphicsUnit.Point);
        public static readonly Font Small = new Font("Segoe UI", 8.25F, FontStyle.Regular, GraphicsUnit.Point);
        public static readonly Font Section = new Font("Segoe UI", 8F, FontStyle.Bold, GraphicsUnit.Point);
        public static readonly Font Heading = new Font("Segoe UI", 12.5F, FontStyle.Bold, GraphicsUnit.Point);
        public static readonly Font Title = new Font("Segoe UI", 15F, FontStyle.Bold, GraphicsUnit.Point);
        public static readonly Font Mono = new Font("Consolas", 8.75F, FontStyle.Regular, GraphicsUnit.Point);

        /// <summary>Rounded rectangle path; radius is clamped so tiny controls still render.</summary>
        public static GraphicsPath RoundedRect(Rectangle bounds, int radius)
        {
            var path = new GraphicsPath();
            int r = Math.Max(0, Math.Min(radius, Math.Min(bounds.Width, bounds.Height) / 2));
            if (r == 0)
            {
                path.AddRectangle(bounds);
                return path;
            }

            int d = r * 2;
            path.AddArc(bounds.Left, bounds.Top, d, d, 180, 90);
            path.AddArc(bounds.Right - d, bounds.Top, d, d, 270, 90);
            path.AddArc(bounds.Right - d, bounds.Bottom - d, d, d, 0, 90);
            path.AddArc(bounds.Left, bounds.Bottom - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }

        public static void FillRounded(Graphics g, Rectangle bounds, int radius, Color fill, Color? border = null)
        {
            using GraphicsPath path = RoundedRect(bounds, radius);
            using var brush = new SolidBrush(fill);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.FillPath(brush, path);
            if (border.HasValue)
            {
                using var pen = new Pen(border.Value, 1f);
                g.DrawPath(pen, path);
            }
        }

        public static Label MakeLabel(string text, Font font, Color color, ContentAlignment align = ContentAlignment.TopLeft)
        {
            return new Label
            {
                Text = text,
                Font = font,
                ForeColor = color,
                AutoSize = false,
                TextAlign = align,
                BackColor = Color.Transparent
            };
        }
    }

    /// <summary>Panel with double buffering on, so custom painting does not flicker.</summary>
    internal class BufferedPanel : Panel
    {
        public BufferedPanel()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            DoubleBuffered = true;
            BackColor = Theme.Surface;
        }
    }

    /// <summary>
    /// A content card: white surface, 1px border, transparent-inheriting children.
    /// Square corners on purpose - rounded corners on a container whose children are square
    /// WinForms controls would show grey wedges, which looks worse than a clean rectangle.
    /// </summary>
    internal sealed class CardPanel : BufferedPanel
    {
        public CardPanel()
        {
            BackColor = Theme.Surface;
            Padding = new Padding(1);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            using var pen = new Pen(Theme.Border, 1f);
            e.Graphics.DrawRectangle(pen, 0, 0, Width - 1, Height - 1);
        }
    }
}
