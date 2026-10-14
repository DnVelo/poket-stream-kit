// Simulates two free-running devices and checks that DriftFifo locks onto
// the target fill level without underruns and with clean audio.
#include "../Source/DriftFifo.h"
#include <cmath>
#include <cstdio>

// nominal rates are what the devices report; inPpm/outPpm is how far their real clocks are off
static int runCase (double inNominal, int inBlock, double outNominal, int outBlock, double seconds,
                    double inPpm = 0.0, double outPpm = 0.0)
{
    const double inRate  = inNominal  * (1.0 + inPpm  * 1e-6);
    const double outRate = outNominal * (1.0 + outPpm * 1e-6);

    DriftFifo fifo;
    fifo.setWriterSampleRate (inNominal);
    fifo.setReaderSampleRate (outNominal);
    fifo.setTargetLatencyMs (30.0);

    const double freq = 1000.0;
    std::vector<float> inL ((size_t) inBlock), inR ((size_t) inBlock), outL ((size_t) outBlock), outR ((size_t) outBlock);

    double tIn = 0.0, tOut = 0.0, inPhase = 0.0;
    bool locked = false;
    double errSq = 0.0, sigSq = 0.0;
    float lastFill = 0.0f;
    int startUnderruns = 0;

    const double end = seconds;
    while (tOut < end)
    {
        // advance whichever device's next callback is due first
        if (tIn <= tOut)
        {
            for (int i = 0; i < inBlock; ++i)
            {
                inL[(size_t) i] = inR[(size_t) i] = (float) std::sin (inPhase);
                inPhase += 2.0 * M_PI * freq / inRate;
            }
            fifo.push (inL.data(), inR.data(), inBlock);
            tIn += inBlock / inRate;
        }
        else
        {
            fifo.pull (outL.data(), outR.data(), outBlock);
            tOut += outBlock / outRate;

            if (tOut > end * 0.5)   // second half: measure steady-state
            {
                if (! locked)
                {
                    locked = true;
                    startUnderruns = fifo.getUnderruns();
                }

                for (int i = 0; i < outBlock; ++i)
                {
                    // compare against a local sine fit: y[n+1] = 2cos(w)y[n] - y[n-1]
                    if (i >= 2)
                    {
                        const double w = 2.0 * M_PI * freq * (inNominal / inRate) / (outNominal / outRate) / outNominal;
                        const double pred = 2.0 * std::cos (w) * outL[(size_t) i - 1] - outL[(size_t) i - 2];
                        errSq += (pred - outL[(size_t) i]) * (pred - outL[(size_t) i]);
                        sigSq += outL[(size_t) i] * outL[(size_t) i];
                    }
                }
            }
            lastFill = fifo.getFillMs();
        }
    }

    const double snrDb = 10.0 * std::log10 (sigSq / std::max (errSq, 1e-20));
    const int under = fifo.getUnderruns() - startUnderruns;
    const bool ok = under == 0 && std::abs (lastFill - 30.0f) < 6.0f && snrDb > 60.0;

    std::printf ("%-5s in %.0f%+.0fppm/%d  out %.0f%+.0fppm/%d  fill %.1f ms  corr %+.0f ppm  steady underruns %d  SNR %.1f dB\n",
                 ok ? "OK" : "FAIL", inNominal, inPpm, inBlock, outNominal, outPpm, outBlock, lastFill,
                 fifo.getCorrectionPpm(), under, snrDb);
    return ok ? 0 : 1;
}

int main()
{
    int failures = 0;
    failures += runCase (48000.0, 128, 48000.0, 480,  60.0);
    failures += runCase (48000.0, 128, 48000.0, 480, 120.0,  100.0, -100.0); // 200 ppm apart
    failures += runCase (48000.0,  64, 48000.0, 441, 120.0, -150.0,   50.0);
    failures += runCase (48000.0, 256, 44100.0, 441,  60.0,   30.0,  -20.0); // rate conversion + drift
    failures += runCase (44100.0, 512, 48000.0, 480,  60.0,  -40.0,   40.0);
    return failures;
}
