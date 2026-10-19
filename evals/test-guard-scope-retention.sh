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

parser = argparse.ArgumentParser(description='Offline guard-scope retention regression; never runs target sources.')
parser.add_argument('--core', help='Absolute path to the core under test; helpers must be beside it.')
args = parser.parse_args(sys.argv[2:])
root = Path(sys.argv[1]).resolve()
core = Path(args.core) if args.core else root / 'bin/local-review.sh'
if not core.is_absolute() or not core.is_file():
    raise SystemExit('--core must resolve to an existing absolute core file')
core = core.resolve()
helpers = [core.parent / name for name in
           ('java-method-window.py', 'java-method-sidecar.py', 'native-output-report.py')]
if not all(path.is_file() for path in helpers):
    raise SystemExit('Core helper snapshot incomplete')

def sha(data):
    return hashlib.sha256(data).hexdigest()

pins_before = {str(path): sha(path.read_bytes()) for path in [core] + helpers}
work = Path(tempfile.mkdtemp(prefix='local-review-guard-scope-')).resolve()
work.chmod(0o700)
fake = work / 'bin'
fake.mkdir(mode=0o700)
template = work / 'empty-git-template'
template.mkdir(mode=0o700)
# A closed child PATH links only already-installed prerequisites. HOME is not
# reassigned. Git configuration/templates/hooks and all output paths are private.
for tool in ('python3', 'jq', 'rg', 'git'):
    executable = sys.executable if tool == 'python3' else shutil.which(tool)
    if not executable:
        raise SystemExit('Required regression tool unavailable: ' + tool + '; evidence: ' + str(work))
    (fake / tool).symlink_to(Path(executable).resolve())

transport = r'''
import json, os, sys
from pathlib import Path
case = Path(os.environ['GUARD_SCOPE_CASE'])
tool, args = Path(sys.argv[1]).name, sys.argv[2:]
with (case / 'calls.jsonl').open('a', encoding='utf-8') as out:
    out.write(json.dumps({'tool': tool, 'args': args}) + '\n')
def require(condition):
    if not condition:
        (case / 'unexpected-operation').touch()
        raise SystemExit('Unexpected fixture operation; transport has no networking implementation')
if tool == 'ollama':
    require(args == ['show', 'guard-scope-fake'])
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
require(request['model'] == 'guard-scope-fake' and request['stream'] is False)
require('think' not in request and 'format' not in request)
require(type(request['options']['num_ctx']) is int and request['options']['num_ctx'] == 16384)
require(type(request['options']['num_predict']) is int and request['options']['num_predict'] == 4096)
require(not (case / 'request.json').exists())
(case / 'request.json').write_bytes(body)
response = (case / 'response.txt').read_text(encoding='utf-8')
envelope = json.dumps({'response': response, 'done': True,
                      'done_reason': os.environ['GUARD_SCOPE_DONE_REASON'],
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

dto_path = 'src/main/java/example/NullTrim.java'
header_path = 'src/main/java/example/HeaderLookup.java'
dto_bug = '''package example;

final class NullTrim {
    record Dto(String name) {}
    // Return the trimmed name, or an empty string if dto or its name is null.
    static String name(Dto dto) {
        String value = dto == null ? null : dto.name();
        return value.trim();
    }
    public static void main(String[] args) {
        System.out.println(name(null));
    }
}
'''
header_bug = '''package example;
import java.util.Map;

final class HeaderLookup {
    static final String TOKEN_HEADER = "X-Tokne";
    // Nonnull map; read the exact case-sensitive X-Token key, or null if absent.
    static String read(Map<String, String> headers) {
        return headers.get(TOKEN_HEADER);
    }
    public static void main(String[] args) {
        System.out.println(read(Map.of("X-Token", "sample")));
    }
}
'''
dto_safe = dto_bug.replace('return value.trim();', 'return value == null ? "" : value.trim();')
header_safe = header_bug.replace('TOKEN_HEADER = "X-Tokne"', 'TOKEN_HEADER = "X-Token"')
clean = '未发现阻塞问题'

def finding(root_id, invalid_range=False, omit_verification=False):
    if root_id == 'dto':
        relative, line = dto_path, 8
        title = 'dto 的条件访问未保护后续对 null 返回值的 trim'
        fields = [
            ('证据', '同方法中的 dto == null ? null : dto.name() 只保护 dto.name()；main 明确调用 name(null)，所以 value 为 null，下一行仍执行 value.trim()。'),
            ('影响', '该明确调用抛出 NullPointerException（NPE），不能按当前方法契约对缺失 dto 返回空字符串。'),
            ('修复建议', '在 trim 前处理 null 返回值，并保留非空名称的 trim 行为。'),
            ('验证方式', '分别调用 name(null)、name(new Dto(null)) 和 name(new Dto(" sample "))，应得到空字符串、空字符串和 sample。')]
    elif root_id == 'header':
        relative, line = header_path, 5
        title = 'TOKEN_HEADER 常量定义拼错了契约要求的键'
        fields = [
            ('证据', 'TOKEN_HEADER 定义为 X-Tokne，而 read 的内联契约要求读取 X-Token；main 明确以 Map.of("X-Token", "sample") 调用，get(TOKEN_HEADER) 得到 null。'),
            ('影响', '已经提供契约规定键的合法 map 无法读取到 sample，返回值违反当前方法契约。'),
            ('修复建议', '将 TOKEN_HEADER 常量值与 X-Token 契约统一，保留缺失键返回 null 的约定。'),
            ('验证方式', '以只含契约要求键且值为 sample 的 map 调用 read，应返回 sample；空 map 应返回 null，单含拼错键的 map 不应被接受为正确键。')]
    else:
        raise ValueError('Unknown root: ' + root_id)
    result = 'P2 ' + relative + ':' + str(999 if invalid_range else line) + ' - ' + title + '\n'
    for label, value in fields:
        if label != '验证方式' or not omit_verification:
            result += label + '：' + value + '\n'
    return result

mixed = finding('dto').rstrip('\n') + '\n\n' + finding('header')
# Two original functional P2 roots, not ten model-quality observations.
# The fixed sources, their main calls and suggested verification are data only:
# no Java compiler, target program, suggested fix, network or model is run.
cases = [
    dict(name='dto-valid', roots=('dto',), response=finding('dto')),
    dict(name='header-valid', roots=('header',), response=finding('header')),
    dict(name='mixed-valid', roots=('dto', 'header'), response=mixed),
    dict(name='dto-missing-verification', roots=('dto',), expected='invalid',
         response=finding('dto', omit_verification=True)),
    dict(name='header-missing-verification', roots=('header',), expected='invalid',
         response=finding('header', omit_verification=True)),
    dict(name='dto-line-999', roots=('dto',), expected='invalid-range',
         response=finding('dto', invalid_range=True)),
    dict(name='header-line-999', roots=('header',), expected='invalid-range',
         response=finding('header', invalid_range=True)),
    dict(name='canonical-clean', roots=('dto', 'header'), safe=True, expected='clean', response=clean),
    dict(name='strict-incomplete-only', roots=('dto', 'header'), safe=True, expected='clean', response=(
        '信息 ' + dto_path + ':1 - 提供完整的文件内容\n'
        '影响：无法确定代码是否符合项目规则\n修复建议：提供完整的文件内容\n验证方式：补充完整文件内容\n')),
    dict(name='mixed-length', roots=('dto', 'header'), expected='length', response=mixed),
]
request_by_material = {}

def run_case(spec):
    case = work / spec['name']
    repo, tmp, reports = case / 'repo', case / 'tmp', case / 'reports'
    repo.mkdir(parents=True, mode=0o700)
    tmp.mkdir(mode=0o700)
    # Fresh mapping, not a modified copy of os.environ: inherited repository,
    # index, objects, config injection, templates, proxies, BASH_ENV, Python
    # imports, model options and report/lock destinations cannot enter children.
    env = dict(PATH=str(fake) + ':/usr/bin:/bin:/usr/sbin:/sbin', HOME=os.environ.get('HOME', ''),
               LANG='C.UTF-8', LC_ALL='C.UTF-8', PYTHONDONTWRITEBYTECODE='1', PYTHONNOUSERSITE='1',
               GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null', GIT_CONFIG_NOSYSTEM='1',
               GIT_TERMINAL_PROMPT='0', GIT_NO_LAZY_FETCH='1', GIT_NO_REPLACE_OBJECTS='1',
               TMPDIR=str(tmp), GUARD_SCOPE_CASE=str(case),
               GUARD_SCOPE_DONE_REASON='length' if spec.get('expected') == 'length' else 'stop',
               LOCAL_REVIEW_DATA_DIR=str(case / 'data'), LOCAL_REVIEW_EXAMPLES_FILE='/dev/null',
               LOCAL_REVIEW_REPORT_DIR=str(reports), OLLAMA_HOST='http://127.0.0.1:11434',
               OLLAMA_REVIEW_MODEL='guard-scope-fake', OLLAMA_REVIEW_NUM_CTX='16384',
               OLLAMA_REVIEW_NUM_PREDICT='4096', OLLAMA_REVIEW_MAX_DIFF_BYTES='6000',
               OLLAMA_REVIEW_RETRY_ATTEMPTS='0', OLLAMA_REVIEW_JAVA_METHOD_SIDECAR='false',
               OLLAMA_REVIEW_LOCK_DIR=str(tmp / 'review.lock'),
               OLLAMA_REVIEW_TRACE_FILE=str(case / 'trace.tsv'),
               OLLAMA_REVIEW_TIMEOUT_SECONDS='60', OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS='60')
    git = [str(fake / 'git'), '-c', 'protocol.allow=never', '-c', 'core.hooksPath=/dev/null', '-C', str(repo)]
    setup_log = []
    def setup(arguments):
        result = subprocess.run(git + arguments, env=env, cwd=work, capture_output=True, timeout=30)
        setup_log.append(dict(argv=git + arguments, exit_code=result.returncode,
                              stdout=result.stdout.decode('utf-8', 'replace'), stderr=result.stderr.decode('utf-8', 'replace')))
        (case / 'setup.json').write_text(json.dumps(setup_log, ensure_ascii=False, indent=2), encoding='utf-8')
        if result.returncode:
            raise RuntimeError('Fixture setup failed; full evidence: ' + str(case / 'setup.json'))
    setup(['init', '-q', '--template=' + str(template)])
    setup(['-c', 'user.name=guard-scope-retention-test', '-c', 'user.email=test@example.invalid',
           '-c', 'commit.gpgSign=false', 'commit', '--allow-empty', '-qm', 'test：建立保护范围保留基线'])
    sources = {}
    for root_id in spec['roots']:
        relative = dto_path if root_id == 'dto' else header_path
        content = (dto_safe if spec.get('safe') else dto_bug) if root_id == 'dto' else (
            header_safe if spec.get('safe') else header_bug)
        source = repo / relative
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text(content, encoding='utf-8')
        source.chmod(0o600)
        sources[relative] = content
    response_bytes = spec['response'].encode('utf-8')
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
    expected, problems = spec.get('expected', 'finding'), []
    if counts != {'curl': 1, 'ollama': 1} or (case / 'unexpected-operation').exists():
        problems.append('expected one exact-tag show and one fake generate, no retry or other transport')
    request_path = case / 'request.json'
    request_sha = None
    if not request_path.is_file():
        problems.append('no captured request; inspect exit-code.txt and complete stderr.txt')
    else:
        body = request_path.read_bytes()
        request_sha = sha(body)
        prompt = json.loads(body)['prompt']
        for relative, content in sources.items():
            full_addition = '\n'.join('+' + line for line in content.splitlines()) + '\n'
            if '+++ b/' + relative not in prompt or prompt.count(full_addition) != 1:
                problems.append('complete source/comment contract missing or duplicated: ' + relative)
        if '人工确认的 Review 示例' in prompt or (expected != 'clean' and spec['response'].strip() in prompt):
            problems.append('fixed final response or disabled examples contaminated input')
        material_key = (spec['roots'], bool(spec.get('safe')))
        reference = request_by_material.setdefault(material_key, body)
        if body != reference:
            problems.append('same-source fixed-response controls must have byte-identical actual requests')
    envelope_path = case / 'fake-response.json'
    if not envelope_path.is_file() or json.loads(envelope_path.read_bytes())['response'].encode('utf-8') != response_bytes:
        problems.append('saved fake response did not preserve fixed final bytes')
    if expected == 'finding':
        if len(spec['roots']) == 1:
            exact_candidates = stdout == response_bytes
        else:
            # The existing severity sorter changes only separator blank lines.
            # Require every complete ordered paragraph byte-for-byte; never
            # delete, merge, rewrite or ignore an additional candidate.
            exact_candidates = re.split(rb'\n+(?=P2 )', stdout.rstrip(b'\n')) == re.split(
                rb'\n+(?=P2 )', response_bytes.rstrip(b'\n'))
        if status != 0 or not exact_candidates or clean in output:
            problems.append('concrete candidates must survive completely and never become clean')
    elif expected == 'clean':
        if status != 0 or stdout != (clean + '\n').encode('utf-8'):
            problems.append('canonical clean and strict pure incomplete-only explanation must normalize to clean')
    else:
        message = {'invalid': '模型输出缺少可验证', 'invalid-range': '模型报告的文件/行号超出当前文件',
                   'length': '模型输出因长度限制被截断'}[expected]
        if status != 1 or stdout or message not in diagnostic:
            problems.append('invalid/length response must fail closed with original diagnostic, not become clean')
    archives = list(reports.glob('review-*/final-candidates.jsonl'))
    if len(archives) != 1:
        problems.append('expected one isolated private original-final archive')
    else:
        archive = archives[0]
        records = [json.loads(line) for line in archive.read_text(encoding='utf-8').splitlines()]
        if len(records) != 1 or records[0]['final_text'].encode('utf-8') != response_bytes:
            problems.append('archive must preserve entire original final byte-for-byte, including excluded or invalid content')
        if archive.resolve().parent.parent != reports.resolve() or str(archive) not in diagnostic:
            problems.append('archive must stay in explicit private destination and announce its path')
        if stat.S_IMODE(archive.stat().st_mode) != 0o600 or stat.S_IMODE(archive.parent.stat().st_mode) != 0o700:
            problems.append('archive permissions not private')
        if 'NONFINAL_MUST_NOT_BE_EXPOSED' in archive.read_text(encoding='utf-8'):
            problems.append('non-final metadata leaked into original-final archive')
    if 'NONFINAL_MUST_NOT_BE_EXPOSED' in output + diagnostic:
        problems.append('non-final metadata leaked into stdout/stderr')
    row = dict(case=spec['name'], expected=expected, exit_code=status, request_sha256=request_sha,
               response_sha256=sha(response_bytes), stdout_sha256=sha(stdout),
               source_sha256={path: sha(content.encode('utf-8')) for path, content in sources.items()},
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
            row = dict(case=spec['name'], result='FAIL', problems=[str(exc)])
            rows.append(row)
            print('FAIL ' + spec['name'] + ': ' + str(exc), file=sys.stderr, flush=True)
    pins_after = {str(path): sha(path.read_bytes()) for path in [core] + helpers}
    failed = any(row['result'] != 'PASS' for row in rows) or pins_before != pins_after
    summary = dict(core_sha256=pins_before[str(core)], pins_before=pins_before, pins_after=pins_after,
                   core_and_helpers_unchanged=pins_before == pins_after, cases=rows,
                   passed=sum(row['result'] == 'PASS' for row in rows), total=len(rows),
                   source_execution=False, real_network_or_model_calls=0,
                   scope='Two-source guard-scope retention/protocol checks, not native model quality or P0/P1 gold.')
    (work / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')
    print('Guard scope retention: {}/{} passed'.format(summary['passed'], summary['total']), flush=True)
finally:
    # Preserve all original successes/failures and requests. Never clean user history.
    print('Guard scope regression artifacts: ' + str(work), file=sys.stderr, flush=True)
raise SystemExit(1 if failed else 0)
PY
