# Hooks and Configuration Reference

## Feature gate

The base `settings.json` permissions structure is used by every normal
onboarding. Hook material in this reference is separate and MUST be used only when the
user passed `--enable-hooks`.

Plan hook content with configuration, but install and register it only as onboarding's
final project-content write after CLAUDE.md, Launch, and documentation are complete.
Once registered, perform no more Edit or Write tool calls in the project.

Without `--enable-hooks`:

- do not add a `hooks` key;
- do not create `.claude/hooks/` scripts;
- preserve any hooks already present in an existing settings file without changing them.

## Hook Command Path Rules — ALWAYS read before generating any hook

Every hook entry you write into `settings.json` MUST use an absolute
path for its `command` field. Claude Code does not guarantee that the
hook process is launched from the project root, so relative paths
resolve against an arbitrary CWD and fail with
`No such file or directory`. Hook failure silently breaks the user's
prompt context for the entire session.

**The ONLY acceptable shape** for shell-script hooks:

```json
{
  "type": "command",
  "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/<script>.sh\""
}
```

`$CLAUDE_PROJECT_DIR` is the canonical absolute project root that
Claude Code injects into every hook process. Use it. NEVER hardcode
`/Users/<name>/path/...` — that path is brittle across machines and
clones.

**Forbidden forms** — these all silently fail and must NEVER appear in
generated settings.json:

| Form | Example |
|---|---|
| Bare relative path (no shell prefix) | `.claude/hooks/x.sh` |
| `bash` + relative path | `bash .claude/hooks/x.sh` |
| `sh` + relative path | `sh .claude/hooks/x.sh` |
| Dot-slash relative | `./scripts/x.sh` or `bash ./scripts/x.sh` |
| Hardcoded user-home absolute | `/Users/jane/proj/.claude/hooks/x.sh` |

This rule applies to **every hook event** — `UserPromptSubmit`,
`SessionStart`, `PreToolUse`, `PostToolUse`, `Stop`, `Notification` —
without exception. If you generate ANY hook entry in `settings.json`,
re-read this section before writing the command field.

Inline `bash -c '...'` hooks (no script file involved) are exempt —
the existing templates in this file already use that pattern for
git/branch commands and need no change.

## settings.json Structure

Base structure for every normal onboarding:

```json
{
  "permissions": {
    "allow": ["<generated from detected stack>"],
    "deny": [
      "Bash(rm -rf /)",
      "Bash(rm -rf /*)",
      "Bash(sudo:*)",
      "Bash(chmod 777:*)",
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
      "Read(./**/credentials*.enc)"
    ]
  }
}
```

Never write a `sandbox` key into the project `.claude/settings.json`, and remove one that
is already there: earlier Launch Control versions generated it. A project-level sandbox silently
changes how every later Claude Code session in the repository runs, and Codex Desktop's
Claude import copies it into `.codex/config.toml` as `sandbox_mode`, overriding the user's
Codex setting. A user who wants Claude Code's Bash sandbox sets it in
`.claude/settings.local.json` or their user settings; onboarding never changes those.

Emit the `credentials` deny globs exactly as listed above in `permissions.deny`. They target
credential *data*: the extensionless `credentials` file, `.credentials*` dotfiles, and
`credentials*` files carrying a credential-data suffix (`.json`, `.yaml`, `.yml`,
`.toml`, `.ini`, `.cfg`, `.conf`, `.env`, `.txt`, `.pem`, `.key`, `.p12`, `.pfx`,
`.jks`, `.keystore`, `.db`, `.sqlite`, `.enc`). Never emit a bare `credentials*` glob:
it also matches source files such as `api/routers/credentials.py`, and blocking those
hides the user's own code from every later session and breaks onboarding's own
verification reads. Source extensions (`.py`, `.ts`, `.tsx`, `.js`, `.jsx`, `.mjs`,
`.cjs`, `.go`, `.rb`, `.java`, `.rs`, `.php`, `.cs`, `.kt`, `.swift`, `.c`, `.h`,
`.cpp`, `.hpp`, `.sh`, `.bash`, `.sql`, `.md`) stay readable. The `./secrets/**` and
`.env*` rules are unchanged.

Keep the `permissions.deny` array in this one-element-per-line form: it is stable
under default 80-column Prettier and Biome settings. When the repository has a formatter
config that uses tabs (e.g. Biome's default `indentStyle`), generate the whole file with
that indent character so the formatter gate passes on first write. Preserve unrelated
existing JSON layout, but format every newly generated JSON fragment to the repository
formatter before the terminal render.

Only with `--enable-hooks`, merge this additional `hooks` object into the base
structure:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "bash -c 'BRANCH=$(git branch --show-current 2>/dev/null); [ \"$BRANCH\" != \"{{BASE_BRANCH}}\" ] && exit 0; echo \"Cannot edit files on {{BASE_BRANCH}} branch. Create a feature branch first.\" >&2; exit 2'",
            "timeout": 5
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "startup|resume",
        "hooks": [
          {
            "type": "command",
            "command": "bash -c 'BRANCH=$(git branch --show-current 2>/dev/null || echo \"detached\"); TICKET=$(echo \"$BRANCH\" | grep -oE \"[A-Z]+-[0-9]+\" | head -1); CHANGES=$(git status --porcelain 2>/dev/null | wc -l | tr -d \" \"); echo \"Current branch: $BRANCH. Ticket: ${TICKET:-None}. Uncommitted changes: $CHANGES files.\"'",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

## Permission Generation by Stack

Allow only exact detected project commands. Do not grant raw interpreter wildcards:
`node:*`, `python:*`, `python3:*`, `ruby:*`, and similar entries permit arbitrary code
execution and bypass command-specific deny rules. Package-manager commands should be
limited to the detected scripts/checks instead of the entire executable namespace.

Use `Bash(<exact command>)` for a fully specified validation command. The `:*` suffix is
reserved for a deliberately variable argument tail after a safe declared prefix. Thus
`./install.sh --dry-run` renders as `Bash(./install.sh --dry-run)`, never
`Bash(./install.sh --dry-run:*)`. Include only commands in the declared validation
contract; tool installation, file type, or config presence alone is not evidence.

### Node.js (yarn/pnpm/npm)
Allow the exact detected `test`, `lint`, `typecheck`, `build`, and formatter commands.
Do not allow `node:*`, `npx:*`, package-manager install commands, or an unrestricted
package-manager wildcard.

### Python (pip/poetry/uv)
Allow exact detected `pytest`, `ruff`, `black`, `mypy`, or project task commands. Do
not allow raw Python interpreters or package installation commands.

### Rust (cargo)
Allow exact detected `cargo test`, `cargo clippy`, `cargo fmt`, and build commands.

### Go
Allow exact detected test, build, format, and lint commands.

### JVM — Gradle
Allow exact detected wrapper tasks. Do not allow raw JVM/compiler wildcards.

### JVM — Maven
Allow exact detected wrapper goals. Do not allow raw JVM/compiler wildcards.

### Ruby
Allow exact detected Bundler, Rake, Rails, or RSpec project commands. Do not allow
the raw Ruby interpreter.

### Swift/iOS
Allow exact detected SwiftPM or Xcode build/test commands.

### Always included
```
Bash(git status:*), Bash(git diff:*), Bash(git log:*), Bash(git show:*)
Bash(git branch --show-current), Bash(git rev-parse:*), Bash(git remote -v)
Bash(gh pr view:*), Bash(gh pr list:*), Bash(gh pr status:*)
Bash(gh issue view:*), Bash(gh issue list:*), Bash(gh auth status:*)
Bash(ls:*), Bash(cat:*), Bash(head:*), Bash(tail:*), Bash(wc:*), Bash(pwd)
Bash(rg:*)
Read, Glob, Grep, WebFetch, Task
```

Do not include `Bash(git:*)`, `Bash(gh:*)`, `Bash(mkdir:*)`, raw interpreter
wildcards, install commands, shell-command wildcards, `Write`, or `Edit` in generated
settings. Mutating tools keep their normal confirmation boundary.

The project-root `Read(/.env*)` and `Read(/**/.env*)` denies protect Claude's built-in
file tools for arbitrary root and nested variants such as `.env.qa`, `.env.preview`, and
`.env.backup`. A single leading `/` anchors at the settings source, so inside a project
`.claude/settings.json` these mean `<project root>/.env*` and `<project root>/**/.env*`,
never the filesystem root. They also cover a Bash reader such as `cat`, `head`, `tail`,
`grep`, or `rg` whenever Claude Code can resolve the path argument, so the deny is not
limited to the built-in file tools. These denies also match the safe example names
(`.env.example`, `.env.sample`, `.env.template`, `.env.local.example`), so those files
become unreadable to Claude — native Read/Glob/Grep and Bash readers alike — once the
settings land. Onboarding must therefore read the safe examples during Phase 0 discovery,
before Phase 1a writes the boundary.

The boundary constrains the Claude Code session, not the project: child processes a
command spawns are outside the permission layer, and the application still loads `.env`
at runtime exactly as before.

### Monorepo additions
```
Bash(nx:*), Bash(turbo:*), Bash(lerna:*)
```

## Merge Strategy for Existing settings.json

When settings.json already exists:

1. Read existing file with `jq` or parse JSON.
2. For `permissions.allow`: union existing + new (no duplicates, never remove).
3. For `permissions.deny`: union existing + new (never remove).
4. Remove any top-level `sandbox` key and say so in the run's report. Never add one. If
   this run cannot modify the file (a dirty-baseline path that must stay PRESERVED), leave
   it unchanged and list the removal as a next step. Never touch a `sandbox` key in
   `.claude/settings.local.json` or user settings.
5. Unless running with `--enable-hooks`, preserve `hooks` byte-for-byte and do not add any.
6. With `--enable-hooks`: add missing hook matchers only — if `PreToolUse` with
   `Edit|Write` already exists, skip.
7. Preserve all other keys untouched.

## skill-eval.sh Hook

Generate at `.claude/hooks/skill-eval.sh`:

```bash
#!/bin/bash
# Skill Evaluation Hook — suggests relevant skills based on prompt keywords
# Runs on UserPromptSubmit

set -e

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""' 2>/dev/null || echo "")
[ -z "$PROMPT" ] && exit 0

PROMPT_LOWER=$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]')
SUGGESTED=""

# Testing
echo "$PROMPT_LOWER" | grep -qE '\b(test|spec|tdd|mock|coverage)\b' && SUGGESTED="$SUGGESTED testing-patterns"

# PR/Git
echo "$PROMPT_LOWER" | grep -qE '\b(pr|pull request|commit|push|merge|branch)\b' && SUGGESTED="$SUGGESTED pr-workflow"

# Code review
echo "$PROMPT_LOWER" | grep -qE '\b(review|check|audit|quality)\b' && SUGGESTED="$SUGGESTED project-code-review"

# Debug
echo "$PROMPT_LOWER" | grep -qE '\b(debug|fix|error|bug|issue|broken)\b' && SUGGESTED="$SUGGESTED systematic-debugging"

# Feature development
echo "$PROMPT_LOWER" | grep -qE '\b(implement|build|create|add|feature|new)\b' && SUGGESTED="$SUGGESTED feature-development"

if [ -n "$SUGGESTED" ]; then
    SKILLS_LIST=$(echo "$SUGGESTED" | xargs | tr ' ' ', ')
    echo "Suggested skills: $SKILLS_LIST"
fi

exit 0
```

Make executable: `chmod +x .claude/hooks/skill-eval.sh`

**Important:** Only create this hook if `.claude/hooks/skill-eval.sh` does not already exist. If a similar hook exists with different name, skip — user may have their own keyword matching.

**Hook command path — ALWAYS absolute, never relative.** If you register this script as a hook in `settings.json` (under `hooks.UserPromptSubmit`), the `command` field MUST use an absolute path. Claude Code resolves relative paths from the process's working directory at hook-fire time, which is NOT guaranteed to be the project root — when CWD diverges, the hook fails with `No such file or directory` and the user's prompt context is silently broken.

Use one of these absolute forms:

```json
"command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/skill-eval.sh\""
```

`$CLAUDE_PROJECT_DIR` is the canonical absolute project root injected by Claude Code into every hook process. Prefer it over hardcoding `/Users/<name>/path/to/project/` — that path is brittle across boxes and clones.

NEVER write `bash .claude/hooks/skill-eval.sh` — that's relative and silently fails. NEVER write `./. claude/hooks/skill-eval.sh` — same defect class.
