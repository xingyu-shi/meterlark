# Release checks

Before publishing source or an app archive:

1. Run `python3 scripts/check-public-content.py`. Review every finding. The
   check covers tracked source and non-ignored new files, rejects private
   addresses, personal paths, email addresses, unapproved URL hosts, common
   credential formats, and obsolete product identities.
2. Run `gitleaks git . --log-opts=--all --redact=100` with
   [Gitleaks](https://github.com/gitleaks/gitleaks). Scan every branch and tag
   being published. A clean current tree does not establish that its history
   is clean. Investigate scanner findings without printing candidate secrets.
3. Run `swift test -c release --build-system native`, then `./scripts/package-app.sh`. The package script
   recreates its app bundle, validates the pinned reporting engine, checks
   signing and architecture, verifies the linked SDK version, and checks the ZIP archive.
   It uses the native build engine to avoid
   [SwiftPM's incorrect SDK stamp](https://github.com/swiftlang/swift-package-manager/issues/10696),
   which can change AppKit and SwiftUI behavior even when the source is unchanged.
4. Inspect the archive for unintended plugins, local configuration, logs,
   credentials, personal metadata, and build paths. Examples use reserved
   domains and are distributed only as source templates.
5. Verify the exact remote revision, its reachable branches and tags, and CI.
   Changing repository visibility is a separate publishing decision.

CI runs the source-content check and a checksum-verified Gitleaks build with a
read-only repository token. Add a public URL host to the checker only after
reviewing why the source needs it.

Deleting a file leaves it in prior commits and tags. Replacing Git history
does not erase old clones, downloads, cached views, or copies held elsewhere.
If a live credential was exposed, revoke it through its issuer; deleting Git
references is not a replacement for revocation.
