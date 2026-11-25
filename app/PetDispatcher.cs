using System;
using System.Collections;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;
using System.Runtime.InteropServices;

namespace RebeccaPet {
    // Keep mouse input and healthy timer ticks inside the WPF dispatcher.
    // Enter PowerShell only when the visible status or window layer needs work.
    public static class PetDispatcher {
        [DllImport("user32.dll", ExactSpelling=true)]
        private static extern int GetWindowLongW(IntPtr handle, int index);

        public static DispatcherTimer Attach(Window window, Hashtable shared, EventHandler refresh) {
            window.MouseLeftButtonDown += delegate(object sender, MouseButtonEventArgs e) {
                if (e.LeftButton == MouseButtonState.Pressed) window.DragMove();
            };
            var helper = new WindowInteropHelper(window);
            var timer = new DispatcherTimer(DispatcherPriority.Background);
            timer.Interval = TimeSpan.FromMilliseconds(500);
            object previous = null;
            bool wasStale = false;
            timer.Tick += delegate(object sender, EventArgs e) {
                var packet = shared["Packet"] as Hashtable;
                bool stale = packet != null && DateTime.UtcNow > (DateTime)packet["Expires"];
                var key = (bool)shared["Ended"] ? "monitor-ended" : packet == null ? null : packet["DisplayKey"];
                bool layerLost = (bool)shared["Pinned"] && window.IsVisible &&
                    window.WindowState != WindowState.Minimized && helper.Handle != IntPtr.Zero &&
                    (GetWindowLongW(helper.Handle, -20) & 8) == 0;
                if (!layerLost && Object.Equals(key, previous) && stale == wasStale) return;
                shared["Stale"] = stale;
                shared["DisplayPacket"] = packet;
                refresh(sender, e);
                previous = key;
                wasStale = stale;
            };
            window.Closed += delegate { timer.Stop(); };
            timer.Start();
            return timer;
        }
    }
}
