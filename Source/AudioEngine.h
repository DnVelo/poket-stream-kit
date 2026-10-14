#pragma once

#include <juce_audio_devices/juce_audio_devices.h>
#include <juce_audio_processors/juce_audio_processors.h>
#include "DriftFifo.h"
#include "PluginChain.h"

/*  AudioDeviceManager that only offers the driver types that make sense for one role.
    - Monitor: ASIO first (lowest latency), then WASAPI exclusive / low-latency shared.
    - Stream:  WASAPI shared and DirectSound, i.e. the modes that coexist with other
               apps and are what VB-CABLE / OBS expect.
*/
class RoleDeviceManager : public juce::AudioDeviceManager
{
public:
    enum class Role { monitor, stream };

    explicit RoleDeviceManager (Role r) : role (r) {}

    void createAudioDeviceTypes (juce::OwnedArray<juce::AudioIODeviceType>& types) override;

private:
    Role role;
};

/*  The whole signal path:

      ASIO in --> input gain --> [plugin chain] --+--> monitor gain --> ASIO out (headphones)
                         \_______ dry ____________/        (wet or dry selectable)
                                                  |
                                                  +--> stream gain --> DriftFifo --> WASAPI out (VB-CABLE -> OBS)
*/
class AudioEngine
{
public:
    AudioEngine();
    ~AudioEngine();

    void loadState();
    void saveState();
    void shutdown();

    RoleDeviceManager& getMonitorDevice()        { return monitorDm; }
    RoleDeviceManager& getStreamDevice()         { return streamDm; }
    PluginChain& getChain()                      { return chain; }
    DriftFifo& getFifo()                         { return fifo; }
    juce::AudioPluginFormatManager& getFormats() { return formats; }

    /** Message thread. Creates the plugin and appends it to the chain. */
    bool addPlugin (const juce::PluginDescription&, juce::String& error,
                    const juce::MemoryBlock* state = nullptr, bool bypassed = false);

    juce::StringArray& getExtraPluginFolders()   { return extraPluginFolders; }

    struct Params
    {
        std::atomic<float> inputGainDb   { 0.0f };
        std::atomic<float> monitorGainDb { -6.0f };
        std::atomic<float> streamGainDb  { 0.0f };
        std::atomic<bool>  monitorWet    { true };
        std::atomic<bool>  monitorMuted  { false };
        std::atomic<bool>  streamMuted   { false };
        std::atomic<bool>  stereoInput   { false };
    };

    struct Meters
    {
        std::atomic<float> input { 0.0f }, monitor { 0.0f }, stream { 0.0f };
    };

    Params params;
    Meters meters;

    static juce::File getStateFile();

private:
    struct MonitorCallback : juce::AudioIODeviceCallback
    {
        explicit MonitorCallback (AudioEngine& e) : engine (e) {}
        void audioDeviceIOCallbackWithContext (const float* const*, int, float* const*, int, int,
                                               const juce::AudioIODeviceCallbackContext&) override;
        void audioDeviceAboutToStart (juce::AudioIODevice*) override;
        void audioDeviceStopped() override;

        AudioEngine& engine;
        juce::AudioBuffer<float> wet, dry, send;
    };

    struct StreamCallback : juce::AudioIODeviceCallback
    {
        explicit StreamCallback (AudioEngine& e) : engine (e) {}
        void audioDeviceIOCallbackWithContext (const float* const*, int, float* const*, int, int,
                                               const juce::AudioIODeviceCallbackContext&) override;
        void audioDeviceAboutToStart (juce::AudioIODevice*) override;
        void audioDeviceStopped() override {}

        AudioEngine& engine;
        juce::AudioBuffer<float> scratch;
    };

    RoleDeviceManager monitorDm { RoleDeviceManager::Role::monitor };
    RoleDeviceManager streamDm  { RoleDeviceManager::Role::stream };
    juce::AudioPluginFormatManager formats;
    PluginChain chain;
    DriftFifo fifo;
    MonitorCallback monitorCallback { *this };
    StreamCallback streamCallback { *this };
    juce::StringArray extraPluginFolders;
    bool isShutDown = false;

    JUCE_DECLARE_NON_COPYABLE (AudioEngine)
};
