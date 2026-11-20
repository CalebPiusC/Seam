using System;
using System.Collections.Generic;
using System.Drawing;
using System.Threading.Tasks;
using System.Windows.Forms;
using Seam.WindowsHost.Bootstrap;
using Seam.WindowsHost.Host;

namespace Seam.WindowsHost.Gui
{
    /// <summary>
    /// The SEAM desktop window.
    ///
    /// It is a thin view over <see cref="SessionController"/>: every connection, bootstrap and
    /// input-routing action goes through the controller, which uses the same primer types the
    /// (hardware-verified) console mode uses. The window itself only renders state and forwards
    /// clicks, so no protocol or control logic lives here.
    /// </summary>
    internal sealed class MainForm : Form
    {
        private readonly UiSettings _settings;
        private readonly SessionController _session;
        private readonly bool _interactive;

        private readonly System.Windows.Forms.Timer _hookTimer = new() { Interval = 250 };
        private readonly System.Windows.Forms.Timer _pollTimer = new() { Interval = 2500 };

        private bool _polling;
        private bool _shuttingDown;
        private AdbDevice? _device;
        private string? _autoConnectSerial;

        // ---- controls ----
        private readonly StatusPill _pill = new();
        private readonly PillButton _btnSettings = new();
        private readonly PillButton _btnDiagnostics = new();
        private readonly PillButton _btnConnect = new();
        private readonly PillButton _btnDisconnect = new();
        private readonly PillButton _btnRefresh = new();
        private readonly PillButton _btnToggleRouting = new();
        private readonly PillButton _btnCopyLog = new();
        private readonly PillButton _btnClearLog = new();
        private readonly Label _lblDeviceModel = Theme.MakeLabel("", Theme.Heading, Theme.TextPrimary);
        private readonly Label _lblDeviceMeta = Theme.MakeLabel("", Theme.Small, Theme.TextSecondary);
        private readonly Label _lblDeviceHint = Theme.MakeLabel("", Theme.Small, Theme.TextTertiary);
        private readonly Label _lblRoutingOwner = Theme.MakeLabel("Windows", Theme.Heading, Theme.TextPrimary);
        private readonly Label _lblRoutingHint = Theme.MakeLabel("", Theme.Small, Theme.TextSecondary);
        private readonly Label _lblStats = Theme.MakeLabel("", Theme.Small, Theme.TextTertiary);
        private readonly Label _lblFooterLeft = Theme.MakeLabel("", Theme.Small, Theme.TextTertiary);
        private readonly Label _lblFooterRight = Theme.MakeLabel("Ctrl + Alt + Q returns control to Windows",
            Theme.BodyStrong, Theme.Accent, ContentAlignment.MiddleRight);
        private readonly LogView _log = new();
        private readonly Label _logPlaceholder = Theme.MakeLabel(
            "Connection activity will appear here.",
            Theme.Body, Theme.TextTertiary, ContentAlignment.MiddleCenter);
        private readonly AlertBanner _banner = new();

        public MainForm(UiSettings settings, bool interactive)
        {
            _settings = settings ?? new UiSettings();
            _settings.Normalize();
            _interactive = interactive;
            _log.MaxEntries = _settings.MaxLogLines;
            _session = new SessionController(_settings);

            SuspendLayout();
            Text = "SEAM";
            BackColor = Theme.Background;
            ForeColor = Theme.TextPrimary;
            Font = Theme.Body;
            AutoScaleMode = AutoScaleMode.Dpi;
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(1000, 680);
            MinimumSize = new Size(880, 600);
            DoubleBuffered = true;
            ApplyIcon();

            BuildUi();
            WireEvents();

            _session.Initialize();
            ApplyState(_session.State, _session.Detail);
            ApplyDevices(_session.Devices);
            AppendLog("SEAM " + Host.DiagnosticsReport.VersionString + " ready.", LogLevel.Good);

            if (_interactive)
            {
                _hookTimer.Tick += (_, _) => OnHookTick();
                _pollTimer.Tick += (_, _) => RefreshDevicesAsync();
                _hookTimer.Start();
                _pollTimer.Start();
                Shown += (_, _) => RefreshDevicesAsync();
            }

            ResumeLayout(true);
        }

        private void ApplyIcon()
        {
            try
            {
                Icon? icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
                if (icon != null)
                {
                    Icon = icon;
                }
            }
            catch
            {
                // The embedded icon is a nicety; a missing one must not stop the window.
            }
        }

        // ---- layout ------------------------------------------------------------------

        private void BuildUi()
        {
            var root = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                BackColor = Theme.Background,
                ColumnCount = 1,
                RowCount = 4,
                Margin = Padding.Empty,
                Padding = Padding.Empty
            };
            root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 68f));  // header
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));       // alert banner
            root.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));  // content
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 36f));  // footer

            root.Controls.Add(BuildHeader(), 0, 0);
            _banner.Dock = DockStyle.Top;
            _banner.Margin = new Padding(20, 0, 20, 10);
            root.Controls.Add(_banner, 0, 1);
            root.Controls.Add(BuildContent(), 0, 2);
            root.Controls.Add(BuildFooter(), 0, 3);
            Controls.Add(root);
        }

        private Control BuildHeader()
        {
            var header = new BufferedPanel
            {
                Dock = DockStyle.Fill,
                BackColor = Theme.Surface,
                Margin = Padding.Empty,
                Padding = Padding.Empty
            };
            header.Paint += (_, e) =>
            {
                using var pen = new Pen(Theme.Border, 1f);
                e.Graphics.DrawLine(pen, 0, header.Height - 1, header.Width, header.Height - 1);
            };

            var logo = new PictureBox
            {
                Location = new Point(20, 18),
                Size = new Size(32, 32),
                SizeMode = PictureBoxSizeMode.Zoom,
                BackColor = Color.Transparent
            };
            try
            {
                Icon? icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
                if (icon != null)
                {
                    logo.Image = icon.ToBitmap();
                }
            }
            catch
            {
                // Rendered as an empty square instead; not worth failing the window over.
            }

            var title = Theme.MakeLabel("SEAM", Theme.Title, Theme.TextPrimary);
            title.SetBounds(64, 13, 200, 28);

            var subtitle = Theme.MakeLabel("Mouse and keyboard sharing", Theme.Small, Theme.TextSecondary);
            subtitle.SetBounds(66, 40, 260, 18);

            _pill.State = SessionState.Disconnected;
            _pill.Label = StatusPill.LabelFor(SessionState.Disconnected);
            _pill.Location = new Point(196, 21);
            _pill.Anchor = AnchorStyles.Top | AnchorStyles.Left;

            _btnSettings.Kind = ButtonKind.Ghost;
            _btnSettings.Font = Theme.Small;
            _btnSettings.Height = 28;
            _btnSettings.Text = "Settings";
            _btnSettings.Anchor = AnchorStyles.Top | AnchorStyles.Right;

            _btnDiagnostics.Kind = ButtonKind.Ghost;
            _btnDiagnostics.Font = Theme.Small;
            _btnDiagnostics.Height = 28;
            _btnDiagnostics.Text = "Diagnostics";
            _btnDiagnostics.Anchor = AnchorStyles.Top | AnchorStyles.Right;

            header.Controls.Add(logo);
            header.Controls.Add(title);
            header.Controls.Add(subtitle);
            header.Controls.Add(_pill);
            header.Controls.Add(_btnDiagnostics);
            header.Controls.Add(_btnSettings);

            header.Resize += (_, _) =>
            {
                _btnSettings.Location = new Point(header.Width - _btnSettings.Width - 18, 20);
                _btnDiagnostics.Location = new Point(_btnSettings.Left - _btnDiagnostics.Width - 6, 20);
            };
            header.HandleCreated += (_, _) => header.PerformLayout();

            return header;
        }

        private Control BuildContent()
        {
            var content = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                BackColor = Theme.Background,
                ColumnCount = 2,
                RowCount = 1,
                Margin = Padding.Empty,
                Padding = new Padding(20, 16, 20, 12)
            };
            content.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 388f));
            content.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
            content.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));

            content.Controls.Add(BuildLeftColumn(), 0, 0);
            content.Controls.Add(BuildActivityCard(), 1, 0);
            return content;
        }

        private Control BuildLeftColumn()
        {
            var left = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                BackColor = Theme.Background,
                ColumnCount = 1,
                RowCount = 4,
                Margin = new Padding(0, 0, 16, 0),
                Padding = Padding.Empty
            };
            left.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
            left.RowStyles.Add(new RowStyle(SizeType.Absolute, 246f));
            left.RowStyles.Add(new RowStyle(SizeType.Absolute, 12f));
            left.RowStyles.Add(new RowStyle(SizeType.Absolute, 214f));
            left.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));

            left.Controls.Add(BuildDeviceCard(), 0, 0);
            left.Controls.Add(BuildRoutingCard(), 0, 2);
            return left;
        }

        private Control BuildDeviceCard()
        {
            var card = new CardPanel { Dock = DockStyle.Fill, Margin = Padding.Empty };
            var grid = CardGrid(5);

            var headingRow = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 2,
                RowCount = 1,
                Margin = Padding.Empty,
                BackColor = Color.Transparent
            };
            headingRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
            headingRow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 76f));
            headingRow.Controls.Add(SectionLabel("DEVICE"), 0, 0);

            _btnRefresh.Kind = ButtonKind.Ghost;
            _btnRefresh.Font = Theme.Small;
            _btnRefresh.Height = 22;
            _btnRefresh.Text = "Refresh";
            _btnRefresh.Dock = DockStyle.Fill;
            _btnRefresh.Margin = Padding.Empty;
            headingRow.Controls.Add(_btnRefresh, 1, 0);

            _lblDeviceModel.Dock = DockStyle.Fill;
            _lblDeviceMeta.Dock = DockStyle.Fill;
            _lblDeviceHint.Dock = DockStyle.Fill;

            var buttonRow = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 3,
                RowCount = 1,
                Margin = Padding.Empty,
                BackColor = Color.Transparent
            };
            buttonRow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 124f));
            buttonRow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 116f));
            buttonRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));

            _btnConnect.Kind = ButtonKind.Primary;
            _btnConnect.Text = "Connect";
            _btnConnect.Height = 34;
            _btnConnect.Dock = DockStyle.Fill;
            _btnConnect.Margin = new Padding(0, 0, 8, 0);

            _btnDisconnect.Text = "Disconnect";
            _btnDisconnect.Height = 34;
            _btnDisconnect.Dock = DockStyle.Fill;
            _btnDisconnect.Margin = Padding.Empty;

            buttonRow.Controls.Add(_btnConnect, 0, 0);
            buttonRow.Controls.Add(_btnDisconnect, 1, 0);

            grid.Controls.Add(headingRow, 0, 0);
            grid.Controls.Add(_lblDeviceModel, 0, 1);
            grid.Controls.Add(_lblDeviceMeta, 0, 2);
            grid.Controls.Add(_lblDeviceHint, 0, 3);
            grid.Controls.Add(buttonRow, 0, 4);

            card.Controls.Add(grid);
            return card;
        }

        private Control BuildRoutingCard()
        {
            var card = new CardPanel { Dock = DockStyle.Fill, Margin = Padding.Empty };
            var grid = CardGrid(5);

            _lblRoutingOwner.Dock = DockStyle.Fill;
            _lblRoutingHint.Dock = DockStyle.Fill;
            _lblStats.Dock = DockStyle.Fill;

            _btnToggleRouting.Kind = ButtonKind.Primary;
            _btnToggleRouting.Text = "Enable input sharing";
            _btnToggleRouting.Height = 34;
            _btnToggleRouting.Dock = DockStyle.Fill;
            _btnToggleRouting.Margin = Padding.Empty;

            grid.Controls.Add(SectionLabel("INPUT ROUTING"), 0, 0);
            grid.Controls.Add(_lblRoutingOwner, 0, 1);
            grid.Controls.Add(_lblRoutingHint, 0, 2);
            grid.Controls.Add(_lblStats, 0, 3);
            grid.Controls.Add(_btnToggleRouting, 0, 4);

            card.Controls.Add(grid);
            return card;
        }

        private Control BuildActivityCard()
        {
            var card = new CardPanel { Dock = DockStyle.Fill, Margin = Padding.Empty };
            var grid = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 1,
                RowCount = 2,
                BackColor = Color.Transparent,
                Padding = new Padding(16, 12, 16, 12),
                Margin = Padding.Empty
            };
            grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
            grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 28f));
            grid.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));

            var headerRow = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 3,
                RowCount = 1,
                Margin = Padding.Empty,
                BackColor = Color.Transparent
            };
            headerRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
            headerRow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 60f));
            headerRow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 62f));
            headerRow.Controls.Add(SectionLabel("ACTIVITY"), 0, 0);

            _btnCopyLog.Kind = ButtonKind.Ghost;
            _btnCopyLog.Font = Theme.Small;
            _btnCopyLog.Height = 22;
            _btnCopyLog.Text = "Copy";
            _btnCopyLog.Dock = DockStyle.Fill;
            _btnCopyLog.Margin = Padding.Empty;
            headerRow.Controls.Add(_btnCopyLog, 1, 0);

            _btnClearLog.Kind = ButtonKind.Ghost;
            _btnClearLog.Font = Theme.Small;
            _btnClearLog.Height = 22;
            _btnClearLog.Text = "Clear";
            _btnClearLog.Dock = DockStyle.Fill;
            _btnClearLog.Margin = Padding.Empty;
            headerRow.Controls.Add(_btnClearLog, 2, 0);

            var logHost = new Panel { Dock = DockStyle.Fill, BackColor = Theme.Surface, Margin = new Padding(0, 6, 0, 0) };
            _log.Dock = DockStyle.Fill;
            _logPlaceholder.Dock = DockStyle.Fill;
            logHost.Controls.Add(_logPlaceholder);
            logHost.Controls.Add(_log);
            _logPlaceholder.BringToFront();

            grid.Controls.Add(headerRow, 0, 0);
            grid.Controls.Add(logHost, 0, 1);
            card.Controls.Add(grid);
            return card;
        }

        private Control BuildFooter()
        {
            var footer = new BufferedPanel
            {
                Dock = DockStyle.Fill,
                BackColor = Theme.SurfaceMuted,
                Margin = Padding.Empty
            };
            footer.Paint += (_, e) =>
            {
                using var pen = new Pen(Theme.Border, 1f);
                e.Graphics.DrawLine(pen, 0, 0, footer.Width, 0);
            };

            _lblFooterRight.Dock = DockStyle.Right;
            _lblFooterRight.Width = 300;
            _lblFooterLeft.Dock = DockStyle.Fill;
            _lblFooterLeft.Padding = new Padding(20, 0, 0, 0);
            _lblFooterLeft.TextAlign = ContentAlignment.MiddleLeft;

            footer.Controls.Add(_lblFooterLeft);
            footer.Controls.Add(_lblFooterRight);
            return footer;
        }

        private static Label SectionLabel(string text)
        {
            Label label = Theme.MakeLabel(text, Theme.Section, Theme.TextTertiary, ContentAlignment.MiddleLeft);
            label.Dock = DockStyle.Fill;
            return label;
        }

        private static TableLayoutPanel CardGrid(int rows)
        {
            var grid = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 1,
                RowCount = rows,
                BackColor = Color.Transparent,
                Padding = new Padding(18, 14, 18, 14),
                Margin = Padding.Empty
            };
            grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
            grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 24f));  // section label
            grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 32f));  // big value
            grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 20f));  // meta line
            grid.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));  // wrapped hint
            grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 40f));  // buttons
            return grid;
        }

        // ---- wiring ------------------------------------------------------------------

        private void WireEvents()
        {
            _session.Log += line => Post(() => AppendLog(line, LevelFor(line)));
            _session.StateChanged += (state, detail) => Post(() => ApplyState(state, detail));
            _session.DevicesChanged += devices => Post(() => ApplyDevices(devices));
            _session.DisplayInfoReceived += info => Post(() =>
                AppendLog($"DISPLAY_INFO {info.WidthPx}x{info.HeightPx} @ {info.DensityDpi} dpi", LogLevel.Info));

            _btnConnect.Click += (_, _) => Connect();
            _btnDisconnect.Click += (_, _) => _session.Disconnect();
            _btnRefresh.Click += (_, _) => RefreshDevicesAsync();
            _btnToggleRouting.Click += (_, _) => ToggleRouting();
            _btnSettings.Click += (_, _) => OpenSettings();
            _btnDiagnostics.Click += (_, _) => OpenDiagnostics();
            _btnCopyLog.Click += (_, _) => CopyLog();
            _btnClearLog.Click += (_, _) => { _log.Items.Clear(); UpdateLogPlaceholder(); };
            _banner.Dismissed += () => PerformLayout();
        }

        private void Post(Action action)
        {
            if (IsDisposed || _shuttingDown)
            {
                return;
            }

            try
            {
                if (InvokeRequired)
                {
                    BeginInvoke(action);
                }
                else
                {
                    action();
                }
            }
            catch (ObjectDisposedException) { }
            catch (InvalidOperationException) { }
        }

        private static LogLevel LevelFor(string line)
        {
            if (line.Contains("[Error]", StringComparison.OrdinalIgnoreCase) ||
                line.Contains("[FATAL]", StringComparison.OrdinalIgnoreCase))
            {
                return LogLevel.Error;
            }
            if (line.Contains("[Warn]", StringComparison.OrdinalIgnoreCase) ||
                line.Contains("[ERROR]", StringComparison.OrdinalIgnoreCase))
            {
                return LogLevel.Warn;
            }
            if (line.Contains("[Auth]", StringComparison.OrdinalIgnoreCase) ||
                line.Contains("Connected", StringComparison.OrdinalIgnoreCase))
            {
                return LogLevel.Good;
            }
            return LogLevel.Info;
        }

        private void AppendLog(string line, LogLevel level)
        {
            if (string.IsNullOrWhiteSpace(line))
            {
                return;
            }
            _log.Append(line, level);
            UpdateLogPlaceholder();
        }

        private void UpdateLogPlaceholder()
        {
            bool empty = _log.Items.Count == 0;
            _logPlaceholder.Visible = empty;
            if (empty)
            {
                _logPlaceholder.BringToFront();
            }
        }

        // ---- state -------------------------------------------------------------------

        private void ApplyState(SessionState state, string detail)
        {
            bool changed = state != _lastState;
            _lastState = state;

            _pill.State = state;
            _pill.Label = StatusPill.LabelFor(state);
            if (_pill.Parent != null)
            {
                // Keep the pill left-aligned next to the title; the label width changes per state.
                _pill.Left = 196;
            }

            switch (state)
            {
                case SessionState.Connected:
                    _banner.HideBanner();
                    break;
                case SessionState.Unauthorized:
                    _banner.ShowWarning(detail);
                    break;
                case SessionState.Error:
                    _banner.ShowError(detail);
                    break;
                case SessionState.Connecting:
                    _banner.HideBanner();
                    break;
                default:
                    if (!string.IsNullOrEmpty(detail) && detail.StartsWith("The phone disconnected", StringComparison.Ordinal))
                    {
                        _banner.ShowWarning(detail);
                    }
                    else
                    {
                        _banner.HideBanner();
                    }
                    break;
            }

            UpdateDeviceCard(detail);
            UpdateRoutingCard();
            UpdateFooter();
            UpdateButtons();

            if (changed)
            {
                PerformLayout();
            }
        }

        private void ApplyDevices(IReadOnlyList<AdbDevice> devices)
        {
            _device = null;
            for (int i = 0; i < devices.Count; i++)
            {
                if (devices[i].IsAuthorized)
                {
                    _device = devices[i];
                    break;
                }
            }
            if (_device == null && devices.Count > 0)
            {
                _device = devices[0];
            }

            UpdateDeviceCard(_session.Detail);
            UpdateButtons();

            // Optional auto-connect: once per newly seen authorised device.
            if (_settings.AutoConnect && _device != null && _device.IsAuthorized &&
                !_session.IsConnected && !_session.IsBusy &&
                !string.Equals(_autoConnectSerial, _device.Serial, StringComparison.Ordinal))
            {
                _autoConnectSerial = _device.Serial;
                Connect();
            }
            else if (_device == null)
            {
                _autoConnectSerial = null;
            }
        }

        private void UpdateDeviceCard(string detail)
        {
            IReadOnlyList<AdbDevice> devices = _session.Devices;

            if (_session.IsConnected && _device != null)
            {
                _lblDeviceModel.Text = SessionController.DeviceLabel(_device);
                _lblDeviceMeta.Text = _device.Serial + " · USB via ADB forward";
                _lblDeviceHint.Text = "Authenticated (mutual HMAC-SHA256) on " + (_session.Endpoint ?? "adb forward") + ".";
                return;
            }

            if (_session.State == SessionState.Connecting)
            {
                _lblDeviceModel.Text = _device != null ? SessionController.DeviceLabel(_device) : "Connecting...";
                _lblDeviceMeta.Text = _device?.Serial ?? "starting the agent";
                _lblDeviceHint.Text = "Pushing and starting the SEAM agent on the phone. This takes a few seconds the first time.";
                return;
            }

            if (devices.Count == 0)
            {
                _lblDeviceModel.Text = "No phone detected";
                _lblDeviceMeta.Text = _session.AdbPath == null ? "adb is missing" : "adb sees no device";
                _lblDeviceHint.Text =
                    "1. Enable Developer options → USB debugging on the phone.\n" +
                    "2. Plug the cable in and tap ALLOW on the phone.\n" +
                    "3. No prompt? Install the OEM ADB driver, or use Wireless debugging.";
                return;
            }

            AdbDevice device = _device ?? devices[0];
            _lblDeviceModel.Text = SessionController.DeviceLabel(device);
            _lblDeviceMeta.Text = device.Serial + " · " + (device.IsAuthorized ? "USB · authorised" : device.State);

            if (!device.IsAuthorized)
            {
                _lblDeviceHint.Text = string.IsNullOrEmpty(detail)
                    ? "Unlock the phone and tap ALLOW on the \"Allow USB debugging?\" prompt."
                    : detail;
            }
            else if (devices.Count > 1)
            {
                _lblDeviceHint.Text = devices.Count + " phones detected; Connect uses the first authorised one. " +
                                      "Unplug the others to choose a different phone.";
            }
            else
            {
                _lblDeviceHint.Text = "Ready. Press Connect to push the agent and start the session.";
            }
        }

        private void UpdateRoutingCard()
        {
            bool connected = _session.IsConnected;
            bool routing = _session.IsRouting;

            if (!connected)
            {
                _lblRoutingOwner.Text = "Windows";
                _lblRoutingHint.Text = "Control stays on Windows until a session is connected.";
                _lblStats.Text = "";
                _btnToggleRouting.SetText("Enable input sharing");
                return;
            }

            _lblRoutingOwner.Text = routing ? "Android phone" : "Windows";
            _lblRoutingHint.Text = routing
                ? "Move the pointer to the " + _settings.EdgeName + " edge to take control of the phone. Ctrl + Alt + Q returns control to Windows."
                : "Press Enable input sharing to arm the " + _settings.EdgeName + " edge. Windows input is unaffected until you cross it.";
            _lblStats.Text = $"sent {_session.FramesSent:n0} · recv {_session.FramesReceived:n0} · " +
                             $"input {_session.EventsForwarded:n0} · uptime {_session.SessionUptime:hh\\:mm\\:ss}";
            _btnToggleRouting.SetText(routing ? "Stop sharing input" : "Enable input sharing");
        }

        private void UpdateFooter()
        {
            string adb = _session.AdbPath == null
                ? "adb: missing"
                : "adb: " + (_session.AdbIsBundled ? "bundled" : "system");
            _lblFooterLeft.Text = "SEAM " + Host.DiagnosticsReport.VersionString + " · " + adb + " · " + _session.AppDirectory;
        }

        private void UpdateButtons()
        {
            bool connected = _session.IsConnected;
            bool busy = _session.IsBusy;
            bool deviceReady = _device != null && _device.IsAuthorized;

            _btnConnect.Enabled = !connected && !busy && deviceReady;
            _btnConnect.SetText(_settings.LastDeviceSerial != null ? "Reconnect" : "Connect");
            _btnDisconnect.Enabled = connected || busy;
            _btnRefresh.Enabled = !connected && !busy;
            _btnToggleRouting.Enabled = connected;
        }

        // ---- actions -----------------------------------------------------------------

        private void Connect()
        {
            AdbDevice? device = _device;
            if (device == null)
            {
                AppendLog("No phone to connect to. Plug the cable in and accept the prompt on the phone.", LogLevel.Warn);
                return;
            }
            _settings.Save();
            _session.Connect(device);
        }

        private void ToggleRouting()
        {
            if (_session.IsRouting)
            {
                _session.StopRouting();
                AppendLog("Input sharing stopped; control is on Windows.", LogLevel.Info);
            }
            else if (_session.StartRouting())
            {
                AppendLog("Input sharing armed on the " + _settings.EdgeName + " edge.", LogLevel.Info);
            }
            else
            {
                AppendLog("Could not arm input sharing. Try running SEAM as administrator.", LogLevel.Error);
            }
            UpdateRoutingCard();
            UpdateButtons();
        }

        private void RefreshDevicesAsync()
        {
            if (_polling || _shuttingDown)
            {
                return;
            }
            _polling = true;
            Task.Run(() =>
            {
                try
                {
                    _session.RefreshDevices();
                }
                finally
                {
                    _polling = false;
                }
            });
        }

        private void OnHookTick()
        {
            if (_shuttingDown)
            {
                return;
            }

            _session.PumpHooks();
            UpdateRoutingCard();
            UpdateButtons();
        }

        private void OpenSettings()
        {
            using var dialog = new SettingsForm(_settings);
            if (dialog.ShowDialog(this) != DialogResult.OK)
            {
                return;
            }

            dialog.ApplyTo(_settings);
            _log.MaxEntries = _settings.MaxLogLines;
            _settings.Normalize();
            _settings.Save();

            bool wasRouting = _session.IsRouting || _settings.RoutingOnConnect;
            if (wasRouting && _session.IsConnected)
            {
                _session.StopRouting();
                _session.StartRouting();
            }

            AppendLog("Settings saved (edge: " + _settings.EdgeName +
                      ", auto-connect: " + (_settings.AutoConnect ? "on" : "off") +
                      ", input sharing on connect: " + (_settings.RoutingOnConnect ? "on" : "off") + ").", LogLevel.Info);
            UpdateRoutingCard();
        }

        private void OpenDiagnostics()
        {
            using var dialog = new DiagnosticsForm();
            dialog.ShowDialog(this);
        }

        private void CopyLog()
        {
            try
            {
                string text = _log.AllText();
                if (!string.IsNullOrEmpty(text))
                {
                    Clipboard.SetText(text);
                }
            }
            catch
            {
                // Clipboard access can fail if another process holds it; not worth a dialog.
            }
        }

        // ---- lifecycle ----------------------------------------------------------------

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            _shuttingDown = true;
            _hookTimer.Stop();
            _pollTimer.Stop();

            try
            {
                // Removes the low-level hooks, closes the TCP session and stops the reader.
                _session.Dispose();
            }
            catch
            {
                // Shutdown must complete even if a component is already gone.
            }

            base.OnFormClosing(e);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                _hookTimer.Dispose();
                _pollTimer.Dispose();
                if (!_shuttingDown)
                {
                    try { _session.Dispose(); } catch { }
                }
            }
            base.Dispose(disposing);
        }
    }
}
