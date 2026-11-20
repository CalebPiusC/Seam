using System;
using System.Drawing;
using System.Windows.Forms;
using Seam.WindowsHost.Host;

namespace Seam.WindowsHost.Gui
{
    /// <summary>
    /// Basic preferences. Everything here is a UI/behaviour choice; none of it touches the
    /// pairing key, the protocol or the agent.
    /// </summary>
    internal sealed class SettingsForm : Form
    {
        private readonly ComboBox _edge = new();
        private readonly CheckBox _routingOnConnect = new();
        private readonly CheckBox _autoConnect = new();
        private readonly NumericUpDown _maxLines = new();

        public SettingsForm(UiSettings settings)
        {
            SuspendLayout();

            Text = "SEAM settings";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            StartPosition = FormStartPosition.CenterParent;
            MaximizeBox = false;
            MinimizeBox = false;
            ShowInTaskbar = false;
            BackColor = Theme.Surface;
            Font = Theme.Body;
            ClientSize = new Size(440, 396);

            var grid = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 1,
                RowCount = 9,
                Padding = new Padding(22, 18, 22, 16),
                BackColor = Color.Transparent
            };
            grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
            grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 22f));  // INPUT
            grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 58f));  // edge
            grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 34f));  // routing on connect
            grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 16f));  // gap
            grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 22f));  // CONNECTION
            grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 34f));  // auto connect
            grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 16f));  // gap
            grid.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));  // ACTIVITY
            grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 40f));  // buttons

            Label inputSection = SectionLabel("INPUT");
            grid.Controls.Add(inputSection, 0, 0);

            var edgePanel = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 2,
                RowCount = 2,
                Margin = Padding.Empty,
                BackColor = Color.Transparent
            };
            edgePanel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 150f));
            edgePanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
            edgePanel.RowStyles.Add(new RowStyle(SizeType.Absolute, 22f));
            edgePanel.RowStyles.Add(new RowStyle(SizeType.Absolute, 30f));

            Label edgeHint = Theme.MakeLabel("Where the pointer hands over to the phone.", Theme.Small, Theme.TextTertiary, ContentAlignment.MiddleLeft);
            Label edgeLabel = Theme.MakeLabel("Screen edge", Theme.Body, Theme.TextPrimary, ContentAlignment.MiddleLeft);
            edgePanel.Controls.Add(edgeHint, 0, 0);
            edgePanel.SetColumnSpan(edgeHint, 2);
            edgePanel.Controls.Add(edgeLabel, 0, 1);

            _edge.DropDownStyle = ComboBoxStyle.DropDownList;
            _edge.FlatStyle = FlatStyle.System;
            _edge.Font = Theme.Body;
            _edge.Dock = DockStyle.Fill;
            _edge.Margin = new Padding(0, 1, 0, 1);
            _edge.Items.AddRange(new object[] { "right", "left", "top", "bottom" });
            _edge.SelectedItem = settings.Edge;
            if (_edge.SelectedIndex < 0)
            {
                _edge.SelectedIndex = 0;
            }
            edgePanel.Controls.Add(_edge, 1, 1);
            grid.Controls.Add(edgePanel, 0, 1);

            _routingOnConnect.Text = "Start sharing input when a session connects";
            StyleCheckBox(_routingOnConnect);
            _routingOnConnect.Checked = settings.RoutingOnConnect;
            grid.Controls.Add(_routingOnConnect, 0, 2);

            grid.Controls.Add(new Panel { Dock = DockStyle.Fill, BackColor = Color.Transparent, Margin = Padding.Empty }, 0, 3);

            grid.Controls.Add(SectionLabel("CONNECTION"), 0, 4);

            _autoConnect.Text = "Connect automatically when an authorised phone appears";
            StyleCheckBox(_autoConnect);
            _autoConnect.Checked = settings.AutoConnect;
            grid.Controls.Add(_autoConnect, 0, 5);

            grid.Controls.Add(new Panel { Dock = DockStyle.Fill, BackColor = Color.Transparent, Margin = Padding.Empty }, 0, 6);

            var activityPanel = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 2,
                RowCount = 2,
                Margin = Padding.Empty,
                BackColor = Color.Transparent
            };
            activityPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 150f));
            activityPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
            activityPanel.RowStyles.Add(new RowStyle(SizeType.Absolute, 22f));
            activityPanel.RowStyles.Add(new RowStyle(SizeType.Absolute, 30f));
            Label activitySection = SectionLabel("ACTIVITY");
            activityPanel.Controls.Add(activitySection, 0, 0);
            activityPanel.SetColumnSpan(activitySection, 2);
            activityPanel.Controls.Add(Theme.MakeLabel("Lines kept", Theme.Body, Theme.TextPrimary, ContentAlignment.MiddleLeft), 0, 1);

            _maxLines.Minimum = 50;
            _maxLines.Maximum = 5000;
            _maxLines.Increment = 50;
            _maxLines.Value = Math.Min(5000, Math.Max(50, settings.MaxLogLines));
            _maxLines.Font = Theme.Body;
            _maxLines.Dock = DockStyle.Left;
            _maxLines.Width = 90;
            activityPanel.Controls.Add(_maxLines, 1, 1);
            grid.Controls.Add(activityPanel, 0, 7);

            var buttonRow = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 3,
                RowCount = 1,
                Margin = Padding.Empty,
                BackColor = Color.Transparent
            };
            buttonRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
            buttonRow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 96f));
            buttonRow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 96f));

            var cancel = new PillButton { Text = "Cancel", Kind = ButtonKind.Secondary, Dock = DockStyle.Fill, Margin = new Padding(0, 2, 8, 2) };
            var save = new PillButton { Text = "Save", Kind = ButtonKind.Primary, Dock = DockStyle.Fill, Margin = new Padding(0, 2, 0, 2) };
            cancel.Click += (_, _) => { DialogResult = DialogResult.Cancel; Close(); };
            save.Click += (_, _) => { DialogResult = DialogResult.OK; Close(); };

            buttonRow.Controls.Add(new Panel { Dock = DockStyle.Fill, BackColor = Color.Transparent }, 0, 0);
            buttonRow.Controls.Add(cancel, 1, 0);
            buttonRow.Controls.Add(save, 2, 0);
            grid.Controls.Add(buttonRow, 0, 8);

            Controls.Add(grid);

            ResumeLayout(true);
            Shown += (_, _) => _edge.Focus();
        }

        /// <summary>Applies the chosen values back onto the caller's settings object.</summary>
        public void ApplyTo(UiSettings settings)
        {
            settings.Edge = _edge.SelectedItem as string ?? "right";
            settings.RoutingOnConnect = _routingOnConnect.Checked;
            settings.AutoConnect = _autoConnect.Checked;
            settings.MaxLogLines = (int)_maxLines.Value;
            settings.Normalize();
        }

        private static Label SectionLabel(string text)
        {
            Label label = Theme.MakeLabel(text, Theme.Section, Theme.TextTertiary, ContentAlignment.MiddleLeft);
            label.Dock = DockStyle.Fill;
            return label;
        }

        private static void StyleCheckBox(CheckBox box)
        {
            box.Font = Theme.Body;
            box.ForeColor = Theme.TextPrimary;
            box.BackColor = Color.Transparent;
            box.AutoSize = true;
            box.Dock = DockStyle.Fill;
            box.Margin = new Padding(0, 4, 0, 4);
        }
    }
}
