<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# cicd-suite

Composite GitHub Actions for estate-wide CI/CD auditing. Consumed by
`.github/workflows/main-estate-audit.yml`, which `rollout_estate.sh` copies into
each repository.

## Status

Published 2026-08-07. Three of the four defects listed below are **fixed and
verified against two live estate repositories**; the advisory/enforcing split
(13 of 26 cannot fail) is still open.

Before wiring this into a repository, read *Known defects* — one item remains.

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

## Known defects

**1. FIXED — `code-hygiene-check` scanned for the word, not the marker.** It ran
one case-insensitive, unanchored `git grep` over the whole tree, so "admit"
matched "admitted", "sorry" matched ordinary English, any document *discussing* a
marker failed, and `believe_me` failed repos whose sanctioned axioms are their
declared trusted base. Measured **112** matching files in one repo and **313** in
another. Now two scans with different semantics — debt markers case-sensitive and
whole-word in source only; circumventions in proof languages only, with comments
filtered. Repos may exempt paths via `.cicd-hygiene-allow`. Result: **112 → 2**
and **313 → 3**, all true positives.

**2. FIXED — `required-files-check` manufactured filler.** Presence-only checking
meant the cheapest way to pass was template boilerplate, and that is exactly what
happened in the estate. It now checks presence, then format, then substance:
documents need real content and no placeholders, `ARCHITECTURE` must name a
directory that actually exists, and `MAINTAINERS` must mention the repository
owner — which catches a template shipping its author's handle. `CODEOWNERS` is
judged on whether it assigns an owner, not on length.

**3. FIXED — the suite contradicted itself.** `required-files-check` hard-failed a
repo for lacking `GOVERNANCE.md` while `formatting-check` warned that same file
should be `.adoc`. Required-files now accepts every policy-legal form, and
formatting-check owns the preference. Verified: a repo passes both gates with
`.adoc` (silently) or with `.md` (with a nudge).

**4. OPEN — 13 of 26 actions still cannot fail.** See the table above. They should
either grow teeth or be renamed, so nobody reads their green tick as a guarantee.
Seven actions also use bare `git grep` with no path restriction
(`idris2-abi`, `metrics`, `secrets`, `spdx-license`, `vaulted-tokens`,
`zig-hexadeca`) and may inherit a milder form of defect (1).

## Blast radius

`rollout_estate.sh` has already copied `main-estate-audit.yml` into **199
repositories**; in **198** of them the file is untracked and has therefore never
run. Committing it in those repos is what arms these gates — so it should follow
closing (4), the last open defect, not precede it.

The workflow also has no `permissions:` block and pins `actions/checkout` by tag
rather than SHA.

## Consuming it

Once (4) is resolved, pin by commit SHA rather than `@main`:

```yaml
- uses: hyperpolymath/cicd-suite/actions/required-files-check@<sha>  # vX.Y.Z
```

`@main` is a moving target: a change here silently changes the gate in every
consuming repository at once.

## Licence

Code MPL-2.0, prose CC-BY-SA-4.0. See [`LICENSE`](LICENSE).
