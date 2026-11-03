# shellcheck shell=bash
# Shell syntax, reference JSON, skill/agent inventory, manifest sync.
# Sourced by tools/validate-pack.sh. Not standalone: shares $ROOT, $failures,
# run_rg/check_absent from tools/validate/lib.sh and state from earlier parts.

printf '%s\n' 'Validating Launch Control'
run_rg --version >/dev/null
bash -n "$ROOT/install.sh"
bash -n "$ROOT/tools/validate-pack.sh"
# Each sourced part must parse standalone: a split that severed an `if` or a
# heredoc across two files would otherwise only surface when that branch ran.
for validate_part_source in "$ROOT"/tools/validate/*.sh; do
  bash -n "$validate_part_source"
done
bash -n "$ROOT/tools/test-install.sh"
bash -n "$ROOT/tools/launch-control-digests.sh"
bash -n "$ROOT/tools/preflight-onboard.sh"
bash -n "$ROOT/tools/mutation-run.sh"
python3 -B -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$ROOT/tools/accept-launch-isolation.py"
bash -n "$ROOT/skills/onboard/scripts/render-report.sh"
bash -n "$ROOT/skills/onboard/scripts/completion-guard.sh"
bash -n "$ROOT/skills/onboard/scripts/unattended-policy.sh"
bash -n "$ROOT/skills/onboard/scripts/discovery-checkpoint.sh"
bash -n "$ROOT/skills/docs-create/scripts/invocation-proof.sh"
jq empty "$ROOT/install/mcp.reference.json" "$MANIFEST"

# A partial run sources lib.sh without validate-pack.sh, so the no-open guard must live in lib.sh.
if ! env -u LAUNCH_CONTROL_NO_OPEN bash -c '. "$1/tools/validate/lib.sh"; [ "${LAUNCH_CONTROL_NO_OPEN:-}" = 1 ]' _ "$ROOT"; then
  printf '%s\n' 'FAIL: tools/validate/lib.sh must export LAUNCH_CONTROL_NO_OPEN=1 (partial runs open report tabs)'
  failures=$((failures + 1))
fi

# Round-4 (review finding 4): settings templates must survive default 80-column
# formatters. Check each JSON fence carrying the credential deny list independently so unrelated
# long hook-command examples in later fences do not contaminate this invariant.
for settings_source in "$ROOT/skills/onboard/references/configuration-generation.md" "$ROOT/skills/onboard/references/hooks-and-config.md"; do
  if ! awk -v limit=80 '
      /^```json/ { fence = 1; settings = 0; long = 0; next }
      /^```/ {
        if (fence && settings && long) failed = 1
        fence = 0
        next
      }
      fence && /"Read\(\.\/\*\*\/credentials\*\.enc\)"/ { settings = 1 }
      fence && length($0) > limit { long = 1 }
      END {
        if (fence && settings && long) failed = 1
        exit failed
      }
    ' "$settings_source"; then
    printf 'FAIL: settings template in %s has a line over 80 chars\n' "$settings_source" >&2
    exit 1
  fi
done

extract_default_manifest() {
  awk '
    /cat <<'\''EOF_MANIFEST'\''/ { capture = 1; next }
    capture && /^EOF_MANIFEST$/ { exit }
    capture { print }
  ' "$1" | LC_ALL=C sort -u
}
fixture_default_manifest="$(
  jq -r '.default.required[], .default.skipped[]' "$MANIFEST" | LC_ALL=C sort -u
)"
for manifest_owner in \
  "$ROOT/skills/onboard/scripts/unattended-policy.sh" \
  "$ROOT/skills/onboard/scripts/completion-guard.sh" \
  "$ROOT/skills/onboard/scripts/render-report.sh"; do
  script_default_manifest="$(extract_default_manifest "$manifest_owner")"
  if [ "$script_default_manifest" != "$fixture_default_manifest" ]; then
    printf 'FAIL: onboard default manifest drifted from fixture: %s\n' "$manifest_owner" >&2
    exit 1
  fi
done

extract_optional_manifest() {
  awk '
    /cat <<'\''EOF_OPTIONAL'\''/ { capture = 1; next }
    capture && /^EOF_OPTIONAL$/ { exit }
    capture { print }
  ' "$1" | LC_ALL=C sort -u
}
fixture_optional_manifest="$(
  jq -r '.default.skipped[]' "$MANIFEST" | LC_ALL=C sort -u
)"
guard_optional_manifest="$(extract_optional_manifest "$ROOT/skills/onboard/scripts/completion-guard.sh")"
if [ "$guard_optional_manifest" != "$fixture_optional_manifest" ]; then
  printf '%s\n' 'FAIL: onboard optional manifest drifted from fixture: completion-guard.sh' >&2
  exit 1
fi

OWNERSHIP_MANIFEST="$ROOT/install/launch-control-owned-digests.txt"
# shellcheck source=launch-control-digests.sh
source "$ROOT/tools/launch-control-digests.sh"
if run_rg -n -v '^(#.*|[[:space:]]*|(?:skills|agents) [^[:space:]]+ [0-9a-f]{64})$' "$OWNERSHIP_MANIFEST"; then
  printf '%s\n' 'FAIL: malformed Launch Control ownership manifest entry' >&2
  exit 1
fi
for source_item in "$ROOT"/skills/* "$ROOT"/agents/*; do
  [ -e "$source_item" ] || continue
  case "$source_item" in
    "$ROOT"/skills/*) scope=skills ;;
    *) scope=agents ;;
  esac
  name="$(basename "$source_item")"
  digest="$(launch_control_item_digest "$source_item")"
  if ! launch_control_manifest_has_digest "$OWNERSHIP_MANIFEST" "$scope" "$name" "$digest"; then
    printf 'FAIL: ownership manifest lacks current digest for %s/%s: %s\n' "$scope" "$name" "$digest" >&2
    exit 1
  fi
done

node - "$ROOT/install/mcp.reference.json" <<'NODE'
const fs = require("fs");
const config = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const servers = config.mcpServers || {};
for (const name of ["github", "atlassian"]) {
  const server = servers[name];
  if (!server || !server.type || !server.url || server.command || server.args) {
    throw new Error(`${name} must remain a URL-based authenticated remote MCP`);
  }
}
for (const name of ["shadcn", "chrome-devtools"]) {
  const server = servers[name];
  if (!server || server.command !== "npx" || !Array.isArray(server.args) || server.type || server.url) {
    throw new Error(`${name} must remain a command-based local stdio MCP`);
  }
}
if (!/authenticated remote integrations/.test(config._comment) ||
    !/local stdio servers/.test(config._comment) ||
    /auth is via OAuth at runtime/.test(config._comment)) {
  throw new Error("MCP reference comment collapses remote auth and local stdio transports");
}
NODE

node - "$ROOT/skills/onboard/references/configuration-generation.md" \
  "$ROOT/skills/onboard/references/mcp-detection.md" \
  "$ROOT/skills/research-questions/SKILL.md" \
  "$ROOT/skills/log-decision/SKILL.md" \
  "$ROOT/skills/snippets-shared-by-skills/source-fetchers.md" \
  "$ROOT/README.md" <<'NODE'
const fs = require("fs");
const [onboardPath, detectionPath, problemPath, decisionPath, fetchersPath, readmePath] = process.argv.slice(2);
const read = path => fs.readFileSync(path, "utf8");
const onboard = read(onboardPath);
const detection = read(detectionPath);
const problem = read(problemPath);
const decision = read(decisionPath);
const fetchers = read(fetchersPath);
const readme = read(readmePath);

for (const [name, source] of [["research-questions", problem], ["log-decision", decision]]) {
  if (!source.includes("mcp__notion__*") || !/otherwise[^\n]*(?:paste|request)/i.test(source)) {
    throw new Error(`${name} must detect Notion MCP dynamically and retain a manual fallback`);
  }
}
for (const [name, source] of [["research-questions", problem], ["log-decision", decision]]) {
  if (/no Notion MCP(?: at user level| yet| is available)?/i.test(source)) {
    throw new Error(`${name} contains a static Notion availability claim`);
  }
}
if (!/active at local, project, user, plugin, or managed scope/.test(onboard) ||
    !/does not prove its scope/.test(onboard) ||
    /active at user level|already configured at user level/i.test(onboard)) {
  throw new Error("onboard must not infer MCP scope from active session tools");
}
if (!/active nowhere[\s\S]*add its missing, secret-free project entry/.test(onboard) ||
    !/already active[\s\S]*do not duplicate it/.test(onboard) ||
    !/already active[\s\S]*different shared configuration[\s\S]*project override/.test(onboard)) {
  throw new Error("onboard must preserve explicit MCP add, skip, and override branches");
}
if (!/^description: .*problem intake.*source artifacts.*neutral, solution-agnostic research questions$/m.test(problem)) {
  throw new Error("research-questions frontmatter must align problem-intake and source-artifact vocabulary");
}
if (!/does not prove its scope/.test(detection) || !/already active/.test(detection)) {
  throw new Error("MCP detection reference must preserve scope-neutral active-server handling");
}
if (!/Datadog MCP is available at any scope/.test(fetchers) || /Datadog MCP is configured at user level/i.test(fetchers)) {
  throw new Error("Datadog fetch guidance must accept MCP availability at any scope");
}
for (const concept of ["Launch Control", "Guide Stars", "Workbench", "Artifacts", "Onboard", "Launch", "Mission"]) {
  if (!readme.includes(`| **${concept}** |`)) {
    throw new Error(`README core concepts glossary is missing ${concept}`);
  }
}
if (!/workbench\/<TICKET>\/<stage>\/[\s\S]*Workflow skills create these artifacts after onboarding/.test(readme)) {
  throw new Error("README must distinguish Workbench artifacts from onboarding output");
}
NODE

node - "$ROOT/skills/onboard/references/launch-template.md" "$ROOT/skills/onboard/references/launch-fixture-example.md" "$ROOT/skills/onboard/references/artifact-templates.md" \
  "$ROOT/skills/onboard/references/launch-ticket-intake-template.md" \
  "$ROOT/skills/onboard/references/launch-implementation-template.md" \
  "$ROOT/skills/onboard/references/launch-delivery-template.md" \
  "$ROOT/skills/onboard/references/launch-verification-template.md" \
  "$ROOT/skills/onboard/references/launch-ticket-intake-fixture-example.md" \
  "$ROOT/skills/onboard/references/launch-implementation-fixture-example.md" \
  "$ROOT/skills/onboard/references/launch-delivery-fixture-example.md" \
  "$ROOT/skills/onboard/references/launch-verification-fixture-example.md" <<'NODE'
const fs = require("fs");
let failed = false;
function frontmatter(source, file) {
  const firstFence = source.indexOf("\n---\n");
  if (source.startsWith("<!--") && firstFence !== -1) source = source.slice(firstFence + 1);
  const match = source.match(/^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/);
  if (!match) throw new Error(`${file}: missing delimited YAML frontmatter`);
  const lines = match[1].split(/\r?\n/);
  let blockIndent = null;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!line.trim() || /^\s*#/.test(line)) continue;
    const indent = line.match(/^\s*/)[0].length;
    if (blockIndent !== null && indent > blockIndent) continue;
    blockIndent = null;
    if (indent !== 0) throw new Error(`${file}:${i + 2}: unexpected indentation`);
    const field = line.match(/^([A-Za-z][A-Za-z0-9_-]*):(?:\s+(.*))?$/);
    if (!field) throw new Error(`${file}:${i + 2}: invalid mapping entry: ${line}`);
    const value = field[2] ?? "";
    if (!value) throw new Error(`${file}:${i + 2}: empty mapping value`);
    if (/^[>|][+-]?$/.test(value)) { blockIndent = indent; continue; }
    const quoted = /^(?:"(?:[^"\\]|\\.)*"|'[^']*')$/.test(value);
    if (!quoted && /:\s/.test(value)) {
      throw new Error(`${file}:${i + 2}: plain scalar contains an unquoted colon`);
    }
  }
  return true;
}
for (const file of process.argv.slice(2, 4)) {
  const source = fs.readFileSync(file, "utf8");
  try { frontmatter(source, file); } catch (error) {
    console.error(`FAIL: ${error.message}`);
    failed = true;
  }
  const token = /\{\{(#|\/)(if|unless|each)(?: [^}]*)?\}\}/g;
  const stack = [];
  let match;
  while ((match = token.exec(source)) !== null) {
    const [, mode, name] = match;
    if (mode === "#") stack.push(name);
    else if (stack.pop() !== name) {
      console.error(`FAIL: unbalanced ${name} block in ${file}`);
      failed = true;
    }
  }
  if (stack.length) {
    console.error(`FAIL: unclosed template blocks in ${file}: ${stack.join(", ")}`);
    failed = true;
  }
}

const template = [process.argv[2], ...process.argv.slice(5, 9)].map(file => fs.readFileSync(file, "utf8")).join("\n");
const fixture = [process.argv[3], ...process.argv.slice(9, 13)].map(file => fs.readFileSync(file, "utf8")).join("\n");
if (!/\*\*Commit format defaults\*\*[\s\S]*up to 150 characters/i.test(template)) {
  console.error("FAIL: Launch template does not cap commit messages at 150 characters");
  failed = true;
}
if (/up to 150\s*\n\s*characters/i.test(fs.readFileSync(process.argv[4], "utf8"))) {
  console.error("FAIL: artifact template splits the atomic commit-limit phrase across lines");
  failed = true;
}
if (!/commit \(lowercase, up to 150 characters, trailers matching the base branch\)/i.test(fixture)) {
  console.error("FAIL: Launch fixture does not cap commit messages at 150 characters");
  failed = true;
}
// Round-37: the template used to default to "No AI co-author lines, no AI attribution". That was
// wrong in both directions -- it stripped trailers from repositories whose history carries them
// (this one does, every recent commit), and it stated a house style as a portable default. The
// replacement derives the answer from the base branch instead of asserting one, so pin the
// derivation, not a verdict: a future edit that reinstates either blanket rule fails here.
if (!/\*\*Commit format defaults\*\*[\s\S]*Trailers follow whatever the base branch already uses[\s\S]*match it[\s\S]*if\s*\n?\s*they carry none, add none/i.test(template)) {
  console.error("FAIL: Launch template does not derive commit trailers from the base branch");
  failed = true;
}
// This scans ONLY launch-template.md, which describes no repository's conventions by literal
// example -- the `## Project Conventions` block is templated, not prose -- so there is no
// false-positive surface today. If someone later adds an illustrative aside quoting a repo whose
// own convention forbids trailers, this will misfire and claim the blanket default came back.
// Narrow it to the defaults section then rather than deleting it.
if (/no AI co-author|no AI attribution|no Claude mention/i.test(template)) {
  console.error("FAIL: Launch template reinstated a blanket AI-attribution rule as a default");
  failed = true;
}
function renderFlags(source, flags) {
  const tag = /\{\{#(if|unless) ([A-Z0-9_]+)\}\}|\{\{\/(if|unless)\}\}/g;
  function renderRange(start, stopKind = null) {
    let output = "", cursor = start, match;
    tag.lastIndex = cursor;
    while ((match = tag.exec(source))) {
      output += source.slice(cursor, match.index);
      if (match[3]) {
        if (match[3] !== stopKind) throw new Error(`provider fixture: mismatched ${match[3]} close`);
        return [output, tag.lastIndex];
      }
      const kind = match[1], flag = match[2], bodyStart = tag.lastIndex;
      const [body, after] = renderRange(bodyStart, kind);
      const enabled = Boolean(flags[flag]);
      if ((kind === "if" && enabled) || (kind === "unless" && !enabled)) output += body;
      cursor = after;
      tag.lastIndex = cursor;
    }
    if (stopKind) throw new Error(`provider fixture: unclosed ${stopKind}`);
    return [output + source.slice(cursor), source.length];
  }
  return renderRange(0)[0];
}
const notionMcp = renderFlags(template, {HAS_NOTION: true, HAS_NOTION_MCP: true});
const notionManual = renderFlags(template, {HAS_NOTION: true, HAS_NOTION_MCP: false});
const chromeWithoutJira = renderFlags(template, {HAS_JIRA_MCP: false, HAS_CHROME_MCP: true, HAS_CHROME_DEVTOOLS_MCP: false});
const chromeWithJira = renderFlags(template, {HAS_JIRA_MCP: true, HAS_CHROME_MCP: true, HAS_CHROME_DEVTOOLS_MCP: false});
const devtoolsWithoutJira = renderFlags(template, {HAS_JIRA_MCP: false, HAS_CHROME_MCP: false, HAS_CHROME_DEVTOOLS_MCP: true});
const devtoolsWithJira = renderFlags(template, {HAS_JIRA_MCP: true, HAS_CHROME_MCP: false, HAS_CHROME_DEVTOOLS_MCP: true});
const withoutConfluence = renderFlags(template, {HAS_CONFLUENCE: false});
if (!notionMcp.includes("mcp__notion__*") || notionMcp.includes("no Notion MCP is available")) {
  console.error("FAIL: Notion-enabled provider fixture is unusable"); failed = true;
}
if (!notionManual.includes("no Notion MCP is available") || notionManual.includes("Use the available `mcp__notion__*`")) {
  console.error("FAIL: Notion-disabled provider fixture is incorrect"); failed = true;
}
if (chromeWithoutJira.includes("Attachment binaries") || chromeWithoutJira.includes("/rest/api/3/attachment/content/")) {
  console.error("FAIL: Chrome attachment workflow renders without Jira relevance"); failed = true;
}
if (!chromeWithJira.includes("mcp__chrome__use_browser") || chromeWithJira.includes("mcp__chrome-devtools__*")) {
  console.error("FAIL: Chrome provider fixture crosses namespaces"); failed = true;
}
if (devtoolsWithoutJira.includes("Attachment binaries")) {
  console.error("FAIL: Chrome DevTools attachment workflow renders without Jira relevance"); failed = true;
}
if (!devtoolsWithJira.includes("mcp__chrome-devtools__*") || devtoolsWithJira.includes("mcp__chrome__use_browser")) {
  console.error("FAIL: Chrome DevTools provider fixture crosses namespaces"); failed = true;
}
if (!withoutConfluence.includes("no Confluence publishing step is available") ||
    withoutConfluence.includes("Atlassian MCP")) {
  console.error("FAIL: no-Confluence Launch workflow is incorrect"); failed = true;
}
if (/^\d+\. \*\*(?:GitHub|Notion|Atlassian|Inline)/m.test(template)) {
  console.error("FAIL: conditional provider source list uses unstable numeric labels"); failed = true;
}
try { frontmatter("---\nname: bad\ndescription: text with: colon\n---\n", "frontmatter-regression"); }
catch (error) { if (!/unquoted colon/.test(error.message)) throw error; }
if (!failed) {
  try {
    frontmatter("---\nname: bad\ndescription: text with: colon\n---\n", "frontmatter-regression");
    console.error("FAIL: frontmatter regression accepted an unquoted colon");
    failed = true;
  } catch {}
}
process.exit(failed ? 1 : 0);
NODE

node - "$ROOT/skills/onboard/SKILL.md" "$ROOT/skills/onboard/references/hooks-and-config.md" "$ROOT/skills/onboard/references/artifact-templates.md" "$ROOT/skills/onboard/references/launch-template.md" "$MANIFEST" \
  "$ROOT/skills/onboard/references/completion-report-and-ledgers.md" \
  "$ROOT/skills/onboard/references/run-authority-and-lifecycle.md" \
  "$ROOT/skills/onboard/references/context-discovery.md" \
  "$ROOT/skills/onboard/references/configuration-generation.md" \
  "$ROOT/skills/onboard/references/skills-agents-and-commands.md" \
  "$ROOT/skills/onboard/references/launch-generation.md" \
  "$ROOT/skills/onboard/references/claude-md-and-documentation.md" \
  "$ROOT/skills/onboard/references/launch-ticket-intake-template.md" \
  "$ROOT/skills/onboard/references/launch-implementation-template.md" \
  "$ROOT/skills/onboard/references/launch-delivery-template.md" \
  "$ROOT/skills/onboard/references/launch-verification-template.md" <<'NODE'
const fs = require("fs");
const path = require("path");
const [
  skillPath, hooksPath, templatesPath, launchPath, manifestPath, reportRefPath,
  runProtocolPath, discoveryRefPath, configurationRefPath,
  artifactsRefPath, launchRefPath, claudeDocsRefPath, ...launchReferencePaths
] = process.argv.slice(2);
const skillFile = fs.readFileSync(skillPath, "utf8");
const reportRef = fs.readFileSync(reportRefPath, "utf8");
const runProtocol = fs.readFileSync(runProtocolPath, "utf8");
const discoveryRef = fs.readFileSync(discoveryRefPath, "utf8");
const configurationRef = fs.readFileSync(configurationRefPath, "utf8");
const artifactsRef = fs.readFileSync(artifactsRefPath, "utf8");
const launchRef = fs.readFileSync(launchRefPath, "utf8");
const claudeDocsRef = fs.readFileSync(claudeDocsRefPath, "utf8");
const hooks = fs.readFileSync(hooksPath, "utf8");
const templates = fs.readFileSync(templatesPath, "utf8");
const launch = [launchPath, ...launchReferencePaths].map(file => fs.readFileSync(file, "utf8")).join("\n");
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
let failed = false;

function requireMatch(source, pattern, message) {
  if (!pattern.test(source)) {
    console.error(`FAIL: ${message}`);
    failed = true;
  }
}

// Round-37: onboarding no longer generates a `sandbox` block -- the Bash sandbox is the user's
// own setting, and a per-project `sandbox.enabled: true` written by a tool the user ran once
// silently changed the execution model for every later session in that repo. What replaced the
// old assertions is NOT nothing. The credential globs used to be required twice, in
// `sandbox.filesystem.denyRead` AND in `permissions.deny`, but only two `.env` spellings were
// ever pinned on the permissions side. Now that `permissions.deny` is the only place the
// boundary lives, every glob is required THERE, so dropping this generation could not quietly
// take the credential list with it.
//
// The residual capability loss is real and deliberately accepted, not papered over: a `Read(...)`
// deny gates Claude's own tools and any Bash reader whose path argument Claude Code can resolve,
// but it does not stop a child process a validation command spawns, nor a recursive grep that
// reaches a secret file without naming it. SKILL.md documents that gap. Re-adding an opt-in
// `--sandbox` flag remains open; silently writing the key does not.
const requiredReadDenies = [
  "Read(/.env*)",
  "Read(/**/.env*)",
  "Read(./secrets/**)",
  "Read(./**/credentials)",
  "Read(./**/.credentials*)",
  "Read(./**/credentials*.json)",
  "Read(./**/credentials*.yaml)",
  "Read(./**/credentials*.yml)",
  "Read(./**/credentials*.toml)",
  "Read(./**/credentials*.ini)",
  "Read(./**/credentials*.cfg)",
  "Read(./**/credentials*.conf)",
  "Read(./**/credentials*.env)",
  "Read(./**/credentials*.txt)",
  "Read(./**/credentials*.pem)",
  "Read(./**/credentials*.key)",
  "Read(./**/credentials*.p12)",
  "Read(./**/credentials*.pfx)",
  "Read(./**/credentials*.jks)",
  "Read(./**/credentials*.keystore)",
  "Read(./**/credentials*.db)",
  "Read(./**/credentials*.sqlite)",
  "Read(./**/credentials*.enc)",
];
function validateSecretBoundary(settings, label) {
  const permissionDenies = settings.permissions?.deny;
  if (!Array.isArray(permissionDenies)) throw new Error(`${label}: permissions deny list is missing`);
  for (const required of requiredReadDenies) {
    if (!permissionDenies.includes(required)) throw new Error(`${label}: permissions deny is missing ${required}`);
  }
  // The invariant is the ABSENCE of the key, not a shape for it. `hasOwnProperty` rather than a
  // truthiness test: `"sandbox": {}` and `"sandbox": null` are both onboarding writing a sandbox
  // key it does not own, and both would pass `if (settings.sandbox)`.
  if (Object.prototype.hasOwnProperty.call(settings, "sandbox")) {
    throw new Error(`${label}: onboarding must not write a sandbox key -- it removes an existing one from the project settings`);
  }
}

const baseSettingsSource = hooks.match(/Base structure for every normal onboarding:\s*```json\s*([\s\S]*?)\s*```/)?.[1];
if (!baseSettingsSource) {
  console.error("FAIL: settings reference lacks a parseable base settings JSON block");
  failed = true;
} else {
  let baseSettings;
  try {
    baseSettings = JSON.parse(baseSettingsSource);
    validateSecretBoundary(baseSettings, "base-settings-positive");
  } catch (error) {
    console.error(`FAIL: ${error.message}`);
    failed = true;
  }
  if (baseSettings) {
    const expectBoundaryFailure = (name, mutate) => {
      const fixture = JSON.parse(JSON.stringify(baseSettings));
      mutate(fixture);
      try {
        validateSecretBoundary(fixture, name);
        console.error(`FAIL: secret-boundary negative fixture succeeded: ${name}`);
        failed = true;
      } catch (error) {
        if (!new RegExp(`^${name}:`).test(error.message)) throw error;
      }
    };
    expectBoundaryFailure("native-read-missing-secret-pattern", fixture => {
      fixture.permissions.deny = fixture.permissions.deny.filter(rule => rule !== "Read(/**/.env*)");
    });
    // Round-37: the six sandbox-internals cases that used to live here lost their subject when
    // generation stopped, and `read-deny-only` (delete fixture.sandbox) asserted the failure of
    // what is now the required shape. These four replace them: the key must not come back in any
    // spelling, and the credential globs must stay pinned now that permissions.deny is their only
    // home. Dropping the old cases without adding these would have left the boundary untested.
    expectBoundaryFailure("sandbox-generated", fixture => {
      fixture.sandbox = { enabled: true, failIfUnavailable: true, autoAllowBashIfSandboxed: false };
    });
    expectBoundaryFailure("sandbox-generated-empty", fixture => { fixture.sandbox = {}; });
    expectBoundaryFailure("credential-glob-dropped", fixture => {
      fixture.permissions.deny = fixture.permissions.deny.filter(rule => rule !== "Read(./**/credentials*.enc)");
    });
    expectBoundaryFailure("secrets-directory-open", fixture => {
      fixture.permissions.deny = fixture.permissions.deny.filter(rule => rule !== "Read(./secrets/**)");
    });
  }
}

const beforeDiscovery = runProtocol;
const settingsPhase = configurationRef.match(/### 1a\. `\.claude\/settings\.json`([\s\S]*?)### 1b\./)?.[1] || "";
const summaryPhase = reportRef;
const routedReferences = new Map([
  ["run-authority-and-lifecycle.md", "Phase 0"],
  ["codex-parity.md", "Phase 0"],
  ["context-discovery.md", "Phase 0"],
  ["configuration-generation.md", "Phase 1"],
  ["hooks-and-config.md", "Phase 1"],
  ["mcp-detection.md", "Phase 1"],
  ["skills-agents-and-commands.md", "Phase 2a"],
  ["artifact-templates.md", "Phase 2a"],
  ["checkpoint-templates.md", "Phase 2a"],
  ["launch-generation.md", "Phase 2d"],
  ["launch-discovery.md", "Phase 2d"],
  ["launch-template.md", "Phase 2d"],
  ["launch-ticket-intake-template.md", "Phase 2d"],
  ["launch-implementation-template.md", "Phase 2d"],
  ["launch-delivery-template.md", "Phase 2d"],
  ["launch-verification-template.md", "Phase 2d"],
  ["launch-acceptance-criteria.md", "Phase 2d"],
  ["claude-md-and-documentation.md", "Phase 3"],
  ["completion-report-and-ledgers.md", "Phase 5"],
]);
const directReferences = [...skillFile.matchAll(/@references\/([A-Za-z0-9._-]+\.md)/g)]
  .map((match) => match[1]);
for (const name of directReferences) {
  if (!fs.existsSync(path.join(path.dirname(skillPath), "references", name))) {
    console.error(`FAIL: onboard direct reference does not exist: ${name}`);
    failed = true;
  }
}
for (const [name, phase] of routedReferences) {
  const escapedName = name.replace(/\./g, "\\.");
  requireMatch(
    skillFile,
    new RegExp(`Read @references/${escapedName} completely before starting ${phase}\\.`),
    `onboard does not require ${name} before ${phase}`,
  );
}
if (new Set(directReferences).size !== routedReferences.size ||
    [...routedReferences.keys()].some((name) => !directReferences.includes(name))) {
  console.error("FAIL: onboard phase router and direct reference inventory differ");
  failed = true;
}
if (skillFile.split(/\r?\n/).length > 500) {
  console.error("FAIL: onboard SKILL.md exceeds the 500-line progressive-disclosure ceiling");
  failed = true;
}
const progressiveReferences = [
  ["run-authority-and-lifecycle.md", runProtocol],
  ["context-discovery.md", discoveryRef],
  ["configuration-generation.md", configurationRef],
  ["skills-agents-and-commands.md", artifactsRef],
  ["launch-generation.md", launchRef],
  ["claude-md-and-documentation.md", claudeDocsRef],
  ["completion-report-and-ledgers.md", reportRef],
];
for (const [name, source] of progressiveReferences) {
  if (source.split(/\r?\n/).length > 100 && !/^## Contents$/m.test(source)) {
    console.error(`FAIL: long onboard reference lacks a contents section: ${name}`);
    failed = true;
  }
}
for (const [name, source] of progressiveReferences.slice(0, -1)) {
  if (/@references\/[A-Za-z0-9._-]+\.md/.test(source)) {
    console.error(`FAIL: onboard reference nests another concrete reference: ${name}`);
    failed = true;
  }
}
const reportOwnerPattern = /blocked protocol is byte-exact and machine-verified[\s\S]*Every `Failed` item is a report of machine output/;
requireMatch(reportRef, reportOwnerPattern, "report reference lost the blocked-protocol ownership rules");

requireMatch(beforeDiscovery, /Unsupported flags[\s\S]*--profile[\s\S]*--minimal[\s\S]*--standard[\s\S]*--full[\s\S]*--config-only[\s\S]*--docs-only[\s\S]*before discovery or writes/i, "removed flags are not rejected before discovery/writes");
requireMatch(beforeDiscovery, /Non-negotiable completion protocol[\s\S]*success is valid only if[\s\S]*render-report\.sh[\s\S]*stdout byte for\s+byte[\s\S]*idempotent no-op/, "renderer gate is not prominent enough for every writing mode");
requireMatch(skillFile, /hooks:[\s\S]*UserPromptSubmit:[\s\S]*completion-guard\.sh[\s\S]*TaskCreated:[\s\S]*completion-guard\.sh[\s\S]*TaskCompleted:[\s\S]*completion-guard\.sh[\s\S]*PreToolUse:[\s\S]*Bash\|Edit\|Write[\s\S]*completion-guard\.sh[\s\S]*Stop:[\s\S]*completion-guard\.sh/, "onboard lacks the skill-scoped completion-guard hooks");
requireMatch(runProtocol, /executable completion boundary/, "run protocol lost the executable completion-boundary rule");
requireMatch(skillFile, /PreToolUse:[\s\S]*Bash\|Edit\|Write\|Read\|Glob\|Grep[\s\S]*unattended-policy\.sh[\s\S]*PermissionRequest:[\s\S]*unattended-policy\.sh/, "onboard lacks the skill-scoped unattended-policy hooks");
requireMatch(runProtocol, /least-privilege unattended boundary[\s\S]*never returns `updatedPermissions`[\s\S]*never edits[\s\S]*settings\.local\.json/, "run protocol lost the non-persistent unattended-policy boundary");
requireMatch(beforeDiscovery, /fixed-depth[\s\S]*find \. -maxdepth N -type f[\s\S]*silently misses[\s\S]*deep monorepo metadata[\s\S]*complete targeted metadata globs/, "onboard still permits shallow root discovery as the sole inventory");
requireMatch(discoveryRef, /Emit this complete block as a standalone assistant progress message[\s\S]*only pre-checkpoint write[\s\S]*discovery-report\.txt[\s\S]*discovery-checkpoint\.sh[\s\S]*validates every[\s\S]*binds that hash[\s\S]*blocks every[\s\S]*manifest `Edit`\/`Write`/, "discovery report is not schema-validated and bound before writes");
requireMatch(beforeDiscovery, /If this run uses `TaskCreate`[\s\S]*Complete every created[\s\S]*before invoking `render-report\.sh`[\s\S]*every task creation or completion invalidates earlier renderer proof[\s\S]*do not call `TaskCreate` or `TaskUpdate`/, "onboard lacks a strict task-closure lifecycle contract");
requireMatch(beforeDiscovery, /captures the live dirty-path baseline[\s\S]*pre-write inventory of every active manifest path inside Git metadata[\s\S]*hash-object --no-filters[\s\S]*renderer enforces that captured baseline and[\s\S]*inventory independently of any caller-supplied ledger file/, "completion guard does not own the pre-write baseline and manifest inventory");
requireMatch(beforeDiscovery, /verified\s+success[\s\S]*disarms both lifecycle hooks[\s\S]*later unrelated turns[\s\S]*later `\/onboard` prompt explicitly re-arms[\s\S]*marker is keyed to the Claude session[\s\S]*Blocked or failed\s+runs do not disarm/, "onboard lacks a post-completion disarm and conservative re-arm contract");
requireMatch(beforeDiscovery, /respects the\s+mode the user chose and does not grade it[\s\S]*may proceed under bypass[\s\S]*say once in conversation that this run executes under permission\s+bypass[\s\S]*ask-gates are denied rather than asked[\s\S]*self-enforce every rule in the degraded-mode/, "onboard bypassPermissions handling is not proceed-with-one-mention and self-enforcement");
// LC-058: onboarding respects the session mode the user chose. It must not steer the user
// toward the default mode or demand the bypass fact be stated twice.
if (/prefer the default permission mode|state it\s+again|turn immediately before the\s+renderer invocation/.test(runProtocol)) {
  console.error("FAIL: onboard again steers the permission mode or demands a second bypass disclosure");
  failed = true;
}
// Round-14 F28. Both acceptance runs presented a completion report under bypass with no
// disclosure anywhere near it, and one never mentioned bypass at all. The cause was not
// negligence: the skill demanded the disclosure "accompany the final report" while the
// completion contract and the Stop guard require the entire final message to equal the
// renderer's stdout byte-for-byte. Those cannot both hold, only one is machine-enforced, so
// both runs satisfied that one and dropped the fact. Pin the placement that satisfies both
// -- an ordinary turn, never the final message -- and the reason, so the conflict is not
// reintroduced as prose.
requireMatch(beforeDiscovery, /ordinary\s+turn, never in the final message[\s\S]*entire\s+final message to equal the renderer's stdout byte-for-byte[\s\S]*`Stop` guard enforces it\s+mechanically/, "onboard does not resolve the bypass-disclosure/byte-exact-report conflict by placement");
if (/disclosure MUST also accompany the final report|bypass disclosure MUST also accompany the final/.test(runProtocol)) {
  console.error("FAIL: onboard again requires the bypass disclosure inside the byte-exact final message, which the Stop guard blocks");
  failed = true;
}
// The run cannot see its own permission mode until something depends on it, so the policy's
// denial text is the detection point. Pin that the skill names it rather than leaving the
// up-front disclosure requirement unsatisfiable in the general case.
// Round-14 F28, second pass. The first fix keyed the disclosure to the first policy
// denial. That signal is not reliable and the same commit destroyed it: allowlisting the
// settings-audit spelling (F29) removed the one denial code-explorer had been hitting, so
// the next bypassed acceptance run tripped no `ask` gate, learned nothing, and reached a
// completion report having never mentioned bypass. Detection now belongs to the policy,
// which sees permission_mode on every call, and the fact is carried by the renderer.
requireMatch(beforeDiscovery, /often not know the mode at the first turn[\s\S]*Do not wait for a denial to find out[\s\S]*denial is not a\s+reliable signal[\s\S]*trips no `ask` gate at all[\s\S]*records bypass the first time it sees the session[\s\S]*prints `permission-mode:` in the report's `Checks` block/, "onboard still keys bypass detection to a denial instead of the policy's own observation");
requireMatch(beforeDiscovery, /fact about the session, not a verdict on the run[\s\S]*report records the mode from the policy's own observation/, "onboard does not state the permission-mode line as a fact rather than a verdict");
if (/renderer cannot observe or attest to the session's permission mode/.test(runProtocol)) {
  console.error("FAIL: onboard still claims the renderer cannot observe the permission mode, which the permission-mode check now derives");
  failed = true;
}
// Round-14 F29. A run that ate the settings-audit denial reasoned the renderer's
// `settings-json:` line covered the same ground and reported completion without ever
// auditing the permissions. Pin the permitted spellings and the fact that the two checks
// are not interchangeable, so a denial cannot resolve into a skipped audit again.
requireMatch(artifactsRef, /permits that parse repo-relative and as the absolute path to the same file[\s\S]*Any other spelling is denied[\s\S]*denial is not\s+a completed audit[\s\S]*reissue it in a permitted spelling[\s\S]*does not\s+stand in for this audit[\s\S]*reports an audit that was\s+never performed/, "onboard does not pin the permitted settings-audit spellings or forbid substituting the renderer's parse");
if (/do not proceed under permission bypass|stop before any discovery or write and ask the user to rerun/.test(runProtocol)) {
  console.error("FAIL: onboard still hard-refuses bypassPermissions instead of proceeding with disclosure");
  failed = true;
}
requireMatch(beforeDiscovery, /one complete onboarding path[\s\S]*\/onboard --dry-run/, "unsupported-flag replacement guidance is missing");
requireMatch(beforeDiscovery, /Invocation authority[\s\S]*plain `\/onboard` invocation is the user's\s+direct authorization[\s\S]*without asking the user to choose between a full run, dry-run preview, or\s+throwaway clone[\s\S]*`--dry-run` is active only when the user explicitly supplied that flag/, "plain onboard can still invent a full/dry-run/clone confirmation");
requireMatch(beforeDiscovery, /repository being Launch Control itself[\s\S]*self-dogfood[\s\S]*dirty baseline paths are not reasons to ask a run-mode question[\s\S]*capture every dirty path as `PRESERVED`[\s\S]*Do not describe[\s\S]*as "pollution"/, "Launch Control dogfood or a dirty baseline can still trigger a false approval gate");
// Round-14 F27. The fourth refusal-before-start, and the first to reject the completion
// contract itself: the run read "return the renderer's stdout as the entire final message"
// as an attempt to remove its ability to say what happened, called the skill body
// untrusted, and offered to do the work its own way instead. Restating a prohibition never
// dissolves a belief about harm -- only the fact does. Pin the fact: the report is
// machine-derived so the run cannot soften it, bad news has its own required sections, and
// refusing the contract yields no report at all rather than a more honest one.
requireMatch(beforeDiscovery, /anti-embellishment rule, not a gag order[\s\S]*derives every line from the filesystem[\s\S]*impossible for the run to soften[\s\S]*strictly less trustworthy[\s\S]*Undeclared gates[\s\S]*blocked protocol exists to stop the run and say why[\s\S]*bypass disclosure conversationally[\s\S]*Every turn before the final one is ordinary conversation/, "onboard does not explain why the byte-exact report is not suppression");
requireMatch(beforeDiscovery, /concern you cannot express is a contradiction[\s\S]*Refusing the contract to preserve honesty inverts itself[\s\S]*no report, no\s+ledger[\s\S]*least honest available outcome/, "onboard does not name the self-defeating outcome of refusing the completion contract");
requireMatch(beforeDiscovery, /being the skill is not evidence that the skill has been tampered with[\s\S]*discarding the\s+verification machinery[\s\S]*unverified narration[\s\S]*weaker artifact the safer one/, "onboard does not answer a run that treats its own body as untrusted");
// Round-37: the "conflicting pre-existing sandbox scalar" clause is gone from this list, because
// onboarding no longer writes the key and so can no longer conflict over it. The rule it belonged
// to is unchanged and still pinned.
requireMatch(beforeDiscovery, /Ask the user only when[\s\S]*actual unresolved choice that blocks\s+writes[\s\S]*branch policy[\s\S]*Launch replacement[\s\S]*run-mode menu is a protocol violation/, "onboard does not distinguish real write conflicts from invented mode choices");
requireMatch(beforeDiscovery, /fail-fast, not interactive[\s\S]*deletion-dirty\s+required manifest path[\s\S]*not a run-mode question\s+and not a user prompt[\s\S]*denies the discovery checkpoint[\s\S]*git restore -- <paths>[\s\S]*committing the deletion/, "deletion-dirty required paths are not a fail-fast blocked condition");
requireMatch(discoveryRef, /baseline shows a required manifest path deleted in the index or worktree[\s\S]*guard denies `discovery-checkpoint\.sh`[\s\S]*blocked protocol[\s\S]*git restore -- <paths>/, "Phase 0d does not state the deletion fail-fast gate");
requireMatch(skillFile, /normal run always installs[\s\S]*Launch[\s\S]*CRISPY[\s\S]*self-validation[\s\S]*deterministic reporting/, "default onboarding is not the complete product path");
requireMatch(runProtocol, /Native `\/init` is independent and is never a prerequisite/, "onboarding still requires native init");
requireMatch(claudeDocsRef, /The generated block carries NO comment markers[\s\S]*begins at the line `## Generated Quick Reference`[\s\S]*next top-level `# ` heading or to the end of the file[\s\S]*No CLAUDE\.md exists[\s\S]*line 1 is `## Generated Quick Reference`[\s\S]*entire generated body/, "first-run CLAUDE.md is not heading-delimited for idempotency");
requireMatch(claudeDocsRef, /Replace ONLY the generated block: from the `## Generated Quick Reference` line[\s\S]*legacy `<!-- BEGIN GENERATED SECTION -- onboard -->`[\s\S]*no comment scaffolding remains/, "rerun does not replace the heading-delimited block or migrate legacy markers");
// The contract is that generated output carries no machine-comment scaffolding at all: the only
// mention of the legacy markers in the skill is the migration rule pinned above.
const skillMarkerMentions = (claudeDocsRef.match(/GENERATED SECTION -- onboard/g) || []).length;
if (skillMarkerMentions !== 2) throw new Error(`onboard SKILL.md mentions the legacy onboard markers ${skillMarkerMentions} times; only the two-line migration rule may name them`);
if (/Re-run \/onboard to update/.test(claudeDocsRef)) throw new Error("onboard SKILL.md still emits the 'Re-run /onboard to update' comment scaffolding");

requireMatch(discoveryRef, /preflight applies to every normal `\/onboard` run and to `--launch-control` maintenance[\s\S]*before any project files are written/, "Superpowers preflight is not universal and atomic");
requireMatch(discoveryRef, /required Launch Control\s+dependency[\s\S]*stop the run without writing partial onboarding output/, "missing Superpowers does not block partial output");
requireMatch(launchRef, /`--launch-control` is present[\s\S]*maintenance-only[\s\S]*Phase 0[\s\S]*Phase 2d[\s\S]*Phase 5/, "launch maintenance mode is not isolated and validated");
requireMatch(launchRef, /render comparison content under `\.launch-control-onboard\/`[\s\S]*byte-identical[\s\S]*explicit `--launch-control` maintenance invocation[\s\S]*does not require a\s+second confirmation/i, "Launch regeneration is not deterministic or sandbox-native for idempotent and maintenance runs");
requireMatch(configurationRef, /This phase remains opt-in[\s\S]*`--enable-mcp` permits the relevant project overlay/, "MCP is not an explicit overlay");
requireMatch(configurationRef, /phase only plans the hook overlay when the user passed `--enable-hooks`/, "hooks are not gated by --enable-hooks");
requireMatch(configurationRef, /covered rule as a no-op[\s\S]*never classify it under `SKIPPED`[\s\S]*under `PRESERVED` whenever it existed before[\s\S]*Dirty[\s\S]*subset of `PRESERVED`/, "covered gitignore rules can still be misreported as merged or skipped");
requireMatch(claudeDocsRef, /Finaliz(?:e|ing) opt-in hooks[\s\S]*final project-content write[\s\S]*perform no further Edit or Write[\s\S]*prevents the[\s\S]*PreToolUse hook from self-blocking/, "hook installation can self-block later onboarding writes");
requireMatch(claudeDocsRef, /CRISPY[\s\S]*create `workbench\/<TICKET>\/<stage>\/` later[\s\S]*not part[\s\S]*onboarding-generated target layout[\s\S]*authenticated remote integrations[\s\S]*local stdio servers[\s\S]*blanket OAuth/, "bootstrap documentation facts do not separate workbench ownership or MCP transports");
requireMatch(claudeDocsRef, /completion guard is declared in this installed skill's frontmatter[\s\S]*not registered in user config, installed config,[\s\S]*`--enable-hooks` overlay is separate[\s\S]*registered in `~\/\.claude` config/, "onboard does not prevent false completion-guard registration claims");
requireMatch(claudeDocsRef, /per-document gates[\s\S]*both `artifacts\/architecture\.md` and `artifacts\/infrastructure\.md`[\s\S]*GitHub\/Atlassian as authenticated remote MCPs[\s\S]*shadcn\/chrome-devtools as local[\s\S]*CRISPY skills as the creator of `workbench\/`/, "onboard does not require both bootstrap docs to carry MCP and workbench facts");
requireMatch(claudeDocsRef, /Launch Control[\s\S]*bundled renderer verifies these facts directly[\s\S]*refuses to render[\s\S]*either document omits one/, "onboard does not expose executable documentation gates");
requireMatch(claudeDocsRef, /invoke the `docs-create` skill[\s\S]*Do not author either document directly[\s\S]*session-scoped proof[\s\S]*Mermaid[\s\S]*Generated snapshot[\s\S]*CLAUDE\.md[\s\S]*artifacts\/architecture\.md[\s\S]*artifacts\/infrastructure\.md/, "onboard does not enforce the full docs-create content and invocation contract");
requireMatch(hooks, /base `settings\.json` permissions structure is used by every normal[\s\S]*only when the\s+user passed[\s\S]*`--enable-hooks`/, "hooks reference does not separate base settings from the opt-in overlay");
if (/PreToolUse|SessionStart/.test(settingsPhase)) {
  console.error("FAIL: base settings phase contains hook-generation instructions");
  failed = true;
}

requireMatch(discoveryRef, /documented gates[\s\S]*shell scripts do[\s\S]*not imply `shellcheck`[\s\S]*Never invent a new[\s\S]*gate/, "gates can still be invented without repository evidence");
requireMatch(configurationRef, /fully specified command is `Bash\(<exact command>\)`[\s\S]*never change `Bash\(\.\/install\.sh --dry-run\)` into[\s\S]*`Bash\(\.\/install\.sh --dry-run:\*\)`/, "exact command permission syntax is not enforced");
requireMatch(hooks, /`\.\/install\.sh --dry-run` renders as `Bash\(\.\/install\.sh --dry-run\)`, never[\s\S]*`Bash\(\.\/install\.sh --dry-run:\*\)`/, "settings reference can broaden fully specified commands");
// Round-37: this pinned the sandbox scalars and the OS-level claim. Both are gone, so it now pins
// what the boundary actually is and, critically, the rule that replaced them -- an explicit
// "never write a `sandbox` key" with the remove-an-existing-one rule. Without that second half
// this assertion would pass on a skill that simply stopped mentioning the sandbox, which is the
// state a future edit could drift back into generating one from.
requireMatch(configurationRef, /\*\*Secret-file boundary:\*\*[\s\S]*native Read\/Glob\/Grep and any Bash reader[\s\S]*`cat`, `head`, `tail`, `grep`,[\s\S]*`rg`[\s\S]*\*\*Never write a `sandbox` key, and remove an existing one from the project\s+`\.claude\/settings\.json`\.\*\*[\s\S]*`\.claude\/settings\.local\.json` or user settings, which onboarding never changes/, "onboard does not require an enforceable Bash secret-file boundary");
// Round-37: the deny-outranks-allowRead precedence clause is gone with the sandbox block. The
// load-bearing half survives and is still pinned: the denies also match the safe-example names, so
// Phase 0 is the only chance to read them.
requireMatch(configurationRef, /every root and nested `\.env\*` variant[\s\S]*native Read\/Glob\/Grep[\s\S]*`\.env\.example`[\s\S]*safe examples in Phase 0/i, "onboard does not define arbitrary env protection and safe-example behavior");
// Round-37: the sandbox denyRead/allowRead half of this pin is gone. What replaces it is the
// honest scope statement the sandbox paragraph used to carry -- the boundary constrains the
// SESSION, not the project, and a command's child processes are outside it. That sentence is the
// one thing here that must not quietly disappear: it is the disclosure of the residual gap.
requireMatch(hooks, /Bash\(git remote -v\)[\s\S]*project-root `Read\(\/\.env\*\)`[\s\S]*arbitrary root and nested variants[\s\S]*native Read\/Glob\/Grep and Bash readers alike[\s\S]*safe examples during Phase 0[\s\S]*constrains the Claude Code session, not the project[\s\S]*child processes a\s+command spawns are outside the permission layer/, "settings reference has unsafe git remote permissions or misleading secret guarantees");
// Round-37: this pinned the `allowUnsandboxedCommands` paragraph, now deleted -- there is no
// generated sandbox left for a command to escape. Replaced by a pin on the merge rule that now
// carries the whole invariant, so the reference cannot lose it silently.
requireMatch(hooks, /Remove any top-level `sandbox` key and say so in the run's report\. Never add one\.[\s\S]*Never touch a `sandbox` key in\s+`\.claude\/settings\.local\.json` or user settings/, "settings reference no longer states the remove-never-add sandbox rule");
requireMatch(hooks, /For `permissions\.deny`: union existing \+ new \(never remove\)[\s\S]*Remove any top-level `sandbox` key[\s\S]*preserve `hooks` byte-for-byte/, "settings merge strategy does not pin the deny union and the sandbox remove rule");
requireMatch(templates, /name: project-code-review[\s\S]*?allowed-tools:[^\n]*Bash\(git status:\*\)[^\n]*Bash\(git diff:\*\)/, "project-code-review template does not authorize its git inventory");
requireMatch(templates, /Use Bash only for the read-only Git inventory commands[\s\S]*Never stage, commit,[\s\S]*push/, "inspector agent lacks a least-privilege mutation boundary");
requireMatch(artifactsRef, /`DETECTED_REVIEW_LENS`[\s\S]*at least two evidence-backed Markdown bullets[\s\S]*Project-specific review lens[\s\S]*incomplete artifact/, "onboard does not require an evidence-backed project-specific reviewer");
requireMatch(artifactsRef, /each cited path directly support[\s\S]*install\/mcp\.reference\.json[\s\S]*cannot\s+evidence generated permission or secret-file rules/, "reviewer evidence sources are not required to support their stated concern");
requireMatch(artifactsRef, /Generated artifacts must not contain raw onboard template controls anywhere[\s\S]*examples, troubleshooting tables, or prose[\s\S]*orphaned closing marker[\s\S]*literal control marker as unresolved generation state/, "onboard permits raw template controls in generated explanatory text");
requireMatch(templates, /## Project-specific review lens\s*\n\{\{DETECTED_REVIEW_LENS\}\}/, "inspector template lacks its required review lens token");
requireMatch(templates, /Git workflow specialist[\s\S]*Before any branch switch, commit, push, or PR write,[\s\S]*explicit user confirmation/, "dispatcher agent lacks an explicit mutation approval boundary");
requireMatch(templates, /### \/validate[\s\S]*?allowed-tools:[^\n]*Bash\(\{\{DETECTED_DEPENDENCY_CHECK_CMD\}\}\)/, "validate template cannot authorize an exact dependency check");
requireMatch(templates, /# PR Workflow[\s\S]*branch switches, commits, pushes, and PR creation[\s\S]*explicit user confirmation/, "pr-workflow lacks an explicit mutation approval boundary");
requireMatch(claudeDocsRef, /commit-subject default is\s+`up to 150 characters`[\s\S]*Observed commit-subject lengths[\s\S]*are not evidence of a\s+72-character limit[\s\S]*PR-title default remains `under 72 characters`/, "onboard can infer commit limits from historical subject lengths");
requireMatch(claudeDocsRef, /Preservation is not a freshness pass[\s\S]*Do not infer\s+staleness from a date or changed HEAD alone[\s\S]*do not overwrite the\s+user-owned document[\s\S]*do not render a successful report with `Next: none`[\s\S]*blocked\s+protocol[\s\S]*`docs-update`/, "preserved documentation can pass despite evidence-backed semantic drift");
// Round-33 F1/F2. The comparison used to live only in Phase 4, so a repository whose docs
// contradicted live evidence learned about it after the workspace was written -- 8m40s and five
// written paths on rymonroe.com for a fact the discovery report printed at minute 3. It is now a
// Phase 0 gate whose accounting the checkpoint enforces before the first write. The behavioral
// proof is the F42 family in 30-guard-lifecycle.sh; these pin the contract the run reads.
// LC-001: the safe-example rule is checkpoint-enforced; the LC-001 fixtures in
// 30-guard-lifecycle.sh are the behavioral proof, these pin the contract the run reads.
requireMatch(discoveryRef, /Safe env examples:\s*\n\s*<path>: <read \/ denied>/, "the discovery report template no longer carries a safe env examples section");
requireMatch(discoveryRef, /`discovery-checkpoint\.sh` enforces this[\s\S]*`  <path>: denied` is accepted only when/, "the safe env example rule is no longer documented as checkpoint-enforced");
requireMatch(discoveryRef, /Preserved doc freshness:\s*\n\s*CLAUDE\.md: <consistent \/ contradicts/, "the discovery report template no longer carries a preserved-doc freshness section");
requireMatch(discoveryRef, /Preserved documentation must be compared here, before the checkpoint[\s\S]*`  \(no preserved documentation\)`[\s\S]*prose OUTSIDE the generated block[\s\S]*ships\s+self-contradictory/, "the freshness comparison is no longer a pre-checkpoint Phase 0 rule covering CLAUDE.md prose");
requireMatch(discoveryRef, /discovery-checkpoint\.sh` validates that accounting and exits non-zero[\s\S]*leaves the lifecycle guard's first-write denial in place[\s\S]*blanket `consistent` to clear the gate is a false attestation[\s\S]*Never name only the first contradiction/, "the freshness gate is no longer documented as blocking before the first write with every contradiction named");
requireMatch(claudeDocsRef, /prospective-claude\.md[\s\S]*byte-for-byte match[\s\S]*structurally plausible stale block cannot\s+pass as preserved/, "preserved CLAUDE.md can pass without a prospective block comparison");
// Round-15 F32: two live runs broke the ordering rule while it was prose only. The behavioral
// proof lives in 30-guard-lifecycle.sh and 40-report-contract.sh; this pins the skill to keep
// documenting the rule as provenance-enforced, so it cannot quietly revert to unenforced prose.
requireMatch(claudeDocsRef, /byte comparison proves the two surfaces agree[\s\S]*never show \*\*which\*\* one was made\s+to agree[\s\S]*write-order\.guard\.txt[\s\S]*last\s+prospective write follows its last `CLAUDE\.md` write/, "onboard no longer documents the prospective block ordering rule as provenance-enforced");
requireMatch(reportRef, /claude-md-provenance: <guard-attested -- prospective block written before CLAUDE\.md \| guard-attested -- CLAUDE\.md unwritten this run \| no write order recorded by the completion guard \| not applicable/, "onboard report shape omits the claude-md-provenance check line");
requireMatch(launchRef, /Model insertion pass[\s\S]*annotation and its\s+bullet on separate lines[\s\S]*Never place `-->` and the list marker on the same line/, "model inserts can still collapse comments and Markdown bullets");
requireMatch(launch, /Only an explicit numeric maximum in a repository-controlled convention may override[\s\S]*Never infer a shorter limit from the observed lengths of recent\s+commit subjects/, "Launch permits history-derived commit limits");

const chain = "research-questions`→`research-codebase`→`design-doc`→`design-outline`→`plan-write";
const compactArrows = (source) => source.replace(/\s*→\s*/g, "→");
if (!compactArrows(launch).includes(chain) || !compactArrows(artifactsRef).includes(chain)) {
  console.error("FAIL: generated guidance does not expose the complete CRISPY chain");
  failed = true;
}
requireMatch(launch, /At every authored artifact boundary, run `review-doc`, resolve blocking findings, and\s+only then advance/, "Launch lacks CRISPY review checkpoints");
requireMatch(launch, /invoke `plan-execute` exactly once[\s\S]*do not also invoke[\s\S]*`superpowers:executing-plans`/i, "Launch duplicates or omits the implementation handoff");
if ((launch.match(/`plan-execute` exactly once/g) || []).length < 2 || /superpowers:writing-plans/.test(launch)) {
  console.error("FAIL: Launch matrix or workflow has a duplicate plan/execution path");
  failed = true;
}
requireMatch(launch, /origin\/\{\{BASE_BRANCH\}\}\.\.\.HEAD[\s\S]*git diff --cached[\s\S]*git diff[\s\S]*untracked/, "Launch pre-ship review omits committed or working-tree state");
requireMatch(launch, /Feature \(small\)[\s\S]*Refactor[\s\S]*Full CRISPY ladder[\s\S]*`plan-execute`/, "Launch depth matrix does not cover small features, fixes, and refactors");

requireMatch(summaryPhase, /Maintain four newline-delimited path ledgers[\s\S]*sort and deduplicate[\s\S]*Compute each heading count[\s\S]*Never estimate or type a count from memory[\s\S]*one exact path per line[\s\S]*do not add commentary[\s\S]*after printing the closing marker, output nothing else/, "completion report is not constrained to the compact ledger protocol");
requireMatch(summaryPhase, /`CREATED`[\s\S]*absent before[\s\S]*`MERGED`[\s\S]*content hash or executable state changed[\s\S]*`PRESERVED`[\s\S]*identical after[\s\S]*`SKIPPED`[\s\S]*absent before and remains absent[\s\S]*protected subset of `PRESERVED`[\s\S]*Reject missing or extra status records, status lies/, "completion ledger statuses are not inventory-defined and machine-provable");
requireMatch(summaryPhase, /Recorded gates[\s\S]*never runs a project's own commands[\s\S]*never use a blanket search for `\{\{`[\s\S]*canonical check[\s\S]*validation: not run \(<N> documented gates; \.\.\.\)[\s\S]*`Next: none`[\s\S]*@scripts\/render-report\.sh[\s\S]*stdout verbatim/, "self-validation or deterministic report rendering is incomplete");
// F15: a repository gate failing on its own terms is disclosed, not blocked, so the binding is
// no longer "any nonzero exit blocks". What must still hold: the finalizer executes the commands
// itself, caller-authored statuses cannot mint success, a failure is never reported as passed,
// and no prompt may offer to accept or downgrade one.
requireMatch(summaryPhase, /VALIDATION_COMMANDS_FILE[\s\S]*executes none of them[\s\S]*disclosure rule, not a tolerance rule[\s\S]*AskUserQuestion/, "onboard does not state that the renderer runs none of the recorded gates or forbid an override prompt");
requireMatch(summaryPhase, /What still blocks is what belongs to this run[\s\S]*Unsafe recorded gates[\s\S]*Ledger or inventory dishonesty/, "onboard does not name what still blocks");
requireMatch(summaryPhase, /Invoke the installed\s+renderer in one simple Bash tool call[\s\S]*literal absolute paths[\s\S]*Do not use a preliminary `renderer=\.\.\.` assignment[\s\S]*separate\s+`test -x`[\s\S]*command substitution[\s\S]*relative control-file path[\s\S]*ONBOARD_REQUIRED_PATHS_FILE="\/absolute\/repo\/\.launch-control-onboard\/required-paths\.txt"[\s\S]*\/absolute\/claude-config\/skills\/onboard\/scripts\/render-report\.sh/, "runtime renderer invocation is not a single policy-compatible command");
requireMatch(summaryPhase, /Created \(<N>\):[\s\S]*Merged \(<N>\):[\s\S]*Skipped \(<N>\):[\s\S]*Preserved \(<N>\):[\s\S]*Checks:[\s\S]*=== End Workspace Setup ===/, "completion report template is incomplete");
requireMatch(summaryPhase, /first byte[\s\S]*=== Workspace Setup Complete ===[\s\S]*Never surround[\s\S]*triple backticks/, "final report can still be wrapped in Markdown");
requireMatch(summaryPhase, /blocked protocol is byte-exact and machine-verified[\s\S]*first byte of the response MUST be the first `=` of[\s\S]*=== Workspace Setup Blocked ===[\s\S]*last line MUST be exactly[\s\S]*=== End Workspace Setup ===[\s\S]*Never surround it with triple\s+backticks[\s\S]*indented exactly two spaces[\s\S]*`Reason:` alone on its line[\s\S]*`Next:` alone on its line[\s\S]*rejected by the Stop guard as malformed/, "blocked protocol format is not byte-exact and enforcement-mirrored");
requireMatch(summaryPhase, /Every `Failed` item is a report of machine output[\s\S]*List only what\s+actually refused the run[\s\S]*Name the required path or the check the renderer's own diagnostic named/, "the Failed list lost its provenance rule");
requireMatch(summaryPhase, /honest\s+blocked protocol clears the same session state[\s\S]*malformed blocked message[\s\S]*next `\/onboard` prompt\s+re-arms the guard and removes them automatically[\s\S]*Never remove them\s+manually/, "blocked-run residue lifecycle is undocumented");

const mutatingPermission = /Bash\((?:git (?:add|commit|push|pull|checkout|switch|reset|clean)|git remote(?::\*| \*)|gh pr create)(?::\*)?\)|\b(?:Write|Edit|mcp__[^,\s]*\*)\b/;
for (const name of ["pr", "validate", "fix", "status", "commit", "ticket", "explore"]) {
  const section = templates.match(new RegExp(`### /${name}\\n([\\s\\S]*?)(?=\\n### /|$)`))?.[1] || "";
  const argumentCount = (section.match(/\$ARGUMENTS/g) || []).length;
  if (argumentCount !== 1) {
    console.error(`FAIL: /${name} template contains ${argumentCount} $ARGUMENTS placeholders`);
    failed = true;
  }
}
for (const [index, line] of templates.split("\n").entries()) {
  if (/^allowed-tools:/.test(line) && mutatingPermission.test(line)) {
    console.error(`FAIL: mutating tool is pre-authorized in artifact template line ${index + 1}`);
    failed = true;
  }
  if (/^tools:/.test(line) && /\w+\([^)]/.test(line)) {
    console.error(`FAIL: agent tools field uses permission patterns at line ${index + 1}`);
    failed = true;
  }
}

let rendered = templates;
for (const [token, value] of Object.entries(manifest.commands)) {
  if (value == null) {
    rendered = rendered.replace(new RegExp(`(?:, )?Bash\\(\\{\\{${token}\\}\\}\\)`, "g"), "");
    rendered = rendered.split("\n").filter((line) => !line.includes(`{{${token}}}`)).join("\n");
  } else rendered = rendered.replaceAll(`{{${token}}}`, value);
}
if (!Array.isArray(manifest.reviewLens) || manifest.reviewLens.length < 2 ||
    manifest.reviewLens.some((line) => !/^- .*Evidence: `[^`]+`\.$/.test(line))) {
  console.error("FAIL: reviewer fixture lacks two well-formed evidence-backed bullets");
  failed = true;
} else {
  rendered = rendered.replaceAll("{{DETECTED_REVIEW_LENS}}", manifest.reviewLens.join("\n"));
}
for (const line of rendered.split("\n").filter((line) => /^allowed-tools:/.test(line))) {
  if (line.includes("{{") || mutatingPermission.test(line)) {
    console.error(`FAIL: rendered default fixture has invalid permissions: ${line}`);
    failed = true;
  }
}

const reviewerTemplate = rendered.match(/### inspector([\s\S]*?)### dispatcher/)?.[1] || "";
const reviewerLens = reviewerTemplate.match(/## Project-specific review lens\s*\n([\s\S]*?)(?:\n## |$)/)?.[1] || "";
const reviewerBullets = reviewerLens.split("\n").filter((line) => /^- .*Evidence: `[^`]+`\.$/.test(line));
if (reviewerBullets.length < 2 || reviewerTemplate.includes("DETECTED_REVIEW_LENS")) {
  console.error("FAIL: rendered reviewer fixture is generic or unresolved");
  failed = true;
}

for (const mode of ["default", "launch-control-maintenance"]) {
  const item = manifest[mode];
  if (!item || !Array.isArray(item.required) || !Array.isArray(item.forbidden)) {
    console.error(`FAIL: manifest lacks a complete ${mode} contract`);
    failed = true;
  }
}
if (!manifest.default.required.includes(".claude/skills/launch/SKILL.md") ||
    !manifest.default.required.includes(".claude/skills/project-code-review/SKILL.md") ||
    !manifest.default.required.includes("artifacts/architecture.md") ||
    !manifest["launch-control-maintenance"].required.includes(".claude/skills/launch/SKILL.md") ||
    !manifest.overlays?.mcp?.required.includes(".mcp.json") ||
    !manifest.overlays?.hooks?.required.includes(".claude/hooks/skill-eval.sh")) {
  console.error("FAIL: default, maintenance, or overlay manifests are incomplete");
  failed = true;
}
if (manifest.default.required.length !== new Set(manifest.default.required).size) {
  console.error("FAIL: default manifest contains duplicate paths");
  failed = true;
}
const reservedProjectSkillNames = new Set(manifest.reservedProjectSkillNames || []);
const generatedProjectSkillNames = manifest.default.required
  .map(item => item.match(/^\.claude\/skills\/([^/]+)\/SKILL\.md$/)?.[1])
  .filter(Boolean);
if (!reservedProjectSkillNames.has("code-review")) {
  console.error("FAIL: manifest does not record the known built-in code-review collision");
  failed = true;
}
for (const name of generatedProjectSkillNames) {
  if (reservedProjectSkillNames.has(name)) {
    console.error(`FAIL: generated project skill uses a reserved or built-in name: ${name}`);
    failed = true;
  }
}

const statusTemplate = templates.match(/### \/status([\s\S]*?)### \/commit/)?.[1] || "";
for (const command of ["git branch --show-current", "git status --short", "git log {{DETECTED_BASE_BRANCH}}..HEAD --oneline", "git diff --stat {{DETECTED_BASE_BRANCH}}", "gh pr status"]) {
  if (!statusTemplate.includes(`\`${command}\``)) {
    console.error(`FAIL: status template is missing explicit command: ${command}`);
    failed = true;
  }
}
if (/\becho\b|\$\(|\|/.test(statusTemplate)) {
  console.error("FAIL: status template uses undeclared shell composition");
  failed = true;
}

const githubWorkflowTemplate = templates.match(/### dispatcher([\s\S]*?)## Commands/)?.[1] || "";
const commitTemplate = templates.match(/### \/commit([\s\S]*?)### \/ticket/)?.[1] || "";
const featureDevelopmentTemplate = templates.match(/### feature-development([\s\S]*?)### systematic-debugging/)?.[1] || "";
for (const [name, source] of [["dispatcher", githubWorkflowTemplate], ["/commit", commitTemplate], ["feature-development", featureDevelopmentTemplate]]) {
  if (!/up to 150 characters/i.test(source) || /under 72 chars/i.test(source)) {
    console.error(`FAIL: ${name} template does not use the 150-character commit limit`);
    failed = true;
  }
}
if (manifest.policies?.commitSubjectMax !== 150 ||
    manifest.policies?.commitSubjectSource !== "default" ||
    manifest.policies?.prTitleMax !== 72) {
  console.error("FAIL: onboarding manifest does not pin 150-character commits and 72-character PR titles");
  failed = true;
}

process.exit(failed ? 1 : 0);
NODE

node - "$ROOT" "$MANIFEST" <<'NODE'
const fs = require("fs");
const os = require("os");
const path = require("path");
const [root, manifestPath] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
const commitSubjectMax = manifest.policies?.commitSubjectMax;
const commitSubjectSource = manifest.policies?.commitSubjectSource;
const prTitleMax = manifest.policies?.prTitleMax;
if (commitSubjectMax !== 150 || commitSubjectSource !== "default" || prTitleMax !== 72) {
  throw new Error("onboarding manifest lacks the expected commit and PR title policies");
}

const conflictingCommitLimit = /(?:commit(?:s| message| subject)?|subject)[^\n]{0,100}(?:under|up to|≤)\s*72|(?:under|up to|≤)\s*72[^\n]{0,100}(?:commit|subject)/i;
const falseHistoryAttribution = /(?:repo convention )?derived from git history/i;
function validateGeneratedCommitPolicy(relative, source) {
  const expected = `up to ${commitSubjectMax} characters`;
  if (!source.toLowerCase().includes(expected) ||
      conflictingCommitLimit.test(source) ||
      (commitSubjectSource === "default" && falseHistoryAttribution.test(source))) {
    throw new Error(`${relative}: generated commit policy must say "${expected}" as a default, without a 72-character limit or history-derived attribution`);
  }
}
function validateGeneratedPrTitlePolicy(relative, source) {
  if (!new RegExp(`under\\s+${prTitleMax}\\s+char`, "i").test(source)) {
    throw new Error(`${relative}: generated PR title policy must remain under ${prTitleMax} characters`);
  }
}

validateGeneratedCommitPolicy("commit-policy-positive", "Commit subject: up to 150 characters.\nPR title: under 72 characters.");
validateGeneratedPrTitlePolicy("pr-policy-positive", "PR title: under 72 characters.");
let rejectedHistoricalLimit = false;
try {
  validateGeneratedCommitPolicy("commit-policy-negative", "Commit subject: under 72 characters.");
} catch (error) {
  rejectedHistoricalLimit = /generated commit policy/.test(error.message);
}
if (!rejectedHistoricalLimit) throw new Error("generated commit policy regression accepted a history-derived 72-character limit");
let rejectedHistoryAttribution = false;
try {
  validateGeneratedCommitPolicy("commit-policy-attribution-negative", "Commit subject: up to 150 characters (derived from git history).");
} catch (error) {
  rejectedHistoryAttribution = /generated commit policy/.test(error.message);
}
if (!rejectedHistoryAttribution) throw new Error("generated commit policy regression accepted false history-derived attribution");
let rejectedWidePrTitle = false;
try {
  validateGeneratedPrTitlePolicy("pr-policy-negative", "PR title: up to 150 characters.");
} catch (error) {
  rejectedWidePrTitle = /generated PR title policy/.test(error.message);
}
if (!rejectedWidePrTitle) throw new Error("generated PR title policy regression accepted a 150-character title limit");

const generatedWorkspacePresent = (candidateRoot) => fs.existsSync(path.join(candidateRoot, ".claude/settings.json"));
function validateGeneratedSkillRename(label, claudeSource, launchSource) {
  for (const [surface, source] of [["CLAUDE.md", claudeSource], ["Launch Project Conventions", launchSource]]) {
    if (source.includes("`code-review`")) {
      throw new Error(`${label}: ${surface} contains stale exact skill name \`code-review\``);
    }
    if (!source.includes("`project-code-review`")) {
      throw new Error(`${label}: ${surface} does not contain \`project-code-review\``);
    }
  }
}
validateGeneratedSkillRename(
  "rename-positive",
  "- `project-code-review` — tailored review",
  "## Project Conventions\n- `project-code-review` — tailored review\n",
);
let rejectedStaleRename = false;
try {
  validateGeneratedSkillRename(
    "rename-negative",
    "- `project-code-review` — tailored review",
    "## Project Conventions\n- `code-review` — stale review\n",
  );
} catch (error) {
  rejectedStaleRename = /stale exact skill name/.test(error.message);
}
if (!rejectedStaleRename) throw new Error("generated guidance regression accepted stale exact `code-review`");

const detectionFixture = fs.mkdtempSync(path.join(os.tmpdir(), "launch-control-validator-detection."));
try {
  fs.writeFileSync(path.join(detectionFixture, "CLAUDE.md"), "# Tracked project guidance\n");
  fs.mkdirSync(path.join(detectionFixture, "artifacts"));
  if (generatedWorkspacePresent(detectionFixture)) {
    throw new Error("tracked fresh-clone files incorrectly activate generated-workspace validation");
  }
  fs.mkdirSync(path.join(detectionFixture, ".claude"));
  fs.writeFileSync(path.join(detectionFixture, ".claude/settings.json"), "{}\n");
  if (!generatedWorkspacePresent(detectionFixture)) {
    throw new Error("generated settings do not activate generated-workspace validation");
  }
} finally {
  fs.rmSync(detectionFixture, {recursive: true, force: true});
}

const generatedPresent = generatedWorkspacePresent(root);

if (generatedPresent) {
  const missing = manifest.default.required.filter((item) => !fs.existsSync(path.join(root, item)));
  const forbidden = manifest.default.forbidden.filter((item) => fs.existsSync(path.join(root, item)));
  if (missing.length || forbidden.length) {
    console.error(`FAIL: generated default workspace mismatch; missing=${missing.join(",") || "none"}; forbidden=${forbidden.join(",") || "none"}`);
    process.exit(1);
  }

  const settings = JSON.parse(fs.readFileSync(path.join(root, ".claude/settings.json"), "utf8"));
  const allow = settings.permissions?.allow || [];
  const deny = settings.permissions?.deny || [];
  for (const forbiddenRule of ["Bash(git remote:*)", "Write", "Edit"]) {
    if (allow.includes(forbiddenRule)) throw new Error(`generated settings contain forbidden allow rule: ${forbiddenRule}`);
  }
  if (!allow.includes("Bash(git remote -v)")) throw new Error("generated settings lack exact read-only git remote permission");
  // Round-37: the full 23-glob list is required of the reference TEMPLATE (the thing onboarding
  // writes) but only the two `.env` spellings are required here, and the asymmetry is deliberate.
  // This block validates a workspace that already exists on disk, which may have been generated by
  // an OLDER Launch Control that put the credential globs in `sandbox.filesystem.denyRead` and left
  // exactly these two on the permissions side. Requiring all 23 here turns every such workspace --
  // including this repository's own, which is how the failure was found -- into a hard validator
  // error for a file the current code never touched. That is a migration break, not a tightening.
  // The boundary is still pinned where it can be: at the template, with mutation coverage.
  for (const required of ["Read(/.env*)", "Read(/**/.env*)"]) {
    if (!deny.includes(required)) throw new Error(`generated settings lack native env deny rule: ${required}`);
  }

  // A project-level sandbox block is what an older Launch Control generated, and onboarding now
  // removes it. Codex Desktop's Claude import turns it into `sandbox_mode` in .codex/config.toml,
  // so a block left here changes both runtimes. A user who wants the sandbox keeps it in
  // .claude/settings.local.json or user settings, which this check never reads.
  if (Object.prototype.hasOwnProperty.call(settings, "sandbox")) {
    throw new Error("generated .claude/settings.json carries a sandbox key; remove it (a user's own sandbox belongs in .claude/settings.local.json)");
  }

  for (const [name, overlay] of Object.entries(manifest.overlays || {})) {
    const trigger = name === "mcp" ? ".mcp.json" : ".claude/hooks";
    if (!fs.existsSync(path.join(root, trigger))) continue;
    const missingOverlay = overlay.required.filter((item) => !fs.existsSync(path.join(root, item)));
    if (missingOverlay.length) throw new Error(`${name} overlay is incomplete: ${missingOverlay.join(",")}`);
  }
  if (fs.existsSync(path.join(root, ".mcp.json"))) {
    JSON.parse(fs.readFileSync(path.join(root, ".mcp.json"), "utf8"));
  }

  const unresolvedPattern = /\{\{(?:DETECTED_[A-Z0-9_]+|[#/](?:if|unless|each)(?:\s+[^}]*)?)\}\}/g;
  const generatedFiles = [];
  function collect(relative) {
    const target = path.join(root, relative);
    if (!fs.existsSync(target)) return;
    if (fs.statSync(target).isFile()) return generatedFiles.push(relative);
    for (const entry of fs.readdirSync(target)) collect(path.join(relative, entry));
  }
  for (const item of ["CLAUDE.md", ".claude", "artifacts"]) collect(item);
  const unresolved = [];
  for (const item of generatedFiles) {
    for (const match of fs.readFileSync(path.join(root, item), "utf8").matchAll(unresolvedPattern)) unresolved.push(`${item}:${match[0]}`);
  }
  if (unresolved.length) throw new Error(`unresolved generated template tokens: ${unresolved.join(",")}`);

  for (const item of [
    "CLAUDE.md",
    ".claude/agents/dispatcher.md",
    ".claude/commands/commit.md",
    ".claude/skills/feature-development/SKILL.md",
    ".claude/skills/launch/SKILL.md",
  ]) {
    validateGeneratedCommitPolicy(item, fs.readFileSync(path.join(root, item), "utf8"));
  }
  for (const item of [
    "CLAUDE.md",
    ".claude/commands/pr.md",
    ".claude/skills/pr-workflow/SKILL.md",
    ".claude/skills/launch/SKILL.md",
  ]) {
    validateGeneratedPrTitlePolicy(item, fs.readFileSync(path.join(root, item), "utf8"));
  }
  validateGeneratedSkillRename(
    "generated-workspace",
    fs.readFileSync(path.join(root, "CLAUDE.md"), "utf8"),
    fs.readFileSync(path.join(root, ".claude/skills/launch/SKILL.md"), "utf8"),
  );

  function validateFrontmatter(relative) {
    const source = fs.readFileSync(path.join(root, relative), "utf8");
    const match = source.match(/^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/);
    if (!match) throw new Error(`${relative}: missing delimited YAML frontmatter`);
    let block = false;
    for (const [index, line] of match[1].split(/\r?\n/).entries()) {
      if (!line.trim() || /^\s*#/.test(line)) continue;
      if (block && /^\s+/.test(line)) continue;
      block = false;
      const field = line.match(/^([A-Za-z][A-Za-z0-9_-]*):(?:\s+(.*))?$/);
      if (!field || !field[2]) throw new Error(`${relative}:${index + 2}: invalid YAML mapping entry`);
      if (/^[>|][+-]?$/.test(field[2])) { block = true; continue; }
      const quoted = /^(?:"(?:[^"\\]|\\.)*"|'[^']*')$/.test(field[2]);
      if (!quoted && /:\s/.test(field[2])) throw new Error(`${relative}:${index + 2}: unquoted colon in YAML scalar`);
    }
  }
  for (const item of generatedFiles.filter((item) =>
    item.endsWith("/SKILL.md") || item.startsWith(".claude/agents/") || item.startsWith(".claude/commands/"))) {
    validateFrontmatter(item);
  }

  const reviewerPath = path.join(root, ".claude/agents/inspector.md");
  const reviewer = fs.readFileSync(reviewerPath, "utf8");
  const reviewerLens = reviewer.match(/## Project-specific review lens\s*\n([\s\S]*?)(?:\n## |$)/)?.[1] || "";
  const reviewerBullets = reviewerLens.split(/\r?\n/).filter((line) => /^- .*Evidence: `[^`]+`\.$/.test(line));
  if (reviewerBullets.length < 2 || reviewer.includes("DETECTED_REVIEW_LENS")) {
    throw new Error("generated code reviewer lacks two evidence-backed project-specific lens bullets");
  }
}
NODE

check_absent 'enableAllProjectMcpServers' "$ROOT/skills/onboard"
check_absent '/mnt/skills' "$ROOT/skills"
check_absent 'name: ckm:' "$ROOT/skills"
check_absent 'Archive\.zip' "$ROOT/README.md" "$ROOT/install.sh" "$ROOT/skills"
check_absent 'HAS_SEMANTIC_SEARCH_MCP' "$ROOT/skills/onboard"
check_absent 'GENERATION_DATE|TEMPLATE_VERSION' "$ROOT/skills/onboard/SKILL.md" "$ROOT/skills/onboard/references/launch-discovery.md"
check_absent 'Claude Project Onboard|claude-project-onboard|crispy-onboard-pack|ClaudeKit|claudekit|Pitcrew' "$ROOT/README.md" "$ROOT/install.sh" "$ROOT/install" "$ROOT/skills" "$ROOT/agents" "$ROOT/CONTRIBUTING.md"
check_absent 'Bash\(git remote:\*\)|Read\(\.env\.\*\)' \
  "$ROOT/skills/onboard/references/configuration-generation.md" "$ROOT/skills/onboard/references/hooks-and-config.md"
# Round-19: the pack used to promise that the safe `.env` examples stayed readable through a
# sandboxed Bash reader. They do not: the generated `Read` denies match those names too and a
# permission deny outranks the sandbox `allowRead`, as a live run proved by having its own
# `cat .env.example` denied. Every retired spelling of that promise stays retired.
# Each alternative is a fragment that fits on ONE line of the retired wording: these pins are
# line-based, so a phrase spanning a wrap would never match.
check_absent 'remain available to sandboxed Bash|Use a sandboxed Bash|reader for those exact safe examples|through sandboxed Bash discovery instead|explicitly rule out the gates' \
  "$ROOT/skills/onboard"
check_absent '~\/\.claude\/\.mcp\.json|settings\.json.*mcpServers|@anthropic\/agent-browser-mcp' \
  "$ROOT/install/mcp.reference.json" "$ROOT/skills/onboard/references/mcp-detection.md"
check_absent 'gh` CLI \(always available\)' "$ROOT/skills/snippets-shared-by-skills/source-fetchers.md"
check_absent '"datadog"[[:space:]]*:[[:space:]]*\{' "$ROOT/skills/onboard/references/mcp-detection.md"
legacy_intake_name='problem-to''-research'
legacy_publish_name='publish-to''-confluence'
repo_files=()
while IFS= read -r -d '' repo_file; do
  [ -f "$ROOT/$repo_file" ] && repo_files+=("$ROOT/$repo_file")
done < <(git -C "$ROOT" ls-files --cached --others --exclude-standard -z)
check_absent "$legacy_intake_name|$legacy_publish_name" "${repo_files[@]}"

run_rg -q '^# Launch Control$' "$ROOT/README.md"
# LC-036: what a person reads says Launch Control, never "Groundwork" or "Send It": every
# shipped skill and agent frontmatter (Claude and Codex), README.md, and installer output.
# LC-047 renamed the paths and identifiers too; the match stays on the capitalized product names.
if ! old_product_names="$(python3 - "$ROOT" <<'PY'
import pathlib, re, sys
root, hits = pathlib.Path(sys.argv[1]), []
old = re.compile(r'Groundwork|Send It')
def scan(path, lines):
    hits.extend('%s:%d: %s' % (path.relative_to(root), n, line.strip()) for n, line in lines if old.search(line))
for path in sorted([*root.glob('skills/*/SKILL.md'), *root.glob('codex/skills/*/SKILL.md'), *root.glob('agents/*.md')]):
    scan(path, enumerate(path.read_text().split('\n---\n', 1)[0].splitlines(), 1))
scan(root / 'README.md', enumerate((root / 'README.md').read_text().splitlines(), 1))
scan(root / 'install.sh', [(n, line) for n, line in enumerate((root / 'install.sh').read_text().splitlines(), 1)
                           if re.match(r'\s*(c_green|c_yellow|c_red|c_blue|echo|printf)\b', line)])
print('\n'.join(hits))
sys.exit(1 if hits else 0)
PY
)"; then
  printf 'FAIL: user-facing text still says Groundwork or Send It (LC-036):\n%s\n' "$old_product_names" >&2
  failures=$((failures + 1))
fi
run_rg -q 'Claude Code-first' "$ROOT/README.md"
run_rg -q 'supports Claude Code and native Codex core skills' "$ROOT/README.md"
run_rg -q 'Do not pre-authorize arbitrary language runtimes or mutating Git/GitHub commands' \
  "$ROOT/skills/onboard/references/configuration-generation.md"
run_rg -q 'in a separate `Untouched pre-existing \(N\)` section, not folded' \
  "$ROOT/skills/onboard/references/completion-report-and-ledgers.md"
run_rg -q 'Do not include `Bash\(git:\*\)`' "$ROOT/skills/onboard/references/hooks-and-config.md"

# The onboarding default manifest is intentionally duplicated across the three onboard
# scripts inside marked blocks; any drift between the copies is a release-blocking bug.
manifest_reference=""
for manifest_script in render-report.sh unattended-policy.sh completion-guard.sh; do
  manifest_block="$(awk '/^# BEGIN ONBOARD_DEFAULT_MANIFEST$/{capture=1;next} /^# END ONBOARD_DEFAULT_MANIFEST$/{capture=0} capture' "$ROOT/skills/onboard/scripts/$manifest_script")"
  if [ -z "$manifest_block" ]; then
    printf 'FAIL: %s lacks the marked ONBOARD_DEFAULT_MANIFEST block\n' "$manifest_script" >&2
    exit 1
  fi
  if [ -z "$manifest_reference" ]; then
    manifest_reference="$manifest_block"
  elif [ "$manifest_block" != "$manifest_reference" ]; then
    printf 'FAIL: ONBOARD_DEFAULT_MANIFEST drift: %s does not match render-report.sh\n' "$manifest_script" >&2
    exit 1
  fi
done
run_rg -q 'git status --short.*inventory committed, staged, unstaged, and untracked work' "$ROOT/skills/onboard/references/artifact-templates.md"
run_rg -q 'git diff HEAD.*staged and unstaged tracked changes' "$ROOT/skills/onboard/references/artifact-templates.md"
run_rg -q 'Bash\(rg:\*\).*Bash\(head:\*\)' "$ROOT/skills/onboard/references/artifact-templates.md"
run_rg -q 'URL-based MCP entry.*remote integration' "$ROOT/skills/docs-create/SKILL.md"
run_rg -q 'command-based MCP entry.*local stdio process' "$ROOT/skills/docs-create/SKILL.md"
run_rg -q 'skills later create `workbench/<TICKET>/<stage>/` artifacts' "$ROOT/skills/docs-create/SKILL.md"
run_rg -q 'reject blanket OAuth/authentication language' "$ROOT/skills/docs-create/SKILL.md"
run_rg -q 'completion guard is declared in `skills/onboard/SKILL.md` frontmatter' "$ROOT/skills/docs-create/SKILL.md"
run_rg -q 'skill-frontmatter lifecycle hook as registered' "$ROOT/skills/docs-create/SKILL.md"
run_rg -q 'each document independently names both MCP transport/auth categories' "$ROOT/skills/docs-create/SKILL.md"
run_rg -q 'documentation omits MCP category fact' "$ROOT/skills/onboard/scripts/render-report.sh"
run_rg -q 'documentation omits workbench path ownership' "$ROOT/skills/onboard/scripts/render-report.sh"
run_rg -q 'documentation omits successful lifecycle disarm' "$ROOT/skills/onboard/scripts/render-report.sh"
run_rg -q 'infrastructure documentation omits arbitrary env protection' "$ROOT/skills/onboard/scripts/render-report.sh"
run_rg -q 'code reviewer needs at least two evidence-backed review lens bullets' "$ROOT/skills/onboard/scripts/render-report.sh"
# F31: `prospective CLAUDE.md marker block is missing` is no longer pinned by grepping the renderer
# source -- 40-report-contract.sh drives the real renderer down the PRESERVED path with the file
# absent, which pins the block and the message together. Pin here only what no fixture can reach:
# Phase 2d, not Phase 3, owes the write. Phase 3's scenarios are all write paths, so an idempotent
# re-run that classifies PRESERVED skipped the write whenever Phase 3 owned it.
run_rg -q 'Persist that assembled block here, in this phase, before Launch renders' \
  "$ROOT/skills/onboard/references/launch-generation.md"
run_rg -q 'the renderer requires the prospective file on the `PRESERVED` path exactly as' \
  "$ROOT/skills/onboard/references/claude-md-and-documentation.md"
run_rg -q '\*\*Phase 2d already wrote it\.\*\*' \
  "$ROOT/skills/onboard/references/claude-md-and-documentation.md"
check_absent 'Build the complete prospective generated marker block before classifying the path' \
  "$ROOT/skills/onboard/references/claude-md-and-documentation.md"
# F30: `/fix` generation was nondeterministic -- three cold runs from identical baselines produced
# Skipped, Created, Skipped, because "detected formatter and linter --fix commands" asks whether the
# linter supports a flag rather than whether the project declared one. Pin the declaredness test and
# the worked negative case, and forbid the judgment wording from coming back.
run_rg -q 'declaredness test, not a judgment' "$ROOT/skills/onboard/references/skills-agents-and-commands.md"
run_rg -q 'Never append `--fix`, `--write`, or any fix flag to a command the project did' \
  "$ROOT/skills/onboard/references/skills-agents-and-commands.md"
run_rg -q 'no fix or format script gets no `/fix`' "$ROOT/skills/onboard/references/artifact-templates.md"
check_absent 'Detected formatter and linter --fix commands' "$ROOT/skills/onboard/references/skills-agents-and-commands.md"
check_absent 'only when a lint-fix or formatter command was actually detected' "$ROOT/skills/onboard/references/artifact-templates.md"
run_rg -q 'model-insert annotations and bullets must be on separate lines' "$ROOT/skills/onboard/scripts/render-report.sh"
run_rg -q 'schema-valid, session-bound Workspace Discovery Report' "$ROOT/skills/onboard/scripts/completion-guard.sh"
run_rg -q 'deletion-dirty required manifest path' "$ROOT/skills/onboard/scripts/completion-guard.sh"
run_rg -q 'launch-control-onboard-run-<session>\.disarmed' "$ROOT/artifacts/architecture.md"
run_rg -q 'later `/onboard` prompt.*re-arms' "$ROOT/artifacts/architecture.md" "$ROOT/artifacts/infrastructure.md"
for protected_variant in .env.qa .env.preview .env.backup; do
  run_rg -Fq "$protected_variant" "$ROOT/artifacts/infrastructure.md"
done
run_rg -Fq 'Read(/.env*)' "$ROOT/artifacts/infrastructure.md"
run_rg -q 'native Read/Glob/Grep' "$ROOT/artifacts/infrastructure.md"
run_rg -q 'claude mcp add --scope user --transport http github' "$ROOT/install.sh"
run_rg -q 'local stdio' "$ROOT/install.sh"
run_rg -q 'do not use remote OAuth' "$ROOT/install.sh"
run_rg -q 'launch-control-backups/<timestamp>' "$ROOT/install.sh" "$ROOT/README.md"
run_rg -q 'backup outside discovery' "$ROOT/install.sh"
run_rg -q 'independently.*blocks any run' "$ROOT/skills/onboard/references/run-authority-and-lifecycle.md"
run_rg -q 'invoked native `Edit` or `Write`' "$ROOT/skills/onboard/references/run-authority-and-lifecycle.md"
run_rg -q 'read-only `--dry-run` creates no guard state' "$ROOT/skills/onboard/references/run-authority-and-lifecycle.md"
run_rg -q 'Bash file mutation to bypass the lifecycle boundary' "$ROOT/skills/onboard/references/run-authority-and-lifecycle.md"
run_rg -q '^name: research-questions$' "$ROOT/skills/research-questions/SKILL.md"
# LC-059: the seven CRISPY skills load guide stars through one shared preamble.
for guide_star_skill in research-questions research-codebase design-doc design-outline plan-write plan-execute review-doc; do
  run_rg -Fq -- '- Read `@snippets-shared-by-skills/guide-stars-preamble.md` and follow it.' \
    "$ROOT/skills/$guide_star_skill/SKILL.md"
done
run_rg -Fq 'guide-stars/*.md' "$ROOT/skills/snippets-shared-by-skills/guide-stars-preamble.md"
check_absent 'foundations-preamble' "$ROOT/skills" "$ROOT/codex" "$ROOT/README.md"
run_rg -q '^name: catalog$' "$ROOT/skills/catalog/SKILL.md"
run_rg -q '^name: log-decision$' "$ROOT/skills/log-decision/SKILL.md"
run_rg -q '^name: logbook$' "$ROOT/skills/logbook/SKILL.md"
run_rg -q '^description: ".*Usage: /logbook \[TICKET \| since YYYY-MM-DD \| last N weeks \| keyword\]"$' "$ROOT/skills/logbook/SKILL.md"
run_rg -q '^argument-hint: "\[TICKET \| since YYYY-MM-DD \| last N weeks \| keyword\]"$' "$ROOT/skills/logbook/SKILL.md"
run_rg -q '^allowed-tools: Read, Glob, Grep$' "$ROOT/skills/logbook/SKILL.md"
run_rg -Fq 'workbench/*/decision/*-DECISION-*.md' "$ROOT/skills/logbook/SKILL.md"
# LC-059: the pack agents ship under their new names, and nothing that ships names the old ones.
for pack_agent in surveyor navigator veteran technician integrator skeptic editor; do
  run_rg -q "^name: $pack_agent\$" "$ROOT/agents/$pack_agent.md"
done
check_absent 'codebase-(locator|analyzer|pattern-finder)|workbench-(locator|analyzer)|(substance|readability)-reviewer' \
  "$ROOT/agents" "$ROOT/skills" "$ROOT/codex" "$ROOT/README.md" "$ROOT/tools/test-install.sh" \
  "$ROOT/tools/validate/15-launch-contract.sh" "$ROOT/tools/fixtures/launch-v2-acceptance-criteria.md" \
  "$ROOT/artifacts" "$ROOT/CONTRIBUTING.md" "$ROOT/CLAUDE.md"
# LC-059: onboarding generates `inspector` and `dispatcher`; the old generated names are gone,
# and the runtime's own errors say "delivery launcher" so they never read as the agent. Only the
# quoted agent name 'dispatcher' may appear in these files, in any case.
check_absent 'code-reviewer|github-workflow' "$ROOT/skills" "$ROOT/codex" "$ROOT/tools/fixtures/onboard-manifests.json" \
  "$ROOT/README.md" "$ROOT/CLAUDE.md" "$ROOT/artifacts"
check_absent "(?i)[^']dispatcher|dispatcher[^']" "$ROOT/skills/onboard/scripts/launch-runtime.py" \
  "$ROOT/skills/onboard/scripts/launch-delivery.py" "$ROOT/skills/onboard/scripts/codex-parity.py"

"$ROOT/tools/test-install.sh" >/dev/null
