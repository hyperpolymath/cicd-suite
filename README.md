<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# cicd-suite

Composite GitHub Actions for estate-wide CI/CD auditing. Consumed by
`.github/workflows/main-estate-audit.yml`, which `rollout_estate.sh` copies into
each repository.

## Status: published so consumers can resolve it — **not yet ready to enforce**

This repository was written but never published, so every consuming workflow
referenced `hyperpolymath/cicd-suite/actions/*@main` against a 404. Publishing it
makes those references resolvable. **It does not make them correct.** Read the
next two sections before wiring this into anything.

## What actually enforces

Of 26 actions, **13 can fail a build and 13 cannot.** The 13 advisory ones emit
`::warning::` and end with a success exit — they are named "Gate" but report green
regardless of what they find.

| Enforcing (can `exit 1`) | Advisory only (cannot fail) |
|---|---|
| affirmation · boj-cartridge · code-hygiene · idris2-abi · linguist · manifest · proof-runner · referencing · required-files · secrets · spdx-license · vaulted-tokens · zig-hexadeca | badges · contractile-validation · custom-tools · formatting · gitsea · hosting · metrics · prat · recipes-set · semantic-audit · tests-benches · trust-humans · www-compliance |

Verify at any time:

```sh
for a in actions/*/; do
  grep -q 'exit 1' "$a/action.yml" && echo "ENFORCE $(basename $a)" || echo "advise  $(basename $a)"
done
```

A gate that cannot fail is worse than no gate, because it is credited as
assurance. The advisory 13 should either grow teeth or be renamed so nobody reads
their green tick as a guarantee.

## Known defects — fix before rollout

**1. The suite contradicts itself.** `required-files-check` **hard-fails** a repo
that lacks `GOVERNANCE.md`, `ARCHITECTURE.md` and `MAINTAINERS.adoc`, while
`formatting-check` **warns** that `GOVERNANCE.md` and `ARCHITECTURE.md` should be
`.adoc`. A repo cannot satisfy both. Several estate repos have an `.adoc`-only
doc policy, which `required-files-check` fails them for following.

**2. `required-files-check` manufactures filler.** Because it checks only for
*presence*, satisfying it produces content-free template files. This has already
happened: a branch in `boj-server` carried an `ARCHITECTURE.md` describing a
directory layout that repo does not have, a `MAINTAINERS` naming the wrong owner,
and a `mise.toml` pinning `zig = "latest"` in direct conflict with the repo's
`.tool-versions`. Presence checks reward filler; content checks don't.

**3. `code-hygiene-check` fails on legitimate code.** It runs:

```sh
git grep -E -i 'TODO|FIXME|STUB|sorry|believe_me|admit'
```

Case-insensitive, unanchored, across the whole repository including prose. So:

- `believe_me` fails `boj-server` **permanently** on its four *sanctioned,
  documented, separately CI-counted* Idris2 axioms — the repo's declared trusted
  base, not debt.
- `admit` matches "admitted", "admittedly"; `sorry` matches ordinary English.
- Any document that *discusses* these markers fails — including a debt register
  that exists to track them, and this README.

It needs to scan source only, honour an allowlist for sanctioned axioms, and
match whole tokens.

**4. Seven actions use bare `git grep`** over the entire tree with no path
restriction (`code-hygiene`, `idris2-abi`, `metrics`, `secrets`, `spdx-license`,
`vaulted-tokens`, `zig-hexadeca`), so all inherit the class of problem in (3) to
some degree.

## Blast radius

`rollout_estate.sh` has already copied `main-estate-audit.yml` into **199
repositories**; in **198** of them the file is untracked and has therefore never
run. Committing it in those repos is what arms these gates. Given (1)–(3), that
should follow fixing them, not precede it.

The workflow also has no `permissions:` block and pins `actions/checkout` by tag
rather than SHA.

## Consuming it

Once the defects above are resolved, pin by commit SHA rather than `@main`:

```yaml
- uses: hyperpolymath/cicd-suite/actions/required-files-check@<sha>  # vX.Y.Z
```

`@main` is a moving target: a change here silently changes the gate in every
consuming repository at once.

## Licence

Code MPL-2.0, prose CC-BY-SA-4.0. See [`LICENSE`](LICENSE).
