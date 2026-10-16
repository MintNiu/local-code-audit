#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 - "$repo_root" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

source = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='synthetic-output-isolation-') as temporary:
    work = Path(temporary).resolve()
    fixture_repo = work / 'fixture-repo'
    evals = fixture_repo / 'evals'
    (evals / 'fixtures').mkdir(parents=True)
    for name in ('run-synthetic.sh', 'finding-signature.sh'):
        shutil.copy2(source / 'evals' / name, evals / name)
    for name in ('java-safe', 'java-xxe-safe', 'java-presigned-replay'):
        fixture = evals / 'fixtures' / name
        fixture.mkdir()
        (fixture / 'Notes.txt').write_text('neutral fixture\n')
    preflight = evals / 'test-preflight.sh'
    preflight.write_text('#!' + sys.executable + '\n' + r'''
import json, os, sys
from pathlib import Path
case = Path(os.environ['SYNTHETIC_TEST_CASE'])
reports = Path(os.environ['LOCAL_REVIEW_REPORT_DIR'])
assert reports.resolve() == reports and reports.is_absolute()
assert reports != case / 'inherited-reports'
assert reports.stat().st_mode & 0o777 == 0o700
(reports / 'preflight-only').write_text('fake preflight output')
(case / 'preflight.json').write_text(json.dumps({'reports': str(reports)}))
sys.exit(7 if os.environ['SYNTHETIC_TEST_MODE'] == 'preflight-failure' else 0)
''')
    preflight.chmod(0o700)
    reviewer = work / 'review-stub'
    reviewer.write_text('#!' + sys.executable + '\n' + r'''
import os, sys
from pathlib import Path
case = Path(os.environ['SYNTHETIC_TEST_CASE'])
mode = os.environ['SYNTHETIC_TEST_MODE']
reports = Path(os.environ['LOCAL_REVIEW_REPORT_DIR'])
assert reports == case / 'inherited-reports', 'model stage lost explicit persistent destination'
(reports / 'model-stage').write_text('model-stage placeholder, not real inference')
stdout = '未发现阻塞问题\n'
if mode == 'positive':
    stdout = 'P1 src/Example.java:1 - 预签名票据可重放\n影响：重复使用票据。\n修复建议：原子消费。\n验证方式：并发消费。\n'
elif mode == 'bad-stdout':
    stdout = 'P2 src/Example.java:1 - unexpected finding\n'
elif mode == 'failure':
    stdout = 'PARTIAL_STDOUT_DO_NOT_LOSE\n'
stderr = ('完整脱敏 final 候选报告：/private/example/report.jsonl\n'
          'P0 src/Example.java:99 - STDERR_ONLY_CANDIDATE\n'
          '未发现阻塞问题\nFIRST_DIAGNOSTIC\n' + 'detail\n' * 300 + 'LAST_DIAGNOSTIC\n')
(case / 'expected.stderr').write_text(stderr)
sys.stdout.write(stdout)
sys.stderr.write(stderr)
sys.exit(7 if mode in ('failure', 'truncated', 'not-truncated') else 0)
''')
    reviewer.chmod(0o700)
    fake_bin = work / 'bin'
    fake_bin.mkdir()
    for tool in ('curl', 'ollama'):
        sentinel = fake_bin / tool
        sentinel.write_text('#!/bin/sh\ntouch "$SYNTHETIC_TEST_CASE/unexpected-network"\nexit 97\n')
        sentinel.chmod(0o700)

    def environment(case, mode, selected, keep):
        for name in ('home', 'tmp', 'inherited-reports'):
            (case / name).mkdir(mode=0o700)
        (case / 'inherited-reports' / 'sentinel').write_text('untouched\n')
        return {'HOME': str(case / 'home'), 'XDG_DATA_HOME': str(case / 'home/data'),
                'XDG_CONFIG_HOME': str(case / 'home/config'), 'PYTHONDONTWRITEBYTECODE': '1',
                'PATH': str(fake_bin) + ':/usr/bin:/bin:/usr/sbin:/sbin', 'TMPDIR': str(case / 'tmp'),
                'LANG': 'en_US.UTF-8', 'LC_ALL': 'en_US.UTF-8',
                'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_NOSYSTEM': '1',
                'SYNTHETIC_TEST_CASE': str(case), 'SYNTHETIC_TEST_MODE': mode,
                'SYNTHETIC_ONLY_CASE': selected, 'SYNTHETIC_REVIEW_RUNS': '2',
                'SYNTHETIC_KEEP_RESULTS': str(keep), 'SYNTHETIC_REVIEW_SCRIPT': str(reviewer),
                'LOCAL_REVIEW_REPORT_DIR': str(case / 'inherited-reports')}

    count = 0
    for name, mode, selected, keep, expected_exit in (
            ('clean', 'clean', 'java-safe', 1, 0),
            ('security-clean', 'clean', 'java-xxe-safe', 1, 0),
            ('positive', 'positive', 'java-presigned-replay', 1, 0),
            ('failure', 'failure', 'java-safe', 0, 1),
            ('bad-stdout', 'bad-stdout', 'java-safe', 0, 1),
            ('success-cleanup', 'clean', 'java-safe', 0, 0),
            ('preflight-failure', 'preflight-failure', 'java-safe', 0, 1)):
        case = work / name
        case.mkdir()
        env = environment(case, mode, selected, keep)
        result = subprocess.run(['bash', str(evals / 'run-synthetic.sh')], env=env,
                                text=True, capture_output=True, timeout=30)
        assert result.returncode == expected_exit, (name, result.stdout, result.stderr)
        assert not (case / 'unexpected-network').exists()
        assert (case / 'inherited-reports' / 'sentinel').read_text() == 'untouched\n'
        assert not (case / 'inherited-reports' / 'preflight-only').exists()
        preflight_path = Path(json.loads((case / 'preflight.json').read_text())['reports'])
        assert not preflight_path.exists(), 'fake preflight reports survived cleanup'
        assert not (case / 'home/.local/share/local-review/reports').exists()
        if mode == 'preflight-failure':
            assert not (case / 'inherited-reports' / 'model-stage').exists()
            count += 1
            continue
        assert (case / 'inherited-reports' / 'model-stage').exists()
        expected_stderr = (case / 'expected.stderr').read_text()
        assert expected_stderr in result.stderr, name + ': diagnostic/fallback text was truncated'
        roots = list((case / 'tmp').glob('local-review-synthetic-results.*'))
        if keep or expected_exit:
            assert len(roots) == 1 and str(roots[0]) in result.stderr, name + ': results path vanished'
            outputs = sorted((roots[0] / selected).glob('run-*.txt'))
            assert outputs
            for output in outputs:
                assert 'STDERR_ONLY_CANDIDATE' not in output.read_text()
                stderr_log = output.with_suffix('.stderr.log')
                assert stderr_log.read_text() == expected_stderr
                assert str(stderr_log) in result.stderr
            if mode == 'clean':
                signatures = [subprocess.check_output(['bash', str(evals / 'finding-signature.sh'), str(p)], env=env)
                              for p in outputs]
                assert signatures == [b'clean\n', b'clean\n'], signatures
                assert (roots[0] / selected / 'baseline.sha256').read_text().strip() == hashlib.sha256(b'clean\n').hexdigest()
            if mode == 'positive':
                assert all('P1 src/Example.java:1' in p.read_text() for p in outputs)
                assert 'P0 src/Example.java:99' not in result.stdout
            if expected_exit:
                assert 'synthetic failed results kept:' in result.stderr
        else:
            assert not roots, 'successful default cleanup changed'
        count += 1

    # Exercise the exact production truncation tail with a stub, without
    # running the full model corpus. Nonzero alone must still be rejected.
    script = (evals / 'run-synthetic.sh').read_text()
    diagnostics = re.search(r'^emit_synthetic_diagnostics\(\) \{\n.*?^\}', script, re.M | re.S).group(0)
    tail = script[script.index('truncation_output="$output_root/truncation.txt"'):]
    truncation_stub = work / 'truncation-stub'
    truncation_stub.write_text('#!/bin/sh\nprintf "safe stdout\\n"\n'
                              'if [ "$SYNTHETIC_TEST_MODE" = truncated ]; then printf "发生截断\\n" >&2; '
                              'else printf "unrelated failure\\n" >&2; fi\nexit 7\n')
    truncation_stub.chmod(0o700)
    for mode, expected_exit in (('truncated', 0), ('not-truncated', 1)):
        case = work / mode
        case.mkdir()
        env = environment(case, mode, '', 0)
        env.update({'output_root': str(case), 'fixture_root': str(case), 'review_script': str(truncation_stub),
                    'model': 'fake-only', 'timeout_seconds': '30', 'runs': '1'})
        result = subprocess.run(['bash', '-c', 'set -euo pipefail\n' + diagnostics + '\n' + tail],
                                env=env, text=True, capture_output=True, timeout=10)
        assert result.returncode == expected_exit, (mode, result.stdout, result.stderr)
        assert (case / 'truncation.txt').read_text() == 'safe stdout\n'
        assert (case / 'truncation.stderr.log').read_text() in result.stderr
        count += 1
    print('synthetic output isolation regression: PASS (%d cases; no real model/network)' % count)
PY
