# shellcheck shell=bash
# Launch progressive generation, workspace ownership, pressure-test, and AI-eval contract.
# Sourced by tools/validate-pack.sh after 10-pack-inventory.sh.

launch_refs=(ticket-intake implementation delivery verification)
launch_templates=()
launch_fixtures=()
for launch_ref in "${launch_refs[@]}"; do
  launch_template="$ROOT/skills/onboard/references/launch-$launch_ref-template.md"
  launch_fixture="$ROOT/skills/onboard/references/launch-$launch_ref-fixture-example.md"
  test -f "$launch_template"
  test -f "$launch_fixture"
  launch_templates+=("$launch_template")
  launch_fixtures+=("$launch_fixture")
done

run_rg -q 'git rev-parse --git-dir.*git rev-parse --git-common-dir' \
  "$ROOT/skills/plan-execute/SKILL.md"
run_rg -q 'never switches the primary checkout or creates a branch' \
  "$ROOT/skills/plan-execute/SKILL.md"
if run_rg -q 'git (checkout|switch)' "$ROOT/skills/plan-execute/SKILL.md"; then
  printf '%s\n' 'FAIL: plan-execute still owns branch switching' >&2
  exit 1
fi

run_rg -qi 'paired positive repository evidence' \
  "$ROOT/skills/onboard/references/launch-discovery.md"
run_rg -qi 'dependency name alone never activates' \
  "$ROOT/skills/onboard/references/launch-discovery.md"
run_rg -q 'DETECTED_AI_EVAL_GUIDANCE' \
  "$ROOT/skills/onboard/references/artifact-templates.md" \
  "$ROOT/skills/onboard/references/skills-agents-and-commands.md"
run_rg -qi 'paired positive repository evidence' \
  "$ROOT/skills/onboard/references/context-discovery.md"
run_rg -q 'show-superproject-working-tree' \
  "$ROOT/skills/onboard/references/launch-discovery.md"
check_absent '\.git.*regular file.*submodule' \
  "$ROOT/skills/onboard/references/launch-discovery.md"
run_rg -q '\.claude/skills/launch/references/\*\.md' \
  "$ROOT/skills/onboard/scripts/render-report.sh"

node - "$ROOT/skills/onboard/references/launch-template.md" \
  "$ROOT/skills/onboard/references/launch-fixture-example.md" \
  "$ROOT/tools/fixtures/launch-workspace-states.json" \
  "$ROOT/tools/fixtures/launch-pressure-cases.json" \
  "$ROOT/tools/fixtures/launch-ai-scope-cases.json" \
  "$ROOT/tools/fixtures/launch-platform-routing-cases.json" \
  "$ROOT/tools/fixtures/launch-v2-acceptance-criteria.md" \
  "${launch_templates[@]}" -- "${launch_fixtures[@]}" <<'NODE'
const fs = require("fs");
const crypto = require("crypto");
const args = process.argv.slice(2);
const split = args.indexOf("--");
const [rootPath, rootFixturePath, workspacePath, pressurePath, aiPath, routingPath, v2AcceptancePath, ...templatePaths] = args.slice(0, split);
const fixturePaths = args.slice(split + 1);
const read = file => fs.readFileSync(file, "utf8");
const root = read(rootPath);
const rootFixture = read(rootFixturePath);
const generatedRootFixture = rootFixture.replace(/^<!-- FIXTURE FILE:[\s\S]*?-->\r?\n/, "");
const templates = templatePaths.map(read);
const fixtures = fixturePaths.map(read);
const completeTemplate = [root, ...templates].join("\n");
const completeFixture = [rootFixture, ...fixtures].join("\n");
const fail = message => { throw new Error(message); };
function renderFlags(source, flags) {
  const tag = /\{\{#(if|unless) ([A-Z0-9_]+)\}\}|\{\{\/(if|unless)\}\}/g;
  function renderRange(start, stopKind = null) {
    let output = "", cursor = start, match;
    tag.lastIndex = cursor;
    while ((match = tag.exec(source))) {
      output += source.slice(cursor, match.index);
      if (match[3]) {
        if (match[3] !== stopKind) fail(`mismatched ${match[3]} conditional`);
        return [output, tag.lastIndex];
      }
      const kind = match[1], flag = match[2];
      const [body, after] = renderRange(tag.lastIndex, kind);
      const enabled = Boolean(flags[flag]);
      if ((kind === "if" && enabled) || (kind === "unless" && !enabled)) output += body;
      cursor = after;
      tag.lastIndex = cursor;
    }
    if (stopKind) fail(`unclosed ${stopKind} conditional`);
    return [output + source.slice(cursor), source.length];
  }
  return renderRange(0)[0];
}

const referenceNames = ["ticket-intake", "implementation", "delivery", "verification"];
for (const name of referenceNames) {
  const link = `@references/${name}.md`;
  if (!root.includes(link) || !rootFixture.includes(link)) fail(`Launch root does not route to ${name}.md`);
}
if (templates.some(source => /@references\//.test(source))) fail("Launch references exceed one-hop traversal");
if (fixtures.some(source => /\{\{[^}]+\}\}/.test(source))) fail("Launch fixture references contain unresolved placeholders");

const rootLines = rootFixture.trimEnd().split(/\r?\n/).length;
if (rootLines > 325) fail(`generated Launch root is ${rootLines} lines; maximum is 325`);

const orderedHeadings = [
  "### 4. Pre-delivery verification",
  "### 5. Pre-delivery review",
  "### 6. Deliver",
  "### 7. Post-deploy verification",
];
let cursor = -1;
for (const heading of orderedHeadings) {
  const next = root.indexOf(heading);
  if (next <= cursor) fail(`Launch phase order is missing or wrong at ${heading}`);
  cursor = next;
}

function checklist(source) {
  const items = [];
  let current = "";
  for (const line of source.split(/\r?\n/)) {
    if (line.startsWith("- [ ] ")) {
      if (current) items.push(current);
      current = line.slice(6).trim();
    } else if (current && /^\s{2,}\S/.test(line)) {
      current += ` ${line.trim()}`;
    } else if (current) {
      items.push(current);
      current = "";
    }
  }
  if (current) items.push(current);
  return items;
}

const v2Criteria = checklist(read(v2AcceptancePath));
const v2AcceptanceDigest = crypto.createHash("sha256").update(read(v2AcceptancePath)).digest("hex");
if (v2AcceptanceDigest !== "22bf27118eb41c0cd61f0ea2cd46635f23db5a5fe9325a4b9ae3899957af93f6") {
  fail("pre-split behavior inventory changed");
}
if (v2Criteria.length !== 72) fail(`pre-split behavior inventory changed: ${v2Criteria.length}/72 criteria`);
const hasAll = (source, ...needles) => needles.every(needle => source.includes(needle));
const ticket = templates[0];
const implementation = templates[1];
const delivery = templates[2];
const verification = templates[3];
const generation = read(rootPath.replace(/launch-template\.md$/, "launch-generation.md"));
const parityChecks = [
  // LC-045: the frozen inventory names the old skill; it is generated as `launch` now.
  hasAll(generatedRootFixture, "name: launch"),
  /description:[\s\S]*platform[\s\S]*ticket/i.test(generatedRootFixture),
  generatedRootFixture.includes("# Launch"),
  generatedRootFixture.startsWith("---\n"),
  hasAll(generatedRootFixture, "A repo-local or external ticket exists", "one package", "ticket understanding"),
  /Skip .*one-line edits/i.test(generatedRootFixture),
  ["Type", "Platform", "Complexity", "Uncertainty"].every(axis => root.includes(`| ${axis} |`)),
  hasAll(root, "feature, fix, polish, refactor, chore"),
  hasAll(generatedRootFixture, "mobile-iOS, mobile-Android, web, backend, shared"),
  hasAll(root, "workbench/<TICKET>/plan/<date>-<slug>.md"),
  hasAll(root, "Full CRISPY ladder", "`plan-execute`"),
  ["Polish (clear)", "Fix (clear)", "Fix (fuzzy)", "Feature (small)", "Feature (medium/large)", "Refactor"].every(x => root.includes(x)),
  hasAll(root, "`MUST` is mandatory", "`situational` applies"),
  hasAll(ticket, "User named", "Ticket or branch", "Package path", "Ambiguous"),
  hasAll(ticket, "## Specialist routing", "selected platform row plus the `any` row", "`mobile-iOS`", "`mobile-Android`", "select the `mobile` row", "{{#each AGENTS_BY_PLATFORM_ROW}}", "{{this.platform}}", "{{this.agents}}"),
  ["react-frontend-specialist", "flow-architect", "testing-quality-expert", "workflow-designer", "cms-specialist", "graphql-backend-expert", "nx-monorepo-expert", "compliance-reviewer", "performance-optimizer"].every(x => fixtures[0].includes(x)),
  hasAll(ticket, "{{#if HAS_JIRA_MCP}}", "Atlassian"),
  hasAll(ticket, "{{#if HAS_CONFLUENCE}}", "via the Atlassian MCP, otherwise paste"),
  hasAll(ticket, "{{#if HAS_CHROME_MCP}}", "mcp__chrome__use_browser"),
  hasAll(ticket, "{{#if HAS_CHROME_DEVTOOLS_MCP}}", "mcp__chrome-devtools__*"),
  hasAll(ticket, "{{#if HAS_NOTION_MCP}}", "{{#if HAS_NOTION}}", "paste the Notion body"),
  hasAll(ticket, "episodic-memory", "technician"),
  hasAll(ticket, "{{#if HAS_GITHUB_MCP}}", "mcp__github__*"),
  ["surveyor", "navigator", "veteran", "feature-researcher"].every(x => ticket.includes(x)),
  hasAll(ticket, "{{#if HAS_CODE_SEARCH_MCP}}", "semantic code-search MCP"),
  ticket.includes("superpowers:dispatching-parallel-agents"),
  root.includes("superpowers:brainstorming"),
  hasAll(root, "research-questions` → `research-codebase` → `design-doc` → `design-outline` →", "plan-write"),
  hasAll(root, "At every authored artifact boundary", "run `review-doc`"),
  hasAll(root, "`plan-execute` exactly once", "after plan approval"),
  hasAll(root, "do not also invoke", "superpowers:executing-plans") && !completeTemplate.includes("superpowers:writing-plans"),
  hasAll(ticket, "publish the approved design to Confluence"),
  hasAll(ticket, "superpowers:systematic-debugging"),
  (root.match(/workbench\/<TICKET>\/plan\/<date>-<slug>\.md/g) || []).length === 1,
  hasAll(ticket, "Clear fixes", "concise reviewed dated plan"),
  implementation.includes("{{TYPECHECK_CMD}}"),
  implementation.includes("{{TEST_CMD}}"),
  implementation.includes("{{LINT_CMD}}"),
  implementation.includes("git diff --stat -- {{PACKAGE_DIFF_SCOPE}}"),
  implementation.includes("Specialist delegation"),
  hasAll(implementation, "write the failing test", "superpowers:test-driven-development"),
  /Do not move to the next phase/i.test(implementation),
  hasAll(implementation, "Run the inspector subagent", "Verdict: ship / ship-with-fixes / reroll"),
  hasAll(implementation, "git diff origin/{{BASE_BRANCH}}...HEAD", "git diff --cached", "git diff", "untracked path"),
  hasAll(implementation, "{{#if HAS_SECURITY_REVIEW_COMMAND}}", "/{{SECURITY_REVIEW_COMMAND_NAME}}"),
  implementation.includes("compliance-reviewer"),
  implementation.includes("performance-optimizer"),
  hasAll(delivery, "{{#if HAS_SHIP_COMMAND}}", "/{{SHIP_COMMAND_NAME}}"),
  hasAll(delivery, "explicit action-time authorization", "push", "pull request"),
  hasAll(delivery, "up to 150 characters", "Only an explicit numeric maximum", "Never infer a shorter limit"),
  hasAll(delivery, "PR body", "Background, Changes, and unchecked manual Test Plan items"),
  hasAll(verification, "{{#if PLATFORM_IOS}}", "### iOS"),
  hasAll(verification, "{{#if PLATFORM_ANDROID}}", "### Android"),
  hasAll(verification, "{{#if PLATFORM_WEB}}", "### Web"),
  hasAll(verification, "{{#if PLATFORM_BACKEND}}", "### Backend"),
  hasAll(verification, "{{#if HAS_GROWTHBOOK_MCP}}", "### Feature flags"),
  hasAll(verification, "{{#if HAS_DEPLOY_VERIFY_COMMAND}}", "/{{DEPLOY_VERIFY_COMMAND_NAME}}"),
  !/(staging-gate|eligibility-check)/i.test(completeTemplate),
  hasAll(verification, "| TC | Description | Status |"),
  hasAll(delivery, "gh pr diff", "gh pr checks"),
  /base drift|merge-base drift|rebased comparison/i.test(delivery),
  ticket.includes("## Parallel dispatch patterns"),
  ["Codebase discovery", "Pre-ship review", "Cross-package impact"].every(x => ticket.includes(x)),
  ticket.includes("Rule of thumb"),
  (root.match(/^## Project Conventions$/gm) || []).length === 1,
  hasAll(generation, "source-tagged by default", "--include-global-claude", "never include", "CLAUDE.local.md") && hasAll(root, "{{#each CLAUDE_MD_FILES}}", "### From {{this.source}}"),
  root.includes("{{this.content}}") && hasAll(rootFixture, "## Project Conventions", "### From CLAUDE.md", "focused test command", "Preserve user-owned files"),
  hasAll(delivery, "Destructive actions", "rebased comparison"),
  delivery.includes("MODEL_INSERT: project_specific_gotchas") && ["worktree", "VPN-gated", "Jira 406", "flex layout", "first-frame race", "empty stubs"].every(x => fixtures[2].includes(x)) && (fixtures[2].match(/<!-- inferred from /g) || []).length >= 6,
  (root.match(/^- \[ \]/gm) || []).length === 9,
  (root.match(/^- Do not /gm) || []).length >= 10,
  !completeTemplate.includes("PROJ-671"),
];
if (parityChecks.length !== v2Criteria.length) fail(`parity implementation covers ${parityChecks.length}/72 criteria`);
for (let index = 0; index < parityChecks.length; index += 1) {
  if (!parityChecks[index]) fail(`pre-split behavior ${index + 1} missing: ${v2Criteria[index]}`);
}

// LC-035: guidance must survive ordinary/autonomy and workspace rendering, including
// the retry-with-a-fresh-fixture case. This checks instructions, not model compliance.
function requireGuidance(label, source, phrases) {
  const normalized = source.replace(/\s+/g, " ");
  for (const phrase of phrases) {
    if (!normalized.includes(phrase)) fail(`${label} lacks delivery boundary: ${phrase}`);
  }
}
const boundaryContracts = [
  ["root", root, rootFixture, [
    "one selected backlog ticket", "priority and dependencies", "observable outcome",
    "explicit exclusions", "not select new work or override backlog dependencies",
    "start time, deadline", "investigation, review, validation, delegated children, retries",
    "fresh fixtures and replacement contexts never reset limits",
    "Check remaining budget before each phase or launch",
    "stop new work, safely settle owned processes", "Never weaken acceptance",
    "Reuse authorization within its scope",
  ]],
  ["intake", ticket, fixtures[0], [
    "demonstrate the native/existing capability gap", "observed missing capability",
    "why reuse cannot meet the outcome", "speculative future needs do not justify it",
    "prerequisites in the backlog before implementing them",
    "necessary for the selected outcome", "otherwise defer it",
    "Changed outcome, architecture or budget", "approach/priority reassessment",
    "do not add repeated generic permission prompts",
  ]],
  ["implementation", implementation, fixtures[1], [
    "Before each phase, retry or child/fixture launch", "remaining whole-effort budget",
    "carry consumed budget across fresh fixtures and replacement contexts",
    "Do not implement substantial discovered prerequisites until recorded in the backlog",
    "Changed outcome, architecture or budget triggers approach/priority reassessment",
    "Repeated acceptance failures trigger approach review before another attempt",
    "a fresh fixture is not a budget reset", "stop new work, safely settle owned processes",
    "Review necessity as well as correctness", "avoid unnecessary machinery",
    "Plans and passing checks do not substitute for the promised outcome or priority decisions",
  ]],
];
for (const [label, source, fixture, phrases] of boundaryContracts) {
  requireGuidance(`${label} fixture`, fixture, phrases);
  for (const enabled of [false, true]) {
    requireGuidance(`${label} rendered ${enabled}`, renderFlags(source, {
      AUTONOMY_ENABLED: enabled, WORKTREES_ENABLED: enabled,
    }), phrases);
  }
}
const agentTemplates = read(require("path").join(require("path").dirname(rootPath), "artifact-templates.md"));
const reviewer = agentTemplates.split("### inspector")[1].split("### dispatcher")[0];
requireGuidance("generated reviewer", reviewer, [
  "For Launch delivery reviews", "review necessity as well as correctness",
  "native/existing capability-gap evidence", "unnecessary machinery",
  "prerequisites were recorded in the backlog before implementation",
  "outcome, architecture or budget received approach/priority reassessment",
  "fresh fixtures and replacement contexts without resets",
  "acceptance failures require approach review", "Reuse existing authorization within scope",
  "unrelated reviews need no Launch fields", "## Project-specific review lens",
  "{{DETECTED_REVIEW_LENS}}",
]);

const workspace = JSON.parse(read(workspacePath));
const expectedWorkspace = {
  "clean-primary": "create-linked-worktree",
  "dirty-primary": "create-linked-worktree-preserve-primary",
  "existing-linked-worktree": "stay-in-linked-worktree",
};
for (const item of workspace.cases || []) {
  if (expectedWorkspace[item.name] !== item.action) fail(`unexpected workspace fixture: ${item.name}`);
  if (!completeFixture.includes(item.action)) fail(`workspace action absent from fixture guidance: ${item.action}`);
  delete expectedWorkspace[item.name];
}
if (Object.keys(expectedWorkspace).length) fail(`missing workspace fixtures: ${Object.keys(expectedWorkspace).join(", ")}`);

const pressure = JSON.parse(read(pressurePath));
for (const item of pressure.cases || []) {
  const shouldTrigger = ["fuzzy", "large", "irreversible", "security-sensitive", "explicit-request"].includes(item.signal);
  if (item.trigger !== shouldTrigger) fail(`wrong pressure-test decision for ${item.signal}`);
}
if (!/Ask at most five/.test(completeTemplate) || !/existing design artifact/.test(completeTemplate)) {
  fail("pressure-test gate is unbounded or creates a separate artifact");
}

const ai = JSON.parse(read(aiPath));
for (const item of ai.cases || []) {
  const shouldActivate = ["explicit-config", "paired-repository-evidence"].includes(item.signal);
  if (item.activate !== shouldActivate) fail(`wrong AI-evaluation decision for ${item.signal}`);
}
for (const phrase of [
  "versioned model, prompt, and configuration",
  "representative evaluation cases",
  "negative and abuse cases",
  "latency and cost",
  "human owner",
  "deterministic policy and tool-authorization tests",
  "probabilistic output scoring",
]) {
  if (!completeTemplate.includes(phrase)) fail(`AI evaluation contract missing: ${phrase}`);
}
if (!/generic dependency name alone/.test(completeTemplate)) fail("AI scope can activate from a dependency name alone");

const routing = JSON.parse(read(routingPath));
const headingFor = selected => ({
  "mobile-iOS": "iOS",
  "mobile-Android": "Android",
  web: "Web",
  backend: "Backend",
  shared: "Shared",
  general: "General or unknown",
})[selected];
if (!/selected Platform subsection/i.test(root) || !/Do not\s+read the file wholesale/i.test(root) || !/unrelated platform subsections/i.test(root) || !/cross-cutting capability sections/i.test(root) || !/Feature flags/i.test(root) || !/AI\s+evaluation contract/i.test(root)) {
  fail("Launch root does not constrain verification to the ticket-selected platform");
}
if (!hasAll(verification, "required by the changed package or ticket", "selected platform and relevant capability sections", "Do not use this common block to widen execution") || /Run every runnable repository gate and user-observable local or staging check/.test(verification)) {
  fail("common verification guidance can widen execution to unrelated platforms");
}
const expectedSelections = new Set(["mobile-iOS", "mobile-Android", "web", "backend", "shared", "general"]);
const platformHeadings = ["iOS", "Android", "Web", "Backend", "Shared", "General or unknown"];
function section(source, heading) {
  const marker = source.includes(`### ${heading}`) ? `### ${heading}` : `## ${heading}`;
  const start = source.indexOf(marker);
  if (start < 0) fail(`verification lacks selected platform section: ${heading}`);
  const tail = source.slice(start + marker.length);
  const next = tail.search(/\n(?:###|##) /);
  return marker + (next < 0 ? tail : tail.slice(0, next));
}
for (const item of routing.cases || []) {
  const selected = headingFor(item.selected);
  const routed = [selected, ...(item.selected === "shared" ? item.affectedConsumers || [] : []), ...(item.capabilities || [])];
  if (!selected || JSON.stringify(item.run) !== JSON.stringify(routed)) {
    fail(`invalid platform routing fixture: ${item.selected}`);
  }
  const expectedRejects = platformHeadings.filter(heading => !routed.includes(heading));
  if (JSON.stringify(item.reject) !== JSON.stringify(expectedRejects)) {
    fail(`incomplete unrelated-platform rejects: ${item.selected}`);
  }
  expectedSelections.delete(item.selected);
  const selectedGuidance = routed.map(heading => section(verification, heading)).join("\n");
  if (item.selected === "shared" && !(item.affectedConsumers || []).length) {
    fail("shared platform routing lacks affected consumers");
  }
  for (const rejected of item.reject) {
    section(verification, rejected);
    if (routed.includes(rejected) || selectedGuidance.includes(`### ${rejected}`)) {
      fail(`unrelated platform route is not rejected: ${item.selected} -> ${rejected}`);
    }
  }
}
if (expectedSelections.size) fail(`missing platform routing fixtures: ${[...expectedSelections].join(", ")}`);
if (!implementation.includes("Each implementation phase is one reviewable commit after its focused checks pass")) {
  fail("implementation lost per-phase green commits");
}
if (/before\s+any commit/i.test(root) || /Before any commit/i.test(templates[2])) {
  fail("pre-delivery ordering incorrectly blocks per-phase commits");
}
const worktreesOn = renderFlags(implementation, {WORKTREES_ENABLED: true});
const worktreesOff = renderFlags(implementation, {WORKTREES_ENABLED: false});
if (!worktreesOn.includes("create-linked-worktree") || worktreesOn.includes("branch-in-place")) {
  fail("worktree-enabled rendering is incorrect");
}
if (!worktreesOff.includes("branch-in-place") ||
    !worktreesOff.includes("stay-current-directory-non-git") ||
    worktreesOff.includes("create-linked-worktree")) {
  fail("worktree-disabled rendering lacks its git and non-git fallbacks");
}

const aiOn = renderFlags(verification, {AI_EVAL_ENABLED: true});
const aiOff = renderFlags(verification, {AI_EVAL_ENABLED: false});
if (!aiOn.includes("## AI evaluation contract") || aiOff.includes("## AI evaluation contract")) {
  fail("AI evaluation conditional rendering is incorrect");
}

const chrome = renderFlags(verification, {PLATFORM_WEB: true, HAS_CHROME_MCP: true});
const devtools = renderFlags(verification, {PLATFORM_WEB: true, HAS_CHROME_DEVTOOLS_MCP: true});
if (!chrome.includes("mcp__chrome__use_browser") || chrome.includes("mcp__chrome-devtools__*")) {
  fail("Chrome verification crosses tool namespaces");
}
if (!devtools.includes("mcp__chrome-devtools__*") || devtools.includes("mcp__chrome__use_browser")) {
  fail("Chrome DevTools verification crosses tool namespaces");
}
// LC-057: a web project with no browser MCP still gets a named driver order,
// and the project's own browser tests come first.
const webSection = text => text.slice(text.indexOf("### Web")).split(/\n### /)[0];
const webPlain = webSection(renderFlags(verification, {PLATFORM_WEB: true}));
const ownTests = webPlain.indexOf("project's own browser tests");
const anyTool = webPlain.indexOf("any available browser automation tool");
if (ownTests < 0 || anyTool < ownTests || !/mocking the session and network/.test(webPlain) ||
    !/names which driver ran/.test(webPlain) || /mcp__/.test(webPlain)) {
  fail("web verification without a browser MCP lacks the driver order");
}
const playwrightMcp = webSection(renderFlags(verification, {PLATFORM_WEB: true, HAS_PLAYWRIGHT_MCP: true}));
for (const [flag, line] of [
  ["HAS_CHROME_MCP", "mcp__chrome__use_browser"],
  ["HAS_CHROME_DEVTOOLS_MCP", "mcp__chrome-devtools__*"],
  ["HAS_PLAYWRIGHT_MCP", "mcp__playwright__*"],
]) {
  const rendered = webSection(renderFlags(verification, {PLATFORM_WEB: true, [flag]: true}));
  const at = rendered.indexOf(line);
  if (at < 0 || at < rendered.indexOf("project's own browser tests") ||
      at > rendered.indexOf("any available browser automation tool")) {
    fail(`web verification misplaces ${line} under ${flag}`);
  }
}
if (playwrightMcp.includes("mcp__chrome")) fail("Playwright MCP verification crosses tool namespaces");

const backend = renderFlags(verification, {
  PLATFORM_BACKEND: true,
  HAS_CODE_SEARCH_MCP: true,
  HAS_DATADOG_MCP: true,
  HAS_SENTRY_MCP: true,
});
for (const capability of ["semantic code-search MCP", "mcp__datadog__*", "mcp__sentry__*"]) {
  if (!backend.includes(capability)) fail(`backend verification omits ${capability}`);
}

const security = renderFlags(implementation, {
  HAS_SECURITY_REVIEW_COMMAND: true,
  HAS_COMPLIANCE_AGENT: true,
  HAS_PERFORMANCE_AGENT: true,
});
for (const capability of [
  "SECURITY_REVIEW_COMMAND_NAME",
  "compliance-reviewer",
  "performance-optimizer",
]) {
  if (!security.includes(capability)) fail(`implementation review omits ${capability}`);
}
NODE

# Shared admission must preserve task identity and durable queue limits.
python3 "$ROOT/tools/test-launch-queue.py"
python3 "$ROOT/tools/test-launch-target.py"
python3 "$ROOT/tools/test-launch-mission.py"
python3 "$ROOT/tools/test-launch-stage.py"
