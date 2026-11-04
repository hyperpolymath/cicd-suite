#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath)
"""Bounded scanner crash/inventory/report controls; not a precision benchmark.

Usage: scanner-adversarial.py /absolute/pons /absolute/panic-attack
No target project is executed. Seed 1371, 64 parser inputs, 10s per process.
Missing binaries, timeouts, malformed output and failed controls are nonzero.
"""
import copy
import json
from pathlib import Path
import random
import subprocess
import sys
import tempfile
import time


def main(argv):
    if len(argv) != 3 or any(not Path(p).is_file() for p in argv[1:]):
        print('NO CHECK PERFORMED: provide both scanner executables', file=sys.stderr)
        return 2
    pons, panic = map(lambda p: str(Path(p).resolve()), argv[1:])
    rows = []

    def run(label, command, expected, machine=True):
        start = time.monotonic()
        try:
            proc = subprocess.run(command, capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise RuntimeError(f'{label}: unavailable or timed out: {exc}') from exc
        if proc.returncode not in expected:
            raise RuntimeError(f'{label}: exit {proc.returncode}, expected {expected}')
        doc = json.loads(proc.stdout) if machine else None
        if machine and not isinstance(doc, dict):
            raise RuntimeError(f'{label}: report is not an object')
        rows.append({'case': label, 'exit': proc.returncode,
                     'seconds': round(time.monotonic() - start, 6)})
        return doc

    with tempfile.TemporaryDirectory(prefix='scanner-controls-') as tmp:
        root = Path(tmp)
        empty = root / 'empty'; empty.mkdir()
        for name, binary, args in [('pons', pons, ['scan', str(empty), '--format', 'json', '--fail-on-skips']),
                                   ('panic', panic, ['assail', str(empty), '--headless', '--fail-on-incomplete'])]:
            run(name + '-empty-refused', [binary, *args], {2})
        source = root / 'control.py'; source.write_text('def answer():\n    return 42\n')
        valid = run('pons-positive', [pons, 'scan', str(source), '--format', 'json', '--fail-on-skips'], {0})
        report = root / 'report.json'; report.write_text(json.dumps(valid))
        run('valid-report', [pons, 'validate-report', str(report)], {0}, False)
        for field, value in [('schema_version', 'wrong'), ('tool', None), ('execution', False),
                             ('scanned', None), ('findings', 'not-an-array')]:
            mutant = copy.deepcopy(valid); mutant[field] = value
            report.write_text(json.dumps(mutant))
            run('malformed-' + field, [pons, 'validate-report', str(report)], {2}, False)
        rng = random.Random(1371)
        tokens = ['(', ')', '{', '}', 'if', 'return', '$x', '"', '\n', 'λ', '\x00', ';', 'await']
        for i in range(64):
            suffix = '.php' if i % 2 else '.py'
            source = root / ('mutation' + suffix)
            payload = ' '.join(rng.choice(tokens) for _ in range(8 + i * 8))
            source.write_text(('<?php\n' if suffix == '.php' else '') + payload)
            run(f'parser-{i}', [pons, 'scan', str(source), '--format', 'json', '--fail-on-skips'], {0, 1, 2})
        # Record the experiment; an exit 0 here asserts robustness of these
        # bounded samples only, never semantic soundness or corpus completeness.
    print(json.dumps({'seed': 1371, 'timeout_seconds': 10,
                      'claim': 'bounded parser and report/inventory controls only',
                      'cases': rows}, indent=2))
    return 0

if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv))
    except (RuntimeError, ValueError) as exc:
        print(f'FAIL: {exc}', file=sys.stderr)
        sys.exit(1)
