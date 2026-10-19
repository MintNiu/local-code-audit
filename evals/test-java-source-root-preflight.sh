#!/usr/bin/env bash
set -euo pipefail
umask 077
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 - "$repo_root" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1]).resolve()
core = root / 'bin/local-review.sh'
work = Path(tempfile.mkdtemp(prefix='local-review-java-source-roots-')).resolve()
work.chmod(0o700)
fake = work / 'bin'
fake.mkdir(mode=0o700)
empty_template = work / 'empty-git-template'
empty_template.mkdir(mode=0o700)
clean = '未发现阻塞问题'
marker = '当前提交快照缺少仓库内类型'
package_path = 'org/example/audit'
core_hash = hashlib.sha256(core.read_bytes()).hexdigest()

# Closed PATH: neither stub has any networking implementation. Explicitly link
# caller-installed prerequisites rather than assuming Homebrew tools are /usr/bin.
for tool in ('python3', 'jq', 'rg', 'git'):
    executable = sys.executable if tool == 'python3' else shutil.which(tool)
    if not executable:
        raise SystemExit('Required regression tool unavailable: ' + tool)
    (fake / tool).symlink_to(Path(executable).resolve())
stub = r'''
import json, os, sys
from pathlib import Path
case = Path(os.environ['SOURCE_ROOT_CASE'])
args = sys.argv[1:]
tool = Path(sys.argv[0]).name
with (case / 'calls.jsonl').open('a') as out:
    out.write(json.dumps({'tool': tool, 'args': args}) + '\n')
if tool == 'ollama':
    if args != ['show', 'source-root-fake']:
        raise SystemExit('Unexpected fake Ollama operation')
    raise SystemExit(0)
urls = [arg for arg in args if arg.startswith(('http://', 'https://'))]
if urls != ['http://127.0.0.1:11434/api/generate'] or '--data-binary' not in args:
    raise SystemExit('Unexpected fake HTTP operation; no network permitted')
argument = args[args.index('--data-binary') + 1]
if not argument.startswith('@'):
    raise SystemExit('Expected a request file')
request_path = Path(argument[1:]).resolve()
request_path.relative_to((case / 'tmp').resolve())
raw = request_path.read_bytes()
request = json.loads(raw)
assert request['model'] == 'source-root-fake' and request['stream'] is False
assert isinstance(request['prompt'], str) and 'think' not in request
(case / 'request.json').write_bytes(raw)
print(json.dumps({'response': '未发现阻塞问题', 'done': True, 'done_reason': 'stop'}, ensure_ascii=False))
'''
for name in ('curl', 'ollama'):
    executable = fake / name
    executable.write_text('#!' + sys.executable + '\n' + stub, encoding='utf-8')
    executable.chmod(0o700)


def source(name):
    return 'package org.example.audit.types;\npublic class ' + name + ' {}\n'


# Original tiny fixtures, not copies from a real repository. Unknown source
# roots have no build/classpath evidence and therefore are not deterministic P1.
cases = [
    dict(name='main-missing', source_root='src/main/java', expected='finding'),
    dict(name='module-main-nested-owner', source_root='module/src/main/java', expected='clean',
         imports=['Container.Inner'], available=[('module/src/main/java', 'Container',
         'package org.example.audit.types;\npublic class Container { public static class Inner {} }\n')]),
    dict(name='main-test-only-is-not-main', source_root='module/src/main/java', expected='finding',
         available=[('module/src/test/java', 'Helper', source('Helper'))]),
    dict(name='test-main-and-test-visible', source_root='src/test/java', expected='clean',
         imports=['MainHelper', 'TestHelper'], available=[
         ('src/main/java', 'MainHelper', source('MainHelper')),
         ('src/test/java', 'TestHelper', source('TestHelper'))]),
    dict(name='module-test-missing', source_root='module/src/test/java', expected='finding'),
    dict(name='legacy-existing', source_root='module/src', expected='clean',
         available=[('module/src', 'Helper', source('Helper'))]),
    dict(name='legacy-unknown-classpath', source_root='module/src', expected='clean'),
    dict(name='custom-existing', source_root='custom-code', expected='clean',
         available=[('custom-code', 'Helper', source('Helper'))]),
    dict(name='lookalike-root-unknown-classpath', source_root='module/not-src/main/java', expected='clean'),
    dict(name='main-outside-repository-is-not-source', source_root='src/main/java', expected='finding',
         outside=True),
]


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding='utf-8')


def run_case(spec):
    case = work / spec['name']
    repo = case / 'repo'
    tmp = case / 'tmp'
    repo.mkdir(parents=True, mode=0o700)
    tmp.mkdir(mode=0o700)
    report_dir = case / 'reports'
    # Construct a fresh environment: no inherited GIT_DIR/INDEX/OBJECT/config,
    # template variables, model options, proxy settings or report destinations.
    # HOME is retained, never repurposed; all data/report outputs are explicit.
    env = {
        'PATH': str(fake) + ':/usr/bin:/bin:/usr/sbin:/sbin',
        'HOME': os.environ.get('HOME', ''),
        'LANG': 'C.UTF-8', 'LC_ALL': 'C.UTF-8', 'PYTHONDONTWRITEBYTECODE': '1',
        'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_SYSTEM': '/dev/null',
        'GIT_CONFIG_NOSYSTEM': '1', 'GIT_TERMINAL_PROMPT': '0',
        'GIT_NO_LAZY_FETCH': '1', 'GIT_NO_REPLACE_OBJECTS': '1',
        'TMPDIR': str(tmp), 'SOURCE_ROOT_CASE': str(case),
        'LOCAL_REVIEW_DATA_DIR': str(case / 'private-data'),
        'LOCAL_REVIEW_EXAMPLES_FILE': '/dev/null',
        'LOCAL_REVIEW_REPORT_DIR': str(report_dir),
        'OLLAMA_HOST': 'http://127.0.0.1:11434',
        'OLLAMA_REVIEW_MODEL': 'source-root-fake',
        'OLLAMA_REVIEW_NUM_CTX': '16384', 'OLLAMA_REVIEW_NUM_PREDICT': '4096',
        'OLLAMA_REVIEW_MAX_DIFF_BYTES': '6000', 'OLLAMA_REVIEW_RETRY_ATTEMPTS': '0',
        'OLLAMA_REVIEW_JAVA_METHOD_SIDECAR': 'false',
        'OLLAMA_REVIEW_LOCK_DIR': str(tmp / 'review.lock'),
        'OLLAMA_REVIEW_TRACE_FILE': str(case / 'trace.tsv'),
        'OLLAMA_REVIEW_TIMEOUT_SECONDS': '60', 'OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS': '60',
    }
    git = [str(fake / 'git'), '-c', 'protocol.allow=never', '-C', str(repo)]
    setup_log = []

    def setup(args):
        result = subprocess.run(git + args, env=env, cwd=work, capture_output=True, timeout=30)
        setup_log.append(dict(argv=git + args, exit_code=result.returncode,
                              stdout=result.stdout.decode('utf-8', 'replace'),
                              stderr=result.stderr.decode('utf-8', 'replace')))
        (case / 'setup.json').write_text(json.dumps(setup_log, ensure_ascii=False, indent=2), encoding='utf-8')
        if result.returncode:
            raise RuntimeError('Fixture Git setup failed: ' + str(case / 'setup.json'))

    setup(['init', '-q', '--template=' + str(empty_template)])
    setup(['config', 'user.name', 'source-root-preflight'])
    setup(['config', 'user.email', 'test@example.invalid'])
    relative = spec['source_root'] + '/' + package_path + '/client/ReviewTarget.java'
    write(repo / relative, 'package org.example.audit.client;\npublic class ReviewTarget {}\n')
    for source_root, name, contents in spec.get('available', []):
        write(repo / source_root / package_path / 'types' / (name + '.java'), contents)
    if spec.get('outside'):
        write(case / 'outside-repo/src/main/java' / package_path / 'types/Helper.java', source('Helper'))
    setup(['add', '.'])
    setup(['-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgSign=false',
           'commit', '-qm', 'test：建立源码根边界基线'])
    imports = spec.get('imports', ['Helper'])
    changed = ('package org.example.audit.client;\n\n' +
               ''.join('import org.example.audit.types.' + name + ';\n' for name in imports) +
               '\npublic class ReviewTarget {\n' +
               ''.join('    ' + name.split('.')[-1] + ' value' + str(index) + ';\n'
                       for index, name in enumerate(imports)) + '}\n')
    write(repo / relative, changed)
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
    (case / 'exit-code.txt').write_text(str(status) + '\n', encoding='ascii')
    calls_file = case / 'calls.jsonl'
    calls = [json.loads(line) for line in calls_file.read_text().splitlines()] if calls_file.exists() else []
    counts = {tool: sum(call['tool'] == tool for call in calls) for tool in ('curl', 'ollama')}
    output = stdout.decode('utf-8', 'replace')
    request_file = case / 'request.json'
    prompt = json.loads(request_file.read_bytes())['prompt'] if request_file.exists() else ''
    findings = output.count(marker)
    problems = []
    if status != 0 or counts != {'curl': 1, 'ollama': 1} or not request_file.is_file():
        problems.append('review must exit0 with exactly one fake generate and model probe')
    if relative not in prompt or 'import org.example.audit.types.' not in prompt:
        problems.append('actual request must retain the changed Java evidence')
    if spec['expected'] == 'finding':
        if findings != 1 or marker not in prompt or ('P1 ' + relative + ':3') not in output:
            problems.append('standard-root missing type must remain one located P1')
        if '来源：确定性预检（代码证据，非模型原文）' not in output:
            problems.append('missing deterministic provenance')
    elif output.strip() != clean or marker in prompt:
        problems.append('unknown/present source must not invent deterministic missing-type P1')
    archives = list(report_dir.glob('review-*/final-candidates.jsonl'))
    if len(archives) != 1 or str(archives[0]) not in stderr.decode('utf-8', 'replace'):
        problems.append('private per-case native report must be retained and announced')
    if archives and archives[0].resolve().parent.parent != report_dir.resolve():
        problems.append('report escaped the isolated destination')
    row = dict(case=spec['name'], expected=spec['expected'], exit_code=status,
               findings=findings, fake_curl_calls=counts['curl'], fake_ollama_calls=counts['ollama'],
               result='FAIL' if problems else 'PASS', problems=problems)
    (case / 'assessment.json').write_text(json.dumps(row, ensure_ascii=False, indent=2), encoding='utf-8')
    print('{result} {case} exit={exit_code} findings={findings} curl={fake_curl_calls} ollama={fake_ollama_calls}'.format(**row), flush=True)
    if problems:
        print('Full evidence: ' + str(case), file=sys.stderr, flush=True)
        print('\n'.join(problems), file=sys.stderr, flush=True)
    return row


failed = True
try:
    rows = [run_case(spec) for spec in cases]
    after_hash = hashlib.sha256(core.read_bytes()).hexdigest()
    failed = any(row['result'] == 'FAIL' for row in rows) or after_hash != core_hash
    summary = dict(core_sha256_before=core_hash, core_sha256_after=after_hash,
                   core_unchanged=after_hash == core_hash, cases=rows,
                   passed=sum(row['result'] == 'PASS' for row in rows), total=len(rows),
                   real_network_or_model_calls=0, application_builds=0)
    (work / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')
    print('Java source-root preflight: {}/{} passed'.format(summary['passed'], summary['total']), flush=True)
finally:
    if failed or os.environ.get('JAVA_SOURCE_ROOT_KEEP_ARTIFACTS') == '1':
        print('Java source-root regression artifacts: ' + str(work), file=sys.stderr, flush=True)
    else:
        shutil.rmtree(work)
raise SystemExit(1 if failed else 0)
PY
