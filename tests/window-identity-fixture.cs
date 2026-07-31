using System;
using System.Drawing;
using System.Windows.Forms;

internal sealed class WindowIdentityFixture : ApplicationContext
{
    private readonly Timer timer;
    private Form window;
    private int step;

    internal WindowIdentityFixture()
    {
        ShowWindow("Stable Identity Alpha");
        timer = new Timer { Interval = 8000 };
        timer.Tick += OnTick;
        timer.Start();
    }

    private void OnTick(object sender, EventArgs eventArgs)
    {
        step++;
        switch (step)
        {
            case 1:
                // Same HWND, different title: OBS must not be retargeted.
                window.Text = "Transient Title Beta";
                window.Activate();
                break;
            case 2:
                // Same process, new HWND: capture must retarget but keep the
                // original inferred game/folder identity.
                Form previousWindow = window;
                ShowWindow("Replacement Window Gamma");
                previousWindow.Hide();
                previousWindow.Dispose();
                break;
            case 3:
                // The replacement HWND must also ignore title-only changes.
                window.Text = "Transient Title Delta";
                window.Activate();
                break;
            default:
                timer.Stop();
                window.Hide();
                window.Dispose();
                ExitThread();
                break;
        }
    }

    private void ShowWindow(string title)
    {
        window = new Form
        {
            Text = title,
            WindowState = FormWindowState.Maximized,
            StartPosition = FormStartPosition.CenterScreen,
            BackColor = Color.FromArgb(32, 48, 64),
            ShowInTaskbar = true,
        };
        window.Shown += delegate { window.Activate(); };
        window.Show();
        window.Activate();
    }

    [STAThread]
    private static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new WindowIdentityFixture());
    }
}
