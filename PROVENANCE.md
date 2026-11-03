# Provenance

This document records the source and license boundary for the Launch Control distribution.

## Launch Control original material

Except for the components listed below, the repository's skills, agents, installer,
validation tools, configuration references, and documentation are Launch Control original
material licensed under Apache-2.0 through the root `LICENSE` file.

## Separately licensed components

| Component | Source | Imported revision | License and notice |
|---|---|---|---|
| `skills/research-codebase/`, `agents/surveyor.md`, `agents/navigator.md`, `agents/veteran.md`, `agents/technician.md`, `agents/integrator.md` | [`humanlayer/humanlayer`](https://github.com/humanlayer/humanlayer) | Not recorded | Apache-2.0; modified by Launch Control; attribution in `NOTICE` |

The HumanLayer-derived files were renamed and modified for Launch Control. Each carries a
one-line notice saying it was modified from HumanLayer's work.

The default Claude onboard bundle also embeds four WOFF2 payloads in
`skills/onboard/assets/completion-report.html`. Their family and copyright metadata
match the following upstream notices, verified on 2026-10-31. The exact upstream
binary revisions are not recorded; these links identify the notice sources, not
binary revision attestations. Font payloads are unchanged by the notice repair.

| Embedded font | Notice source | Shipped full notice |
|---|---|---|
| Anton Regular | [Anton project](https://github.com/googlefonts/AntonFont/blob/main/OFL.txt), copyright 2020 The Anton Project Authors | `skills/onboard/assets/ANTON-OFL.txt` |
| Barlow Condensed SemiBold and Bold | [Barlow project](https://github.com/jpt/barlow/blob/main/OFL.txt), copyright 2017 The Barlow Project Authors | `skills/onboard/assets/BARLOW-OFL.txt` |
| IBM Plex Mono Regular | [IBM Plex](https://github.com/IBM/plex/blob/master/LICENSE.txt), copyright 2017 IBM Corp., Reserved Font Name "Plex" | `skills/onboard/assets/IBMPlexMono-OFL.txt` |

Each notice contains the full SIL Open Font License 1.1. The same notices are
embedded in the HTML's inert `font-licenses` template block so they travel with
generated standalone reports. Native Codex's current onboard bundle does not ship
the HTML template or font payloads.

The optional `deploy-to-vercel` pack was removed before the initial-history rewrite
because its upstream repository did not provide a complete authoritative license and
copyright notice at the audited revision.
