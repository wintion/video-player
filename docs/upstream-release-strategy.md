# Upstream release strategy

Rawya release branches are based on immutable stable IINA release tags, not on
IINA's `develop` branch.

## Current base

- Upstream repository: `https://github.com/iina/iina.git`
- Stable base: `v1.4.4`
- Base commit: `c111221ea027466b79b40bfca054772d4851e06f`

## Branch policy

- Use `release/rawya-*` branches for distributable Rawya builds.
- Treat `upstream/develop` as an integration and research branch only.
- Do not merge `upstream/develop` wholesale into a Rawya release branch.
- When IINA publishes a newer stable tag, create a new Rawya release branch
  from that tag and migrate the Rawya-specific commits intentionally.
- Security fixes that have not reached an IINA stable tag may be cherry-picked
  individually after review and validation.

This keeps Rawya's branding and product changes separate from unfinished IINA
work while preserving a clear, auditable upstream baseline.
