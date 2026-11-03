#!/usr/bin/env python3
"""One command: stage, confirm once, deliver every eligible task; or resume the mission in progress.

`mission/` beside project.json is the one mission root for that config. A resumable mission there
(active, paused, error, publication_pending) is resumed with `run`: never restaged, limits never
reset. A complete one is reported; merged_source_pending and blocked are refused with what to do.
Otherwise the stage is built (or an unconfirmed one for the same config reused), the dry-run summary
is printed, and the operator confirms once: at the prompt, or with --approve <mission digest> when
no terminal is attached. --stage stops after the summary and prints the digest to approve; it never
starts or resumes a mission. Spec section 4
of the LC-030 backlog-target spec (the maintainers' private design record).
"""
import argparse
import fcntl
import importlib.util
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location('launch_stage', HERE / 'launch-stage.py')
stage = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(stage)
mission, rt, require = stage.mission, stage.rt, stage.require


# error: a killed child; publication_pending: a PR that may still merge. run() reconciles the reserved task.
RESUMABLE = ('active', 'paused', 'error', 'publication_pending')


def go(config_path, github=None, reader=None, approve=None, ask=input, say=print, stage_only=False):
    config_path = Path(config_path).resolve()
    root, planned = config_path.parent / 'mission', config_path.parent / 'stage/mission.json'
    current = mission.Mission(root, reader=reader)
    if current.state_path.exists():
        require(not stage_only, 'a mission already exists here; check its status, or go to resume it')
        state = rt.read_json(current.state_path)
        reason = ': ' + state['reason'] if state.get('reason') else ''
        if state['outcome'] == 'complete':
            return state
        require(state['outcome'] != 'merged_source_pending', 'a task merged with its Done write unconfirmed%s; confirm the merge, '
                'mark its source row Done by hand if it is not, then move %s and stage/ aside; while the row is '
                'still Todo a new mission would deliver it again' % (reason, root))
        require(state['outcome'] in RESUMABLE, 'mission ended %s%s; inspect it, then remove mission/ and stage/ to start another'
                % (state['outcome'], reason))
        with (root / 'mission.lock').open('a') as lock:  # A live run holds it: never lift a pause under it.
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise rt.Invalid('mission already running') from error
            current.resume()  # The operator asked to go: lift a pause; exhausted limits still stop the run.
        # ponytail: lock released before run() retakes it; a run started in that gap makes run() refuse, pause already lifted.
        return run(current)
    if not planned.exists():
        stage.stage(config_path, github or stage.gh_api)
    require(rt.read_json(planned.parent / 'project.json') == rt.read_json(config_path),
            'project.json changed since staging; remove stage/ to restage')
    digest = rt.digest(planned.read_bytes())
    say(json.dumps(current.init(planned, digest, dry_run=True), indent=2, sort_keys=True))
    if stage_only:
        return {'outcome': 'staged', 'digest': digest}
    if approve is None:
        require(sys.stdin.isatty(), 'confirmation required: rerun with --approve ' + digest)
        approve = digest if ask('Deliver these tasks (mission %s)? [y/N] ' % digest[:12]).strip().lower() == 'y' else ''
    require(approve == digest, 'not approved: mission %s was not confirmed' % digest)
    mission.Mission(root, reader=reader).init(planned, digest)
    return run(mission.Mission(root, reader=reader))


def run(current):
    try:
        return current.run()
    except mission.StopMission as stopped:
        return stopped.state


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True, help='operator project.json')
    parser.add_argument('--approve', help='mission digest the operator confirmed (no terminal)')
    parser.add_argument('--stage', action='store_true', help='stage and print the digest; never start or resume')
    args = parser.parse_args()
    try:
        result = go(args.config, approve=args.approve, stage_only=args.stage)
    except Exception as error:  # Recorded in the mission state when it got that far; report, never a traceback.
        print(json.dumps({'error': str(error) if isinstance(error, rt.Invalid) else '%s: %s' % (type(error).__name__, error)}), file=sys.stderr)
        return 2
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result.get('outcome') in ('complete', 'staged') else 1


if __name__ == '__main__':
    sys.exit(main())
