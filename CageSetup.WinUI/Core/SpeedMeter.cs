using System;
using System.Collections.Generic;
using System.Diagnostics;

namespace CageSetup.WinUI.Core
{
    /// <summary>
    /// Sliding-window speed meter. A single 500 ms delta is too noisy for a
    /// download that moves in 4 MB chunks: the rate jumps between zero and
    /// several MB/s and the ETA disappears. This keeps the last ten seconds
    /// of samples and smooths the result with an EWMA, so the UI shows a
    /// steady speed and a stable "left" value.
    /// </summary>
    internal sealed class SpeedMeter
    {
        private const double Smoothing = 0.35;

        private readonly Queue<(double Seconds, long Bytes)> _samples = new();
        private readonly Stopwatch _clock = Stopwatch.StartNew();
        private readonly double _windowSeconds;
        private double _speed;

        public SpeedMeter(double windowSeconds = 10.0)
        {
            _windowSeconds = windowSeconds;
        }

        public double Speed => _speed;

        /// <summary>Starts a new measurement from <paramref name="bytes"/>.</summary>
        public void Reset(long bytes)
        {
            _samples.Clear();
            _samples.Enqueue((0, bytes));
            _speed = 0;
            _clock.Restart();
        }

        /// <summary>Feeds the cumulative byte count; call it on a fixed tick.</summary>
        public void Add(long bytes)
        {
            if (_samples.Count == 0)
            {
                Reset(bytes);
                return;
            }

            double now = _clock.Elapsed.TotalSeconds;
            _samples.Enqueue((now, bytes));

            while (_samples.Count > 2 && now - _samples.Peek().Seconds > _windowSeconds)
            {
                _samples.Dequeue();
            }

            (double firstSeconds, long firstBytes) = _samples.Peek();
            double elapsed = now - firstSeconds;
            if (elapsed < 1.0) return;

            double raw = Math.Max(0, bytes - firstBytes) / elapsed;
            _speed = _speed <= 0 ? raw : _speed * (1 - Smoothing) + raw * Smoothing;
        }
    }
}
