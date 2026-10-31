using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

internal sealed class HookPolicyWindow : Form
{
    private readonly Timer focusTimer;
    private readonly Timer closeTimer;
    private readonly Timer renderTimer;
    private int focusAttempts;
    private IntPtr deviceContext;
    private IntPtr renderingContext;
#if CAPTURE_ACCEPTANCE
    private System.IO.MemoryStream toneStream;
    private System.Media.SoundPlayer tone;
    protected override bool ShowWithoutActivation { get { return true; } }
#endif

    [StructLayout(LayoutKind.Sequential)]
    private struct PixelFormatDescriptor
    {
        internal ushort Size;
        internal ushort Version;
        internal uint Flags;
        internal byte PixelType;
        internal byte ColorBits;
        internal byte RedBits;
        internal byte RedShift;
        internal byte GreenBits;
        internal byte GreenShift;
        internal byte BlueBits;
        internal byte BlueShift;
        internal byte AlphaBits;
        internal byte AlphaShift;
        internal byte AccumBits;
        internal byte AccumRedBits;
        internal byte AccumGreenBits;
        internal byte AccumBlueBits;
        internal byte AccumAlphaBits;
        internal byte DepthBits;
        internal byte StencilBits;
        internal byte AuxBuffers;
        internal byte LayerType;
        internal byte Reserved;
        internal uint LayerMask;
        internal uint VisibleMask;
        internal uint DamageMask;
    }

    private const uint DrawToWindow = 0x00000004;
    private const uint SupportOpenGl = 0x00000020;
    private const uint DoubleBuffer = 0x00000001;
    private const uint ColorBufferBit = 0x00004000;

    [DllImport("user32.dll")]
    private static extern IntPtr GetDC(IntPtr window);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(IntPtr window, IntPtr deviceContext);

    [DllImport("gdi32.dll")]
    private static extern int ChoosePixelFormat(IntPtr deviceContext, ref PixelFormatDescriptor descriptor);

    [DllImport("gdi32.dll")]
    private static extern bool SetPixelFormat(IntPtr deviceContext, int format, ref PixelFormatDescriptor descriptor);

    [DllImport("gdi32.dll")]
    private static extern bool SwapBuffers(IntPtr deviceContext);

    [DllImport("opengl32.dll")]
    private static extern IntPtr wglCreateContext(IntPtr deviceContext);

    [DllImport("opengl32.dll")]
    private static extern bool wglDeleteContext(IntPtr renderingContext);

    [DllImport("opengl32.dll")]
    private static extern bool wglMakeCurrent(IntPtr deviceContext, IntPtr renderingContext);

    [DllImport("opengl32.dll")]
    private static extern void glClearColor(float red, float green, float blue, float alpha);

    [DllImport("opengl32.dll")]
    private static extern void glClear(uint mask);

    [DllImport("opengl32.dll")]
    private static extern void glViewport(int x, int y, int width, int height);

    internal HookPolicyWindow()
    {
        Text = "OBS Hook Policy Fixture";
        WindowState = FormWindowState.Maximized;
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(24, 48, 72);
        ShowInTaskbar = true;
        TopMost = true;
#if CAPTURE_ACCEPTANCE
        Text = "Replay Capture Acceptance";
        WindowState = FormWindowState.Normal;
        StartPosition = FormStartPosition.Manual;
        Location = new Point(-10000, -10000);
        ClientSize = new Size(320, 180);
        ShowInTaskbar = false;
        TopMost = false;
#endif

        focusTimer = new Timer { Interval = 100 };
        focusTimer.Tick += delegate
        {
            focusAttempts++;
            BringToFront();
            Activate();
            Focus();
            // Keep reclaiming focus long enough to cover a cold OBS startup and
            // several automation polls. This is an isolated capture-policy
            // fixture, so deterministic foreground ownership is intentional.
            if (focusAttempts >= 200)
            {
                focusTimer.Stop();
            }
        };

        closeTimer = new Timer { Interval = 90000 };
        closeTimer.Tick += delegate
        {
            closeTimer.Stop();
            Close();
        };

        renderTimer = new Timer { Interval = 16 };
        renderTimer.Tick += delegate
        {
            if (renderingContext == IntPtr.Zero)
            {
                return;
            }

            wglMakeCurrent(deviceContext, renderingContext);
            glViewport(0, 0, Math.Max(1, ClientSize.Width), Math.Max(1, ClientSize.Height));
            glClearColor(0.09f, 0.19f, 0.28f, 1.0f);
#if CAPTURE_ACCEPTANCE
            float phase = (float)(0.5 + 0.4 * Math.Sin(Environment.TickCount / 250.0));
            glClearColor(phase, 0.25f, 1.0f - phase, 1.0f);
#endif
            glClear(ColorBufferBit);
            SwapBuffers(deviceContext);
        };

        Shown += delegate
        {
            InitializeOpenGl();
#if CAPTURE_ACCEPTANCE
            // Quiet 440 Hz stereo tone, produced in this process only.
            System.IO.File.WriteAllText(Environment.GetCommandLineArgs()[1], Handle.ToInt64().ToString(System.Globalization.CultureInfo.InvariantCulture));
            toneStream = new System.IO.MemoryStream();
            var writer = new System.IO.BinaryWriter(toneStream);
            int bytes = 48000 * 4;
            writer.Write(System.Text.Encoding.ASCII.GetBytes("RIFF"));
            writer.Write(bytes + 36); writer.Write(System.Text.Encoding.ASCII.GetBytes("WAVEfmt "));
            writer.Write(16); writer.Write((short)1); writer.Write((short)2);
            writer.Write(48000); writer.Write(192000); writer.Write((short)4); writer.Write((short)16);
            writer.Write(System.Text.Encoding.ASCII.GetBytes("data")); writer.Write(bytes);
            for (int i = 0; i < 48000; i++) {
                short sample = (short)(32767 * 0.01 * Math.Sin(2 * Math.PI * 440 * i / 48000));
                writer.Write(sample); writer.Write(sample);
            }
            writer.Flush(); toneStream.Position = 0;
            tone = new System.Media.SoundPlayer(toneStream); tone.PlayLooping();
#else
            BringToFront();
            Activate();
            Focus();
            focusTimer.Start();
#endif
            closeTimer.Start();
            renderTimer.Start();
        };

        FormClosed += delegate { DisposeOpenGl(); };
    }

    private void InitializeOpenGl()
    {
        var descriptor = new PixelFormatDescriptor
        {
            Size = (ushort)Marshal.SizeOf(typeof(PixelFormatDescriptor)),
            Version = 1,
            Flags = DrawToWindow | SupportOpenGl | DoubleBuffer,
            PixelType = 0,
            ColorBits = 32,
            DepthBits = 24,
            StencilBits = 8,
            LayerType = 0
        };

        deviceContext = GetDC(Handle);
        int pixelFormat = ChoosePixelFormat(deviceContext, ref descriptor);
        if (deviceContext == IntPtr.Zero || pixelFormat == 0 ||
            !SetPixelFormat(deviceContext, pixelFormat, ref descriptor))
        {
            throw new InvalidOperationException("Could not initialize the OpenGL pixel format.");
        }

        renderingContext = wglCreateContext(deviceContext);
        if (renderingContext == IntPtr.Zero || !wglMakeCurrent(deviceContext, renderingContext))
        {
            throw new InvalidOperationException("Could not initialize the OpenGL rendering context.");
        }
    }

    private void DisposeOpenGl()
    {
        renderTimer.Stop();
#if CAPTURE_ACCEPTANCE
        if (tone != null) { tone.Stop(); tone.Dispose(); toneStream.Dispose(); }
#endif
        wglMakeCurrent(IntPtr.Zero, IntPtr.Zero);
        if (renderingContext != IntPtr.Zero)
        {
            wglDeleteContext(renderingContext);
            renderingContext = IntPtr.Zero;
        }
        if (deviceContext != IntPtr.Zero)
        {
            ReleaseDC(Handle, deviceContext);
            deviceContext = IntPtr.Zero;
        }
    }

    [STAThread]
    private static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new HookPolicyWindow());
    }
}
