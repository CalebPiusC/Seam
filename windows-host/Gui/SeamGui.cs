using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Threading;
using System.Windows.Forms;
using Seam.WindowsHost.Host;

namespace Seam.WindowsHost.Gui
{
    /// <summary>
    /// Entry points for the desktop application. Kept separate from <c>Program</c> so the CLI
    /// paths stay readable and the UI never runs unless it is asked for.
    /// </summary>
    internal static class SeamGui
    {
        /// <summary>Normal start: shows the window and runs the message loop.</summary>
        public static int Run()
        {
            try
            {
                Configure();
                using var form = new MainForm(UiSettings.Load(), interactive: true);
                Application.Run(form);
                return 0;
            }
            catch (Exception ex)
            {
                try
                {
                    MessageBox.Show(
                        "SEAM could not start its window.\r\n\r\n" + ex.Message +
                        "\r\n\r\nRun \"seam-host.exe --diagnose\" in a terminal for details.",
                        "SEAM", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
                catch
                {
                    // No window station (e.g. a service context): fall through to the exit code.
                }
                return 1;
            }
        }

        /// <summary>
        /// Headless smoke test used by CI: builds the real window, forces layout, optionally
        /// renders it to a PNG, and exits without entering the message loop. Proves the UI
        /// initialises on a machine with no phone attached.
        /// </summary>
        public static int RunSmoke(string? screenshotPath)
        {
            try
            {
                Configure();
                using var form = new MainForm(UiSettings.Load(), interactive: false);
                form.StartPosition = FormStartPosition.Manual;
                form.Location = new Point(0, 0);

                _ = form.Handle;          // create the native window
                form.CreateControl();
                form.PerformLayout();
                Application.DoEvents();

                int controls = CountControls(form);
                if (controls < 20)
                {
                    Console.Error.WriteLine($"UI smoke test FAILED: only {controls} controls were created.");
                    return 2;
                }

                if (!string.IsNullOrEmpty(screenshotPath))
                {
                    form.Show();
                    Application.DoEvents();
                    Thread.Sleep(300);
                    Application.DoEvents();

                    using var bitmap = new Bitmap(form.Width, form.Height, PixelFormat.Format32bppArgb);
                    form.DrawToBitmap(bitmap, new Rectangle(0, 0, form.Width, form.Height));
                    bitmap.Save(screenshotPath!, ImageFormat.Png);

                    form.Hide();
                    Console.WriteLine($"UI screenshot written: {screenshotPath} ({bitmap.Width}x{bitmap.Height})");
                }

                Console.WriteLine($"UI smoke test OK: window created, {controls} controls, state=Disconnected, no console window.");
                return 0;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("UI smoke test FAILED: " + ex);
                return 1;
            }
        }

        private static void Configure()
        {
            try
            {
                Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
            }
            catch
            {
                // The manifest already declares per-monitor-v2; a host that rejects the call is fine.
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            Application.ThreadException += (_, e) =>
            {
                try
                {
                    MessageBox.Show("SEAM hit an unexpected error:\r\n\r\n" + e.Exception.Message,
                        "SEAM", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
                catch
                {
                    // Ignore: already in a failing state.
                }
            };
        }

        private static int CountControls(Control root)
        {
            int count = 1;
            foreach (Control child in root.Controls)
            {
                count += CountControls(child);
            }
            return count;
        }
    }
}
