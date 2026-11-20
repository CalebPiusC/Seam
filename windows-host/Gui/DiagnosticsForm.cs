using System;
using System.Drawing;
using System.Threading.Tasks;
using System.Windows.Forms;
using Seam.WindowsHost.Host;

namespace Seam.WindowsHost.Gui
{
    /// <summary>
    /// Shows exactly what <c>seam-host.exe --diagnose</c> prints, built by the same code.
    /// Read-only, copyable, and safe to attach to a bug report: the pairing key appears only
    /// as a SHA-256 fingerprint.
    /// </summary>
    internal sealed class DiagnosticsForm : Form
    {
        private readonly TextBox _output = new();
        private readonly Label _status = Theme.MakeLabel("Collecting information...", Theme.Small, Theme.TextTertiary);
        private readonly PillButton _copy = new() { Text = "Copy", Kind = ButtonKind.Secondary };
        private readonly PillButton _close = new() { Text = "Close", Kind = ButtonKind.Primary };

        public DiagnosticsForm()
        {
            SuspendLayout();

            Text = "SEAM diagnostics";
            StartPosition = FormStartPosition.CenterParent;
            MinimizeBox = false;
            ShowInTaskbar = false;
            BackColor = Theme.Surface;
            Font = Theme.Body;
            ClientSize = new Size(760, 560);
            MinimumSize = new Size(560, 400);

            var root = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 1,
                RowCount = 4,
                Padding = new Padding(16, 14, 16, 14),
                BackColor = Color.Transparent
            };
            root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 22f));
            root.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 24f));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 40f));

            root.Controls.Add(Theme.MakeLabel(
                "Read-only report. It never contains your pairing key - only a fingerprint.",
                Theme.Small, Theme.TextTertiary, ContentAlignment.MiddleLeft), 0, 0);

            _output.Multiline = true;
            _output.ReadOnly = true;
            _output.ScrollBars = ScrollBars.Both;
            _output.WordWrap = false;
            _output.Font = Theme.Mono;
            _output.BackColor = Theme.SurfaceMuted;
            _output.ForeColor = Theme.TextPrimary;
            _output.BorderStyle = BorderStyle.FixedSingle;
            _output.Dock = DockStyle.Fill;
            _output.Margin = new Padding(0, 6, 0, 6);
            root.Controls.Add(_output, 0, 1);

            _status.Dock = DockStyle.Fill;
            root.Controls.Add(_status, 0, 2);

            var buttonRow = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 3,
                RowCount = 1,
                Margin = Padding.Empty,
                BackColor = Color.Transparent
            };
            buttonRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
            buttonRow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 100f));
            buttonRow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 100f));

            _copy.Dock = DockStyle.Fill;
            _copy.Margin = new Padding(0, 3, 8, 3);
            _close.Dock = DockStyle.Fill;
            _close.Margin = new Padding(0, 3, 0, 3);
            _copy.Click += (_, _) => CopyReport();
            _close.Click += (_, _) => Close();

            buttonRow.Controls.Add(new Panel { Dock = DockStyle.Fill, BackColor = Color.Transparent }, 0, 0);
            buttonRow.Controls.Add(_copy, 1, 0);
            buttonRow.Controls.Add(_close, 2, 0);
            root.Controls.Add(buttonRow, 0, 3);

            Controls.Add(root);

            ResumeLayout(true);
            Shown += (_, _) => LoadReportAsync();
        }

        private void LoadReportAsync()
        {
            Task.Run(() =>
            {
                string text;
                try
                {
                    text = DiagnosticsReport.Build(null, null, out bool ok);
                    if (!ok)
                    {
                        text = text.Replace("RESULT: a required resource is missing (see FAIL above).",
                            "RESULT: a required resource is missing (see FAIL above).\r\nReinstall SEAM to restore the bundled files.");
                    }
                }
                catch (Exception ex)
                {
                    text = "Diagnostics failed: " + ex.Message;
                }

                if (IsDisposed)
                {
                    return;
                }

                try
                {
                    BeginInvoke(new Action(() =>
                    {
                        if (IsDisposed)
                        {
                            return;
                        }
                        _output.Text = text.Replace("\n", "\r\n");
                        _output.SelectionStart = 0;
                        _status.Text = "Generated " + DateTime.Now.ToString("HH:mm:ss") + " - copy this into a bug report.";
                    }));
                }
                catch (ObjectDisposedException) { }
                catch (InvalidOperationException) { }
            });
        }

        private void CopyReport()
        {
            try
            {
                if (!string.IsNullOrEmpty(_output.Text))
                {
                    Clipboard.SetText(_output.Text);
                    _status.Text = "Copied to the clipboard.";
                }
            }
            catch
            {
                _status.Text = "Could not access the clipboard.";
            }
        }
    }
}
