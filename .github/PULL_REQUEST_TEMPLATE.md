## What and why

<!-- What changes for users, and why. Link the issue it closes. -->

## Checklist

- [ ] Commit subjects are Conventional Commits (`node scripts/release.mjs lint-commits origin/main..HEAD`)
- [ ] An entry under `## Unreleased` in CHANGELOG.md, or this change needs none (docs, tests, CI)
- [ ] Tests cover the change; `task testor:test` (or `mix test --cover`) passes with 100% coverage
- [ ] Documentation updated: `docs/`, `website/docs/`, README
- [ ] Breaking change to a public surface (VERSIONING.md)? Marked with `!` and a `BREAKING CHANGE:` footer, with the migration in the changelog
