using System;
using System.Drawing;
using System.Windows.Forms;

namespace Seam.WindowsHost.Gui
{
    /// <summary>
    /// Read-only arrangement diagram: a PC tile and a phone tile placed on the screen edge the
    /// user picked in Settings, with the tile that currently owns the pointer drawn in the
    /// accent colour.
    ///
    /// It reflects real state only — <see cref="Edge"/>, <see cref="IsConnected"/> and
    /// <see cref="RoutingToPhone"/> all come from the live session. Nothing here is clickable:
    /// the edge is changed in Settings, so the diagram must not pretend to be a control.
    /// </summary>
    internal sealed class ArrangementPanel : Control
    {
        private string _edge = "right";
        private bool _connected;
        private bool _routingToPhone;

        public ArrangementPanel()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Surface;
            AccessibleName = "Arrangement";
        }

        /// <summary>Screen edge the phone sits on: right, left, top or bottom.</summary>
        public string Edge
        {
            get => _edge;
            set
            {
                string normalized = (value ?? "right").Trim().ToLowerInvariant();
                if (normalized != "left" && normalized != "top" && normalized != "bottom")
                {
                    normalized = "right";
                }

                if (_edge == normalized)
                {
                    return;
                }

                _edge = normalized;
                Invalidate();
            }
        }

        public bool IsConnected
        {
            get => _connected;
            set { if (_connected != value) { _connected = value; Invalidate(); } }
        }

        public bool RoutingToPhone
        {
            get => _routingToPhone;
            set { if (_routingToPhone != value) { _routingToPhone = value; Invalidate(); } }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;

            using (var background = new SolidBrush(Theme.Surface))
            {
                g.FillRectangle(background, ClientRectangle);
            }

            const int MacWidth = 132;
            const int MacHeight = 82;
            const int PhoneLong = 64;
            const int PhoneShort = 34;
            const int Gap = 12;

            bool verticalPhone = _edge == "left" || _edge == "right";
            Size phone = verticalPhone ? new Size(PhoneShort, PhoneLong) : new Size(PhoneLong, PhoneShort);

            int groupWidth = verticalPhone ? MacWidth + Gap + phone.Width : Math.Max(MacWidth, phone.Width);
            int groupHeight = verticalPhone ? Math.Max(MacHeight, phone.Height) : MacHeight + Gap + phone.Height;

            int originX = (ClientSize.Width - groupWidth) / 2;
            int originY = (ClientSize.Height - groupHeight) / 2;

            Rectangle mac;
            Rectangle phoneRect;
            switch (_edge)
            {
                case "left":
                    mac = new Rectangle(originX + phone.Width + Gap, originY + (groupHeight - MacHeight) / 2, MacWidth, MacHeight);
                    phoneRect = new Rectangle(originX, originY + (groupHeight - phone.Height) / 2, phone.Width, phone.Height);
                    break;
                case "top":
                    phoneRect = new Rectangle(originX + (groupWidth - phone.Width) / 2, originY, phone.Width, phone.Height);
                    mac = new Rectangle(originX + (groupWidth - MacWidth) / 2, originY + phone.Height + Gap, MacWidth, MacHeight);
                    break;
                case "bottom":
                    mac = new Rectangle(originX + (groupWidth - MacWidth) / 2, originY, MacWidth, MacHeight);
                    phoneRect = new Rectangle(originX + (groupWidth - phone.Width) / 2, originY + MacHeight + Gap, phone.Width, phone.Height);
                    break;
                default:
                    mac = new Rectangle(originX, originY + (groupHeight - MacHeight) / 2, MacWidth, MacHeight);
                    phoneRect = new Rectangle(originX + MacWidth + Gap, originY + (groupHeight - phone.Height) / 2, phone.Width, phone.Height);
                    break;
            }

            bool pcActive = _connected && !_routingToPhone;
            bool phoneActive = _connected && _routingToPhone;

            PaintMac(g, mac, pcActive);
            PaintPhone(g, phoneRect, phoneActive, _connected);
        }

        private static void PaintMac(Graphics g, Rectangle bounds, bool active)
        {
            Color fill = active ? Blend(Theme.Accent, Theme.Surface, 0.82f) : Theme.SurfaceRaised;
            Color border = active ? Theme.Accent : Theme.Border;
            Theme.FillRounded(g, bounds, 10, fill, border);

            // Screen: a lighter inset rectangle, then the hinge bar underneath.
            Rectangle screen = new(bounds.X + 16, bounds.Y + 14, bounds.Width - 32, bounds.Height - 34);
            Theme.FillRounded(g, screen, 5, active ? Color.FromArgb(38, 255, 255, 255) : Theme.SurfaceMuted, null);

            Rectangle hinge = new(bounds.X + 8, screen.Bottom + 6, bounds.Width - 16, 4);
            Theme.FillRounded(g, hinge, 2, active ? Theme.Accent : Theme.BorderStrong, null);

            var label = new Rectangle(bounds.X, bounds.Bottom - 20, bounds.Width, 16);
            TextRenderer.DrawText(g, "This PC", Theme.Caption, label,
                active ? Theme.TextPrimary : Theme.TextTertiary,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);

            if (active)
            {
                FillDot(g, bounds.Right - 14, bounds.Top + 14);
            }
        }

        private static void PaintPhone(Graphics g, Rectangle bounds, bool active, bool connected)
        {
            Color fill = active ? Blend(Theme.Accent, Theme.Surface, 0.82f)
                       : connected ? Theme.SurfaceRaised
                       : Blend(Theme.SurfaceRaised, Theme.Surface, 0.5f);
            Color border = active ? Theme.Accent : connected ? Theme.BorderStrong : Theme.Border;

            Theme.FillRounded(g, bounds, 8, fill, border);

            bool vertical = bounds.Height >= bounds.Width;
            Rectangle speaker = vertical
                ? new(bounds.X + bounds.Width / 2 - 6, bounds.Y + 7, 12, 2)
                : new(bounds.X + 7, bounds.Y + bounds.Height / 2 - 6, 2, 12);
            Theme.FillRounded(g, speaker, 1,
                active ? Theme.Accent : connected ? Theme.BorderStrong : Theme.TextTertiary, null);

            if (active)
            {
                FillDot(g, bounds.Right - 12, bounds.Top + 12);
            }
        }

        private static void FillDot(Graphics g, int centerX, int centerY)
        {
            using var brush = new SolidBrush(Theme.TextPrimary);
            g.FillEllipse(brush, centerX - 3, centerY - 3, 6, 6);
        }

        /// <summary>Mixes <paramref name="fore"/> over <paramref name="back"/> at the given share.</summary>
        private static Color Blend(Color fore, Color back, float amount)
        {
            amount = Math.Max(0f, Math.Min(1f, amount));
            return Color.FromArgb(
                (int)Math.Round((fore.R * amount) + (back.R * (1 - amount))),
                (int)Math.Round((fore.G * amount) + (back.G * (1 - amount))),
                (int)Math.Round((fore.B * amount) + (back.B * (1 - amount))));
        }
    }
}
