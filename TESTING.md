# Testing ImmersiveMap on your own device

Thank you for helping. This takes about half an hour, most of which is the
phone rendering while you do something else.

ImmersiveMap draws maps with Metal. Automated tests can check that a corner is
not painted or that a frame got darker, but nothing can decide whether a shadow
looks like a shadow or whether a label is readable. A person has to look, on
real hardware, because every phone renders slightly differently. That is what
you are doing here.

## What you need

- A Mac with Xcode 26 or later.
- An iPhone on iOS 18 or later, and a cable.
- An Apple ID. The free one is enough.
- Internet on the phone: the map downloads its tiles as it renders.

## Run it

1. Clone this repository and open `ImmersiveMap.xcworkspace`.
2. Plug the iPhone in, unlock it, tap **Trust** if it asks.
3. In the scheme picker at the top of the Xcode window choose
   **ImmersiveMapVisualReviewIOS**, and next to it choose your iPhone.
4. If Xcode complains about signing: open the project settings, select the
   `ImmersiveMapVisualReviewIOS` target, go to **Signing & Capabilities**, pick
   your own team, and change the bundle identifier to something of your own
   (for example `com.yourname.ImmersiveMapVisualReviewIOS`).
5. Press Run. The first build takes a few minutes. It builds in Release on
   purpose: a debug build of the engine drops frames and you would be judging
   the wrong thing.
6. The first time on a new phone, iOS refuses to open the app until you trust
   the developer: Settings, General, VPN & Device Management, tap the profile,
   trust it. Then press Run again.

## Do the pass

1. Press **Start the check** and put the phone down for a few minutes. It
   renders a dozen fixed scenes on your hardware. Keep the app in the
   foreground, and plug the phone in if you can.
2. It then shows you one picture at a time, with a sentence under it saying
   what to look at. Press **Approve** if it looks right, or write what is wrong
   and press **Reject**. It moves to the next one by itself.
3. When you run out of pictures you get a summary. Press **Make the report**,
   then **Send the report**, and AirDrop or message the file back.

That is the whole thing. Nothing needs to be committed, and there are no files
to go looking for.

## What you are judging

The picture, not the map. A road with the wrong name, or a shop that has
closed, is the map data being out of date and is not interesting here. What is
interesting:

- edges that look ragged, stepped or shimmering where they should be smooth;
- text that is hard to read, too small, cut off, overlapping other text, or
  swallowed by its outline;
- colours that band, seams and cracks between tiles, geometry that is missing
  or drawn twice;
- in the video clips: motion that stutters, jumps, or pops things in and out.

If you are not sure whether something is wrong, reject it and describe what you
see. A false alarm costs a minute; something nobody mentioned costs a release.

## What you are sending back

One zip. It holds the pictures you looked at, what you said about each of them,
and which phone, GPU, OS and build produced them. Nothing else, and nothing
personal: no location, no account, no contents of your phone.

## If something goes wrong

- **"Untrusted Developer" when the app opens.** Step 6 above.
- **A scene says it failed to render.** That is itself a useful result. It is
  recorded in the report. Carry on with the rest.
- **The app is killed while rendering.** It usually means the phone went to
  sleep or the app went to the background. Start again; what already rendered
  is kept.
- **Anything else.** Send the report anyway, with a note about what happened.

## On a Mac instead

Same workspace, the **ImmersiveMapVisualReview** scheme. It shows the whole
catalogue in a window rather than one picture at a time, and **Make the report**
is in the toolbar. Useful, but it cannot answer the questions a phone can:
shadows in particular are rendered by a path that only exists on real iOS
hardware.

More detail, including how the catalogue and the verdict files work, is in
[`Tools/VisualReview/README.md`](Tools/VisualReview/README.md).
