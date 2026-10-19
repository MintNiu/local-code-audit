#!/usr/bin/env bash
set -euo pipefail
umask 077
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 -I -B - "$repo_root" "$@" <<'PY'
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

parser = argparse.ArgumentParser(description='Offline deterministic-preflight retention and shard-scope regression.')
parser.add_argument('--core', help='Absolute core path; companion helpers must be beside it.')
args = parser.parse_args(sys.argv[2:])
root = Path(sys.argv[1]).resolve()
core = Path(args.core) if args.core else root / 'bin/local-review.sh'
if not core.is_absolute() or not core.is_file():
    raise SystemExit('--core must name an existing absolute file')
core = core.resolve()
helpers = [core.parent / name for name in
           ('java-method-window.py', 'java-method-sidecar.py', 'native-output-report.py')]
if not all(path.is_file() for path in helpers):
    raise SystemExit('Core helper snapshot incomplete')
sha = lambda data: hashlib.sha256(data).hexdigest()
pins = lambda: {str(path): sha(path.read_bytes()) for path in [core] + helpers}
before = pins()
source = core.read_text(encoding='utf-8')
work = Path(tempfile.mkdtemp(prefix='local-review-preflight-monotonicity-')).resolve()
work.chmod(0o700)
fake, template = work / 'bin', work / 'empty-git-template'
fake.mkdir(mode=0o700)
template.mkdir(mode=0o700)
for name in ('python3', 'jq', 'rg', 'git'):
    executable = sys.executable if name == 'python3' else shutil.which(name)
    if not executable:
        raise SystemExit('Missing prerequisite ' + name + '; evidence: ' + str(work))
    (fake / name).symlink_to(Path(executable).resolve())

def save_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')

# New mapping: no inherited Git object/index/config, BASH_ENV, proxies, model
# settings, examples or destination overrides. HOME is preserved, not repointed.
env = dict(PATH=str(fake) + ':/usr/bin:/bin:/usr/sbin:/sbin', HOME=os.environ.get('HOME', ''),
           LANG='C.UTF-8', LC_ALL='C.UTF-8', PYTHONDONTWRITEBYTECODE='1', PYTHONNOUSERSITE='1',
           GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null', GIT_CONFIG_NOSYSTEM='1',
           GIT_TERMINAL_PROMPT='0', GIT_NO_LAZY_FETCH='1', GIT_NO_REPLACE_OBJECTS='1',
           GIT_CONFIG_COUNT='4', GIT_CONFIG_KEY_0='protocol.allow', GIT_CONFIG_VALUE_0='never',
           GIT_CONFIG_KEY_1='core.hooksPath', GIT_CONFIG_VALUE_1='/dev/null',
           GIT_CONFIG_KEY_2='core.fsmonitor', GIT_CONFIG_VALUE_2='false',
           # This fixture tests a deletion plus addition, not rename detection.
           GIT_CONFIG_KEY_3='diff.renames', GIT_CONFIG_VALUE_3='false')
rows = []

def record(name, problems, **facts):
    row = dict(case=name, result='FAIL' if problems else 'PASS', problems=problems, **facts)
    rows.append(row)
    save_json(work / (name + '.assessment.json'), row)
    print(row['result'] + ' ' + name, flush=True)
    if problems:
        print('\n'.join(problems) + '\nEvidence: ' + str(work), file=sys.stderr, flush=True)

def function(name):
    match = re.search(r'^' + re.escape(name) + r'\(\) \{\n.*?^\}', source, re.M | re.S)
    if not match:
        raise RuntimeError('Cannot isolate production function: ' + name)
    return match.group(0)

# Inspect the actual producer templates, not copies of their findings. These
# are format contracts only, not new business fixtures or truth/impact labels.
producers = [('tenant-conditional-header', 'collect_tenant_lifecycle_login_preflight', '条件'),
             ('password-conditional-header', 'collect_hr_default_password_policy_preflight', '有条件')]
for name, producer, qualifier in producers:
    body = function(producer)
    headers = [line for line in body.splitlines() if 'printf' in line and 'P1' in line]
    correct = len(headers) == 1 and re.search(r'P1 [^\n]+:[^\n]+ - （' + qualifier + '）', headers[0])
    record(name, [] if correct and 'P1（' not in body else ['Producer must place its condition after canonical P1 path:line - .'],
           producer=producer, producer_sha256=sha(body.encode()), matched_printf_lines=headers)

sorter = function('sort_findings_by_severity')
(work / 'sorter-under-test.sh').write_text(sorter + '\n', encoding='utf-8')

def block(severity, path, qualifier, title):
    return (severity + ' ' + path + ':2 - ' + qualifier + title + '\n'
            '来源：确定性预检（代码证据，非模型原文）\n'
            '影响：合成契约下的可见结果。\n修复建议：保留本段及其条件限定。\n验证方式：仅检查文本，不运行源码。\n')

conditional = block('P1', 'src/main/java/example/Conditional.java', '（条件）', '合成条件证据')
qualified = block('P1', 'src/main/java/example/Qualified.java', '（有条件）', '合成有条件证据')
lower = block('P2', 'src/main/java/example/Other.java', '', '合成低优先级证据')
sort_cases = [
    ('sort-retains-conditions', lower + conditional + '\n' + qualified, False),
    ('sort-rejects-unknown-only', 'P9 example/Unknown.java:2 - 未知级别\n影响：不得丢失。\n', True),
    ('sort-rejects-unknown-middle', conditional + '\nP9 example/Unknown.java:2 - 未知级别\n' + lower, True),
    ('sort-rejects-leading-block', '非空的未分类候选段\n\n' + conditional, True),
    ('sort-rejects-legacy-prefix', conditional.replace('P1 ', 'P1（条件） ', 1) + lower, True),
]
for name, text, invalid in sort_cases:
    case = work / name
    case.mkdir(mode=0o700)
    (case / 'stdin.txt').write_text(text, encoding='utf-8')
    command = ['/bin/bash', '-c', 'set -euo pipefail\n' + sorter + '\nsort_findings_by_severity\n']
    result = subprocess.run(command, input=text.encode(), env=env, cwd=case, capture_output=True, timeout=15)
    (case / 'stdout.txt').write_bytes(result.stdout)
    (case / 'stderr.txt').write_bytes(result.stderr)
    save_json(case / 'command.json', dict(argv=command, exit_code=result.returncode))
    if invalid:
        problems = [] if result.returncode != 0 and not result.stdout else ['Noncanonical block must fail without partial successful output.']
    else:
        actual = re.split(rb'\n\n+', result.stdout.rstrip(b'\n'))
        expected = [part.rstrip('\n').encode() for part in (conditional, qualified, lower)]
        problems = [] if result.returncode == 0 and actual == expected else ['Sorting lost, rewrote or misordered a complete conditional block.']
    record(name, problems, exit_code=result.returncode, stdin_sha256=sha(text.encode()), stdout_sha256=sha(result.stdout))

transport = r'''
import json, os, sys
from pathlib import Path
case = Path(os.environ['PREFLIGHT_MONOTONICITY_CASE'])
tool, args = Path(sys.argv[1]).name, sys.argv[2:]
with (case / 'calls.jsonl').open('a', encoding='utf-8') as out:
    out.write(json.dumps({'tool': tool, 'args': args}) + '\n')
def require(condition):
    if not condition:
        (case / 'unexpected-operation').touch()
        raise SystemExit('Unexpected fake transport operation; no networking implementation exists')
if tool == 'ollama':
    require(args == ['show', 'preflight-monotonicity-fake'])
    raise SystemExit(0)
require(tool == 'curl' and '--data-binary' in args)
require([arg for arg in args if arg.startswith(('http://', 'https://'))] == ['http://127.0.0.1:11434/api/generate'])
argument = args[args.index('--data-binary') + 1]
require(argument.startswith('@'))
request_path = Path(argument[1:]).resolve()
request_path.relative_to((case / 'tmp').resolve())
body = request_path.read_bytes()
request = json.loads(body)
require(request['model'] == 'preflight-monotonicity-fake' and request['stream'] is False)
require('think' not in request and 'format' not in request)
require(request['options']['num_ctx'] == 16384 and request['options']['num_predict'] == 2048)
require('--- 当前审查分片：' in request['prompt'])
number = len(list(case.glob('request-*.json'))) + 1
require(number <= 8)
(case / ('request-%03d.json' % number)).write_bytes(body)
envelope = json.dumps({'response': '未发现阻塞问题', 'done': True, 'done_reason': 'stop'}, ensure_ascii=False).encode() + b'\n'
(case / ('fake-response-%03d.json' % number)).write_bytes(envelope)
sys.stdout.buffer.write(envelope)
'''
transport_path = fake / 'transport.py'
transport_path.write_text(transport, encoding='utf-8')
for name in ('curl', 'ollama'):
    wrapper = fake / name
    wrapper.write_text('#!/bin/sh\nexec ' + shlex.quote(sys.executable) + ' -I -B ' +
                       shlex.quote(str(transport_path)) + ' "$0" "$@"\n', encoding='utf-8')
    wrapper.chmod(0o700)

def global_union():
    case = work / 'global-deleted-importer'
    repo, tmp, reports = case / 'repo', case / 'tmp', case / 'reports'
    repo.mkdir(parents=True, mode=0o700)
    tmp.mkdir(mode=0o700)
    child_env = dict(env, TMPDIR=str(tmp), PREFLIGHT_MONOTONICITY_CASE=str(case),
                     LOCAL_REVIEW_DATA_DIR=str(case / 'data'), LOCAL_REVIEW_EXAMPLES_FILE='/dev/null',
                     LOCAL_REVIEW_REPORT_DIR=str(reports), OLLAMA_HOST='http://127.0.0.1:11434',
                     OLLAMA_REVIEW_MODEL='preflight-monotonicity-fake', OLLAMA_REVIEW_NUM_CTX='16384',
                     OLLAMA_REVIEW_NUM_PREDICT='4096', OLLAMA_REVIEW_CHUNK_NUM_PREDICT='2048',
                     OLLAMA_REVIEW_MAX_DIFF_BYTES='1000', OLLAMA_REVIEW_RETRY_ATTEMPTS='0',
                     OLLAMA_REVIEW_JAVA_METHOD_SIDECAR='false', OLLAMA_REVIEW_LOCK_DIR=str(tmp / 'review.lock'),
                     OLLAMA_REVIEW_TRACE_FILE=str(case / 'trace.tsv'), OLLAMA_REVIEW_TIMEOUT_SECONDS='60',
                     OLLAMA_REVIEW_CHUNK_TIMEOUT_SECONDS='60', OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS='90')
    git = [str(fake / 'git'), '-C', str(repo)]
    setup_log = []
    def setup(arguments):
        result = subprocess.run(git + arguments, env=child_env, cwd=work, capture_output=True, timeout=30)
        setup_log.append(dict(argv=git + arguments, exit_code=result.returncode,
                              stdout=result.stdout.decode('utf-8', 'replace'), stderr=result.stderr.decode('utf-8', 'replace')))
        save_json(case / 'setup.json', setup_log)
        if result.returncode:
            raise RuntimeError('Fixture Git operation failed; inspect setup.json')
        return result.stdout
    deleted = 'src/main/java/example/contract/RetiredBadge.java'
    importer = 'src/main/java/example/consumer/BadgeReader.java'
    unrelated = 'src/main/java/example/display/Banner.java'
    padding = ''.join('    // Original synthetic file-boundary padding row %02d; no runtime effect.\n' % i for i in range(6))
    sources = {
        deleted: 'package example.contract;\npublic final class RetiredBadge {\n' + padding + '}\n',
        importer: 'package example.consumer;\nimport example.contract.RetiredBadge;\nfinal class BadgeReader { RetiredBadge badge; }\n',
        unrelated: 'package example.display;\nfinal class Banner {\n' + padding + '    static String text() { return "synthetic"; }\n}\n'}
    setup(['init', '-q', '--template=' + str(template)])
    for path in (deleted, importer):
        target = repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(sources[path], encoding='utf-8')
    setup(['add', '--', deleted, importer])
    setup(['-c', 'user.name=preflight-monotonicity-test', '-c', 'user.email=test@example.invalid',
           '-c', 'commit.gpgSign=false', 'commit', '-qm', 'test：建立原创删除类型回归基线'])
    (repo / deleted).unlink()  # Only the exact synthetic file created above is removed.
    target = repo / unrelated
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(sources[unrelated], encoding='utf-8')
    setup(['add', '--', deleted, unrelated])
    diff = setup(['diff', '--cached', '--no-ext-diff', '--no-textconv', '--no-renames'])
    (case / 'fixture.diff').write_bytes(diff)
    changed = setup(['diff', '--cached', '--name-only', '--no-renames']).decode().splitlines()
    save_json(case / 'fixture.json', dict(sources=sources, changed_paths=changed, importer_unchanged=importer not in changed))
    command = ['/bin/bash', str(core), '--repo', str(repo)]
    save_json(case / 'command.json', dict(argv=command, env=child_env, cwd=str(work)))
    try:
        result = subprocess.run(command, env=child_env, cwd=work, capture_output=True, timeout=120)
        status, stdout, stderr = result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired as exc:
        status, stdout, stderr = 124, exc.stdout or b'', exc.stderr or b''
    (case / 'stdout.txt').write_bytes(stdout)
    (case / 'stderr.txt').write_bytes(stderr)
    (case / 'exit-code.txt').write_text(str(status) + '\n', encoding='utf-8')
    problems, requests, request_scopes = [], sorted(case.glob('request-*.json')), {}
    if changed != sorted((deleted, unrelated)) or importer in diff.decode():
        problems.append('Fixture must change only deleted type and unrelated file, never importer.')
    if status != 0 or '未发现阻塞问题' in stdout.decode():
        problems.append('Global deterministic evidence must prevent clean after all clean shards.')
    expected_header = 'P1 ' + importer + ':2 - '
    headers = re.findall(r'^(?:P[0-3]|信息) .*$', stdout.decode(), re.M)
    if len(headers) != 1 or not headers[0].startswith(expected_header):
        problems.append('Final report must contain exactly one importer P1, with its real import line.')
    for required in ('example.contract.RetiredBadge', '证据：删除 ' + deleted,
                     '来源：确定性预检（代码证据，非模型原文）', '影响：', '修复建议：', '验证方式：'):
        if required not in stdout.decode():
            problems.append('Incomplete final deterministic paragraph: ' + required)
    if not 2 <= len(requests) <= 8:
        problems.append('Expected at least two bounded real core shard requests to fake transport.')
    for path in requests:
        prompt = json.loads(path.read_bytes())['prompt']
        shard = re.search(r'--- 当前审查分片：(chunk-[^ ]+) ---', prompt)
        inventory = re.search(r'--- 当前审查分片文件列表 ---\n(.*?)(?=\n---)', prompt, re.S)
        global_inventory = re.search(r'--- 本次提交全部变更路径（仅范围元数据，不是当前分片证据） ---\n(.*?)\n--- 变更路径元数据结束', prompt, re.S)
        diff_paths = set(re.findall(r'^diff --git a/(\S+) b/\S+$', prompt, re.M))
        allowed = set(re.findall(r'^ M (.+)$', inventory.group(1), re.M)) if inventory else set()
        if not shard or not allowed or allowed != diff_paths or not allowed <= set(changed):
            problems.append('Actual request scope must equal only that shard diff paths: ' + path.name)
        if importer in allowed:
            problems.append('Unchanged importer was injected into model shard permission scope.')
        if not global_inventory or set(global_inventory.group(1).splitlines()) != set(changed):
            problems.append('Global scope metadata must remain actual changed paths, not the importer.')
        if shard:
            request_scopes[shard.group(1)] = sorted(allowed)
    if len(request_scopes) != len(requests) or {path for paths in request_scopes.values() for path in paths} != set(changed):
        problems.append('Unique captured shards must cover both changed paths without expanding scope.')
    trace = (case / 'trace.tsv').read_text() if (case / 'trace.tsv').exists() else ''
    traced_scopes = {fields[1]: sorted(fields[2].split(',')) for line in trace.splitlines()
                     if len(fields := line.split('\t')) == 3 and fields[0] == 'chunk_paths'}
    counts = re.findall(r'^chunk_count\t(\d+)$', trace, re.M)
    if traced_scopes != request_scopes or not counts or int(counts[-1]) != len(requests):
        problems.append('Trace actual validator path sets/chunk count must match captured requests.')
    calls = [json.loads(line) for line in (case / 'calls.jsonl').read_text().splitlines()] if (case / 'calls.jsonl').exists() else []
    if sum(call['tool'] == 'curl' for call in calls) != len(requests) or sum(call['tool'] == 'ollama' for call in calls) != 1 or (case / 'unexpected-operation').exists():
        problems.append('Unexpected transport, retry, missing request or model lookup.')
    archives = list(reports.glob('review-*/final-candidates.jsonl'))
    records = [json.loads(line) for path in archives for line in path.read_text().splitlines()]
    if len(archives) != 1 or len(records) != len(requests) or any(row['final_text'] != '未发现阻塞问题' for row in records):
        problems.append('Private original-final archive must retain each clean fake response.')
    if any(stat.S_IMODE(path.stat().st_mode) != 0o600 for path in archives):
        problems.append('Original-final archive is not private.')
    record('global-deleted-importer', problems, exit_code=status, request_count=len(requests),
           request_sha256={path.name: sha(path.read_bytes()) for path in requests},
           stdout_sha256=sha(stdout), shard_scopes=traced_scopes, changed_paths=changed)

try:
    global_union()
except Exception as exc:
    record('global-deleted-importer', [str(exc)])
after = pins()
summary = dict(cases=rows, passed=sum(row['result'] == 'PASS' for row in rows), total=len(rows),
               pins_before=before, pins_after=after, core_and_helpers_unchanged=before == after,
               source_execution=False, real_network_or_model_calls=0,
               scope='Producer format, fail-closed ordering and global preflight union; not model quality or real-project gold.')
save_json(work / 'summary.json', summary)
print('Preflight monotonicity: {passed}/{total} passed'.format(**summary), flush=True)
print('Preflight monotonicity artifacts: ' + str(work), file=sys.stderr, flush=True)
raise SystemExit(0 if summary['passed'] == summary['total'] and before == after else 1)
PY
