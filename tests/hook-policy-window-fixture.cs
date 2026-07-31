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

        closeTimer = new Timer { Interval = 45000 };
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
            glClear(ColorBufferBit);
            SwapBuffers(deviceContext);
        };

        Shown += delegate
        {
            InitializeOpenGl();
            BringToFront();
            Activate();
            Focus();
            focusTimer.Start();
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
