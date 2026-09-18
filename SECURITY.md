# Security and privacy

PhoneMirror controls a trusted, unlocked iPhone through local Apple developer
services. It has no analytics service, background clipboard synchronization, or
default screen/keystroke recording. Explicit paste replaces the iPhone clipboard.
Device identity is discovered at runtime rather than embedded in the source.

## Reporting

For vulnerabilities or accidental exposure of private information, use
[GitHub's private vulnerability reporting](https://github.com/gdelataillade/phone-mirror/security/advisories/new).
Do not put credentials, pairing records, device identifiers, private screenshots,
or unredacted logs in a public issue. Ordinary reproducible bugs can be reported
as issues with sensitive details removed.

## Before committing or sharing

- Keep build products, local tools, credentials, signing assets, captures and
  device diagnostics out of Git. `.gitignore` excludes common forms of these.
- Review the actual staged files with `git diff --cached` and
  `git diff --cached --name-only`. Ignore patterns are not a security boundary.
- Install [Gitleaks](https://github.com/gitleaks/gitleaks), then run
  `gitleaks git --staged --redact --no-banner .` before committing and
  `gitleaks git --redact --no-banner --log-opts="--all" .` before publishing history.
- Check images, binary fixtures and encoded data manually. A scanner cannot
  establish that all personal information is absent.

The repository extends Gitleaks' default rules with checks for local home paths
and Apple device identifiers. Only the exact all-zero device test fixture is
allowed by that rule. No vendored directory is excluded from the scan.
One reviewed false-positive exception matches an exact Rust variable assignment
in one file; it does not permit literal credentials in that file.

GitHub Actions runs the history scan after pushes and for pull requests, with
read-only repository permissions. This is a detection check, not a replacement
for scanning locally before a public push.
