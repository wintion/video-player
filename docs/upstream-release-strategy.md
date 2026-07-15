# Upstream release strategy

Rawya is maintained on a stable `main` branch. Upstream updates are based on
immutable IINA release tags, not on IINA's `develop` branch.

## Current base

- Upstream repository: `https://github.com/iina/iina.git`
- Stable base: `v1.4.4`
- Base commit: `c111221ea027466b79b40bfca054772d4851e06f`

## Branch policy

- Keep `main` as the only permanent Rawya branch and the source of
  distributable builds.
- Treat `upstream/develop` as an integration and research branch only.
- Do not merge `upstream/develop` wholesale into `main`.
- When IINA publishes a newer stable tag, create a temporary branch named
  `upgrade/iina-X.Y.Z` from that tag and migrate the Rawya-specific commits
  intentionally.
- Build and validate the temporary upgrade branch before merging it into
  `main`, then delete the temporary branch after the upgrade is complete.
- If Rawya does not need an upstream release, leave `main` unchanged.
- Security fixes that have not reached an IINA stable tag may be cherry-picked
  individually after review and validation.

This keeps Rawya's branding and product changes separate from unfinished IINA
work while preserving a clear, auditable upstream baseline.
