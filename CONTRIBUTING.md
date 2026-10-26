# Contributing to umbar

This guide is for anyone who wants to report a bug in umbar or send a change to it.

umbar is a fork of [boring.notch](https://github.com/TheBoredTeam/boring.notch). Report umbar
problems here, not to the boring.notch project: they do not maintain umbar.

## Report a bug

Open an issue with the **Bug Report** form. Include:

- what you did, what you expected, and what happened instead;
- the umbar version, from **Settings > About** (click the version to show the build number);
- the macOS version, from **Apple menu > About This Mac**;
- for music problems, the **Music Source** selected in **Settings > Media** and the app or website
  that was playing.

Report security problems privately as described in [SECURITY.md](SECURITY.md), not in a public
issue.

## Suggest a feature

Open an issue with the **Feature Request** form. Describe the problem you want solved before the
solution you have in mind.

## Send a change

### Branches

| Branch | Contains |
|---|---|
| `product/main` | umbar. Base every change on this branch. |
| `main` | An unmodified mirror of upstream boring.notch. Do not send changes to it. |

### Set up

Prerequisites: macOS 27.0 or later and Xcode 27.0 or later.

1. Clone the repository.
2. Create a branch from `product/main`:

   ```bash
   git switch -c fix/short-description product/main
   ```

3. Build the app:

   ```bash
   xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug build
   ```

   The last line of output is `** BUILD SUCCEEDED **`.

The project, scheme and source folders keep upstream's `boringNotch` names so that upstream
changes can still be merged. Do not rename them in a feature change.

### Before you open a pull request

- Build the **boringNotch** scheme and make sure it succeeds.
- Run the unit tests with `scripts/test.sh` (target **umbarTests**, headless) and make sure they
  pass. Add tests for logic you change.
- CI (`.github/workflows/ci.yml`) runs the same build and tests on every pull request to
  `product/main`, using only the package versions in `Package.resolved`. To reproduce a CI
  failure, run `scripts/ci-build.sh` and then `scripts/test.sh`. A dependency change must
  come with its updated `Package.resolved`.
- Run the app and check the behaviour you changed, and describe in the pull request what you
  checked and on which Mac.
- Keep the GPL-3.0 license and the upstream copyright headers in every file you touch.
- If your change alters what a user sees or does, update [README.md](README.md) and
  [README.tr.md](README.tr.md) in the same pull request.

### Translations

Strings live in `boringNotch/Localizable.xcstrings`. Edit them in Xcode and send them as a pull
request. umbar does not use upstream's Crowdin project.

## License

By contributing, you agree that your contribution is licensed under the
[GNU General Public License v3.0](LICENSE), the license of umbar.
