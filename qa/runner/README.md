# UmbarQARunner

A tiny menu bar app that runs umbar's GUI acceptance tests on the Air, in the
dedicated standard account `umbarqa`, and a `qa-cli` client to drive it over
SSH. The security design is [docs/qa-gui-runner.md](../../../docs/qa-gui-runner.md)
(Muhittin, approved with conditions); this package implements its §3. Card #96.

It is **not** a remote-control tool. The socket accepts a fixed list of
commands that target only umbar's windows and the Finder window the runner
opened under `~/umbar-qa/drop/`. Arming is only possible by a physical click
at the Air; SSH can disarm, never arm.

This package is not part of `boringNotch.xcodeproj` and must never be added to
it (design §7).

## Layout

| Path | What |
|---|---|
| `Sources/QARunnerCore` | All policy, no AppKit: strict wire parser, command allowlist, arm state machine, launch gate (account + expiry), drop-path and hit-test rules, audio preconditions, write roots, log records. Unit tested. |
| `Sources/QARunnerStamp` | Build stamp. The committed file is unstamped, so a plain `swift build` produces a runner that refuses to start (`unstamped-build`). |
| `Sources/UmbarQARunner` | The app: menu, socket, ScreenCaptureKit, AX, CGEvent, CoreAudio. |
| `Sources/qa-cli` | Socket client. Needs no TCC grant. |
| `Tests/QARunnerCoreTests` | Schema/allowlist/expiry tests, one rejection test per "never" of the design (`NeverListTests`), and a source scan for forbidden APIs (`ForbiddenAPITests`). |
| `build.sh` | Stamps, builds, checks `nm -u`, signs with Hardened Runtime and no entitlements, writes a build record. |

## Test

```sh
swift test --package-path qa/runner
```

Runs on any Mac without any permission: nothing in the tests touches TCC, the
screen, input or the network.

## Build

```sh
UMBAR_QA_TARGET_UID=<id -u umbarqa on the Air> qa/runner/build.sh <out-dir>
```

- The UID and expiry (build + 14 days, `UMBAR_QA_LIFETIME_DAYS` to shorten)
  are compiled into the binary as Swift constants, not Info.plist values.
  UID 0 and 501 (the owner's account) are refused by the script and by the
  runner.
- The script refuses to package a binary whose `nm -u` contains
  `posix_spawn`, `fork`, `system`, `popen`, `exec*`, `dlopen`, `connect`,
  `NSTask`, `NSAppleScript`, `NSPasteboard`, `NSURLSession`, ... (full list in
  the script), verifies an empty entitlement set and the runtime flag, and
  writes `UmbarQARunner.build-record.txt` with the cdhash Habibe compares
  against `qa-cli status` (§3.3, A3).
- Default signing is ad-hoc, for development only.

## Signing (decision D5)

Ad-hoc signing is not acceptable for a build that receives a grant (§3.1):
its designated requirement is `cdhash H"..."`, which changes on every build,
so every rebuild would need a new trip to the Air and a new "Allow". The
build that is granted anything is signed by the user on the Mac mini:

```sh
UMBAR_QA_TARGET_UID=<uid> CODE_SIGN_IDENTITY="Developer ID Application" \
NOTARY_PROFILE=<notarytool profile> qa/runner/build.sh <out-dir>
```

(`codesign` prompts for keychain access; that is why the agents cannot do
this step.) Expected result, checked by build.sh and recorded in the build
record:

- `Authority=Developer ID Application: ... (264H2ARX4K)`, `TeamIdentifier=264H2ARX4K`
- `flags=0x10000(runtime)`, `codesign -d --entitlements -` prints nothing
- Designated requirement: the one `codesign` generates for a Developer ID
  identity. Expected form (not yet observed for this app, since it has not
  been Developer ID signed; the build record prints the real one):

  ```
  identifier "com.serhadbahadir.qarunner" and anchor apple generic and
  certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and
  certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and
  certificate leaf[subject.OU] = "264H2ARX4K"
  ```

  This is stable across rebuilds (no cdhash in it), so TCC keeps the grant.
  It is intentionally the generated requirement and not the shorter one
  written in §3.1: the generated one additionally pins the Developer ID
  intermediate and leaf certificate types, so an *Apple Development*
  certificate of the same team does not satisfy it. The §3.1 form would let
  any team-signed binary with this identifier inherit the grant, which widens
  A3. **For Muhittin to confirm.**

Notarization: with `NOTARY_PROFILE` set, build.sh submits, waits and staples.

## Install and grant (not done; T1 / card #97 with the user present)

Nothing in this package has been installed on, launched on, or granted
anything on the Air. When it is:

1. In `umbarqa`: `~/Applications/UmbarQARunner.app`, `~/umbar-qa/bin/qa-cli`,
   and the directories `~/umbar-qa/evidence` and `~/umbar-qa/drop/<case>`
   (`drop` must be a real directory, owned by `umbarqa`, not group/world
   writable; the runner refuses a symlinked or writable root).
2. Launch only through LaunchServices: `open -g -a ~/Applications/UmbarQARunner.app`.
   Never run `Contents/MacOS/UmbarQARunner` from a shell (§3.3).
3. Follow §10 of the design for the prompts. The prompt must name
   **UmbarQARunner**; anything else is "Don't Allow".

## Use

```sh
ssh umbarqa@air '~/umbar-qa/bin/qa-cli status'
ssh umbarqa@air '~/umbar-qa/bin/qa-cli capture notch'
ssh umbarqa@air '~/umbar-qa/bin/qa-cli finder.open-drop folder=case-1'
ssh umbarqa@air '~/umbar-qa/bin/qa-cli drag from=umbar-shelf:0 to=finder-drop:case-1'
ssh umbarqa@air '~/umbar-qa/bin/qa-cli disarm'
```

`qa-cli <command> [key=value ...]`: digits are sent as integers,
`true`/`false` as booleans, everything else as strings. Exit status: 0 ok,
2 refused, 64 usage, 69 runner not reachable.

### Commands (design §3.5)

| Command | Parameters | Needs arm |
|---|---|---|
| `status` | `windows=true` (owner name/PID/layer/bounds of on-screen windows, for T6; no titles) | only with `windows` |
| `version` | | no |
| `disarm` | | no (always accepted) |
| `capture.app` | `format=png` | yes |
| `capture.region` | `name=notch\|shelf\|hud\|finder-drop` | yes |
| `capture.alert` | `name=tcc\|gatekeeper\|pasteboard` | yes; **always refused in v1** until T6 fills the owner list |
| `record.start` / `record.stop` | `target=app\|notch`, `max_s=1..30` (default 30) | yes |
| `ax.tree` | `target=umbar\|finder-drop`, `depth=1..12` (default 12) | yes |
| `pointer.hover` | `target=notch\|umbar:<AXIdentifier>`, `dwell_ms=0..5000` (default 500) | yes |
| `pointer.click` | `target=umbar:<AXIdentifier>` | yes |
| `drag` | `from=umbar-shelf:<0..99> to=finder-drop:<folder>` or `from=finder-drop:<file> to=umbar-shelf` | yes |
| `finder.open-drop` | `folder=[a-z0-9-]{1,32}` | yes |
| `key` | `name=esc\|space\|return\|tab\|up\|down\|left\|right` | yes |
| `media-key` | `name=volume-up\|volume-down\|brightness-up\|brightness-down\|kbd-light-up\|kbd-light-down` | yes |
| `measure.hover-expand` | `target=notch`, `runs=1..20` (default 5); needs an open `finder.open-drop` window as the rest point | yes |

Volume keys additionally need (§3.7): `com.apple.sound.beep.feedback` ≠ 1,
`~/umbar-qa/silent-precondition` containing exactly `asserted-by habibe` and
written *after* the current arm, a readable output volume, and for
`volume-up` a resulting level ≤ 0.30. The level is restored on disarm.

### Wire protocol

One request per connection: one line, at most 4096 bytes, a flat JSON object
of strings, integers and booleans. No escapes, no non-ASCII, no floats, no
null, no nesting, no duplicate keys, at most 16 fields, no unknown fields.
Answers: `{"ok":true,"result":{...}}` or `{"ok":false,"refused":"<code>[:<detail>]"}`.
Refusal codes are the `Refusal.Code` cases in `Sources/QARunnerCore/Refusal.swift`;
they are stable and never reused. A peer with another UID gets no answer at
all and a `peer-refused` log line.

## Arm, timeouts and kill switches (§3.4)

- Arm: menu bar item → **Arm 30/60/120 dk**. Accepted only if the triggering
  event is a left-mouse event whose `kCGEventSourceUnixProcessID` is 0 and
  which is at most 1 s old (this also rules out `AXPress` on the menu item,
  which runs the action with a stale or no event), the KILL file is absent,
  and the session is on console, unlocked, without secure input.
- Disarms on: time up, 15 min without an acting command (`status` polling
  does not count), secure input, screen lock / display sleep, session moved
  to the background (fast user switch), `qa-cli disarm`, the KILL file.
  Every command re-checks these first; a 2 s timer is the backstop.
- Quits 10 min after entering the disarmed state (including right after
  launch if nobody arms), immediately on menu **Durdur**, and when the
  embedded expiry passes while running.
- Kill switches: menu **Durdur**; `qa-cli disarm`;
  `touch ~/Library/Application\ Support/com.serhadbahadir.qarunner/KILL`;
  `killall UmbarQARunner`; last resort `tccutil reset` (§5).

## Logs (§3.8)

- Unified log: `/usr/bin/log show --predicate 'subsystem == "com.serhadbahadir.qarunner"' --last 1d`
  (categories `cmd`, `arm`, `refuse`). Use the full path in zsh, where `log`
  is a builtin.
- JSONL: `~/Library/Logs/UmbarQARunner/runner.jsonl` (O_APPEND, 0600).
- Logged: launch (cdhash, UID, expiry), arm/disarm and reason, every refusal,
  every evidence file path, caller PID and path. Not logged: AX values (an
  `ax.tree` is logged as a node count), capture content.
- A refused launch (wrong account, expired, unstamped) writes to the unified
  log only, so a runner started in the wrong account creates no files there.

## Where it writes

`~/Library/Application Support/com.serhadbahadir.qarunner/` (socket dir
`run/` 0700, socket 0600, KILL), `~/umbar-qa/evidence/<arm-time>/` (PNG/MOV +
`.json` sidecar with the runner cdhash and umbar's build record), and
`~/Library/Logs/UmbarQARunner/`. Every file is created with
`O_EXCL | O_NOFOLLOW` (the recording file is created by ScreenCaptureKit and
is checked for non-existence first) after a realpath check against those
roots. Nothing is deleted.

## Open items and interpretations (for review)

- **umbar has no AX identifiers yet.** `umbar:<id>` targets, shelf items
  (`umbar.shelf.item.<index>`) and the shelf drop zone (`umbar.shelf`) are
  found by `AXIdentifier`; until umbar sets them, those commands are refused
  with `target-not-found` (drag from Finder falls back to the notch point).
  Needs a umbar-side card.
- **`shelf` and `hud` regions** are not sized in the design. `shelf` = the
  notch region (the shelf lives in the expanded panel), `hud` = the top 120 pt
  of it. Both stay inside the notch region by construction; to be measured on
  the Air.
- **`ax.tree finder-drop` item names** come from the verified folder's
  directory listing, not from Finder's AX tree, so the Finder sidebar is
  never read. Locating the test window does read the `AXDocument` (a path)
  of each Finder window; the hit test reads role/subrole/window document of
  whatever is under a point to decide ownership. Neither is returned or
  logged.
- **`status windows=true`** (needed for T6) lists owner name, PID, layer and
  bounds of all on-screen windows, never titles. Armed only.
- **Log path.** §3.2 rule 7 lists two write roots; §3.8 adds
  `~/Library/Logs/UmbarQARunner`. Implemented as §3.8 says.
- **`measure.hover-expand`** detects the expansion as the first change of
  umbar's AX window frames. If umbar's panel window has a fixed frame and
  only its content animates, every run reports `null`; then the detector has
  to change (T2-adjacent, measure on the Air).
- **Unverified on real hardware:** the physical-click check on a status-item
  menu (T3), TCC attribution of an `open -a` launch (T1), event delivery to
  umbar's notch panel (T2), background-session behavior (T5). None of these
  can be checked without the account and the user at the Air.
