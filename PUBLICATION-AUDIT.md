# Initial publication audit

Reviewed 18 September 2026, before creating the public source history.

## Scope and changes

- Publish the app source, tests, scripts, dependency lockfiles, vendored sources,
  license notices and documentation from this repository root.
- Exclude the surrounding research workspace, device diagnostic files, local
  toolchains, build caches, compiled apps, archives and screenshots.
- Replace the unused vendored OPACK module with an earlier MIT-declared upstream
  version. This removes a captured device pairing fixture and later additions
  with unclear license provenance. See [Vendor/README.md](Vendor/README.md).
- Use an all-zero device identifier in the remaining synthetic peer-device test.
- Retain upstream copyright notices and add the project's MIT license.
- Use the maintainer's GitHub public handle and GitHub noreply email in Git
  metadata. No previous local investigation history is imported.

## Checks

- Inspect the exact Git file manifest, including hidden files and symlink targets.
- Scan staged contents and complete initial history with Gitleaks 8.30.1,
  default rules plus device-identifier and personal-home-path rules.
- Review the scanner's one false positive: a Rust variable assignment rather
  than a credential. Its exception is restricted to that exact line and file.
- Review text and encoded fixtures for device identity, pairing material,
  credential literals, personal paths and private account data.
- Verify that binaries, logs, images, signing material and local device records
  are absent from the initial Git tree.
- Build the app, verify its ad-hoc signature and run all 69 tests.

No remaining credentials or personal device information were identified in the
reviewed publication tree. This is a bounded source audit, not a guarantee that
automated scanning detects every possible secret or a full application security
assessment. Future commits and release artifacts require their own review.

The secret-scanning workflow inspects fetched Git history on pushes and pull
requests. It uses a pinned checkout action and checksum-verified Gitleaks binary,
with read-only repository permissions and redacted output. Scan locally before
pushing: CI runs after content has already reached GitHub.
