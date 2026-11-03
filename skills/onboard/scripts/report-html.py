#!/usr/bin/env python3
"""Render the onboard completion report as one self-contained HTML page.

The text report stays the record; this page is a view of it. Every fact on the page is parsed
from that text, so the two can never disagree. Usage:

    report-html.py REPORT_TXT OUT_HTML REPO_NAME [--template PATH]   # prints the page's file:// URI
    report-html.py REPORT_TXT - REPO_NAME --json    # the parsed model, for inspection
"""
import argparse
import json
import os
import pathlib
import re
import sys

HEADER = re.compile(r'^(?P<label>[A-Z][^:]*?)(?: \((?P<count>\d+)\))?:$')
DIR_GROUP = re.compile(r'^(?P<dir>.+/) \((?P<n>\d+) paths?\)$')


def parse(text):
    """Split the report into blank-line-separated blocks; each block's first line is its header."""
    lines = text.splitlines()
    if not lines or lines[0] != '=== Workspace Setup Complete ===':
        raise ValueError('not a completion report')
    sections, checks, next_steps = [], [], []
    block = []
    for line in lines[1:] + ['']:
        if line.startswith('=== End Workspace Setup'):
            line = ''
        if line.strip():
            block.append(line)
            continue
        if not block:
            continue
        head, body = block[0], block[1:]
        block = []
        match = HEADER.match(head)
        if not match:
            sections.append({'label': 'Notes', 'count': None, 'items': [], 'groups': [], 'notes': [head] + [b.strip() for b in body]})
            continue
        label = match.group('label')
        if label == 'Checks':
            for entry in body:
                key, _, value = entry.strip().partition(': ')
                checks.append({'key': key, 'value': value})
            continue
        if label == 'Next':
            next_steps = [b.strip() for b in body if b.strip() != 'none']
            continue
        count = int(match.group('count')) if match.group('count') else None
        sections.append(section(label, count, body))
    return {'sections': sections, 'checks': checks, 'next': next_steps}


def section(label, count, body):
    """Items come first; once `count` is reached, any remaining indented lines are notes."""
    items, groups, notes, seen = [], [], [], 0
    for raw in body:
        text = raw.strip()
        depth = len(raw) - len(raw.lstrip(' '))
        if count is None:
            (notes if text.endswith('.') else items).append(text)
            continue
        if seen < count and depth == 2 and text.endswith(':') and label == 'Undeclared gates':
            groups.append({'label': text[:-1], 'items': []})
            continue
        if seen < count and depth == 4 and groups:
            groups[-1]['items'].append(text)
            seen += 1
            continue
        if seen < count and depth == 2:
            folded = DIR_GROUP.match(text)
            items.append({'dir': folded.group('dir'), 'n': int(folded.group('n'))} if folded else text)
            seen += int(folded.group('n')) if folded else 1
            continue
        notes.append(text)
    return {'label': label, 'count': count, 'items': items, 'groups': groups, 'notes': notes}


def embed(model):
    """JSON for an inline <script type=application/json>: nothing in a path can close the tag."""
    data = json.dumps(model, ensure_ascii=False, separators=(',', ':'))
    for char, escaped in (('&', '\\u0026'), ('<', '\\u003c'), ('>', '\\u003e'),
                          ('\u2028', '\\u2028'), ('\u2029', '\\u2029')):
        data = data.replace(char, escaped)
    return data


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('report')
    parser.add_argument('out')
    parser.add_argument('repo')
    parser.add_argument('--template', default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                           '..', 'assets', 'completion-report.html'))
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    with open(args.report, encoding='utf-8') as handle:
        text = handle.read()
    model = parse(text)
    model.update(repo=args.repo, raw=text)
    if args.json:
        json.dump(model, sys.stdout, indent=2, ensure_ascii=False)
        print()
        return
    with open(args.template, encoding='utf-8') as handle:
        template = handle.read()
    if template.count('__REPORT_DATA__') != 1:
        raise ValueError('template must hold exactly one __REPORT_DATA__ placeholder')
    page = template.replace('__REPORT_DATA__', embed(model))
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    partial = args.out + '.partial'
    with open(partial, 'w', encoding='utf-8') as handle:
        handle.write(page)
    os.replace(partial, args.out)
    print(pathlib.Path(os.path.abspath(args.out)).as_uri())


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        print('report-html: ' + str(error), file=sys.stderr)
        sys.exit(1)
