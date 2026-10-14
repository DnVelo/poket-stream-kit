#include "DriftFifo.h"
#include <cmath>
#include <cstring>

namespace
{
    // 4-point, 3rd-order Hermite interpolation between y1 and y2
    inline float hermite (float y0, float y1, float y2, float y3, float t) noexcept
    {
        const float c1 = 0.5f * (y2 - y0);
        const float c2 = y0 - 2.5f * y1 + 2.0f * y2 - 0.5f * y3;
        const float c3 = 0.5f * (y3 - y0) + 1.5f * (y1 - y2);
        return ((c3 * t + c2) * t + c1) * t + y1;
    }

    constexpr double kp = 0.002;          // proportional gain on normalised fill error
    constexpr double ki = 0.0005;         // integral gain (per second)
    constexpr double maxCorrection = 0.002; // +-2000 ppm, far below audible pitch change
    constexpr int maxLocal = 1 << 14;
}

DriftFifo::DriftFifo (int capacityFrames)
    : fifo (capacityFrames), ring (2, capacityFrames),
      localL ((size_t) maxLocal), localR ((size_t) maxLocal)
{
    ring.clear();
}

void DriftFifo::setWriterSampleRate (double sr) { if (sr > 0) writerRate.store (sr); requestReset(); }
void DriftFifo::setReaderSampleRate (double sr) { if (sr > 0) readerRate.store (sr); requestReset(); }

void DriftFifo::push (const float* left, const float* right, int numFrames)
{
    int s1, n1, s2, n2;
    fifo.prepareToWrite (numFrames, s1, n1, s2, n2);

    if (n1 + n2 < numFrames)
        overruns.fetch_add (1, std::memory_order_relaxed);   // reader stalled: drop the excess

    if (n1 > 0)
    {
        ring.copyFrom (0, s1, left, n1);
        ring.copyFrom (1, s1, right, n1);
    }
    if (n2 > 0)
    {
        ring.copyFrom (0, s2, left + n1, n2);
        ring.copyFrom (1, s2, right + n1, n2);
    }

    fifo.finishedWrite (n1 + n2);
}

void DriftFifo::discard (int numFrames)
{
    int s1, n1, s2, n2;
    fifo.prepareToRead (juce::jmax (0, numFrames), s1, n1, s2, n2);
    fifo.finishedRead (n1 + n2);
}

int DriftFifo::readInto (int destOffset, int numFrames)
{
    int s1, n1, s2, n2;
    fifo.prepareToRead (numFrames, s1, n1, s2, n2);

    if (n1 > 0)
    {
        std::memcpy (localL.data() + destOffset, ring.getReadPointer (0, s1), sizeof (float) * (size_t) n1);
        std::memcpy (localR.data() + destOffset, ring.getReadPointer (1, s1), sizeof (float) * (size_t) n1);
    }
    if (n2 > 0)
    {
        std::memcpy (localL.data() + destOffset + n1, ring.getReadPointer (0, s2), sizeof (float) * (size_t) n2);
        std::memcpy (localR.data() + destOffset + n1, ring.getReadPointer (1, s2), sizeof (float) * (size_t) n2);
    }

    fifo.finishedRead (n1 + n2);
    return n1 + n2;
}

void DriftFifo::outputSilence (float* l, float* r, int n)
{
    juce::FloatVectorOperations::clear (l, n);
    juce::FloatVectorOperations::clear (r, n);
}

void DriftFifo::pull (float* left, float* right, int numFrames)
{
    const double inRate  = writerRate.load();
    const double outRate = readerRate.load();
    const double target  = juce::jmax (64.0, targetMs.load() * 0.001 * inRate);

    if (resetFlag.exchange (false))
    {
        discard (fifo.getNumReady());
        localCount = 0;
        phase = 0.0;
        integral = 0.0;
        buffering = true;
    }

    double fill = fifo.getNumReady() + localCount - phase;

    if (buffering)
    {
        if (fill < target)
        {
            outputSilence (left, right, numFrames);
            statFillMs.store ((float) (fill * 1000.0 / inRate));
            statBuffering.store (true);
            return;
        }

        discard ((int) (fill - target));   // start exactly at the target fill
        fill = fifo.getNumReady() + localCount - phase;
        smoothedFill = fill;
        integral = 0.0;
        buffering = false;
    }
    else if (fill > target * 3.0 + 4096.0)
    {
        // writer ran far ahead (e.g. the stream device stalled): jump back to target
        discard ((int) (fill - target));
        fill = fifo.getNumReady() + localCount - phase;
        smoothedFill = fill;
        overruns.fetch_add (1, std::memory_order_relaxed);
    }

    // PI control of the resampling ratio around the nominal inRate/outRate
    smoothedFill += 0.05 * (fill - smoothedFill);
    const double err = (smoothedFill - target) / target;
    integral = juce::jlimit (-4.0, 4.0, integral + err * numFrames / outRate);
    const double correction = juce::jlimit (-maxCorrection, maxCorrection, kp * err + ki * integral);
    const double step = inRate / outRate * (1.0 + correction);

    const int needed = (int) std::ceil (phase + step * numFrames) + 4;

    if (needed > maxLocal)
    {
        outputSilence (left, right, numFrames);   // absurd ratio / block size, refuse rather than overrun
        return;
    }

    if (localCount < needed)
        localCount += readInto (localCount, needed - localCount);

    if (localCount < needed)
    {
        underruns.fetch_add (1, std::memory_order_relaxed);
        outputSilence (left, right, numFrames);
        localCount = 0;
        phase = 0.0;
        buffering = true;
        statBuffering.store (true);
        return;
    }

    const float* L = localL.data();
    const float* R = localR.data();
    double pos = phase;

    for (int i = 0; i < numFrames; ++i)
    {
        const int idx = (int) pos;
        const float t = (float) (pos - idx);
        left[i]  = hermite (L[idx], L[idx + 1], L[idx + 2], L[idx + 3], t);
        right[i] = hermite (R[idx], R[idx + 1], R[idx + 2], R[idx + 3], t);
        pos += step;
    }

    const int consumed = juce::jmin ((int) pos, localCount);
    phase = pos - consumed;
    localCount -= consumed;

    if (localCount > 0)
    {
        std::memmove (localL.data(), localL.data() + consumed, sizeof (float) * (size_t) localCount);
        std::memmove (localR.data(), localR.data() + consumed, sizeof (float) * (size_t) localCount);
    }

    statFillMs.store ((float) (smoothedFill * 1000.0 / inRate));
    statPpm.store ((float) (correction * 1.0e6));
    statBuffering.store (false);
}
