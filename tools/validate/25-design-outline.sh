#!/usr/bin/env bash
set -euo pipefail

if [ -z "${ROOT:-}" ]; then
  # shellcheck source=lib.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
fi

node - "$ROOT/skills/design-outline/SKILL.md" <<'NODE'
const fs = require("fs");

const skill = fs.readFileSync(process.argv[2], "utf8");
const commonPatterns = skill.split("## Common Patterns\n")[1] || "";

const layerOnly = [
  "### Phase 1: Persistence preparation",
  "**Delivers**: The new database schema exists.",
  "**Implementation steps inside the slice**: Add the table and migration.",
  "**Verification**: Inspect the migrated schema.",
].join("\n");

const verticalSlice = [
  "### Phase 1: Let users update notification preferences",
  "**Delivers**: A preference can be changed and read back end to end.",
  "**Implementation steps inside the slice**: migrate storage, update the service and API, then expose the control in the client.",
  "**Verification**: Change a preference through the client and confirm the stored value through the API.",
].join("\n");

const layerPatterns = [
  /\b(?:schema|database|data model|migration|store|stored|table)\b/i,
  /\b(?:service|business logic|backend)\b/i,
  /\b(?:api|endpoint|contract)\b/i,
  /\b(?:client|ui|user-visible)\b/i,
];

function coveredLayers(text) {
  return layerPatterns.filter((pattern) => pattern.test(text)).length;
}

function isVertical(outline) {
  const phases = outline.split(/^### Phase \d+: /m).slice(1);
  return phases.length > 0 && phases.every((phase) => {
    const [title, ...bodyLines] = phase.split("\n");
    const body = bodyLines.join("\n");
    const layerTitle = /^(?:schema|database|data model|store|service|business logic|api|client|ui|migration)s?\b/i.test(title.trim());
    return !layerTitle && coveredLayers(body) >= 2 && /\*\*Delivers\*\*:/.test(body) &&
      /\*\*Implementation steps inside the slice\*\*:/.test(body) &&
      /\*\*Verification\*\*:/.test(body);
  });
}

if (isVertical(layerOnly)) throw new Error("layer-only phase outline was accepted");
if (!isVertical(verticalSlice)) throw new Error("end-to-end vertical slice was rejected");

for (const heading of ["For Database Changes", "For New Features", "For Refactoring"]) {
  const block = commonPatterns.split(`### ${heading}:\n`)[1]?.split(/^### /m)[0] || "";
  if (!/\*\*Capability slice\*\*:/.test(block)) throw new Error(`${heading} lacks a capability slice`);
  if (!/\*\*Implementation steps inside the slice\*\*:/.test(block)) throw new Error(`${heading} exposes layer ordering as phases`);
  if (!/\*\*Verification\*\*:/.test(block)) throw new Error(`${heading} lacks per-slice verification`);
  if (coveredLayers(block) < 2) throw new Error(`${heading} remains a single-layer example`);
}

const legacySequences = [
  ["Start with schema/migration", "Add store methods", "Update business logic", "Expose via API", "Update clients"],
  ["Start with data model", "Build backend logic", "Add API endpoints", "Implement UI last"],
  ["Document current behavior", "Plan incremental changes", "Maintain backwards compatibility", "Include migration strategy"],
];
if (legacySequences.some((sequence) => sequence.every((line) => commonPatterns.includes(line)))) {
  throw new Error("Common Patterns restored a legacy horizontal sequence");
}

if (!/backward-compatible migration/i.test(commonPatterns) || !/rollback/i.test(commonPatterns)) {
  throw new Error("Common Patterns lack explicit migration safety");
}
if (!/backward compatibility/i.test(commonPatterns)) {
  throw new Error("Common Patterns lack explicit backward compatibility");
}
NODE
