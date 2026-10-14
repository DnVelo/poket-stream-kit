#pragma once

#include <juce_audio_utils/juce_audio_utils.h>
#include <map>
#include "AudioEngine.h"

class LevelMeter : public juce::Component
{
public:
    explicit LevelMeter (juce::String labelText) : label (std::move (labelText)) {}
    void setLevel (float peakGain);
    void paint (juce::Graphics&) override;

private:
    juce::String label;
    float levelDb = -60.0f, holdDb = -60.0f;
    int holdFrames = 0;
};

class MainComponent : public juce::Component,
                      private juce::ListBoxModel,
                      private juce::Timer
{
public:
    explicit MainComponent (AudioEngine&);
    ~MainComponent() override;

    void resized() override;
    void paint (juce::Graphics&) override;
    void closeAllPluginWindows();

private:
    class PluginWindow;

    // ListBoxModel
    int getNumRows() override;
    void paintListBoxItem (int row, juce::Graphics&, int width, int height, bool selected) override;
    void listBoxItemDoubleClicked (int row, const juce::MouseEvent&) override;

    void timerCallback() override;

    void showDeviceDialog (bool monitor);
    void showAddPluginMenu();
    void addPluginFromFile (const juce::File&);
    void openEditor (int row);
    void closeEditor (juce::AudioPluginInstance*);
    void removeSelected();
    void moveSelected (int delta);
    void toggleBypassSelected();
    void refreshList();
    juce::Array<juce::File> findVst3Files() const;

    AudioEngine& engine;

    juce::TextButton monitorDeviceButton { "Monitor device (ASIO)..." },
                     streamDeviceButton  { "Stream device (WASAPI)..." },
                     saveButton          { "Save" };

    juce::Slider inputGain, monitorGain, streamGain, streamBuffer;
    juce::Label inputGainLabel   { {}, "Input gain" },
                monitorGainLabel { {}, "Monitor" },
                streamGainLabel  { {}, "Stream" },
                streamBufferLabel{ {}, "Stream buffer" };

    juce::ToggleButton monitorWet   { "Monitor processed (off = dry, zero plugin latency)" },
                       monitorMute  { "Mute monitor" },
                       streamMute   { "Mute stream" },
                       stereoInput  { "Stereo input (ch1/ch2)" };

    LevelMeter inputMeter { "IN" }, monitorMeter { "MON" }, streamMeter { "OBS" };

    juce::ListBox pluginList { "Plugins", this };
    juce::TextButton addButton { "+ Add" }, removeButton { "Remove" }, upButton { "Up" },
                     downButton { "Down" }, bypassButton { "Bypass" }, editButton { "Edit" };

    juce::Label status;

    std::map<juce::AudioPluginInstance*, std::unique_ptr<PluginWindow>> pluginWindows;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (MainComponent)
};
