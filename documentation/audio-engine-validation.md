# Historical engine validation record

These measurements describe the archived sources and workloads named below. They are retained for reproducibility and do not describe a separate current API version. For the current interface, read the [Sound reference](sound-api.md).

## Own-platform performance verification

The measurements in this section predate native variation and describe the archived revisions in the cited reports. They do not measure version 1.1.0. Its separate [variation verification](native-variation-validation.md) records compatibility, storage and callback checks.

The [performance review](../docs/validation/performance-review.json) separates measured host improvements, exact compatibility checks and pending device acceptance. Its [raw evidence](../docs/validation/performance-review-evidence.zip) retains rejected prototypes and the investigation of idle/stereo regressions. The Apple FIR, stable-control cache and exact idle-effects bypass were evaluated as one atomic candidate and then rejected after physical 32-stereo timing regressed. All three production changes were removed together; the full-score publication and control-memory fixes remain.

Matched 48 kHz/1024-frame iPad full-load runs completed 600 audio seconds without callback deadline misses, with p95 load upper bounds 0.427 for the reference and 0.383 for the rejected initial candidate. The original Apple callback was restored because 32-stereo bypass p95 regressed reproducibly, including continuous-voice windows. Android Sim20/Sim80 frame presentation remains near 60 FPS, while occasional Sim80 output underruns persist in both versions. Compact 48 kHz iPad memory growth is about 18.2 MiB in both versions; no material RAM saving or physical 192 kHz acceptance is claimed. These results and qualified listening observations are recorded separately in the review.

`tools/build_ios_render_host.py` compiles the actual Objective-C render-block body and voice/transport helpers on macOS. It replaces hardware/session/Titanium startup and fixes only the noise-seed/disabled-diagnostic clock. Output and semantic state are compared against a separately archived reference from the same platform. This is an Apple renderer test; it does not execute AVAudioEngine or establish iPad scheduling, route recovery, footprint or listening acceptance.

The commands below reproduce the historical pre-pipeline performance review. Use its archived candidate source when requiring exact PCM/state equality with `7ab3110`; the renderer since 1.0.2 intentionally removes the old final-output delay and changes overload behavior, so it cannot satisfy that earlier exact-output comparison. For the later correction, use the [audio pipeline validation](audio-pipeline-validation.md) protocol: align only the former output delay, compare no-overload PCM within the declared tolerance, and retain overload differences separately. The module's `tools/compare_output_pcm.py` checks the corresponding matched Android/Apple capture sets; host comparisons do not establish physical output latency.

```sh
mkdir -p /tmp/synth-reference
git archive 7ab3110 | tar -x -C /tmp/synth-reference
python3 tools/build_ios_render_host.py --source /tmp/synth-reference --output /tmp/apple-reference
python3 tools/build_ios_render_host.py --output /tmp/apple-candidate
python3 tools/compare_ios_render.py /tmp/apple-reference /tmp/apple-candidate
python3 tools/benchmark_performance_review.py --baseline /tmp/apple-reference --candidate /tmp/apple-candidate --output /tmp/apple-performance.json
/tmp/apple-candidate --metadata
```

The build tool defaults to the module's Apple Release `-Os` optimization. The comparator streams PCM for every fixture block and full original voice/tail, FIR/filter, limiter, effect-buffer and transport state at fixture checkpoints. Cases include five engine rates, zero/short/irregular blocks, all sources, held updates, replacements, send and position ramps, four sequences, effects, panic, drain and later re-enabling. A deliberately changed phase increment was rejected as a negative control.

Finish compilation and fidelity checks before timing. The benchmark uses fixed matched warmups and at least ten alternating pairs; CPU and elapsed totals, p95, maxima and process high-water memory remain separate. Investigate repeatable total regressions above 2% or p95 regressions above 5%. Short-process or single-kernel gains do not establish whole-app performance. The Android producer harness exercises the actual JNI publication with supplied JVM array accessors, so its numbers exclude Java validation and VM allocation time.

Full-score producers reserve a free bank without copying the previous score. Generic partial-bank callers still inherit the latest accepted bank, and publication retains its ownership, validation and mailbox checks. The iOS producer commits an already prepared score once; Android prepares its complete packet at native publication. Empty completion polls and empty metadata pruning avoid transient objects. Accepted edits of unknown iOS IDs do not create retained spatial metadata. Sequence capacity, diagnostics, event delivery cadence and public defaults are unchanged.

The shared processor check is `cc -std=c99 -O2 -Wall -Wextra -Wpedantic tests/spatial_regression.c -lm -o /tmp/spatial_regression` followed by `/tmp/spatial_regression`. `tests/spatial_engine_host.cpp` uses the same compile flags as `engine_render_host.cpp` and verifies native left/right rendering, elevation changes, stealing and stopping. Java spatial validation is checked by `SynthSpatialContractRegression`; the common Java/iOS corpus also covers spatial acceptance and conflicts.

### Reproduce a host CPU comparison

Compile `tests/spatial_benchmark_host.cpp` with the same Oboe/JDK includes and definitions as `engine_render_host.cpp` above, replacing the source filename and choosing an output such as `/tmp/spatial_benchmark`. Supply a whitespace-separated timeline, one event per line, with these 25 columns in order:

```text
timeMs frequency frequencyEnd durationMs attackMs releaseMs decayMs sustain waveType volume noiseRate noiseRateEnd lowPassHz pulseWidth lfoFreq lfoDepth filterTypeIndex filterHz filterHzEnd filterQ fmRatio fmDepth fmDepthEnd pan panEnd
```

The filter indices are 0=none, 1=lowpass, 2=highpass and 3=bandpass. This internal harness bypasses public contract validation, so only feed valid event recipes. In binaural mode every event uses its `pan` column as spatialX and a synthetic moving elevation `0.8 * sin(timeMs / 1000)`; the other pan column is irrelevant to that mode. This tests CPU, not the localization of the original timeline.

```sh
python3 tools/benchmark_spatial.py /tmp/spatial_benchmark /path/to/timeline.txt
```

The script compares stereo and binaural using a warmup and five measured trials, reporting the median by audio processing time. There is no hardware stream or JavaScript bridge. Results include peak level, non-finite/clipped frames, voice replacements and processing time; they do not measure device CPU, latency, underruns, heat or battery.

## Unified transport acceptance boundaries

TiSynth uses one renderer, at most 32 voices and capacity for 1-4 sequences. `bus` categories and per-voice sends share one effects chain. These API changes do not establish complete multiplatform ten-minute maximum-load acceptance; the measured iPad result and Android limits are recorded separately in [physical validation](../docs/validation/physical-validation.json) and [the performance summary](stats-performance.md). Host timing, bypass comparisons, memory accounting, actual Android/iOS builds and the remaining device/listening checks are separate evidence. The cited Studio and unified-transport benchmarks are historical observations. In the pre-variation layout, effects buffers at 192 kHz used approximately 13.1 MiB and four maximum-size triple-bank transports used 8,627,712 bytes (8.23 MiB), excluding renderer voices and queues. Version 1.1.0 grows those four transports to 9,537,152 bytes (9.10 MiB) on the measured 64-bit macOS layout, an increase of 909,440 bytes; see [variation storage measurements](native-variation-validation.md#storage-and-callback-work). These structure sizes are not a new whole-process or physical-device measurement. Total accounting must also include renderer voices/tails, command queues, effects, bridge/canonical options and recovery peaks. The 32 MiB additional-memory target remains a target, not a certified bound for version 1.1.0.

