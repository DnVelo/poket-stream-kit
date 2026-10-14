#pragma once

#include <juce_audio_processors/juce_audio_processors.h>
#include <atomic>
#include <memory>
#include <vector>

/*  A serial insert chain of hosted plugins, processed on the audio thread.
    Structural edits (add/remove/move) happen on the message thread under a lock
    that the audio thread only try-locks, so it never blocks.
*/
class PluginChain
{
public:
    struct Slot
    {
        std::unique_ptr<juce::AudioPluginInstance> plugin;
        juce::PluginDescription description;
        std::atomic<bool> bypassed { false };
    };

    PluginChain();

    // audio device lifecycle (called by the monitor device callback)
    void prepare (double sampleRate, int maxBlockSize);
    void release();

    /** Audio thread. Processes the first two channels of `buffer` in place. */
    void process (juce::AudioBuffer<float>& buffer, int numSamples);

    // message thread
    void add (std::unique_ptr<juce::AudioPluginInstance>, const juce::PluginDescription&, bool bypassed = false);
    std::unique_ptr<juce::AudioPluginInstance> remove (int index);
    void move (int from, int to);
    void clear();

    int size() const                       { return (int) slots.size(); }
    Slot* getSlot (int index) const        { return juce::isPositiveAndBelow (index, size()) ? slots[(size_t) index].get() : nullptr; }
    int getLatencySamples() const;

    double getSampleRate() const           { return sampleRate; }
    int getBlockSize() const               { return blockSize; }

private:
    static void configureLayout (juce::AudioPluginInstance&);
    void preparePlugin (juce::AudioPluginInstance&) const;

    juce::CriticalSection lock;
    std::vector<std::unique_ptr<Slot>> slots;
    double sampleRate = 48000.0;
    int blockSize = 512;
    juce::AudioBuffer<float> wideScratch;
    juce::MidiBuffer midi;
};
