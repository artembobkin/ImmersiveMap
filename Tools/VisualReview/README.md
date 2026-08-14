# Visual Review

A macOS app for the pass a person makes over the rendering before a release:
it renders a fixed set of scenes to images and short clips, then walks you
through them one at a time so you can mark each one right or wrong.

This is the counterpart to the automated suite, not a replacement for it. The
tests in `Tests/ImmersiveMapTests` assert properties a machine can decide (a
corner is unpainted, N pixels carry a colour, the frame got darker). Whether a
shadow looks like a shadow, whether labels are legible, whether a descent from
orbit reads as smooth, is judged by the person at the screen. This tool exists
to put those judgements in front of that person on purpose, on a schedule,
instead of hoping someone notices.

## If you were asked to help test

You need a Mac with Xcode and an iPhone. Everything else the app does for you.

1. Clone the repository, open `ImmersiveMap.xcworkspace`.
2. Pick the **ImmersiveMapVisualReviewIOS** scheme, choose your iPhone as the
   destination, press Run. Xcode may ask you to trust the developer on the
   phone the first time (Settings, General, VPN & Device Management).
3. In the app, press **Start the check** and leave the phone alone for a few
   minutes. It renders every scene in the catalogue on your hardware.
4. It then shows you one picture at a time with a sentence saying what to look
   at. Approve it, or reject it and write what is wrong. It moves on by itself.
5. At the end, press **Make the report**, then **Send the report**, and AirDrop
   or message the zip back. That one file has the judgements, every picture
   they were made about, and which phone, GPU and commit produced them.

Nothing needs to be committed, and nothing needs to be found in a folder.

## Running it

Open `ImmersiveMap.xcworkspace`, pick the **ImmersiveMapVisualReview** scheme
and run. It is not part of CI and never runs on a pull request.

There is a second scheme, **ImmersiveMapVisualReviewIOS**, that runs the same
catalogue on an iPhone. Same sources, one screen at a time. It exists because a
Mac cannot answer every question. Shadows rasterize through layered rendering,
which the iOS simulator does not have, so the only place the iOS shadow path
can be looked at is a device.

The phone build is a guided pass rather than a tool: one start button, then one
picture at a time, then a report. That shape is deliberate. A pass is worth
much more when somebody else can make it, and somebody else will not learn what
a catalogue is, which button renders, or where a verdict file ends up. The
catalogue list is still behind the finish screen for a session that was
interrupted, but no part of a complete pass requires going through it.

1. **Render all** renders every scenario in the catalogue. Stills go through
   `ImmersiveMapStillRecorder` with nothing on screen; each video takes a turn
   with a live map, because the video recorder only works attached to one.
2. Walk the list. `A` approves the current scene, `R` rejects it (a rejection
   needs a description, since a note to nobody helps nobody). Both bindings are
   printed on the buttons under the render, and both stand down while the note
   field has focus, so a rejection can be typed without triggering them.
3. Verdicts are written to `verdicts.json` next to this file, and that file is
   committed.

## Two verdict files, one per platform

A Mac pass writes `verdicts.json`; a phone pass writes `verdicts.ios.json`.
They are separate on purpose. The two render on different GPUs at different
sizes, so a scenario's fingerprint from one never matches the other: sharing a
file would make every entry read as changed, and merging a phone pass back into
the checkout would overwrite a Mac verdict with a judgement about a picture
nobody looked at on a Mac. Both files are committed.

On a phone there is no checkout to write into, so the renders and the verdict
file live in the app's own container. They come back inside the report zip, and
`verdicts.ios.json` in it is the file to move next to this README. The
container is also visible in the Files app, so anything can be pulled off that
way too.

## The report

**Make the report** packs a pass into one zip, on both platforms:

- `report.json`: one entry per scenario with the outcome (approved, rejected,
  not reviewed, failed to render), the note, the fingerprint, the path of the
  render inside the zip, and whether that render still matches the approval
  committed in the checkout. Alongside it, the environment: model identifier,
  OS version, Metal device name, commit and app version.
- `README.txt`: the same thing as a page of text, for whoever opens the zip
  first.
- `verdicts.json` or `verdicts.ios.json`, unchanged, so a pass made on someone
  else's phone drops straight into this folder instead of being retyped.
- `Renders/`: every picture the judgements were made about.

Reports are written to `Reports/` next to this file on a Mac, and into the
app's Documents container on a phone, where the Files app can also reach them.
They are gitignored: the report is a copy of state that already lives in the
checkout, plus renders, which is not something to accumulate in git. Only the
newest is kept.

## What the fingerprint is for

Reviewing forty scenes from scratch every release is how a ritual like this
dies. Each rendered artifact gets a coarse fingerprint, stored with the verdict
it was approved under. On the next run anything that still matches is marked
unchanged, and **Needs a look** filters the list down to what actually moved.

The fingerprint is deliberately blunt: a 16x16 thumbnail with each channel
quantized to 4 bits. Rendering is not bit-identical across GPU models, driver
versions or macOS updates, and an exact hash would call every scene changed the
first time you reviewed on a different machine, which is precisely when you
would stop trusting it. It never decides that a picture is good, only that it
is the same picture.

## Adding a scenario

Add it to `VisualReviewCatalogue.scenarios`. Give it:

- a stable `id`, which is the key its verdict history is stored under, so
  renaming it forgets every verdict it ever had;
- a `lookFor` sentence saying what to examine, so the scene is judged against
  the same question this release as last;
- a camera, or for a video an establish position and a list of shots.

A feature that ships without a scenario here does not get looked at before a
release.

## Layout

- `verdicts.json` is committed. It is the record of what a person approved and
  when, against which commit.
- `Output/` holds the renders and is gitignored: large, machine specific, and
  regenerated on demand.

## Determinism

Every scenario pins the scene date, so the sun, the terminator and the night
side land in the same place on every run. Without that, half the catalogue
would differ from its last approval for a reason that has nothing to do with
the code.
