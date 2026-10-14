#pragma once

#include <juce_audio_basics/juce_audio_basics.h>
#include <atomic>
#include <vector>

/*  Stereo single-producer / single-consumer FIFO that bridges two audio devices
    running on independent clocks (e.g. an ASIO interface and VB-CABLE via WASAPI).

    The reader side runs a cubic resampler whose ratio is nudged by a PI controller
    so that the FIFO fill level stays at the target latency. This absorbs both a
    nominal sample-rate mismatch (48k -> 44.1k) and slow crystal drift (~ppm),
    without the periodic clicks you get from simply dropping/duplicating blocks.
*/
class DriftFifo
{
public:
    explicit DriftFifo (int capacityFrames = 1 << 15);

    void setWriterSampleRate (double sr);
    void setReaderSampleRate (double sr);
    void setTargetLatencyMs (double ms)   { targetMs.store (ms); }
    double getTargetLatencyMs() const     { return targetMs.load(); }

    /** Asks the reader to flush and re-buffer on its next pull. Any thread. */
    void requestReset()                   { resetFlag.store (true); }

    /** Writer (monitor device) thread only. */
    void push (const float* left, const float* right, int numFrames);

    /** Reader (stream device) thread only. */
    void pull (float* left, float* right, int numFrames);

    // Stats, safe from any thread
    float getFillMs() const               { return statFillMs.load(); }
    float getCorrectionPpm() const        { return statPpm.load(); }
    int getUnderruns() const              { return underruns.load(); }
    int getOverruns() const               { return overruns.load(); }
    bool isBuffering() const              { return statBuffering.load(); }

private:
    void discard (int numFrames);
    int readInto (int destOffset, int numFrames);
    void outputSilence (float* l, float* r, int n);

    juce::AbstractFifo fifo;
    juce::AudioBuffer<float> ring;

    // reader-only state
    std::vector<float> localL, localR;
    int localCount = 0;
    double phase = 0.0, smoothedFill = 0.0, integral = 0.0;
    bool buffering = true;

    std::atomic<double> writerRate { 48000.0 }, readerRate { 48000.0 }, targetMs { 30.0 };
    std::atomic<bool> resetFlag { true };

    std::atomic<float> statFillMs { 0.0f }, statPpm { 0.0f };
    std::atomic<bool> statBuffering { true };
    std::atomic<int> underruns { 0 }, overruns { 0 };
};
