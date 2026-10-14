#include "PluginChain.h"

PluginChain::PluginChain()
    : wideScratch (16, 8192)
{
}

void PluginChain::configureLayout (juce::AudioPluginInstance& p)
{
    // Prefer stereo in/out on the main buses, fall back to mono. Side-chains are disabled.
    for (auto set : { juce::AudioChannelSet::stereo(), juce::AudioChannelSet::mono() })
    {
        auto layout = p.getBusesLayout();

        if (! layout.inputBuses.isEmpty())  layout.inputBuses.getReference (0) = set;
        if (! layout.outputBuses.isEmpty()) layout.outputBuses.getReference (0) = set;

        for (int i = 1; i < layout.inputBuses.size(); ++i)
            layout.inputBuses.getReference (i) = juce::AudioChannelSet::disabled();

        if (p.setBusesLayout (layout))
            return;
    }
}

void PluginChain::preparePlugin (juce::AudioPluginInstance& p) const
{
    p.setNonRealtime (false);
    p.setRateAndBufferSizeDetails (sampleRate, blockSize);
    p.prepareToPlay (sampleRate, blockSize);
}

void PluginChain::prepare (double newSampleRate, int maxBlockSize)
{
    const juce::ScopedLock sl (lock);

    sampleRate = newSampleRate;
    blockSize = juce::jmax (32, maxBlockSize);
    wideScratch.setSize (16, juce::jmax (8192, blockSize), false, false, true);

    for (auto& s : slots)
    {
        s->plugin->releaseResources();
        preparePlugin (*s->plugin);
    }
}

void PluginChain::release()
{
    const juce::ScopedLock sl (lock);

    for (auto& s : slots)
        s->plugin->releaseResources();
}

void PluginChain::process (juce::AudioBuffer<float>& buffer, int numSamples)
{
    const juce::ScopedTryLock sl (lock);

    if (! sl.isLocked())
        return;   // chain is being edited: pass through dry for this block

    for (auto& s : slots)
    {
        if (s->bypassed.load (std::memory_order_relaxed))
            continue;

        auto& p = *s->plugin;
        const int numCh = juce::jmax (p.getTotalNumInputChannels(), p.getTotalNumOutputChannels());
        midi.clear();

        if (numCh <= 2)
        {
            juce::AudioBuffer<float> view (buffer.getArrayOfWritePointers(), juce::jmax (1, numCh), numSamples);
            p.processBlock (view, midi);

            if (numCh <= 1)
                buffer.copyFrom (1, 0, buffer, 0, 0, numSamples);   // mono plugin: mirror to R
        }
        else if (numCh <= wideScratch.getNumChannels() && numSamples <= wideScratch.getNumSamples())
        {
            for (int ch = 0; ch < numCh; ++ch)
            {
                if (ch < 2) wideScratch.copyFrom (ch, 0, buffer, ch, 0, numSamples);
                else        wideScratch.clear (ch, 0, numSamples);
            }

            juce::AudioBuffer<float> view (wideScratch.getArrayOfWritePointers(), numCh, numSamples);
            p.processBlock (view, midi);

            buffer.copyFrom (0, 0, wideScratch, 0, 0, numSamples);
            buffer.copyFrom (1, 0, wideScratch, 1, 0, numSamples);
        }
    }
}

void PluginChain::add (std::unique_ptr<juce::AudioPluginInstance> plugin,
                       const juce::PluginDescription& desc, bool bypassed)
{
    jassert (plugin != nullptr);

    configureLayout (*plugin);
    preparePlugin (*plugin);   // outside the lock: may be slow

    auto slot = std::make_unique<Slot>();
    slot->plugin = std::move (plugin);
    slot->description = desc;
    slot->bypassed = bypassed;

    const juce::ScopedLock sl (lock);
    slots.push_back (std::move (slot));
}

std::unique_ptr<juce::AudioPluginInstance> PluginChain::remove (int index)
{
    std::unique_ptr<Slot> slot;

    {
        const juce::ScopedLock sl (lock);

        if (! juce::isPositiveAndBelow (index, size()))
            return {};

        slot = std::move (slots[(size_t) index]);
        slots.erase (slots.begin() + index);
    }

    slot->plugin->releaseResources();
    return std::move (slot->plugin);
}

void PluginChain::move (int from, int to)
{
    const juce::ScopedLock sl (lock);

    if (! juce::isPositiveAndBelow (from, size()) || ! juce::isPositiveAndBelow (to, size()) || from == to)
        return;

    auto slot = std::move (slots[(size_t) from]);
    slots.erase (slots.begin() + from);
    slots.insert (slots.begin() + to, std::move (slot));
}

void PluginChain::clear()
{
    while (size() > 0)
        remove (size() - 1);
}

int PluginChain::getLatencySamples() const
{
    int total = 0;

    for (auto& s : slots)
        if (! s->bypassed.load())
            total += s->plugin->getLatencySamples();

    return total;
}
