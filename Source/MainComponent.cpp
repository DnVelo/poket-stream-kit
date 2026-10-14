#include "MainComponent.h"

//==============================================================================
void LevelMeter::setLevel (float peakGain)
{
    const float db = juce::Decibels::gainToDecibels (peakGain, -60.0f);
    levelDb = juce::jmax (db, levelDb - 1.5f);   // ~45 dB/s fall at 30 fps

    if (db >= holdDb) { holdDb = db; holdFrames = 45; }
    else if (--holdFrames <= 0) holdDb = juce::jmax (-60.0f, holdDb - 1.5f);

    repaint();
}

void LevelMeter::paint (juce::Graphics& g)
{
    auto r = getLocalBounds().toFloat();
    auto labelArea = r.removeFromLeft (36.0f);

    g.setColour (juce::Colours::white.withAlpha (0.8f));
    g.setFont (12.0f);
    g.drawText (label, labelArea, juce::Justification::centredLeft);

    g.setColour (juce::Colour (0xff1c1c1c));
    g.fillRoundedRectangle (r, 3.0f);

    auto toX = [&] (float db) { return r.getX() + r.getWidth() * juce::jmap (db, -60.0f, 0.0f, 0.0f, 1.0f); };

    const auto colour = levelDb > -1.0f ? juce::Colours::red
                      : levelDb > -9.0f ? juce::Colours::orange
                                        : juce::Colour (0xff3ec46d);
    g.setColour (colour);
    g.fillRoundedRectangle (r.withRight (toX (levelDb)), 3.0f);

    g.setColour (juce::Colours::white);
    g.fillRect (juce::Rectangle<float> (toX (holdDb) - 1.0f, r.getY(), 2.0f, r.getHeight()));
}

//==============================================================================
class MainComponent::PluginWindow : public juce::DocumentWindow
{
public:
    PluginWindow (juce::AudioPluginInstance& p, std::function<void()> onClose)
        : DocumentWindow (p.getName(), juce::Colours::darkgrey, DocumentWindow::closeButton | DocumentWindow::minimiseButton),
          closeCallback (std::move (onClose))
    {
        juce::AudioProcessorEditor* editor = p.hasEditor() ? p.createEditorIfNeeded() : nullptr;

        if (editor == nullptr)
            editor = new juce::GenericAudioProcessorEditor (p);

        setUsingNativeTitleBar (true);
        setContentOwned (editor, true);
        setResizable (editor->isResizable(), false);
        centreWithSize (getWidth(), getHeight());
        setVisible (true);
    }

    void closeButtonPressed() override { closeCallback(); }

private:
    std::function<void()> closeCallback;
};

//==============================================================================
static void setupDbSlider (juce::Slider& s, double min, double max, double value)
{
    s.setSliderStyle (juce::Slider::LinearHorizontal);
    s.setTextBoxStyle (juce::Slider::TextBoxRight, false, 70, 20);
    s.setRange (min, max, 0.1);
    s.setTextValueSuffix (" dB");
    s.setValue (value, juce::dontSendNotification);
    s.setDoubleClickReturnValue (true, 0.0);
}

MainComponent::MainComponent (AudioEngine& e) : engine (e)
{
    auto& p = engine.params;

    for (auto* c : std::initializer_list<juce::Component*> {
             &monitorDeviceButton, &streamDeviceButton, &saveButton,
             &inputGain, &monitorGain, &streamGain, &streamBuffer,
             &inputGainLabel, &monitorGainLabel, &streamGainLabel, &streamBufferLabel,
             &monitorWet, &monitorMute, &streamMute, &stereoInput,
             &inputMeter, &monitorMeter, &streamMeter,
             &pluginList, &addButton, &removeButton, &upButton, &downButton, &bypassButton, &editButton,
             &status })
        addAndMakeVisible (c);

    setupDbSlider (inputGain, -24.0, 24.0, p.inputGainDb.load());
    setupDbSlider (monitorGain, -60.0, 6.0, p.monitorGainDb.load());
    setupDbSlider (streamGain, -60.0, 12.0, p.streamGainDb.load());

    streamBuffer.setSliderStyle (juce::Slider::LinearHorizontal);
    streamBuffer.setTextBoxStyle (juce::Slider::TextBoxRight, false, 70, 20);
    streamBuffer.setRange (10.0, 150.0, 1.0);
    streamBuffer.setTextValueSuffix (" ms");
    streamBuffer.setValue (engine.getFifo().getTargetLatencyMs(), juce::dontSendNotification);

    inputGain.onValueChange    = [this] { engine.params.inputGainDb   = (float) inputGain.getValue(); };
    monitorGain.onValueChange  = [this] { engine.params.monitorGainDb = (float) monitorGain.getValue(); };
    streamGain.onValueChange   = [this] { engine.params.streamGainDb  = (float) streamGain.getValue(); };
    streamBuffer.onValueChange = [this] { engine.getFifo().setTargetLatencyMs (streamBuffer.getValue());
                                          engine.getFifo().requestReset(); };

    auto bindToggle = [] (juce::ToggleButton& b, std::atomic<bool>& flag)
    {
        b.setToggleState (flag.load(), juce::dontSendNotification);
        b.onClick = [&b, &flag] { flag = b.getToggleState(); };
    };
    bindToggle (monitorWet, p.monitorWet);
    bindToggle (monitorMute, p.monitorMuted);
    bindToggle (streamMute, p.streamMuted);
    bindToggle (stereoInput, p.stereoInput);

    monitorDeviceButton.onClick = [this] { showDeviceDialog (true); };
    streamDeviceButton.onClick  = [this] { showDeviceDialog (false); };
    saveButton.onClick          = [this] { engine.saveState(); };

    addButton.onClick    = [this] { showAddPluginMenu(); };
    removeButton.onClick = [this] { removeSelected(); };
    upButton.onClick     = [this] { moveSelected (-1); };
    downButton.onClick   = [this] { moveSelected (1); };
    bypassButton.onClick = [this] { toggleBypassSelected(); };
    editButton.onClick   = [this] { openEditor (pluginList.getSelectedRow()); };

    pluginList.setRowHeight (26);
    pluginList.setColour (juce::ListBox::backgroundColourId, juce::Colour (0xff202020));

    status.setFont (juce::FontOptions (13.0f));
    status.setJustificationType (juce::Justification::topLeft);
    status.setColour (juce::Label::textColourId, juce::Colours::lightgrey);

    setSize (560, 640);
    startTimerHz (30);
}

MainComponent::~MainComponent()
{
    closeAllPluginWindows();
}

void MainComponent::paint (juce::Graphics& g)
{
    g.fillAll (juce::Colour (0xff2a2a2a));
}

void MainComponent::resized()
{
    auto r = getLocalBounds().reduced (10);

    auto top = r.removeFromTop (28);
    saveButton.setBounds (top.removeFromRight (70));
    top.removeFromRight (6);
    monitorDeviceButton.setBounds (top.removeFromLeft ((top.getWidth() - 6) / 2));
    top.removeFromLeft (6);
    streamDeviceButton.setBounds (top);
    r.removeFromTop (10);

    auto sliderRow = [&r] (juce::Label& l, juce::Slider& s)
    {
        auto row = r.removeFromTop (26);
        l.setBounds (row.removeFromLeft (100));
        s.setBounds (row);
        r.removeFromTop (2);
    };
    sliderRow (inputGainLabel, inputGain);
    sliderRow (monitorGainLabel, monitorGain);
    sliderRow (streamGainLabel, streamGain);
    sliderRow (streamBufferLabel, streamBuffer);
    r.removeFromTop (4);

    monitorWet.setBounds (r.removeFromTop (24));
    auto toggles = r.removeFromTop (24);
    const int w = toggles.getWidth() / 3;
    monitorMute.setBounds (toggles.removeFromLeft (w));
    streamMute.setBounds (toggles.removeFromLeft (w));
    stereoInput.setBounds (toggles);
    r.removeFromTop (8);

    for (auto* m : { &inputMeter, &monitorMeter, &streamMeter })
    {
        m->setBounds (r.removeFromTop (14));
        r.removeFromTop (4);
    }
    r.removeFromTop (6);

    status.setBounds (r.removeFromBottom (76));
    r.removeFromBottom (6);

    auto buttons = r.removeFromBottom (28);
    const int bw = buttons.getWidth() / 6;
    for (auto* b : { &addButton, &removeButton, &upButton, &downButton, &bypassButton, &editButton })
        b->setBounds (buttons.removeFromLeft (bw).reduced (2, 0));
    r.removeFromBottom (4);

    pluginList.setBounds (r);
}

//==============================================================================
int MainComponent::getNumRows()
{
    return engine.getChain().size();
}

void MainComponent::paintListBoxItem (int row, juce::Graphics& g, int width, int height, bool selected)
{
    auto* slot = engine.getChain().getSlot (row);
    if (slot == nullptr)
        return;

    if (selected)
        g.fillAll (juce::Colour (0xff3a5f8a));

    const bool bypassed = slot->bypassed.load();
    g.setColour (bypassed ? juce::Colours::grey : juce::Colours::white);
    g.setFont (14.0f);

    juce::String text;
    text << (row + 1) << ".  " << slot->plugin->getName();
    if (bypassed) text << "   [bypassed]";

    const int latency = slot->plugin->getLatencySamples();
    if (latency > 0)
        text << "   (" << juce::String (latency * 1000.0 / engine.getChain().getSampleRate(), 1) << " ms)";

    g.drawText (text, 8, 0, width - 16, height, juce::Justification::centredLeft);
}

void MainComponent::listBoxItemDoubleClicked (int row, const juce::MouseEvent&)
{
    openEditor (row);
}

void MainComponent::refreshList()
{
    pluginList.updateContent();
    pluginList.repaint();
}

//==============================================================================
void MainComponent::showDeviceDialog (bool monitor)
{
    auto& dm = monitor ? static_cast<juce::AudioDeviceManager&> (engine.getMonitorDevice())
                       : static_cast<juce::AudioDeviceManager&> (engine.getStreamDevice());

    auto selector = monitor
        ? std::make_unique<juce::AudioDeviceSelectorComponent> (dm, 1, 2, 1, 2, false, false, false, false)
        : std::make_unique<juce::AudioDeviceSelectorComponent> (dm, 0, 0, 2, 2, false, false, true, false);
    selector->setSize (520, monitor ? 460 : 300);

    juce::DialogWindow::LaunchOptions o;
    o.content.setOwned (selector.release());
    o.dialogTitle = monitor ? "Monitor device (ASIO / headphones)" : "Stream device (VB-CABLE -> OBS)";
    o.dialogBackgroundColour = juce::Colour (0xff2a2a2a);
    o.useNativeTitleBar = true;
    o.resizable = false;
    o.launchAsync();
}

juce::Array<juce::File> MainComponent::findVst3Files() const
{
    juce::FileSearchPath paths;

    for (auto* format : engine.getFormats().getFormats())
        if (format->getName() == "VST3")
            paths = format->getDefaultLocationsToSearch();

    for (auto& folder : engine.getExtraPluginFolders())
        paths.addIfNotAlreadyThere (juce::File (folder));

    juce::Array<juce::File> result;

    for (int i = 0; i < paths.getNumPaths(); ++i)
    {
        for (const auto& entry : juce::RangedDirectoryIterator (paths.getRawString (i), true, "*.vst3",
                                                                 juce::File::findFilesAndDirectories))
        {
            const auto f = entry.getFile();

            // Skip the binaries inside a .vst3 bundle (Contents/x86_64-win/Foo.vst3)
            bool insideBundle = false;
            for (auto parent = f.getParentDirectory(); parent != parent.getParentDirectory(); parent = parent.getParentDirectory())
                if (parent.hasFileExtension ("vst3")) { insideBundle = true; break; }

            if (! insideBundle)
                result.addIfNotAlreadyThere (f);
        }
    }

    std::sort (result.begin(), result.end(),
               [] (const juce::File& a, const juce::File& b) { return a.getFileName().compareIgnoreCase (b.getFileName()) < 0; });
    return result;
}

void MainComponent::showAddPluginMenu()
{
    const auto files = findVst3Files();

    juce::PopupMenu menu;
    for (int i = 0; i < files.size(); ++i)
        menu.addItem (i + 1, files[i].getFileNameWithoutExtension());

    if (files.isEmpty())
        menu.addItem (-2, "(no VST3 found)", false);

    menu.addSeparator();
    menu.addItem (-1, "Add VST3 folder...");

    menu.showMenuAsync (juce::PopupMenu::Options().withTargetComponent (addButton),
                        [this, files] (int result)
    {
        if (result > 0)
        {
            addPluginFromFile (files[result - 1]);
        }
        else if (result == -1)
        {
            auto chooser = std::make_shared<juce::FileChooser> ("VST3 folder");
            chooser->launchAsync (juce::FileBrowserComponent::openMode | juce::FileBrowserComponent::canSelectDirectories,
                                  [this, chooser] (const juce::FileChooser& fc)
            {
                if (fc.getResult().isDirectory())
                {
                    engine.getExtraPluginFolders().addIfNotAlreadyThere (fc.getResult().getFullPathName());
                    engine.saveState();
                    showAddPluginMenu();
                }
            });
        }
    });
}

void MainComponent::addPluginFromFile (const juce::File& file)
{
    juce::OwnedArray<juce::PluginDescription> found;

    for (auto* format : engine.getFormats().getFormats())
        if (format->fileMightContainThisPluginType (file.getFullPathName()))
            format->findAllTypesForFile (found, file.getFullPathName());

    auto add = [this] (const juce::PluginDescription& desc)
    {
        juce::String error;
        if (! engine.addPlugin (desc, error))
            juce::AlertWindow::showMessageBoxAsync (juce::MessageBoxIconType::WarningIcon, "Could not load plugin", error);

        refreshList();
        pluginList.selectRow (engine.getChain().size() - 1);
    };

    if (found.isEmpty())
    {
        juce::AlertWindow::showMessageBoxAsync (juce::MessageBoxIconType::WarningIcon, "Could not load plugin",
                                                "No plugin found in " + file.getFullPathName());
        return;
    }

    if (found.size() == 1)
    {
        add (*found[0]);
        return;
    }

    // Shell bundles (several plugins in one .vst3)
    std::vector<juce::PluginDescription> descs;
    juce::PopupMenu menu;
    for (auto* d : found)
    {
        descs.push_back (*d);
        menu.addItem ((int) descs.size(), d->name);
    }

    menu.showMenuAsync (juce::PopupMenu::Options().withTargetComponent (addButton),
                        [add, descs] (int r) { if (r > 0) add (descs[(size_t) r - 1]); });
}

//==============================================================================
void MainComponent::openEditor (int row)
{
    auto* slot = engine.getChain().getSlot (row);
    if (slot == nullptr)
        return;

    auto* plugin = slot->plugin.get();

    if (auto it = pluginWindows.find (plugin); it != pluginWindows.end())
    {
        it->second->toFront (true);
        return;
    }

    pluginWindows[plugin] = std::make_unique<PluginWindow> (*plugin, [this, plugin]
    {
        juce::MessageManager::callAsync ([safe = juce::Component::SafePointer<MainComponent> (this), plugin]
        {
            if (safe != nullptr)
                safe->closeEditor (plugin);
        });
    });
}

void MainComponent::closeEditor (juce::AudioPluginInstance* plugin)
{
    pluginWindows.erase (plugin);
}

void MainComponent::closeAllPluginWindows()
{
    pluginWindows.clear();
}

void MainComponent::removeSelected()
{
    const int row = pluginList.getSelectedRow();
    auto* slot = engine.getChain().getSlot (row);
    if (slot == nullptr)
        return;

    closeEditor (slot->plugin.get());     // editor must die before its processor
    auto removed = engine.getChain().remove (row);
    removed.reset();

    refreshList();
    pluginList.selectRow (juce::jmin (row, engine.getChain().size() - 1));
}

void MainComponent::moveSelected (int delta)
{
    const int row = pluginList.getSelectedRow();
    const int target = row + delta;

    if (row < 0 || ! juce::isPositiveAndBelow (target, engine.getChain().size()))
        return;

    engine.getChain().move (row, target);
    refreshList();
    pluginList.selectRow (target);
}

void MainComponent::toggleBypassSelected()
{
    if (auto* slot = engine.getChain().getSlot (pluginList.getSelectedRow()))
    {
        slot->bypassed = ! slot->bypassed.load();
        refreshList();
    }
}

//==============================================================================
void MainComponent::timerCallback()
{
    auto& m = engine.meters;
    inputMeter.setLevel (m.input.exchange (0.0f));
    monitorMeter.setLevel (m.monitor.exchange (0.0f));
    streamMeter.setLevel (m.stream.exchange (0.0f));

    static int frame = 0;
    if (++frame % 10 != 0)
        return;

    juce::String text;

    if (auto* d = engine.getMonitorDevice().getCurrentAudioDevice())
    {
        const double sr = d->getCurrentSampleRate();
        const int bs = d->getCurrentBufferSizeSamples();
        const int pluginLatency = engine.getChain().getLatencySamples();
        const double roundTrip = (d->getInputLatencyInSamples() + d->getOutputLatencyInSamples()
                                  + (engine.params.monitorWet.load() ? pluginLatency : 0)) * 1000.0 / sr;

        text << "MON: " << engine.getMonitorDevice().getCurrentAudioDeviceType() << " / " << d->getName()
             << "  " << juce::String (sr, 0) << " Hz, " << bs << " smp\n"
             << "     round trip ~" << juce::String (roundTrip, 1) << " ms (plugins "
             << juce::String (pluginLatency * 1000.0 / sr, 1) << " ms)  CPU "
             << juce::String (engine.getMonitorDevice().getCpuUsage() * 100.0, 0) << "%  xruns " << d->getXRunCount() << "\n";
    }
    else
    {
        text << "MON: no device open\n\n";
    }

    if (auto* d = engine.getStreamDevice().getCurrentAudioDevice())
    {
        auto& f = engine.getFifo();
        text << "OBS: " << engine.getStreamDevice().getCurrentAudioDeviceType() << " / " << d->getName()
             << "  " << juce::String (d->getCurrentSampleRate(), 0) << " Hz\n"
             << "     buffer " << juce::String (f.getFillMs(), 1) << " ms" << (f.isBuffering() ? " (buffering)" : "")
             << "  drift " << juce::String (f.getCorrectionPpm(), 0) << " ppm"
             << "  under " << f.getUnderruns() << " / over " << f.getOverruns();
    }
    else
    {
        text << "OBS: no device open";
    }

    status.setText (text, juce::dontSendNotification);
}
