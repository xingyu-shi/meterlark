# App updates

Meterlark uses Sparkle for checking, downloading, verifying, installing, and
relaunching app updates. Open the settings menu and choose **Check for updates…**
to start a manual check. Scheduled checks are enabled by default. Users may opt
into **Automatically download and install**; Sparkle downloads in the background
and installs when the app quits, or offers to install and relaunch.

When a scheduled check finds an update while the user is working elsewhere, the
menu-bar panel offers an update button. Sparkle owns its preferences in the app's
defaults domain. They are separate from usage refresh and pricing refresh.

The first release containing the updater needs to be installed normally. Earlier
releases, including 1.2.13, do not contain code that can install it automatically.
After that initial installation, updates run inside the app.

## Update trust and hosting

The app embeds a fixed Sparkle binary target with a SHA-256 checksum. Release
packaging preserves its symlinks and signs its nested services, helper app,
framework, and the Meterlark host using the same Developer ID identity. The
complete upstream license is bundled as `Sparkle-LICENSE.txt`.

The stable feed URL is
`https://github.com/xingyu-shi/meterlark/releases/latest/download/appcast.xml`.
Each published release includes a signed `appcast.xml` whose download URL points
to that release's exact ZIP asset. The feed uses the internal build number for
comparison, the display version for UI, macOS 14 as the minimum, and an arm64
hardware requirement.

Both the archive and feed are Ed25519 signed. The app requires signed feeds and
verifies the archive before extraction, in addition to Apple code signing and
notarization. See [Sparkle's signing guidance](https://sparkle-project.org/documentation/).

## Signing key setup

The public key is committed in `Resources/Info.plist` under `SUPublicEDKey`.
The corresponding private seed belongs in the repository's **release** environment
secret named `SPARKLE_PRIVATE_KEY`. Its local Keychain account is
`com.xingyu.meterlark`. Only the repository owner should provision or rotate this
secret; private key material must never enter source control, release assets,
command arguments, or logs.

The release workflow writes the secret into a restricted temporary file, checks
that its derived public key matches the app, and removes it after the job. The
normal CI jobs have no access to this key. Back up the private key securely:
losing it can prevent existing installations from trusting future feeds. Follow
[Sparkle's key rotation guidance](https://sparkle-project.org/documentation/#rotating-signing-keys)
before changing the embedded public key. With pre-extraction verification enabled,
key rotation requires a Developer ID signed DMG update; the normal ZIP feed must
not be reused for that migration.

## Publishing and validation

1. Merge the release changes through a PR and create the version tag from a commit
   already in `main`. The release workflow verifies this ancestry.
2. Package, Developer ID sign, and notarize the app and DMG. Packaging copies the
   updater's full license and signs its nested code before the host.
3. Run `scripts/package-update-feed.sh` with `SPARKLE_PRIVATE_KEY_FILE` pointing
   to the protected private seed file. It stages only the exact versioned ZIP,
   embeds the matching changelog entry, signs the archive and feed, and verifies
   both signatures. It rejects stale app metadata, wrong asset URLs, mismatched
   lengths, missing notes, and incompatible hardware metadata.
4. Publish the draft with its DMG, ZIP, two checksum files, and `appcast.xml`.
   Mark it latest, then verify that the stable feed URL serves the signed file
   and that the ZIP URL resolves to the intended artifact. Do not mark a release
   without an appcast as latest after updater-enabled builds have shipped.

Do not edit `appcast.xml` after signing: a change to its content invalidates the
feed signature. Regenerate it through the publishing script instead.

For a signed and notarized validation build that creates no GitHub release,
dispatch the existing Release workflow from the feature branch with
`verify_only=true`. This still requires access to the protected release
environment and its signing secrets.

Run `python3 -m unittest discover -s Tests/Packaging -v` for update metadata
regression checks. Test actual installation using an isolated app identifier and
an ephemeral local signing key, including rejection of a modified archive and
successful installation/relaunch of a valid archive. Keep production app data
and signing keys out of these tests.
