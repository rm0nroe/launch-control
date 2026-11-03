#!/usr/bin/env python3
"""Run with python3 tools/validate-codex-parity.py (no model calls)."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import sys
sys.dont_write_bytecode = True
import tomllib
os.environ.setdefault('LAUNCH_CONTROL_NO_OPEN', '1')  # never open the report page from a test run

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / 'skills/onboard/scripts/codex-parity.py'
spec = importlib.util.spec_from_file_location('parity', SCRIPT)
parity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parity)
mapping = json.loads((SCRIPT.parent.parent / 'references/codex-model-tiers.json').read_text())


def run(*args, ok=True, env=None):
    result = subprocess.run(['python3', str(SCRIPT), *map(str, args)], capture_output=True, text=True, env=env)
    assert (result.returncode == 0) == ok, result.stdout + result.stderr
    return result


def put(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


with tempfile.TemporaryDirectory(prefix='lc020-') as scratch:
    root = Path(scratch).resolve()
    project = root / 'project'
    project.mkdir()
    assert run('--project', project).stdout == ''
    assert not (project / '.codex').exists()
    source = project / '.claude'
    put(source / 'agents/inspector.md', '---\nname: inspector\ndescription: Review café 中文\nmodel: sonnet\ntools: Read, Grep\n---\nKeep “quotes” and emoji 🐈.\n')
    put(source / 'skills/testing-patterns/SKILL.md', '---\nname: testing-patterns\ndescription: >\n  Use this skill\n  for checking.\nallowed-tools: Read\n---\nRead .claude/agents/inspector.md and .claude/skills/testing-patterns/references/check.md.\n')
    put(source / 'skills/testing-patterns/references/check.md', 'Check café.\n')
    put(source / 'commands/status.md', '---\ndescription: Read status\nallowed-tools: Bash(git status:*)\n---\nRun git status.\n')
    # Claude Code commands may omit frontmatter (target repo D's do); the first line is the description.
    put(source / 'commands/pr.md', 'Run local validation, then open a PR.\n\nSteps:\n\n1. `git status`\n')
    run('--project', project, '--codex', '--dry-run')
    assert not (project / '.codex').exists()
    legacy_locale = dict(os.environ, LC_ALL='C', PYTHONUTF8='0', PYTHONCOERCECLOCALE='0')
    run('--project', project, '--codex', env=legacy_locale)
    target = project / '.codex'
    assert not (target / 'config.toml').exists(), 'onboarding created project config.toml'
    agent = tomllib.loads((target / 'agents/inspector.toml').read_text())
    assert agent['model'] == mapping['tiers']['sonnet']['model']
    assert agent['sandbox_mode'] == 'read-only'
    # LC-059: the generated dispatcher keeps its write sandbox; a read-only twin does not.
    shell_only = '---\nname: {}\ndescription: X\nmodel: sonnet\ntools: Bash\n---\nX\n'
    assert 'sandbox_mode' not in tomllib.loads(parity.agent_text(shell_only.format('dispatcher'), mapping))
    assert tomllib.loads(parity.agent_text(shell_only.format('inspector'), mapping))['sandbox_mode'] == 'read-only'
    assert '中文' in agent['description'] and '🐈' in agent['developer_instructions']
    assert '.codex/agents/inspector.toml' in (target / 'skills/testing-patterns/SKILL.md').read_text()
    assert (target / 'skills/status/SKILL.md').is_file()
    pr_skill = (target / 'skills/pr/SKILL.md').read_text()
    assert 'description: "Run local validation, then open a PR."' in pr_skill
    assert '1. `git status`' in pr_skill
    # Old rendered projects receive all three portable checkpoint workflows.
    for name in ('checkpoint-save', 'checkpoint-load', 'checkpoint-list'):
        text = (target / 'skills' / name / 'SKILL.md').read_text()
        assert '<project-root>/.claude_states/' in text
        assert 'legacy' in text.lower()
        assert 'git rev-parse --show-toplevel' in text
    assert 'In Codex, remind me to run `/clear`' not in (target / 'skills/checkpoint-save/SKILL.md').read_text()
    assert not (project / '.claude_states').exists()  # created only when saving
    # A project-authored checkpoint remains authoritative on rerun.
    (target / 'skills/checkpoint-save/SKILL.md').write_text('custom checkpoint workflow\n')
    before = {p.relative_to(target): p.read_bytes() for p in target.rglob('*') if p.is_file()}
    run('--project', project)
    assert before == {p.relative_to(target): p.read_bytes() for p in target.rglob('*') if p.is_file()}
    # A preserved skill must not receive references from a newer source version.
    put(source / 'skills/testing-patterns/references/new.md', 'new version')
    run('--project', project)
    assert not (target / 'skills/testing-patterns/references/new.md').exists()
    # Validate all candidates before any write, including unmapped tiers and placeholders.
    put(source / 'agents/dispatcher.md', '---\nname: dispatcher\ndescription: X\nmodel: future\ntools: Read\n---\nX\n')
    failure = run('--project', project, ok=False)
    assert 'unmapped model tier' in failure.stderr
    assert not (target / 'agents/dispatcher.toml').exists()
    (source / 'agents/dispatcher.md').unlink()
    put(source / 'skills/pr-workflow/SKILL.md', '---\nname: pr-workflow\ndescription: bad\n---\n{{DETECTED_TEST_CMD}}\n')
    assert 'unresolved template token' in run('--project', project, ok=False).stderr
    assert not (target / 'skills/pr-workflow').exists()
    (source / 'skills/pr-workflow/SKILL.md').unlink()
    # Existing project config is preserved without requiring local agent defaults.
    config = target / 'config.toml'
    config.write_text('# user config\nmodel = "custom"\n')
    run('--project', project)
    assert config.read_text() == '# user config\nmodel = "custom"\n'
    config.unlink()
    run('--project', project)
    assert not config.exists()
    external = root / 'external'
    external.mkdir()
    (target / 'skills/feature-development').symlink_to(external, target_is_directory=True)
    put(source / 'skills/feature-development/SKILL.md', '---\nname: feature-development\ndescription: linked\n---\nX')
    assert 'symlink' in run('--project', project, ok=False).stderr
    assert list(external.iterdir()) == []
    # The shipped five-file Launch fixture remains complete after native conversion.
    staging = root / 'staged'
    refs = ROOT / 'skills/onboard/references'
    fixture = (refs / 'launch-fixture-example.md').read_text().split('\n', 1)[1]
    put(staging / 'skills/launch/SKILL.md', fixture)
    for part in ('ticket-intake', 'implementation', 'delivery', 'verification'):
        put(staging / ('skills/launch/references/' + part + '.md'),
            (refs / ('launch-' + part + '-fixture-example.md')).read_text())
    clean_project = root / 'native-project'
    clean_project.mkdir()
    # LC-045: maintenance publishes `launch` and parks the old generated `send-it` copy.
    put(clean_project / '.codex/skills/send-it/SKILL.md', '---\nname: send-it\ndescription: old\n---\nX')
    assert 'RETIRE ' in run('--project', clean_project, '--source', staging, '--codex', '--launch-control').stdout
    assert not (clean_project / '.codex/skills/send-it').exists()
    assert not (clean_project / '.codex/config.toml').exists()
    native_launch = clean_project / '.codex/skills/launch'
    assert len(list(native_launch.rglob('*.md'))) == 5
    assert '.claude/agents/' not in (native_launch / 'references/ticket-intake.md').read_text()
    assert 'plan-execute' in ''.join(p.read_text() for p in native_launch.rglob('*.md'))
    # A Codex-only project has no .claude/: a bare rerun names --source, a staged one is a no-op.
    codex_only = root / 'codex-only'
    codex_only.mkdir()
    run('--project', codex_only, '--source', staging, '--codex')
    before = {p.relative_to(codex_only): p.read_bytes() for p in codex_only.rglob('*') if p.is_file()}
    missing = run('--project', codex_only, ok=False).stderr
    assert 'rendered source directory is missing' in missing and '--source' in missing
    run('--project', codex_only, '--source', staging)
    assert before == {p.relative_to(codex_only): p.read_bytes() for p in codex_only.rglob('*') if p.is_file()}
    assert not (codex_only / '.claude').exists()
    # LC-061: Codex reads AGENTS.md, not CLAUDE.md. The finalizer mirrors only the verified
    # generated block, converted for Codex; user prose around it is never touched.
    agents_project = root / 'agents-md'
    put(agents_project / '.claude/commands/status.md', '---\ndescription: Read status\n---\nRun git status.\n')
    put(agents_project / 'CLAUDE.md', '# Proj\n\nUser prose.\n\n## Generated Quick Reference\n\nUse Claude Code skills in .claude/skills/x.\n')
    subprocess.run(['git', 'init', '-q', str(agents_project)], check=True)
    agents_md = agents_project / 'AGENTS.md'
    # Paths convert; product names in the project's own description stay true (LC-061 acceptance:
    # 'a Claude Code-first kit' must not become 'a Codex-first kit').
    block = '## Generated Quick Reference\n\nUse Claude Code skills in .codex/skills/x.\n'
    out = run('--project', agents_project, '--codex', '--dry-run').stdout
    assert 'PLANNED ' + str(agents_md) in out and not agents_md.exists()
    out = run('--project', agents_project, '--codex').stdout
    assert agents_md.read_text() == block and 'CREATED ' + str(agents_md) in out
    assert 'PRESERVED ' + str(agents_md) in run('--project', agents_project).stdout
    assert agents_md.read_text() == block
    put(agents_md, '# Mine\n\nKeep me.\n\n## Generated Quick Reference\n\nold rows\n\n# Tail\n\nKeep tail.\n')
    assert 'MERGED ' + str(agents_md) in run('--project', agents_project).stdout
    assert agents_md.read_text() == '# Mine\n\nKeep me.\n\n' + block + '\n# Tail\n\nKeep tail.\n'
    put(agents_md, '# Mine\n')
    run('--project', agents_project)
    assert agents_md.read_text() == '# Mine\n\n' + block
    put(agents_md, '# Mine\n\n<!-- BEGIN GENERATED SECTION -- onboard -->\nlegacy\n<!-- END GENERATED SECTION -- onboard -->\n')
    run('--project', agents_project)
    assert agents_md.read_text() == '# Mine\n\n' + block
    subprocess.run(['git', '-C', str(agents_project), 'add', 'AGENTS.md'], check=True)
    subprocess.run(['git', '-C', str(agents_project), '-c', 'user.name=v', '-c', 'user.email=v@example.com',
                    'commit', '-qm', 'agents'], check=True)
    put(agents_md, '# Mine\n\nuncommitted edit\n')
    assert 'KEPT ' + str(agents_md) + ': uncommitted' in run('--project', agents_project).stdout
    assert agents_md.read_text() == '# Mine\n\nuncommitted edit\n'
    subprocess.run(['git', '-C', str(agents_project), 'rm', '-q', '--cached', 'AGENTS.md'], check=True)
    subprocess.run(['git', '-C', str(agents_project), '-c', 'user.name=v', '-c', 'user.email=v@example.com',
                    'commit', '-qm', 'untrack'], check=True)
    agents_md.write_bytes(b'# Mine\r\n\r\n## Generated Quick Reference\r\n\r\nold\r\n')
    assert 'KEPT ' + str(agents_md) + ': CRLF' in run('--project', agents_project).stdout
    assert agents_md.read_bytes() == b'# Mine\r\n\r\n## Generated Quick Reference\r\n\r\nold\r\n'
    agents_md.unlink()
    put(root / 'agents-target.md', 'linked\n')
    agents_md.symlink_to(root / 'agents-target.md')
    assert 'KEPT ' + str(agents_md) + ': not a regular file' in run('--project', agents_project).stdout
    assert (root / 'agents-target.md').read_text() == 'linked\n'
    agents_md.unlink()
    put(agents_project / 'CLAUDE.md', '# Proj\n\nNo generated block.\n')
    run('--project', agents_project)
    assert not agents_md.exists()
    # A Codex-only onboard stages its guidance beside the rendered tree; the project's own block wins.
    staged = root / 'agents-stage'
    put(staged / '.claude/commands/status.md', '---\ndescription: Read status\n---\nRun git status.\n')
    put(staged / 'CLAUDE.md', '## Generated Quick Reference\n\nStaged .claude/skills/y.\n')
    assert 'CREATED ' + str(agents_md) in run('--project', agents_project, '--source', staged / '.claude', '--codex').stdout
    assert agents_md.read_text() == '## Generated Quick Reference\n\nStaged .codex/skills/y.\n'
    put(agents_project / 'CLAUDE.md', '## Generated Quick Reference\n\nProject .claude/skills/z.\n')
    run('--project', agents_project, '--source', staged / '.claude', '--codex')
    assert agents_md.read_text() == '## Generated Quick Reference\n\nProject .codex/skills/z.\n'
    # Install uses pack agent definitions, preserves user roots, and makes no Claude changes.
    install_target = root / 'codex-home'
    run('--install', ROOT, '--target', install_target, '--dry-run')
    assert not install_target.exists()
    run('--install', ROOT, '--target', install_target, env=legacy_locale)
    native = (install_target / 'skills/onboard/SKILL.md').read_text()
    assert 'hooks:' not in native and 'Onboard for Codex' in native
    # The shared Launch template resolves BACKEND_LOCAL_URL from `.env.example`; "do not read
    # secrets" alone left a Codex run free to skip the secret-free examples.
    assert 'The safe examples `.env.example`, `.env.sample`, `.env.template`, and `.env.local.example` are not secrets' in ' '.join(native.split())
    assert len(list((install_target / 'agents').glob('*.toml'))) == len(list((ROOT / 'agents').glob('*.md')))
    for path in (install_target / 'agents').glob('*.toml'):
        data = tomllib.loads(path.read_text())
        assert data['model'] and data['model_reasoning_effort'] and data['sandbox_mode'] == 'read-only'
    result = subprocess.run([str(ROOT / 'install.sh'), '--codex', '--dry-run'],
                            env=dict(os.environ, CODEX_HOME=str(install_target)), capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert 'PRESERVED' in result.stdout and 'Superpowers' not in result.stdout
    # Exercise the real Claude finalizer for automatic and explicit Codex opt-in.
    for explicit in (False, True):
        fixture = root / ('renderer-' + str(explicit))
        fixture.mkdir()
        subprocess.run(['git', 'init', '-q', '-b', 'main', str(fixture)], check=True)
        put(fixture / 'noop.sh', '#!/usr/bin/env bash\nexit 0\n')
        (fixture / 'noop.sh').chmod(0o755)
        put(fixture / '.claude/settings.json', '{"permissions":{"allow":["Bash(./noop.sh)"]}}')
        old_load = (ROOT / 'tools/fixtures/project-skills/load-v1.md').read_text()
        put(fixture / '.claude/skills/load/SKILL.md', old_load)
        subprocess.run(['git', '-C', str(fixture), 'add', 'noop.sh', '.claude/settings.json', '.claude/skills/load/SKILL.md'], check=True)
        subprocess.run(['git', '-C', str(fixture), '-c', 'user.name=validator', '-c',
                        'user.email=validator@example.com', 'commit', '-qm', 'fixture'], check=True)
        state = fixture / '.launch-control-onboard'
        put(state / 'ledger.tsv', 'PRESERVED\t.claude/settings.json\nPRESERVED\t.claude/skills/load/SKILL.md\n')
        put(state / 'baseline.txt', '')
        put(state / 'validation.txt', './noop.sh\n')
        if explicit:
            put(state / 'codex-requested', 'requested\n')
        else:
            (fixture / '.codex').mkdir()
        report = subprocess.run([str(SCRIPT.parent / 'render-report.sh'), str(state / 'ledger.tsv'),
                                 'main', 'valid', 'absent', 'ready', str(state / 'validation.txt'),
                                 'none', 'complete'], cwd=fixture, capture_output=True, text=True,
                                env=dict(os.environ, ONBOARD_BASELINE_PATHS_FILE=str(state / 'baseline.txt')))
        assert report.returncode == 0, report.stderr
        assert 'Codex artifacts:' in report.stdout and 'project config unchanged' in report.stdout
        assert not (fixture / '.codex/config.toml').exists()
        assert 'set_thread_title' in (fixture / '.claude/skills/checkpoint-load/SKILL.md').read_text()
        # LC-044: the report names repository paths relative, like every other section.
        assert 'RETIRE .claude/skills/load (now checkpoint-load)' in report.stdout, report.stdout
        # The Visual report link is a file:// URI into the git dir, absolute by necessity.
        paths_text = '\n'.join(line for line in report.stdout.splitlines() if not line.startswith('Visual report: '))
        assert str(fixture.resolve()) + '/' not in paths_text and str(fixture) + '/' not in paths_text
        assert not (fixture / '.claude/skills/load').exists()
print('Codex parity checks passed: opt-in, native conversion, tiers, preservation, failure preflight, symlinks, installer.')
