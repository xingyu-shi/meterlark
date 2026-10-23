# Release checks

Before publishing source or an app archive:

1. Match the version and build in `Resources/Info.plist` to a dated version
   entry in `CHANGELOG.md`. Move completed changes out of `Unreleased`, keep
   historical entries, and update the download links in both README files.
2. Run `python3 scripts/check-public-content.py`. Review every finding. The
   check covers tracked source and non-ignored new files, rejects private
   addresses, personal paths, email addresses, unapproved URL hosts, common
   credential formats, and obsolete product identities.
3. Make an isolated clone containing only the branch and any new tags being
   published, without unrelated local refs. Run
   `gitleaks git <isolated-checkout> --log-opts=--all --redact=100` with
   [Gitleaks](https://github.com/gitleaks/gitleaks). A clean current tree does
   not establish that its history is clean. Investigate scanner findings
   without printing candidate secrets.
4. Run `swift test -c release --build-system native`, then `./scripts/package-app.sh`. The package script
   recreates its app bundle, validates the pinned reporting engine, checks
   signing and architecture, verifies the linked SDK version, and checks the ZIP archive.
   It uses the native build engine to avoid
   [SwiftPM's incorrect SDK stamp](https://github.com/swiftlang/swift-package-manager/issues/10696),
   which can change AppKit and SwiftUI behavior even when the source is unchanged.
5. Inspect the archive for unintended plugins, local configuration, logs,
   credentials, personal metadata, and build paths. Examples use reserved
   domains and are distributed only as source templates.
6. Verify the exact remote revision, its reachable branches and tags, and CI.
   Changing repository visibility is a separate publishing decision.
7. Create a new `v<version>` tag at that reviewed revision and push only that
   tag to `xingyu-shi/meterlark`. Do not push unrelated local tags or branches.
8. Pushing the tag runs the Release workflow. It tests, signs with the
   Developer ID certificate, notarizes and staples the app, and creates a
   draft GitHub Release with the exact versioned ZIP and a SHA-256 checksum
   file that names that ZIP. Keep the signing secrets in the `release`
   environment, limited to `v*` tags with a required reviewer. Replace the
   generated notes with user-facing notes from the
   versioned changelog, then publish the draft.
   Verify that the release is published, is marked latest when appropriate,
   and that its downloadable ZIP matches the local checksum. A pushed commit
   or tag alone does not publish a GitHub Release. When restoring historical
   notes, do not invent old release assets or publish unaudited old refs.

CI runs the source-content check and a checksum-verified Gitleaks build with a
read-only repository token. Add a public URL host to the checker only after
reviewing why the source needs it.

Deleting a file leaves it in prior commits and tags. Replacing Git history
does not erase old clones, downloads, cached views, or copies held elsewhere.
If a live credential was exposed, revoke it through its issuer; deleting Git
references is not a replacement for revocation.
