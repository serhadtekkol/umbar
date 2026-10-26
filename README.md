# umbar

umbar turns the notch of a MacBook into a small panel for what is playing, your next events,
a file shelf, and volume and brightness indicators.

umbar is a fork of [boring.notch](https://github.com/TheBoredTeam/boring.notch) by TheBoredTeam,
released under the GNU General Public License v3.0. It is not affiliated with or endorsed by
TheBoredTeam. See [License and credits](#license-and-credits).

Türkçe: [README.tr.md](README.tr.md)

## Features

- **Notch panel.** Hover over or click the notch to open it, or swipe down on it with two
  fingers; swipe up to close it. You can change the hover delay, the notch height, and turn haptic feedback off.
- **Music.** Shows the track, artwork and playback controls for whatever macOS is playing,
  including YouTube Music and other music in a browser tab. If that stops working, umbar
  switches to Apple Music and Spotify on its own. You can choose which controls appear (shuffle,
  previous, play/pause, next, repeat, volume, favourite, skip back, skip forward) and get a short
  preview in the closed notch when the track changes.
- **Calendar and Reminders.** Shows the events and scheduled reminders of the day you pick in a
  week strip. It is on by default on a new installation (an existing installation keeps its
  setting); turn it off in **Settings > Calendar**. Calendar access is asked for only when you
  click **Allow** on the calendar's card in the notch.
- **File shelf.** Drag files onto the notch to keep them at hand, then drag them out where you
  need them. Right-click an item for Open, Open With, Show in Finder, Quick Look, Share, Copy,
  Copy Path, Rename and Remove, plus Compress, Create PDF, Convert Image and Remove Background
  where they apply. The shelf accepts files only.

  Dragging an item from the shelf into a Finder folder moves the file, on the same disk and to
  another disk, so the original is no longer at its old place. Hold ⌥ to copy instead. When you drop
  into an app that accepts only a copy, such as a Mail message, umbar copies the file. With
  **Remove from shelf after dragging** on in **Settings > Shelf** (on by default on a new
  installation), the item leaves the shelf only
  after the move is confirmed; if you cancel the drop or it fails, the item stays. Files that cannot
  be removed from where they are, such as files on a read-only disk image, are copied.
- **Caffeinate.** The cup button in the open notch's header keeps the Mac awake. Click it, then
  choose ∞ (until you turn it off), 15m, 1h or 2h. While it is on, the cup is filled, the open notch
  shows the time left, and the closed notch shows a small cup badge. Click the filled cup to turn it
  off. On battery power, caffeinate turns itself off when the battery falls below 10%, and it does
  not start below 10%. It is off whenever you start umbar.
- **Eye break reminders.** After 20 minutes of active use, umbar asks you to look about 6 metres
  (20 feet) away for 20 seconds, with a countdown in the notch. Choose **Snooze 5 min** to be asked
  again in 5 minutes, or **Skip** to restart the 20 minutes. Time with no keyboard or mouse input
  (5 minutes by default), a locked screen and sleep all count as a break and restart the count.
  The reminder waits while a full-screen video or presentation is on; full-screen video detection
  may not work with every player. It never plays a sound. It is
  on by default on a new installation; change the timings or turn it off in
  **Settings > Eye break**.
- **System HUD replacement.** Replaces the macOS volume, display brightness and keyboard
  brightness indicators with ones drawn in the notch. On by default on a new installation (an
  existing installation keeps its setting); it needs Accessibility access, which the notch asks for
  from a card the first time you change the volume or open the notch.
- **Battery.** Shows battery level and charging state, and a short notice when the power source
  changes.
- **Keyboard shortcuts.** Toggle the notch open with ⌘⇧I and toggle the track preview with ⌘⇧H.
  Change them in **Settings > Shortcuts**.

umbar has no automatic updater. See [Update](#update).

## Requirements

- macOS 27.0 or later.
- A MacBook with a notch. On a display without a notch, such as an external monitor, umbar draws
  a notch-shaped panel at the top centre of the screen.

## Install

> [!NOTE]
> No release has been published yet. This section describes the Developer ID–signed and
> notarized DMG that releases will ship as. Until the first release exists, use
> [Build from source](#build-from-source).

1. Download the umbar DMG from this repository's Releases page.
2. Open the DMG.
3. Drag **umbar** into **Applications**.
4. Eject the DMG.
5. Open **umbar** from **Applications**.

macOS asks you once to confirm that you want to open an app downloaded from the internet.
Confirm it. umbar then shows a short welcome. It asks for no permissions at this point.

To check that your copy is the signed and notarized build, run:

```bash
spctl -a -vv /Applications/umbar.app
```

Expected output:

```
/Applications/umbar.app: accepted
source=Notarized Developer ID
origin=Developer ID Application: … (264H2ARX4K)
```

### If macOS refuses to open umbar

A release build of umbar is notarized, so macOS opens it without any extra steps. If macOS says
the app is damaged, cannot be checked for malicious software, or is from an unidentified
developer, the copy you have is not one we published, or it was changed after download.

1. Move that copy of umbar to the Trash.
2. Download it again from this repository's Releases page.
3. If the warning comes back, open an issue and do not open the app.

Do not remove the quarantine attribute or override Gatekeeper to open umbar.

### Coming from Boring Notch

umbar has its own bundle identifier (`com.serhadbahadir.umbar`). It does not read Boring Notch's
settings, shelf or permissions, so you set it up and grant permissions again.

## Update

umbar does not check for updates. To update:

1. Quit umbar from its menu bar icon.
2. Download the new DMG from this repository's Releases page.
3. Drag **umbar** into **Applications** and replace the old copy.
4. Open umbar.

Your settings and shelf are kept.

## Permissions

umbar asks for nothing at first launch. It asks for a permission when you first use the feature
that needs it, explains why, and waits for you to click **Allow Access** before macOS shows its
own prompt. If you decline, only that feature stops working.

| Permission | When umbar asks | What it is used for | If you decline |
|---|---|---|---|
| Calendars | When the calendar first appears in the notch, or in **Settings > Calendar** | Reading your events to show them in the notch | No events are shown |
| Reminders | In a banner under your events once calendar access is on, or in **Settings > Calendar** | Reading scheduled reminders to show them next to your events | No reminders are shown |
| Accessibility | From a card in the notch the first time you change the volume or open the notch while the HUD replacement is on, or in **Settings > HUDs** | Seeing the volume and brightness keys so umbar can draw its own HUD | The HUD replacement stays off; macOS shows its own HUD |
| Automation: Music, Spotify | macOS asks the first time umbar sends a command to that app | Reading the current track and controlling playback, volume and favourites in that app | umbar cannot read or control that app |

The **Now Playing** music source needs no permission prompt.

macOS shows its own prompt only once per permission. To change a decision later, use the
**Open System Settings** button umbar shows in place of the feature, or open
**System Settings > Privacy & Security** and choose **Calendars**, **Reminders**,
**Accessibility** or **Automation**.

## Privacy

umbar has no account, no analytics and no crash reporting. Everything it stores stays on your Mac.

**Stored on your Mac**

| What | Where |
|---|---|
| Settings and keyboard shortcuts | The `com.serhadbahadir.umbar` defaults domain (`~/Library/Preferences/com.serhadbahadir.umbar.plist`) |
| Shelf contents: references to your files, not copies of them | `~/Library/Application Support/com.serhadbahadir.umbar/Shelf/items.json` |
| Downloaded Spotify artwork, up to 20 MB, deleted after 7 days | `~/Library/Caches/com.serhadbahadir.umbar/Artwork/` |
| Files created by shelf actions such as Compress or Convert Image, before you drag them out | The macOS temporary folder |

Calendar events and reminders are read from macOS each time they are shown. umbar does not save
copies of them.

umbar writes diagnostic messages to the macOS unified log, which stays on your Mac. These
messages include the paths of files you put on the shelf and changes in playback state.

**Network connections**

- **Album artwork.** umbar downloads artwork only over HTTPS and only from Spotify's image
  servers (`scdn.co` and `spotifycdn.com`). It refuses any other address and any redirect to one.
  Artwork from the Now Playing source and from Apple Music comes from macOS and the Music app,
  with no download.
- **Custom visualizers.** If you add a custom visualizer in **Settings > Appearance** by entering
  a Lottie JSON URL, umbar downloads that file from the address you entered.

umbar makes no other network connections of its own.

## Uninstall

1. In **Settings > General**, turn off **Launch at login**.
2. Quit umbar from its menu bar icon.
3. Reset the permissions umbar was given:

   ```bash
   tccutil reset All com.serhadbahadir.umbar
   ```

   Run this before you delete the app. Once the app is gone, `tccutil` cannot find it and prints
   `No such bundle identifier`.
4. Drag **umbar** from **Applications** to the Trash.
5. Delete its settings:

   ```bash
   defaults delete com.serhadbahadir.umbar
   ```

6. Delete its shelf data and caches:

   ```bash
   rm -rf ~/Library/Application\ Support/com.serhadbahadir.umbar
   rm -rf ~/Library/Caches/com.serhadbahadir.umbar
   rm -rf ~/Library/HTTPStorages/com.serhadbahadir.umbar
   ```

   A folder that does not exist is skipped without an error.

## Build from source

Prerequisites: macOS 27.0 or later and Xcode 27.0 or later.

1. Clone this repository and change into it.
2. Open the project:

   ```bash
   open boringNotch.xcodeproj
   ```

3. Select the **boringNotch** scheme and press ⌘R.

To build from the command line instead:

```bash
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug build
```

The last line of output is `** BUILD SUCCEEDED **`. A local build is signed ad hoc ("Sign to Run
Locally"), so it is neither Developer ID–signed nor notarized. It runs on the Mac that built it.

The project, scheme and source folders keep upstream's `boringNotch` names so that upstream
changes can still be merged. The app they build is `umbar.app`.

## Contributing and security

- [CONTRIBUTING.md](CONTRIBUTING.md) explains how to report bugs and send changes.
- [SECURITY.md](SECURITY.md) explains how to report a vulnerability privately.

## License and credits

umbar is free software under the [GNU General Public License v3.0](LICENSE). Its source code is
available in this repository.

umbar is based on [boring.notch](https://github.com/TheBoredTeam/boring.notch) by TheBoredTeam
and the boring.notch contributors, forked from upstream `main` at `23e7705` (2026-10-18). The
upstream copyright notices are kept in the source files. [NOTICE](NOTICE) records the fork, and
the git history records every change made since.

umbar also includes code from these projects:

- [MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter) by Jonas van den Berg
  (BSD 3-Clause), which provides the system-wide Now Playing source.
- [NotchDrop](https://github.com/Lakr233/NotchDrop) by Lakr Aream (MIT), the basis of the shelf.
- [Calendr](https://github.com/pakerwreah/Calendr) by Carlos César Neves Enumo (MIT).
- [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit) by Kai Azim (MIT).
- [Parrot](https://github.com/avaidyam/Parrot) by Aditya Vaidyam and contributors (MPL 2.0).

The full license texts are in [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES).
