# PerformanceBench

Two benchmark hosts that run the same scripted camera session on a physical iPhone and report what each engine costs: display-link cadence on the main thread, engine frames, process CPU, physical memory footprint. `ImmersiveMapBench` links only ImmersiveMap; `MapboxBench` links only the Mapbox Maps SDK for iOS (v11, from SwiftPM). One SDK per process keeps the picture honest: what a run reports belongs to its engine, with no second map SDK resident in the binary. The scenario, the metrics and the secrets are shared sources in `Shared/`, compiled into both apps, so the two engines replay exactly the same session. It exists to put a number next to "how does it compare"; it is never part of CI and it is not a test.

One launch measures one engine variant in one cache state, chosen through the launch environment, then quits. `run_bench.sh` picks the app by the engine name, launches it once per combination and collects the JSON each run prints.

## What is measured

Every run replays one `BenchScenario` script, chosen by `BENCH_SCENARIO`, through the same four windows: warm-up at a globe view, a five-shot tour chained by animated flights, a twenty-second programmatic pan that sets the camera once per display refresh from a strict timer at the display rate, the way a drag gesture does, and ten seconds of an idle map. `full` (the default) is the mixed session: dense downtowns at street zoom with tilt (Manhattan, Berlin, Paris, Tokyo, then back to the globe), a Midtown pan, an idle street map. `globe` never leaves the sphere: every pose stays well below the flat transition, the tour covers the whole planet below zoom 2 (deep tone, surface layers lit inline) and region views up to zoom 4.8 (plain palette, layers blend unlit under the deferred lighting pass), and the pan spins the planet the way a drag does. `globe0` holds every window at zoom 0 and fits the whole run in about fifteen seconds: the whole planet on screen, tone at its deepest, every tile fragment lit inline; the flight and the pan only rotate the planet. Poses are shared and converted per engine: degrees to radians for ImmersiveMap, a 512 px Mercator zoom for both, so equal zooms load equal tile levels.

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
for app in ImmersiveMapBench MapboxBench; do
  xcodebuild -project "Tools/PerformanceBench/$app.xcodeproj" \
    -scheme "$app" -configuration Release \
    -destination 'id=<device-id>' -derivedDataPath "DerivedData/$app" build
  xcrun devicectl device install app --device <device-id> \
    "DerivedData/$app/Build/Products/Release-iphoneos/$app.app"
done
Tools/PerformanceBench/run_bench.sh <device-id>              # the default matrix
Tools/PerformanceBench/run_bench.sh <device-id> immersivemap:warm mapbox-standard:warm
Tools/PerformanceBench/run_bench.sh <device-id> immersivemap:warm:globe    # the sphere-only scenario
```

Launch environment: `BENCH_ENGINE` picks the variant within its app (`immersivemap`, `immersivemap-noshadows`, `immersivemap-lean` for shadows off, `immersivemap-nosky` for transparent space, which drops the starfield entirely, `immersivemap-bare` for the planet alone (the same frame as `immersivemap-nosky`, kept for measurement continuity), in `ImmersiveMapBench`; `mapbox-standard`, `mapbox-standard-msaa4`, `mapbox-streets` in `MapboxBench`), `BENCH_SCENARIO` picks the script (`full`, the default, `globe` or `globe0`; the third field of a `run_bench.sh` combo), `BENCH_CACHE` (`warm`, or `cold` to clear the disk caches before the map is made), `BENCH_FPS` (default 120), `BENCH_EXIT` (`0` keeps the app open after the run), and for `ImmersiveMapBench` only, `BENCH_CONTINUOUS` (`1` forces continuous rendering, so the on-demand loop never pauses its display link between the pan's one-shot frames; the A/B for the pause cost, see below). Results land in `Tools/PerformanceBench/Output/` (gitignored) as one log and one JSON per run, and `summarize.py` turns a folder of them into a comparison table (`BENCH_OUT` points the script at another folder).

The device must be unlocked when a run starts; the app disables auto-lock for its duration. Keep the phone off the charger cable's heat and give it the cooldown the script inserts between runs, and read the thermal state before trusting a number.

## GPU time and the real frame rate

GPU time per frame is not visible from inside the process, and the host display link turned out to be a poor frame-rate proxy: a second display link in a process whose engine runs its own `CAMetalDisplayLink` coalesces with it and settles on every other vsync (60 ticks per second while ImmersiveMap presents 120), hiding differences between variants. For the same reason the pan is driven from a strict GCD timer at the display rate rather than from that link; driven from the link, ImmersiveMap's pan camera moved at 60 Hz while Mapbox's moved at 120 Hz, and the two pans were not the same session. The pan then still measured 104 frames per second on screen for ImmersiveMap against 119 for Mapbox: a programmatic jump requests one frame and holds no activity, so after each frame the on-demand loop pauses its `CAMetalDisplayLink` and the next jump resumes it, and a resumed link skips vsyncs. With `BENCH_CONTINUOUS=1` (the link never pauses) the same pan holds 117 to 120. A real drag never sees this, because a gesture holds the interaction activity for its whole duration; a programmatic camera driven per frame does, which is what the bench's pan is. The reference for both is a Metal System Trace recorded on the device, exported to XML and summarized by `trace_gpu.py`: on-screen frames per second (`displayed-surfaces-per-second`), GPU time per second by channel, the GPU span per frame, and GPU time by encoder label (the engine names its passes, so `world`, `shadowMap` and `overlay` show up by name):

```sh
xcrun xctrace record --device <device-id> --template 'Metal System Trace' --time-limit 45s \
  --output Traces/bench/im.trace --env BENCH_ENGINE=immersivemap --env BENCH_CACHE=warm --env BENCH_EXIT=0 \
  --launch -- com.artembobkin.ImmersiveMapBench
for t in gpu:metal-gpu-intervals dsps:displayed-surfaces-per-second enc:metal-application-encoders-list; do
  xcrun xctrace export --input Traces/bench/im.trace \
    --xpath "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"${t##*:}\"]" --output Traces/bench/im-${t%%:*}.xml
done
Tools/PerformanceBench/trace_gpu.py Traces/bench/im-gpu.xml Traces/bench/im-dsps.xml Traces/bench/im-enc.xml
```

`Traces/` is gitignored. Network bytes are not counted, so a cold run's numbers include whatever each service's CDN was doing that minute. The two engines draw different styles from different data (ImmersiveMap's own tiles against Mapbox Standard or Streets), so this compares two products at their defaults, not two renderers on identical input.
