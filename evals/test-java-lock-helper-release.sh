#!/usr/bin/env bash
set -euo pipefail
umask 077
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 -I -B - "$repo_root" "${BASH_SOURCE[0]}" "$@" <<'PY'
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description='Offline Java private lock-release helper regression; target Java is data only.')
parser.add_argument('--core', help='Existing absolute core path; its helpers must be beside it.')
args = parser.parse_args(sys.argv[3:])
root, test_path = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
core = Path(args.core) if args.core else root / 'bin/local-review.sh'
if not core.is_absolute() or not core.is_file():
    raise SystemExit('--core must be an existing absolute core path')
core = core.resolve()
required = ('java-method-window.py', 'java-method-sidecar.py', 'native-output-report.py')
if not all((core.parent / name).is_file() for name in required):
    raise SystemExit('Core helper snapshot incomplete')
# Include any new adjacent Python helper without requiring its presence in an
# old baseline snapshot. The same frozen test is usable for both red and green.
pin_paths = [core, test_path] + sorted(core.parent.glob('*.py'))

def sha(data):
    return hashlib.sha256(data).hexdigest()

pins_before = {str(path): sha(path.read_bytes()) for path in pin_paths}
work = Path(tempfile.mkdtemp(prefix='local-review-java-lock-helper-')).resolve()
work.chmod(0o700)
fake, template = work / 'bin', work / 'empty-git-template'
fake.mkdir(mode=0o700)
template.mkdir(mode=0o700)
for tool in ('python3', 'jq', 'rg', 'git'):
    executable = sys.executable if tool == 'python3' else shutil.which(tool)
    if not executable:
        raise SystemExit('Required installed tool unavailable: ' + tool + '; evidence: ' + str(work))
    (fake / tool).symlink_to(Path(executable).resolve())

transport = r'''
import hashlib, json, os, sys
from pathlib import Path
case = Path(os.environ['LOCK_HELPER_CASE'])
tool, args = Path(sys.argv[1]).name, sys.argv[2:]
with (case / 'calls.jsonl').open('a', encoding='utf-8') as out:
    out.write(json.dumps({'tool': tool, 'args': args}) + '\n')
def require(condition):
    if not condition:
        (case / 'unexpected-operation').touch()
        raise SystemExit('Unexpected fake operation; no networking implementation exists')
if tool == 'ollama':
    require(args == ['show', 'lock-helper-fake'])
    raise SystemExit(0)
require(tool == 'curl')
urls = [arg for arg in args if arg.startswith(('http://', 'https://'))]
require(urls == ['http://127.0.0.1:11434/api/generate'] and '--data-binary' in args)
argument = args[args.index('--data-binary') + 1]
require(argument.startswith('@'))
request_path = Path(argument[1:]).resolve()
request_path.relative_to((case / 'tmp').resolve())
body = request_path.read_bytes()
request = json.loads(body)
require(request['model'] == 'lock-helper-fake' and request['stream'] is False)
require('think' not in request and 'format' not in request)
require(hashlib.sha256(request['system'].encode('utf-8')).hexdigest() ==
        '967f552a888b03509a0f6fa9ed27888fbd76f901a8bb112844b1f101307908d4')
options = request['options']
require(type(options['num_ctx']) is int and options['num_ctx'] == 16384)
require(type(options['num_predict']) is int and options['num_predict'] == 4096)
require(options['temperature'] == 0 and options['seed'] == 42 and
        options['top_k'] == 40 and options['top_p'] == 0.9)
require(not (case / 'request.json').exists())
(case / 'request.json').write_bytes(body)
response = (case / 'response.txt').read_text(encoding='utf-8')
envelope = json.dumps({'response': response, 'done': True,
                      'done_reason': os.environ['LOCK_HELPER_DONE_REASON'],
                      'thinking': 'NONFINAL_MUST_NOT_BE_EXPOSED'}, ensure_ascii=False).encode('utf-8') + b'\n'
(case / 'fake-response.json').write_bytes(envelope)
sys.stdout.buffer.write(envelope)
'''
transport_path = fake / 'transport.py'
transport_path.write_text(transport, encoding='utf-8')
transport_path.chmod(0o600)
for name in ('curl', 'ollama'):
    path = fake / name
    path.write_text('#!/bin/sh\nexec ' + shlex.quote(sys.executable) + ' -I -B ' +
                    shlex.quote(str(transport_path)) + ' "$0" "$@"\n', encoding='utf-8')
    path.chmod(0o700)

relative = 'src/main/java/example/LockScope.java'
clean = '未发现阻塞问题'
field = '    private final java.util.concurrent.locks.ReentrantLock lock = new java.util.concurrent.locks.ReentrantLock();\n'
other_field = '    private final java.util.concurrent.locks.ReentrantLock other = new java.util.concurrent.locks.ReentrantLock();\n'

def source(work_body, helper='', extra_field='', throws=''):
    return ('package example;\n\nclass LockScope {\n' + field + extra_field +
            '    private int visits;\n\n    void work()' + throws + ' {\n' +
            work_body + '    }\n' + helper + '}\n')

ordinary_body = '''        lock.lock();
        try {
            visits++;
        } finally {
            release();
        }
'''
leaf_helper = '''
    private void release() {
        lock.unlock();
    }
'''
ordinary = source(ordinary_body, leaf_helper)
direct = source(ordinary_body.replace('release();', 'lock.unlock();'))
qualified_multiline = source('''        this.lock.lock();
        try {
            visits++;
        } finally {
            this.release(
                /* no arguments */
            );
        }
''', '''
    private void release() {
        this.lock
            .unlock(
                /* same field, no arguments */
            );
    }
''')
interruptible = source(ordinary_body.replace('lock.lock();', 'lock.lockInterruptibly();'),
                       leaf_helper, throws=' throws InterruptedException')
missing = source(ordinary_body.replace('release();', 'visits += 0;'))
other = source(ordinary_body, leaf_helper.replace('lock.unlock();', 'other.unlock();'),
               extra_field=other_field)
uncalled = source(ordinary_body.replace('release();', 'visits += 0;'), leaf_helper)
normal_only = source('''        lock.lock();
        try {
            if (visits == 0) throw new IllegalStateException();
            visits++;
            release();
        } finally {
            visits += 0;
        }
''', leaf_helper)
conditional = source(ordinary_body.replace('release();', 'if (visits > 1) release();'), leaf_helper)
throwing = source(ordinary_body, '''
    private void release() {
        throwBeforeRelease();
        lock.unlock();
    }

    private void throwBeforeRelease() {
        throw new IllegalStateException();
    }
''')
shadowed = source(ordinary_body.replace(
    'release();', 'release(new java.util.concurrent.locks.ReentrantLock());'), '''
    private void release(java.util.concurrent.locks.ReentrantLock lock) {
        lock.unlock();
    }
''')
overridable = source(ordinary_body, leaf_helper.replace('private void release()', 'void release()'))

# The fixed information paragraph is visibility-only, not factual model gold.
fixed_candidate = (
    '信息 ' + relative + ':3 - 固定建议段留存控制\n'
    '证据：本段是替身注入的完整候选，不是由目标源码推导的缺陷。\n'
    '影响：未确认的建议仍须向用户保留，不能被预检规则改写为 clean。\n'
    '修复建议：由维护者对照真实需求独立判断，不自动修改源码。\n'
    '验证方式：逐字比较最终输出和私有归档，不将本段计入模型质量。\n')

# Four safe evidence cases, eight conservative controls, two protocol controls.
# The non-private case is unsupported, not a certified leak: it must not obtain
# an unconditional safety exemption merely because its name matches a helper.
# None of these Java sources, their work methods or model suggestions is run.
cases = [
    dict(name='direct-finally', source=direct, expected='clean'),
    dict(name='private-leaf-helper', source=ordinary, expected='clean'),
    dict(name='this-multiline-comments', source=qualified_multiline, expected='clean'),
    dict(name='interruptible-finally-helper', source=interruptible, expected='clean'),
    dict(name='missing-release', source=missing, expected='preflight'),
    dict(name='other-field-helper', source=other, expected='preflight'),
    dict(name='helper-not-called', source=uncalled, expected='preflight'),
    dict(name='normal-path-only', source=normal_only, expected='preflight'),
    dict(name='conditional-finally', source=conditional, expected='preflight'),
    dict(name='throw-before-unlock', source=throwing, expected='preflight'),
    dict(name='parameter-shadows-field', source=shadowed, expected='preflight'),
    dict(name='nonprivate-helper', source=overridable, expected='preflight'),
    dict(name='fixed-candidate-retention', source=ordinary, expected='candidate', response=fixed_candidate),
    dict(name='length-fails-closed', source=ordinary, expected='length', response=fixed_candidate),
]
request_by_source = {}

def run_case(spec):
    case = work / spec['name']
    repo, tmp, reports = case / 'repo', case / 'tmp', case / 'reports'
    repo.mkdir(parents=True, mode=0o700)
    tmp.mkdir(mode=0o700)
    env = dict(PATH=str(fake) + ':/usr/bin:/bin:/usr/sbin:/sbin', HOME=os.environ.get('HOME', ''),
               LANG='C.UTF-8', LC_ALL='C.UTF-8', PYTHONDONTWRITEBYTECODE='1', PYTHONNOUSERSITE='1',
               GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null', GIT_CONFIG_NOSYSTEM='1',
               GIT_TERMINAL_PROMPT='0', GIT_NO_LAZY_FETCH='1', GIT_NO_REPLACE_OBJECTS='1',
               TMPDIR=str(tmp), LOCK_HELPER_CASE=str(case),
               LOCK_HELPER_DONE_REASON='length' if spec['expected'] == 'length' else 'stop',
               LOCAL_REVIEW_DATA_DIR=str(case / 'data'), LOCAL_REVIEW_EXAMPLES_FILE='/dev/null',
               LOCAL_REVIEW_REPORT_DIR=str(reports), OLLAMA_HOST='http://127.0.0.1:11434',
               OLLAMA_REVIEW_MODEL='lock-helper-fake', OLLAMA_REVIEW_NUM_CTX='16384',
               OLLAMA_REVIEW_NUM_PREDICT='4096', OLLAMA_REVIEW_MAX_DIFF_BYTES='6000',
               OLLAMA_REVIEW_TEMPERATURE='0', OLLAMA_REVIEW_SEED='42',
               OLLAMA_REVIEW_TOP_K='40', OLLAMA_REVIEW_TOP_P='0.9',
               OLLAMA_REVIEW_RETRY_ATTEMPTS='0', OLLAMA_REVIEW_JAVA_METHOD_SIDECAR='false',
               OLLAMA_REVIEW_LOCK_DIR=str(tmp / 'review.lock'),
               OLLAMA_REVIEW_TRACE_FILE=str(case / 'trace.tsv'),
               OLLAMA_REVIEW_TIMEOUT_SECONDS='60', OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS='60')
    git = [str(fake / 'git'), '-c', 'protocol.allow=never', '-c', 'core.hooksPath=/dev/null', '-C', str(repo)]
    setup_log = []

    def setup(arguments):
        result = subprocess.run(git + arguments, env=env, cwd=work, capture_output=True, timeout=30)
        setup_log.append(dict(argv=git + arguments, exit_code=result.returncode,
                              stdout=result.stdout.decode('utf-8', 'replace'),
                              stderr=result.stderr.decode('utf-8', 'replace')))
        (case / 'setup.json').write_text(json.dumps(setup_log, ensure_ascii=False, indent=2), encoding='utf-8')
        if result.returncode:
            raise RuntimeError('Fixture setup failed; see ' + str(case / 'setup.json'))

    setup(['init', '-q', '--template=' + str(template)])
    setup(['-c', 'user.name=lock-helper-test', '-c', 'user.email=test@example.invalid',
           '-c', 'commit.gpgSign=false', 'commit', '--allow-empty', '-qm', 'test：建立锁释放回归基线'])
    target = repo / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(spec['source'], encoding='utf-8')
    target.chmod(0o600)
    (case / 'source.java').write_text(spec['source'], encoding='utf-8')
    response_bytes = spec.get('response', clean + '\n').encode('utf-8')
    (case / 'response.txt').write_bytes(response_bytes)
    argv = ['/bin/bash', str(core), '--repo', str(repo)]
    (case / 'command.json').write_text(json.dumps(dict(argv=argv, cwd=str(work), env=env),
                                                  ensure_ascii=False, indent=2), encoding='utf-8')
    try:
        result = subprocess.run(argv, env=env, cwd=work, capture_output=True, timeout=90)
        status, stdout, stderr = result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired as exc:
        status, stdout, stderr = 124, exc.stdout or b'', exc.stderr or b''
    (case / 'stdout.txt').write_bytes(stdout)
    (case / 'stderr.txt').write_bytes(stderr)
    (case / 'exit-code.txt').write_text(str(status) + '\n', encoding='utf-8')
    calls_file = case / 'calls.jsonl'
    calls = [json.loads(line) for line in calls_file.read_text().splitlines()] if calls_file.exists() else []
    counts = {tool: sum(call['tool'] == tool for call in calls) for tool in ('curl', 'ollama')}
    output, diagnostic = stdout.decode('utf-8', 'replace'), stderr.decode('utf-8', 'replace')
    problems, request_sha = [], None
    if counts != {'curl': 1, 'ollama': 1} or (case / 'unexpected-operation').exists():
        problems.append('expected one exact-tag show and one fake generate, no retry or additional transport')
    request_file = case / 'request.json'
    if not request_file.is_file():
        problems.append('no captured request; inspect exit-code.txt and complete stderr.txt')
    else:
        body = request_file.read_bytes()
        request_sha = sha(body)
        request = json.loads(body)
        full_addition = '\n'.join('+' + line for line in spec['source'].splitlines()) + '\n'
        if '+++ b/' + relative not in request['prompt'] or request['prompt'].count(full_addition) != 1:
            problems.append('complete target source missing or duplicated in actual request')
        if '人工确认的 Review 示例' in request['prompt'] or fixed_candidate in request['prompt']:
            problems.append('disabled examples or fixed model candidate contaminated input')
        reference = request_by_source.setdefault(spec['source'], body)
        if body != reference:
            problems.append('same-source clean/candidate/length controls must have byte-identical actual requests')
    envelope = case / 'fake-response.json'
    if not envelope.is_file() or json.loads(envelope.read_bytes())['response'].encode('utf-8') != response_bytes:
        problems.append('fake response must preserve the entire fixed final')
    lock_headers = [line for line in output.splitlines()
                    if line.startswith('P1 ' + relative + ':') and 'Java 锁获取后' in line]
    if spec['expected'] == 'clean':
        if status != 0 or stdout != (clean + '\n').encode('utf-8') or lock_headers:
            problems.append('complete direct/private-leaf finally release must not produce lock preflight')
    elif spec['expected'] == 'preflight':
        acquisition_line = next(i for i, line in enumerate(spec['source'].splitlines(), 1)
                                if line.strip() == 'lock.lock();')
        blocks = re.split(rb'\n\n+', stdout.rstrip(b'\n')) if stdout else []
        required_header = 'P1 ' + relative + ':' + str(acquisition_line) + ' - Java 锁获取后'
        if (status != 0 or len(lock_headers) != 1 or not lock_headers[0].startswith(required_header)
                or len(blocks) != 1 or clean in output
                or not all(label in output for label in ('影响：', '修复建议：', '验证方式：'))):
            problems.append('unproved/unsafe helper control must retain one complete acquisition-located lock preflight')
    elif spec['expected'] == 'candidate':
        if status != 0 or stdout != response_bytes or lock_headers or clean in output:
            problems.append('fixed complete candidate must remain byte-exact without false lock preflight or clean')
    else:
        if status != 1 or stdout or '模型输出因长度限制被截断' not in diagnostic:
            problems.append('length response must fail closed, never return preflight-only success or clean')
    archives = list(reports.glob('review-*/final-candidates.jsonl'))
    if len(archives) != 1:
        problems.append('expected one isolated private original-final archive')
    else:
        archive = archives[0]
        records = [json.loads(line) for line in archive.read_text(encoding='utf-8').splitlines()]
        if len(records) != 1 or records[0]['final_text'].encode('utf-8') != response_bytes:
            problems.append('archive must preserve the complete original final including failed or unconfirmed content')
        elif (records[0]['stage'] != 'initial' or records[0]['attempt'] != 1
              or records[0]['curl_status'] != 0 or records[0]['done'] is not True
              or records[0]['done_reason'] != env['LOCK_HELPER_DONE_REASON']):
            problems.append('archive stage/attempt/transport/completion provenance mismatch')
        if archive.resolve().parent.parent != reports.resolve() or str(archive) not in diagnostic:
            problems.append('archive must stay in explicit private destination and announce its path')
        if stat.S_IMODE(archive.stat().st_mode) != 0o600 or stat.S_IMODE(archive.parent.stat().st_mode) != 0o700:
            problems.append('original final archive permissions must be private')
        if 'NONFINAL_MUST_NOT_BE_EXPOSED' in archive.read_text(encoding='utf-8'):
            problems.append('non-final metadata leaked into original-final archive')
    if 'NONFINAL_MUST_NOT_BE_EXPOSED' in output + diagnostic:
        problems.append('non-final metadata leaked into stdout/stderr')
    row = dict(case=spec['name'], expected=spec['expected'], exit_code=status,
               source_sha256=sha(spec['source'].encode('utf-8')), request_sha256=request_sha,
               response_sha256=sha(response_bytes), stdout_sha256=sha(stdout),
               fake_curl_calls=counts['curl'], fake_ollama_calls=counts['ollama'],
               result='FAIL' if problems else 'PASS', problems=problems)
    (case / 'assessment.json').write_text(json.dumps(row, ensure_ascii=False, indent=2), encoding='utf-8')
    print('{result} {case} exit={exit_code} curl={fake_curl_calls} ollama={fake_ollama_calls}'.format(**row), flush=True)
    if problems:
        print('Full evidence: ' + str(case) + '\n' + '\n'.join(problems), file=sys.stderr, flush=True)
    return row

rows = []
try:
    for spec in cases:
        try:
            rows.append(run_case(spec))
        except Exception as exc:
            rows.append(dict(case=spec['name'], result='FAIL', problems=[str(exc)]))
            print('FAIL ' + spec['name'] + ': ' + str(exc), file=sys.stderr, flush=True)
    pins_after = {str(path): sha(path.read_bytes()) for path in pin_paths}
    failed = any(row['result'] != 'PASS' for row in rows) or pins_before != pins_after
    summary = dict(core_sha256=pins_before[str(core)], test_sha256=pins_before[str(test_path)],
                   pins_before=pins_before, pins_after=pins_after,
                   core_helpers_and_test_unchanged=pins_before == pins_after,
                   cases=rows, passed=sum(row['result'] == 'PASS' for row in rows), total=len(rows),
                   target_source_execution=False, real_network_or_model_calls=0,
                   scope='Private-leaf helper completeness and conservative controls; fixed outputs are workflow stimuli, not model quality or P0/P1 gold.')
    (work / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')
    print('Java lock helper release: {}/{} passed'.format(summary['passed'], summary['total']), flush=True)
finally:
    print('Java lock helper regression artifacts: ' + str(work), file=sys.stderr, flush=True)
raise SystemExit(1 if failed else 0)
PY
