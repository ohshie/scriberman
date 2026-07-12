# Contributing to Scriberman

Thanks for your interest in contributing!

## Contributor License Agreement (CLA)

Scriberman is published under the PolyForm Noncommercial License 1.0.0, but the
project maintainer also distributes it under other terms (for example,
commercial licenses or App Store builds). To keep that possible, **all
contributions require a Contributor License Agreement**.

By submitting a pull request, issue patch, or other contribution, you agree
that:

1. You are the author of the contribution (or have the right to submit it),
   and you license it to the project maintainer (@ohshie) under the Apache
   License 2.0 — permitting the maintainer to relicense and distribute it,
   including in commercial or otherwise-licensed builds of Scriberman.
2. Your contribution is simultaneously made available to everyone else under
   the project's PolyForm Noncommercial License 1.0.0, like the rest of the
   codebase.
3. You retain copyright to your contribution.

If you do not agree, please do not submit contributions. Opening issues,
discussions, and bug reports requires no agreement.

## Practical notes

- Branch naming: `feature/<short-name>` or `fix/<short-name>`.
- Commit style: Conventional Commits (`feat(scope): …`, `fix(scope): …`).
- New services, extracted logic types, and ViewModels need unit tests in
  `ScribermanTests` that pass before merging.
- Add newly created files to the Xcode project before building or testing.
- Keep PRs small and focused; include verification steps, and screenshots or
  recordings for UI changes.

## Development setup

See the repository README. Local release signing uses a self-signed
certificate (`scripts/setup-signing.sh`); never commit certificates, private
keys, or other secrets.
