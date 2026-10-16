#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 - "$repo_root" <<'PY'
import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
core = root / 'bin/local-review.sh'
helper = root / 'bin/native-output-report.py'
temporary = tempfile.TemporaryDirectory(prefix='local-review-visibility-')
work = Path(temporary.name).resolve()
fake = work / 'bin'
fake.mkdir(mode=0o700)
private_marker = 'SYNTHETIC_NONFINAL_FIELD'
secret = 'DummyPass12345678'
fake_source = r'''
import json, os, runpy, sys
from pathlib import Path
case = Path(os.environ['VIS_CASE'])
args = sys.argv[1:]
if Path(sys.argv[0]).name == 'python3':
    if os.environ['VIS_MODE'] == 'flush-failure' and len(args) > 1 and args[0].endswith('/native-output-report.py') and args[1] == 'append':
        def fail_flush(descriptor):
            raise OSError('controlled report flush failure')
        os.fsync = fail_flush
        sys.argv = args
        runpy.run_path(args[0], run_name='__main__')
    os.execv(sys.executable, [sys.executable] + args)
if Path(sys.argv[0]).name == 'ollama':
    if args != ['show', 'visibility-fake']:
        (case / 'unexpected-network').touch()
        sys.exit(97)
    sys.exit(0)
urls = [arg for arg in args if arg.startswith(('http://', 'https://'))]
if urls != ['http://127.0.0.1:11434/api/generate'] or '--data-binary' not in args:
    (case / 'unexpected-network').touch()
    sys.exit(97)
request = json.loads(Path(args[args.index('--data-binary') + 1][1:]).read_bytes())
assert request['model'] == 'visibility-fake'
ledger = case / 'emitted.jsonl'
ordinal = len(ledger.read_text().splitlines()) + 1 if ledger.exists() else 1
mode = os.environ['VIS_MODE']
filtered = ('信息 src/CaseA.js:1 - CANDIDATE_' + str(ordinal) + ' 缺少日志\n'
            '证据：函数没有日志。\n影响：排查调用需要额外信息。\n修复建议：补日志。\n验证方式：观察调用。')
retained = ('P2 src/CaseA.js:1 - RETAINED_' + str(ordinal) + ' 返回值不符\n'
            '证据：函数返回常量。\n影响：返回不同结果。\n修复建议：核对固定值。\n验证方式：断言返回值。')
final, done, reason, status = filtered, True, 'stop', 0
if mode == 'mixed': final += '\n\n' + retained
if mode == 'specialist' and ordinal == 1: final = '未发现阻塞问题'
if mode == 'retry':
    if ordinal == 1: final, status = retained, 28
    else: final = '未发现阻塞问题'
if mode == 'nonzero': final, status = retained, 28
if mode == 'length': final, reason = retained, 'length'
if mode == 'done-false': final, done = retained, False
if mode == 'unsupported': final, reason = retained, 'SYNTHETIC_NONFINAL_FIELD'
if mode == 'empty': final = ''
if mode == 'invalid-format': final += '\n\nP2 src/CaseA.js:1 - INVALID_FORMAT'
if mode == 'secret-controls':
    final = filtered + '\n\n' + filtered + '\n证据：password=DummyPass12345678\n\x1b[31mTAIL\x1b[0m\x00\n\n'
if mode == 'large-fallback': final = (filtered + '\n证据：ALL_FINAL_TEXT_END\n\n') * 40
if mode == 'append-failure' and ordinal == 2:
    for report in (case / 'reports').glob('review-*/*.jsonl'): report.chmod(0o400)
payload = {'response': final, 'done': done, 'done_reason': reason,
           'thinking': 'SYNTHETIC_NONFINAL_FIELD', 'error': 'password=DummyPass12345678'}
with ledger.open('a') as out:
    out.write(json.dumps({'final': final, 'curl_status': status, 'done': done,
                          'reason': reason, 'shard': '当前审查分片' in request['prompt']}) + '\n')
if mode == 'invalid-json':
    print('{"thinking":"SYNTHETIC_NONFINAL_FIELD","error":"password=DummyPass12345678"')
elif mode == 'wrong-type':
    payload['response'] = {'thinking': 'SYNTHETIC_NONFINAL_FIELD'}
    print(json.dumps(payload))
else: print(json.dumps(payload))
sys.exit(status)
'''
for name in ('curl', 'ollama', 'python3'):
    path = fake / name
    path.write_text('#!' + sys.executable + '\n' + fake_source)
    path.chmod(0o700)
rg = shutil.which('rg')
assert rg, 'rg is required to run the existing core'
(fake / 'rg').symlink_to(Path(rg).resolve())
scenarios = ['initial', 'personal', 'mixed', 'sharded', 'specialist', 'retry', 'nonzero',
             'length', 'done-false', 'unsupported', 'empty', 'invalid-json', 'wrong-type',
             'invalid-format', 'secret-controls', 'directory-file', 'symlink-dir',
             'symlink-ancestor', 'public-mode', 'relative-dir', 'control-dir',
             'append-failure', 'flush-failure', 'large-fallback', 'path-spaces', 'default-home']


def require(condition, message, case):
    if not condition:
        stderr = (case / 'stderr').read_text() if (case / 'stderr').exists() else ''
        raise AssertionError(message + '\n' + stderr)


def run_case(name):
    case = work / name
    case.mkdir(mode=0o700)
    home, tmp, repo = [case / part for part in ('home', 'tmp', 'repo')]
    for path in (home, tmp, repo, repo / 'src'): path.mkdir(mode=0o700)
    report_dir = case / ('reports with spaces' if name == 'path-spaces' else 'reports')
    env = {'HOME': str(home), 'XDG_DATA_HOME': str(home / 'data'), 'XDG_CONFIG_HOME': str(home / 'config'),
           'LOCAL_REVIEW_DATA_DIR': str(home / 'data/local-review'), 'LOCAL_REVIEW_EXAMPLES_FILE': '/dev/null',
           'PATH': str(fake) + ':/usr/bin:/bin:/usr/sbin:/sbin', 'TMPDIR': str(tmp),
           'LANG': 'en_US.UTF-8', 'LC_ALL': 'en_US.UTF-8', 'PYTHONDONTWRITEBYTECODE': '1',
           'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_TERMINAL_PROMPT': '0',
           'OLLAMA_HOST': 'http://127.0.0.1:11434', 'OLLAMA_REVIEW_MODEL': 'visibility-fake',
           'OLLAMA_REVIEW_LOCK_DIR': str(tmp / 'model-lock'), 'OLLAMA_REVIEW_RETRY_ATTEMPTS': '1' if name == 'retry' else '0',
           'OLLAMA_REVIEW_MAX_DIFF_BYTES': '1000' if name == 'sharded' else '60000',
           'OLLAMA_REVIEW_NUM_CTX': '16384', 'OLLAMA_REVIEW_NUM_PREDICT': '4096',
           'OLLAMA_REVIEW_CHUNK_NUM_PREDICT': '4096', 'OLLAMA_REVIEW_TIMEOUT_SECONDS': '60',
           'OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS': '60', 'OLLAMA_REVIEW_CHUNK_TIMEOUT_SECONDS': '30',
           'VIS_CASE': str(case), 'VIS_MODE': name}
    if name in ('specialist', 'append-failure'):
        env['OLLAMA_REVIEW_SPECIALIST_CHANNEL'] = 'external-io'
    fallback = name in ('directory-file', 'symlink-dir', 'symlink-ancestor', 'public-mode',
                        'relative-dir', 'control-dir', 'append-failure', 'flush-failure', 'large-fallback')
    if name in ('directory-file', 'large-fallback'): report_dir.write_text('untouched')
    elif name in ('symlink-dir', 'symlink-ancestor'):
        target = case / 'untouched'
        target.mkdir(mode=0o700)
        report_dir.symlink_to(target, target_is_directory=True)
        if name == 'symlink-ancestor': report_dir = report_dir / 'child'
    elif name == 'public-mode':
        report_dir.mkdir(mode=0o755)
        report_dir.chmod(0o755)
    elif name == 'relative-dir': report_dir = Path('not-an-absolute-directory')
    elif name == 'control-dir': report_dir = case / 'reports\nunsafe'
    if name != 'default-home': env['LOCAL_REVIEW_REPORT_DIR'] = str(report_dir)
    else: report_dir = home / '.local/share/local-review/reports'
    for command in (['git', '-C', str(repo), 'init', '-q'],
                    ['git', '-C', str(repo), '-c', 'user.name=test', '-c', 'user.email=test@example.invalid',
                     '-c', 'core.hooksPath=/dev/null', 'commit', '--allow-empty', '-qm', 'base']):
        subprocess.run(command, env=env, check=True, capture_output=True)
    for letter in 'ABC':
        (repo / 'src' / ('Case' + letter + '.js')).write_text('export const value = 2;\n' +
                            '// neutral padding abcdefghijklmnopqrstuvwxyz\n' * 10)
    command = ['bash', str(root / 'bin/local-review-local.sh' if name == 'personal' else core), '--repo', str(repo)]
    if name == 'path-spaces':
        # CLI override takes precedence over an invalid environment destination.
        env['LOCAL_REVIEW_REPORT_DIR'] = 'invalid-relative-path'
        command += ['--report-dir', str(report_dir)]
    result = subprocess.run(command, env=env, cwd=repo, capture_output=True, timeout=75)
    (case / 'stderr').write_bytes(result.stderr)
    stdout, stderr = result.stdout.decode(), result.stderr.decode()
    emitted = [json.loads(line) for line in (case / 'emitted.jsonl').read_text().splitlines()]
    failed = name in ('nonzero', 'length', 'done-false', 'unsupported', 'empty', 'invalid-json', 'wrong-type', 'invalid-format')
    require(result.returncode == (1 if failed else 0), name + ': return code changed', case)
    if not failed and name not in ('mixed', 'secret-controls'):
        require(stdout.strip() == '未发现阻塞问题', name + ': stdout gate changed', case)
    if name != 'secret-controls':
        require('缺少日志' not in stdout, name + ': filtered candidate entered final stdout', case)
    require(private_marker not in stdout + stderr and secret not in stdout + stderr, name + ': secret/nonfinal leaked', case)
    require(not (case / 'unexpected-network').exists(), name + ': unrecognized transport', case)
    reports = list(report_dir.glob('review-*/final-candidates.jsonl')) if report_dir.is_dir() else []
    records = []
    for report in reports:
        records += [json.loads(line) for line in report.read_text().splitlines()]
        require(stat.S_IMODE(report.parent.stat().st_mode) == 0o700, name + ': directory permission', case)
        expected_mode = 0o400 if name == 'append-failure' else 0o600
        require(stat.S_IMODE(report.stat().st_mode) == expected_mode, name + ': file permission', case)
        require(str(report) in stderr, name + ': absolute report path not announced', case)
    parseable = name not in ('invalid-json', 'wrong-type')
    if not fallback and parseable:
        require(len(reports) == 1 and len(records) == len(emitted), name + ': missing attempted final', case)
        require(stderr.count('完整脱敏 final 候选报告：') == 1, name + ': duplicate/missing announcement', case)
        for record, source in zip(records, emitted):
            expected = source['final']
            if name == 'secret-controls':
                expected = expected.replace(secret, '<REDACTED>').replace('\x1b[31m', '').replace('\x1b[0m', '').replace('\x00', '')
            require(record['final_text'] == expected, name + ': lost/reordered/truncated final text', case)
            require(record['curl_status'] == source['curl_status'] and record['done'] == source['done'], name + ': attempt metadata', case)
        require(private_marker not in json.dumps(records), name + ': private field persisted', case)
    elif fallback:
        require('完整候选保存失败' in stderr, name + ': missing fallback diagnostic', case)
        require(emitted[-1]['final'] in stderr, name + ': fallback final incomplete', case)
        if name == 'append-failure':
            require(len(records) == 1 and len(emitted) == 2, name + ': append failure fixture did not trigger', case)
        elif name == 'flush-failure':
            require(len(records) == 1 and '报告可能不完整' in stderr, name + ': flush failure fixture did not trigger', case)
        else: require(not records, name + ': invalid path was used', case)
    else:
        require(not records and '不展示原始 API 包' in stderr, name + ': malformed JSON diagnostics unsafe', case)
    if name == 'directory-file': require(report_dir.read_text() == 'untouched', name + ': target overwritten', case)
    if name in ('symlink-dir', 'symlink-ancestor'):
        require(not list((case / 'untouched').iterdir()), name + ': followed directory link', case)
    if name == 'public-mode': require(stat.S_IMODE(report_dir.stat().st_mode) == 0o755, name + ': changed existing permissions', case)
    if name == 'sharded': require(len(records) == 3 and all(r['stage'].startswith('chunk-') for r in records), 'missing shard capture', case)
    if name == 'specialist': require(len(records) == 2 and records[1]['stage'] == 'initial.specialist', 'missing specialist capture', case)
    if name == 'retry': require([r['attempt'] for r in records] == [1, 2] and records[0]['curl_status'] == 28, 'retry overwritten', case)
    if name == 'mixed': require('RETAINED_1' in stdout and 'CANDIDATE_1' not in stdout, 'mixed stdout gate changed', case)
    if name != 'default-home': require(not (home / '.local/share/local-review/reports').exists(), name + ': ignored isolated report directory', case)
    return len(emitted)


with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
    calls = list(pool.map(run_case, scenarios))

# Direct helper boundary checks supplement the real shell flow without a model.
destination = work / 'helper-report'
created = subprocess.run([sys.executable, str(helper), 'create', str(destination)], capture_output=True, check=True)
report = Path(created.stdout.decode().strip())
outside = work / 'outside.txt'
outside.write_text('do not overwrite')
report.unlink()
report.symlink_to(outside)
arguments = [sys.executable, str(helper), 'append', str(report), 'initial', '1', '0', 'true', 'stop']
assert subprocess.run(arguments, input=b'candidate', capture_output=True).returncode != 0
assert outside.read_text() == 'do not overwrite'
report.unlink()
os.link(outside, report)
assert subprocess.run(arguments, input=b'candidate', capture_output=True).returncode != 0
assert outside.read_text() == 'do not overwrite'
report.unlink()
os.mkfifo(report, 0o600)
assert subprocess.run(arguments, input=b'candidate', capture_output=True, timeout=5).returncode != 0
print('native output visibility regression: PASS (%d isolated cases, %d fake requests, 3 file guards; no real model/network)' %
      (len(scenarios), sum(calls)))
temporary.cleanup()
PY
