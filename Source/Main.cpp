#include <juce_gui_basics/juce_gui_basics.h>
#include "AudioEngine.h"
#include "MainComponent.h"

class PocketStreamHostApp : public juce::JUCEApplication
{
public:
    const juce::String getApplicationName() override    { return JUCE_APPLICATION_NAME_STRING; }
    const juce::String getApplicationVersion() override { return JUCE_APPLICATION_VERSION_STRING; }
    bool moreThanOneInstanceAllowed() override          { return false; }

    void initialise (const juce::String&) override
    {
        engine = std::make_unique<AudioEngine>();
        engine->loadState();
        window = std::make_unique<MainWindow> (getApplicationName(), *engine);
    }

    void shutdown() override
    {
        if (window != nullptr)
            window->closePluginWindows();

        engine->saveState();
        window = nullptr;   // GUI first: plugin editors must go before the plugins
        engine->shutdown();
        engine = nullptr;
    }

    void systemRequestedQuit() override { quit(); }

private:
    class MainWindow : public juce::DocumentWindow
    {
    public:
        MainWindow (const juce::String& name, AudioEngine& engine)
            : DocumentWindow (name, juce::Colour (0xff2a2a2a), DocumentWindow::allButtons)
        {
            setUsingNativeTitleBar (true);
            content = new MainComponent (engine);
            setContentOwned (content, true);
            setResizable (true, false);
            setResizeLimits (460, 520, 1200, 1600);
            centreWithSize (getWidth(), getHeight());
            setVisible (true);
        }

        void closePluginWindows() { content->closeAllPluginWindows(); }
        void closeButtonPressed() override { JUCEApplication::getInstance()->systemRequestedQuit(); }

    private:
        MainComponent* content = nullptr;
    };

    std::unique_ptr<AudioEngine> engine;
    std::unique_ptr<MainWindow> window;
};

START_JUCE_APPLICATION (PocketStreamHostApp)
