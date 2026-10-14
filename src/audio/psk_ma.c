/* miniaudio の実体化と、Zig から呼ぶための薄い窓口（PSK_ENGINE §1.2: ASIO 以外の入出力は miniaudio）。
 *
 * Zig から miniaudio.h を直接読む（translate-c）と巨大なヘッダの解釈に頼ることになるので、
 * 本ツールが使う操作だけを C の関数にして出す。音の処理はここに置かない。
 *
 * ケーブルの入出力は低遅延を求めない（PSK_ENGINE §3.3）ので、共有モード・conservative の設定で開く。
 *
 * MA_ENABLE_ONLY_SPECIFIC_BACKENDS を使う以上、プラットフォームを増やしたらここも増やす。
 * Gear-vk では Android と Linux の移植で指定し忘れ、ma_context_init が MA_NO_BACKEND(-203) を返して
 * 音が一切鳴らなかった（同リポの miniaudio_impl.c の注意書き）。
 *
 * 持ち込んだ miniaudio.h には1か所だけ手を入れてある（"poket-stream-kit patch" で検索）。
 * ma_context_get_MMDevice__wasapi が COM の初期化の成否を見ずに CoUninitialize していて、
 * ASIO 用に STA で初期化したスレッドの COM を壊していた（2026-10-14 に偽ドライバ＋Wine で発覚）。
 * miniaudio を更新するときは、このパッチが要るか（上流で直っているか）を確かめること。
 */
#define MA_ENABLE_ONLY_SPECIFIC_BACKENDS
#if defined(_WIN32)
    #define MA_ENABLE_WASAPI
#elif defined(__ANDROID__)
    #define MA_ENABLE_AAUDIO
    #define MA_ENABLE_OPENSL
#elif defined(__linux__)
    #define MA_ENABLE_ALSA
#endif
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#include <stdlib.h>
#include <string.h>

typedef void (*psk_ma_callback)(void* user, float* out, const float* in, unsigned int frames, unsigned int channels);

typedef struct psk_ma_device {
    ma_device device;
    psk_ma_callback cb;
    void* user;
    char name[256];
} psk_ma_device;

static ma_context g_context;
static int g_context_ready = 0;

int psk_ma_init(void)
{
    if (g_context_ready) return 0;
    ma_result r = ma_context_init(NULL, 0, NULL, &g_context);
    if (r != MA_SUCCESS) return (int)r;
    g_context_ready = 1;
    return 0;
}

void psk_ma_uninit(void)
{
    if (!g_context_ready) return;
    ma_context_uninit(&g_context);
    g_context_ready = 0;
}

static int get_infos(int capture, ma_device_info** infos, ma_uint32* count)
{
    ma_device_info* playback; ma_uint32 nplay;
    ma_device_info* cap; ma_uint32 ncap;
    if (!g_context_ready) return -1;
    ma_result r = ma_context_get_devices(&g_context, &playback, &nplay, &cap, &ncap);
    if (r != MA_SUCCESS) return (int)r;
    *infos = capture ? cap : playback;
    *count = capture ? ncap : nplay;
    return 0;
}

int psk_ma_device_count(int capture)
{
    ma_device_info* infos; ma_uint32 count;
    if (get_infos(capture, &infos, &count) != 0) return 0;
    return (int)count;
}

/* 名前を UTF-8 で buf へ。戻り値は書いたバイト数（失敗は -1）。 */
int psk_ma_device_name(int capture, int index, char* buf, int cap)
{
    ma_device_info* infos; ma_uint32 count;
    if (cap <= 0 || get_infos(capture, &infos, &count) != 0 || index < 0 || (ma_uint32)index >= count) return -1;
    size_t n = strlen(infos[index].name);
    if (n >= (size_t)cap) n = (size_t)cap - 1;
    memcpy(buf, infos[index].name, n);
    buf[n] = 0;
    return (int)n;
}

static void data_callback(ma_device* dev, void* out, const void* in, ma_uint32 frames)
{
    psk_ma_device* d = (psk_ma_device*)dev->pUserData;
    unsigned int ch = d->device.type == ma_device_type_capture ? d->device.capture.channels : d->device.playback.channels;
    d->cb(d->user, (float*)out, (const float*)in, frames, ch);
}

/* 名前に name_contains を含む最初のデバイスを開く（NULL か空なら既定のデバイス）。開いたら止まった状態で返す。 */
psk_ma_device* psk_ma_open(int capture, const char* name_contains, unsigned int channels,
                           psk_ma_callback cb, void* user, int* err)
{
    ma_device_info* infos; ma_uint32 count;
    const ma_device_id* id = NULL;
    const char* found = NULL;
    *err = 0;

    int gr = get_infos(capture, &infos, &count);
    if (gr != 0) { *err = gr; return NULL; }
    if (name_contains != NULL && name_contains[0] != 0) {
        for (ma_uint32 i = 0; i < count; ++i) {
            if (strstr(infos[i].name, name_contains) != NULL) { id = &infos[i].id; found = infos[i].name; break; }
        }
        if (id == NULL) { *err = -2; return NULL; } /* 見つからない */
    }

    psk_ma_device* d = (psk_ma_device*)calloc(1, sizeof(psk_ma_device));
    if (d == NULL) { *err = -3; return NULL; }
    d->cb = cb;
    d->user = user;

    ma_device_config cfg = ma_device_config_init(capture ? ma_device_type_capture : ma_device_type_playback);
    cfg.performanceProfile = ma_performance_profile_conservative;
    cfg.dataCallback = data_callback;
    cfg.pUserData = d;
    cfg.sampleRate = 0; /* デバイス本来のレート（レートの違いは橋渡しの FIFO が吸収する） */
    if (capture) {
        cfg.capture.pDeviceID = id;
        cfg.capture.format = ma_format_f32;
        cfg.capture.channels = channels;
        cfg.capture.shareMode = ma_share_mode_shared;
    } else {
        cfg.playback.pDeviceID = id;
        cfg.playback.format = ma_format_f32;
        cfg.playback.channels = channels;
        cfg.playback.shareMode = ma_share_mode_shared;
    }

    ma_result r = ma_device_init(&g_context, &cfg, &d->device);
    if (r != MA_SUCCESS) { free(d); *err = (int)r; return NULL; }

    const char* nm = found;
    if (nm == NULL) nm = capture ? d->device.capture.name : d->device.playback.name;
    strncpy(d->name, nm, sizeof(d->name) - 1);
    return d;
}

unsigned int psk_ma_sample_rate(psk_ma_device* d) { return d->device.sampleRate; }

unsigned int psk_ma_period_frames(psk_ma_device* d)
{
    return d->device.type == ma_device_type_capture ? d->device.capture.internalPeriodSizeInFrames
                                                    : d->device.playback.internalPeriodSizeInFrames;
}

const char* psk_ma_name(psk_ma_device* d) { return d->name; }

int psk_ma_start(psk_ma_device* d) { return (int)ma_device_start(&d->device); }

void psk_ma_close(psk_ma_device* d)
{
    if (d == NULL) return;
    ma_device_uninit(&d->device);
    free(d);
}
