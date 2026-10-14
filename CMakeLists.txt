cmake_minimum_required(VERSION 3.22)

project(PocketStreamHost VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(FetchContent)

# ---- JUCE -------------------------------------------------------------------
set(JUCE_SOURCE_DIR "" CACHE PATH "Local JUCE checkout (leave empty to download)")
if(JUCE_SOURCE_DIR)
    add_subdirectory(${JUCE_SOURCE_DIR} ${CMAKE_BINARY_DIR}/juce EXCLUDE_FROM_ALL)
else()
    FetchContent_Declare(juce
        GIT_REPOSITORY https://github.com/juce-framework/JUCE.git
        GIT_TAG        8.0.9
        GIT_SHALLOW    TRUE)
    FetchContent_MakeAvailable(juce)
endif()

# ---- ASIO SDK (Windows only) ------------------------------------------------
option(PSH_ENABLE_ASIO "Build with ASIO support (Windows only)" ON)
set(ASIO_SDK_DIR "" CACHE PATH "Local ASIO SDK root (leave empty to download)")

if(WIN32 AND PSH_ENABLE_ASIO AND NOT ASIO_SDK_DIR)
    FetchContent_Declare(asiosdk
        URL https://download.steinberg.net/sdk_downloads/ASIO-SDK_2.3.4_2025-10-15.zip
        DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
    FetchContent_MakeAvailable(asiosdk)   # header-only use: no CMakeLists inside
    set(ASIO_SDK_DIR ${asiosdk_SOURCE_DIR})
endif()

# ---- App --------------------------------------------------------------------
juce_add_gui_app(PocketStreamHost
    PRODUCT_NAME "Pocket Stream Host"
    COMPANY_NAME "poket-stream-kit"
    VERSION      ${PROJECT_VERSION})

target_sources(PocketStreamHost PRIVATE
    Source/Main.cpp
    Source/MainComponent.cpp
    Source/AudioEngine.cpp
    Source/PluginChain.cpp
    Source/DriftFifo.cpp)

target_compile_definitions(PocketStreamHost PRIVATE
    JUCE_APPLICATION_NAME_STRING="$<TARGET_PROPERTY:PocketStreamHost,JUCE_PRODUCT_NAME>"
    JUCE_APPLICATION_VERSION_STRING="$<TARGET_PROPERTY:PocketStreamHost,JUCE_VERSION>"
    JUCE_DISPLAY_SPLASH_SCREEN=0
    JUCE_REPORT_APP_USAGE=0
    JUCE_USE_CURL=0
    JUCE_WEB_BROWSER=0
    JUCE_WASAPI=1
    JUCE_DIRECTSOUND=1
    JUCE_PLUGINHOST_VST3=1
    JUCE_PLUGINHOST_VST=0
    JUCE_PLUGINHOST_AU=0
    JUCE_PLUGINHOST_LADSPA=0
    JUCE_PLUGINHOST_LV2=0)

if(WIN32 AND PSH_ENABLE_ASIO)
    target_compile_definitions(PocketStreamHost PRIVATE JUCE_ASIO=1)
    target_include_directories(PocketStreamHost PRIVATE ${ASIO_SDK_DIR}/common)
endif()

target_link_libraries(PocketStreamHost
    PRIVATE
        juce::juce_audio_utils
        juce::juce_audio_processors
        juce::juce_audio_devices
    PUBLIC
        juce::juce_recommended_config_flags
        juce::juce_recommended_lto_flags
        juce::juce_recommended_warning_flags)

# ---- Tests ------------------------------------------------------------------
option(PSH_BUILD_TESTS "Build the DriftFifo simulation test" OFF)
if(PSH_BUILD_TESTS)
    juce_add_console_app(DriftFifoTest)
    target_sources(DriftFifoTest PRIVATE Tests/DriftFifoTest.cpp Source/DriftFifo.cpp)
    target_compile_definitions(DriftFifoTest PRIVATE JUCE_USE_CURL=0 JUCE_WEB_BROWSER=0 _USE_MATH_DEFINES)
    target_link_libraries(DriftFifoTest PRIVATE juce::juce_audio_basics PUBLIC juce::juce_recommended_config_flags)
    enable_testing()
    add_test(NAME DriftFifoTest COMMAND DriftFifoTest)
endif()
