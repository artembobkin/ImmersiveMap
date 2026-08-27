# ImmersiveMapPerformanceBench

A benchmark host that runs the same scripted camera session on ImmersiveMap and on the Mapbox Maps SDK for iOS (v11, from SwiftPM) on a physical iPhone, and reports what each costs: display-link cadence on the main thread, engine frames, process CPU, physical memory footprint. It exists to put a number next to "how does it compare"; it is never part of CI and it is not a test.

The app links both SDKs, and one launch measures one engine in one cache state, chosen through the launch environment, then quits. `run_bench.sh` launches it once per combination and collects the JSON each run prints.

## What is measured

Every run replays `BenchScenario`: eight seconds of warm-up at a globe view, a five-shot city tour (Manhattan, Berlin, Paris, Tokyo at street zoom with tilt, then back to the globe) chained by animated flights, a twenty-second programmatic pan that sets the camera on every display tick the way a drag gesture does, and ten seconds of an idle map. Poses are shared and converted per engine: degrees to radians for ImmersiveMap, a 512 px Mercator zoom for both, so equal zooms load equal tile levels.

Per window the result carries:

| Field | Meaning |
|---|---|
| `hostTicksPerSecond`, `hostInterval*Ms` | A `CADisplayLink` on the main thread at the requested rate (120 Hz on ProMotion). Its cadence says whether the engine's main-thread work keeps up with the display. |
| `hostHitches`, `hostHitchTimeMs` | Ticks that arrived two or more vsyncs late, and the time lost inside them. |
| `engineFramesPerSecond` | Frames the engine reported: `onRenderFrameFinished` for Mapbox, `onCameraPositionChanged` for ImmersiveMap (which has no public frame callback; the camera callback fires once per frame the camera moves). Comparable only while the camera moves. |
| `cpuAveragePercent`, `cpuPeakPercent` | Process CPU time over wall time, all threads, sampled four times a second. 100 is one core. |
| `memoryAverageMB`, `memoryPeakMB` | `phys_footprint`, the number Xcode's memory gauge and jetsam use. |

The result also records the device, the OS, Low Power Mode and the thermal state at start and end: a run that ends `serious` was throttled and should be repeated.

## Running

Keys come from the gitignored `LocalSecrets.plist` at the repository root (`IMMERSIVEMAP_API_KEY`, `MAPBOX_ACCESS_TOKEN`), copied into the bundle by the "Bundle LocalSecrets" phase; the environment variables of the same names win when set. The Mapbox token is a public `pk.` token with the default scopes.

```sh
xcrun xctrace list devices                                   # find the device id
xcodebuild -project Tools/PerformanceBench/ImmersiveMapPerformanceBench.xcodeproj \
  -scheme ImmersiveMapPerformanceBench -configuration Release \
  -destination 'id=<device-id>' -derivedDataPath DerivedData/Bench build
xcrun devicectl device install app --device <device-id> \
  DerivedData/Bench/Build/Products/Release-iphoneos/ImmersiveMapPerformanceBench.app
Tools/PerformanceBench/run_bench.sh <device-id>              # the default matrix
Tools/PerformanceBench/run_bench.sh <device-id> immersivemap:warm mapbox-standard:warm
```

Launch environment: `BENCH_ENGINE` (`immersivemap`, `immersivemap-noshadows`, `immersivemap-lean` for shadows and atmosphere off, `mapbox-standard`, `mapbox-standard-msaa4`, `mapbox-streets`), `BENCH_CACHE` (`warm`, or `cold` to clear the disk caches before the map is made), `BENCH_FPS` (default 120), `BENCH_EXIT` (`0` keeps the app open after the run). Results land in `Tools/PerformanceBench/Output/` (gitignored) as one log and one JSON per run, and `summarize.py` turns a folder of them into a comparison table (`BENCH_OUT` points the script at another folder).

The device must be unlocked when a run starts; the app disables auto-lock for its duration. Keep the phone off the charger cable's heat and give it the cooldown the script inserts between runs, and read the thermal state before trusting a number.

## GPU time and the real frame rate

GPU time per frame is not visible from inside the process, and the host display link turned out to be a poor frame-rate proxy (it coalesces with the engine's own `CAMetalDisplayLink` and settles on its cadence, hiding differences between variants). The reference for both is a Metal System Trace recorded on the device, exported to XML and summarized by `trace_gpu.py`: on-screen frames per second (`displayed-surfaces-per-second`), GPU time per second by channel, the GPU span per frame, and GPU time by encoder label (the engine names its passes, so `world`, `shadowMap` and `overlay` show up by name):

```sh
xcrun xctrace record --device <device-id> --template 'Metal System Trace' --time-limit 45s \
  --output Traces/bench/im.trace --env BENCH_ENGINE=immersivemap --env BENCH_CACHE=warm --env BENCH_EXIT=0 \
  --launch -- com.artembobkin.ImmersiveMapPerformanceBench
for t in gpu:metal-gpu-intervals dsps:displayed-surfaces-per-second enc:metal-application-encoders-list; do
  xcrun xctrace export --input Traces/bench/im.trace \
    --xpath "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"${t##*:}\"]" --output Traces/bench/im-${t%%:*}.xml
done
Tools/PerformanceBench/trace_gpu.py Traces/bench/im-gpu.xml Traces/bench/im-dsps.xml Traces/bench/im-enc.xml
```

`Traces/` is gitignored. Network bytes are not counted, so a cold run's numbers include whatever each service's CDN was doing that minute. The two engines draw different styles from different data (ImmersiveMap's own tiles against Mapbox Standard or Streets), so this compares two products at their defaults, not two renderers on identical input.
