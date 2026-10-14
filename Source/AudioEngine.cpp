#include "AudioEngine.h"

namespace
{
    void addType (juce::OwnedArray<juce::AudioIODeviceType>& types, juce::AudioIODeviceType* t)
    {
        if (t != nullptr)
            types.add (t);
    }

    inline void updatePeak (std::atomic<float>& meter, float value)
    {
        if (value > meter.load (std::memory_order_relaxed))
            meter.store (value, std::memory_order_relaxed);
    }
}

//==============================================================================
void RoleDeviceManager::createAudioDeviceTypes (juce::OwnedArray<juce::AudioIODeviceType>& types)
{
    using Mode = juce::WASAPIDeviceMode;
    using T = juce::AudioIODeviceType;

    if (role == Role::monitor)
    {
        addType (types, T::createAudioIODeviceType_ASIO());
        addType (types, T::createAudioIODeviceType_WASAPI (Mode::exclusive));
        addType (types, T::createAudioIODeviceType_WASAPI (Mode::sharedLowLatency));
    }
    else
    {
        addType (types, T::createAudioIODeviceType_WASAPI (Mode::shared));
        addType (types, T::createAudioIODeviceType_DirectSound());
    }

    // Non-Windows builds (development only)
    addType (types, T::createAudioIODeviceType_CoreAudio());
    addType (types, T::createAudioIODeviceType_ALSA());
    addType (types, T::createAudioIODeviceType_JACK());
}

//==============================================================================
void AudioEngine::MonitorCallback::audioDeviceAboutToStart (juce::AudioIODevice* device)
{
    const int bs = juce::jmax (device->getCurrentBufferSizeSamples(), 4096);
    wet.setSize (2, bs);
    dry.setSize (2, bs);
    send.setSize (2, bs);

    engine.chain.prepare (device->getCurrentSampleRate(), device->getCurrentBufferSizeSamples());
    engine.fifo.setWriterSampleRate (device->getCurrentSampleRate());
}

void AudioEngine::MonitorCallback::audioDeviceStopped()
{
    engine.chain.release();
}

void AudioEngine::MonitorCallback::audioDeviceIOCallbackWithContext (const float* const* inputs, int numInputs,
                                                                     float* const* outputs, int numOutputs,
                                                                     int numSamples,
                                                                     const juce::AudioIODeviceCallbackContext&)
{
    juce::ScopedNoDenormals noDenormals;
    auto& p = engine.params;

    if (numSamples > wet.getNumSamples())
    {
        for (int ch = 0; ch < numOutputs; ++ch)
            if (outputs[ch] != nullptr)
                juce::FloatVectorOperations::clear (outputs[ch], numSamples);
        return;
    }

    // ---- input: mono mic duplicated to L/R, or a stereo pair
    const float inGain = juce::Decibels::decibelsToGain (p.inputGainDb.load());

    if (numInputs <= 0 || inputs[0] == nullptr)
    {
        dry.clear (0, numSamples);
    }
    else
    {
        const bool stereo = p.stereoInput.load() && numInputs >= 2 && inputs[1] != nullptr;
        dry.copyFrom (0, 0, inputs[0], numSamples, inGain);
        dry.copyFrom (1, 0, stereo ? inputs[1] : inputs[0], numSamples, inGain);
    }

    updatePeak (engine.meters.input, dry.getMagnitude (0, numSamples));

    // ---- plugin chain
    wet.copyFrom (0, 0, dry, 0, 0, numSamples);
    wet.copyFrom (1, 0, dry, 1, 0, numSamples);
    engine.chain.process (wet, numSamples);

    // ---- monitor (headphones)
    const auto& monSrc = p.monitorWet.load() ? wet : dry;
    const float monGain = p.monitorMuted.load() ? 0.0f : juce::Decibels::decibelsToGain (p.monitorGainDb.load(), -60.0f);

    for (int ch = 0; ch < numOutputs; ++ch)
    {
        if (outputs[ch] == nullptr)
            continue;

        if (ch < 2)
            juce::FloatVectorOperations::copyWithMultiply (outputs[ch], monSrc.getReadPointer (ch), monGain, numSamples);
        else
            juce::FloatVectorOperations::clear (outputs[ch], numSamples);
    }

    updatePeak (engine.meters.monitor, monSrc.getMagnitude (0, numSamples) * monGain);

    // ---- stream send (always pushed, even muted, so the clocks stay locked)
    const float sendGain = p.streamMuted.load() ? 0.0f : juce::Decibels::decibelsToGain (p.streamGainDb.load(), -60.0f);
    send.copyFrom (0, 0, wet.getReadPointer (0), numSamples, sendGain);
    send.copyFrom (1, 0, wet.getReadPointer (1), numSamples, sendGain);
    engine.fifo.push (send.getReadPointer (0), send.getReadPointer (1), numSamples);

    updatePeak (engine.meters.stream, send.getMagnitude (0, numSamples));
}

//==============================================================================
void AudioEngine::StreamCallback::audioDeviceAboutToStart (juce::AudioIODevice* device)
{
    scratch.setSize (2, juce::jmax (device->getCurrentBufferSizeSamples(), 2048));
    engine.fifo.setReaderSampleRate (device->getCurrentSampleRate());
}

void AudioEngine::StreamCallback::audioDeviceIOCallbackWithContext (const float* const*, int,
                                                                    float* const* outputs, int numOutputs,
                                                                    int numSamples,
                                                                    const juce::AudioIODeviceCallbackContext&)
{
    juce::ScopedNoDenormals noDenormals;
    const int chunk = scratch.getNumSamples();

    for (int start = 0; start < numSamples; start += chunk)
    {
        const int n = juce::jmin (chunk, numSamples - start);
        engine.fifo.pull (scratch.getWritePointer (0), scratch.getWritePointer (1), n);

        for (int ch = 0; ch < numOutputs; ++ch)
        {
            if (outputs[ch] == nullptr)
                continue;

            if (ch < 2)
                juce::FloatVectorOperations::copy (outputs[ch] + start, scratch.getReadPointer (ch), n);
            else
                juce::FloatVectorOperations::clear (outputs[ch] + start, n);
        }
    }
}

//==============================================================================
AudioEngine::AudioEngine()
{
    formats.addDefaultFormats();
}

AudioEngine::~AudioEngine()
{
    shutdown();
}

juce::File AudioEngine::getStateFile()
{
    return juce::File::getSpecialLocation (juce::File::userApplicationDataDirectory)
             .getChildFile ("PocketStreamHost")
             .getChildFile ("state.xml");
}

bool AudioEngine::addPlugin (const juce::PluginDescription& desc, juce::String& error,
                             const juce::MemoryBlock* state, bool bypassed)
{
    auto instance = formats.createPluginInstance (desc, chain.getSampleRate(), chain.getBlockSize(), error);

    if (instance == nullptr)
        return false;

    if (state != nullptr && state->getSize() > 0)
        instance->setStateInformation (state->getData(), (int) state->getSize());

    chain.add (std::move (instance), desc, bypassed);
    return true;
}

void AudioEngine::loadState()
{
    auto xml = juce::parseXML (getStateFile());

    if (xml != nullptr && xml->hasTagName ("PocketStreamHost"))
    {
        if (auto* s = xml->getChildByName ("Settings"))
        {
            params.inputGainDb   = (float) s->getDoubleAttribute ("inputGainDb", 0.0);
            params.monitorGainDb = (float) s->getDoubleAttribute ("monitorGainDb", -6.0);
            params.streamGainDb  = (float) s->getDoubleAttribute ("streamGainDb", 0.0);
            params.monitorWet    = s->getBoolAttribute ("monitorWet", true);
            params.monitorMuted  = s->getBoolAttribute ("monitorMuted", false);
            params.streamMuted   = s->getBoolAttribute ("streamMuted", false);
            params.stereoInput   = s->getBoolAttribute ("stereoInput", false);
            fifo.setTargetLatencyMs (s->getDoubleAttribute ("streamBufferMs", 30.0));
            extraPluginFolders.addTokens (s->getStringAttribute ("pluginFolders"), ";", {});
            extraPluginFolders.removeEmptyStrings();
        }
    }

    auto* monitorXml = xml != nullptr ? xml->getChildByName ("MonitorDevice") : nullptr;
    auto* streamXml  = xml != nullptr ? xml->getChildByName ("StreamDevice")  : nullptr;

    // Monitor: first run prefers 48 kHz / 128 samples on whatever the first (ASIO) driver is
    juce::AudioDeviceManager::AudioDeviceSetup monitorDefaults;
    monitorDefaults.sampleRate = 48000.0;
    monitorDefaults.bufferSize = 128;
    monitorDm.initialise (2, 2, monitorXml != nullptr ? monitorXml->getFirstChildElement() : nullptr,
                          true, {}, monitorXml == nullptr ? &monitorDefaults : nullptr);

    // Stream: first run looks for VB-CABLE's playback endpoint
    streamDm.initialise (0, 2, streamXml != nullptr ? streamXml->getFirstChildElement() : nullptr,
                         true, "CABLE Input*");

    // Mark the opened setups as explicit so createStateXml() persists them even on first run
    for (auto* dm : { static_cast<juce::AudioDeviceManager*> (&monitorDm), static_cast<juce::AudioDeviceManager*> (&streamDm) })
        if (dm->getCurrentAudioDevice() != nullptr)
            dm->setAudioDeviceSetup (dm->getAudioDeviceSetup(), true);

    if (auto* device = monitorDm.getCurrentAudioDevice())
        chain.prepare (device->getCurrentSampleRate(), device->getCurrentBufferSizeSamples());

    // Plugins are restored after the monitor device is open so they get the real rate / block size
    if (xml != nullptr)
    {
        if (auto* chainXml = xml->getChildByName ("Chain"))
        {
            for (auto* slotXml : chainXml->getChildIterator())
            {
                juce::PluginDescription desc;

                if (auto* d = slotXml->getFirstChildElement(); d == nullptr || ! desc.loadFromXml (*d))
                    continue;

                juce::MemoryBlock state;
                state.fromBase64Encoding (slotXml->getStringAttribute ("state"));

                juce::String error;
                if (! addPlugin (desc, error, &state, slotXml->getBoolAttribute ("bypassed")))
                    juce::Logger::writeToLog ("Failed to restore " + desc.name + ": " + error);
            }
        }
    }

    monitorDm.addAudioCallback (&monitorCallback);
    streamDm.addAudioCallback (&streamCallback);
}

void AudioEngine::saveState()
{
    juce::XmlElement root ("PocketStreamHost");
    root.setAttribute ("version", 1);

    auto* s = root.createNewChildElement ("Settings");
    s->setAttribute ("inputGainDb",   params.inputGainDb.load());
    s->setAttribute ("monitorGainDb", params.monitorGainDb.load());
    s->setAttribute ("streamGainDb",  params.streamGainDb.load());
    s->setAttribute ("monitorWet",    params.monitorWet.load());
    s->setAttribute ("monitorMuted",  params.monitorMuted.load());
    s->setAttribute ("streamMuted",   params.streamMuted.load());
    s->setAttribute ("stereoInput",   params.stereoInput.load());
    s->setAttribute ("streamBufferMs", fifo.getTargetLatencyMs());
    s->setAttribute ("pluginFolders", extraPluginFolders.joinIntoString (";"));

    if (auto m = monitorDm.createStateXml())
        root.createNewChildElement ("MonitorDevice")->addChildElement (m.release());

    if (auto st = streamDm.createStateXml())
        root.createNewChildElement ("StreamDevice")->addChildElement (st.release());

    auto* chainXml = root.createNewChildElement ("Chain");

    for (int i = 0; i < chain.size(); ++i)
    {
        auto* slot = chain.getSlot (i);
        juce::MemoryBlock state;
        slot->plugin->getStateInformation (state);

        auto* slotXml = chainXml->createNewChildElement ("Slot");
        slotXml->setAttribute ("bypassed", slot->bypassed.load());
        slotXml->setAttribute ("state", state.toBase64Encoding());
        slotXml->addChildElement (slot->description.createXml().release());
    }

    auto file = getStateFile();
    file.getParentDirectory().createDirectory();
    root.writeTo (file);
}

void AudioEngine::shutdown()
{
    if (isShutDown)
        return;

    isShutDown = true;
    streamDm.removeAudioCallback (&streamCallback);
    monitorDm.removeAudioCallback (&monitorCallback);
    streamDm.closeAudioDevice();
    monitorDm.closeAudioDevice();
    chain.clear();
}
