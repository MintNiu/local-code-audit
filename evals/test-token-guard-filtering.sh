#!/usr/bin/env bash
set -euo pipefail
umask 077
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 -I -B - "$repo_root" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile

root = Path(sys.argv[1]).resolve()
core = root / 'bin/local-review.sh'
core_hash = hashlib.sha256(core.read_bytes()).hexdigest()
work = Path(tempfile.mkdtemp(prefix='local-review-token-guard-')).resolve()
work.chmod(0o700)
fake = work / 'bin'
fake.mkdir(mode=0o700)
template = work / 'empty-git-template'
template.mkdir(mode=0o700)
relative = 'src/main/java/example/TokenSize.java'
clean = '未发现阻塞问题'

# Closed child PATH: caller-installed dependencies are explicit; curl/ollama
# below only read/write fixture files and have no network implementation.
for tool in ('python3', 'jq', 'rg', 'git'):
    executable = sys.executable if tool == 'python3' else shutil.which(tool)
    if not executable:
        raise SystemExit('Required regression tool unavailable: ' + tool)
    (fake / tool).symlink_to(Path(executable).resolve())
stub = r'''
import json, os, sys
from pathlib import Path
case = Path(os.environ['TOKEN_GUARD_CASE'])
tool, args = Path(sys.argv[0]).name, sys.argv[1:]
with (case / 'calls.jsonl').open('a') as out:
    out.write(json.dumps({'tool': tool, 'args': args}) + '\n')
def require(condition):
    if not condition:
        (case / 'unexpected-operation').touch()
        raise SystemExit('Unexpected fixture operation; no network permitted')
if tool == 'ollama':
    require(args == ['show', 'token-guard-fake'])
    raise SystemExit(0)
require(tool == 'curl')
urls = [arg for arg in args if arg.startswith(('http://', 'https://'))]
require(urls == ['http://127.0.0.1:11434/api/generate'] and '--data-binary' in args)
argument = args[args.index('--data-binary') + 1]
require(argument.startswith('@'))
request_file = Path(argument[1:]).resolve()
request_file.relative_to((case / 'tmp').resolve())
request = json.loads(request_file.read_bytes())
require(request['model'] == 'token-guard-fake' and request['stream'] is False)
require('think' not in request and request['options']['num_ctx'] == 16384)
require(not (case / 'request.json').exists())
(case / 'request.json').write_bytes(request_file.read_bytes())
response = (case / 'response.txt').read_text(encoding='utf-8')
print(json.dumps({'response': response, 'done': True,
                  'done_reason': os.environ['TOKEN_GUARD_DONE_REASON'],
                  'thinking': 'NONFINAL_MUST_NOT_BE_EXPOSED'}, ensure_ascii=False))
'''
for name in ('curl', 'ollama'):
    path = fake / name
    path.write_text('#!' + sys.executable + '\n' + stub, encoding='utf-8')
    path.chmod(0o700)


def java(body):
    return ('package example;\n\nfinal class TokenSize {\n'
            '    // size accepts null and must return 0 for it.\n' + body + '}\n')


guarded = java('    int size(String token) {\n'
               '        if (token != null && !token.isBlank()) return token.length();\n'
               '        return 0;\n    }\n')
unguarded = java('    int size(String token) {\n'
                 '        return token.length();\n    }\n')
other_guard = ('    boolean usable(String token) {\n'
               '        return token != null && !token.isBlank();\n    }\n')
cases = [
    dict(name='deleted-guard', before=guarded, after=unguarded),
    dict(name='other-method', before=java('    int size(String token) { return 0; }\n' + other_guard),
         after=java('    int size(String token) {\n        return token.length();\n    }\n' + other_guard)),
    dict(name='comment-and-string', before=java('    int size(String token) { return 0; }\n'),
         after=java('    int size(String token) {\n'
                    '        // token != null && !token.isBlank() is not executable.\n'
                    '        String note = "token != null && !token.isBlank()";\n'
                    '        return token.length();\n    }\n')),
    dict(name='guard-after-dereference', before=java('    int size(String token) { return 0; }\n'),
         after=java('    int size(String token) {\n        int size = token.length();\n'
                    '        if (token != null && !token.isBlank()) return size;\n'
                    '        return 0;\n    }\n'), sink='        int size = token.length();'),
    dict(name='different-current-token', before=java(other_guard), variable='currentToken',
         after=java('    int size(String currentToken) {\n'
                    '        return currentToken.length();\n    }\n' + other_guard)),
    dict(name='exact-clean', before=java('    int size(String token) { return 0; }\n'),
         after=guarded, expected='clean'),
    dict(name='missing-verification-field', before=java('    int size(String token) { return 0; }\n'),
         after=unguarded, expected='invalid'),
    dict(name='length-incomplete', before=guarded, after=unguarded, expected='length'),
]


def run_case(spec):
    case = work / spec['name']
    repo, tmp = case / 'repo', case / 'tmp'
    repo.mkdir(parents=True, mode=0o700)
    tmp.mkdir(mode=0o700)
    reports = case / 'reports'
    # Fresh environment excludes inherited Git index/object/config/template
    # injection, model settings, proxies and report destinations. HOME is not
    # repurposed; all data/report/lock writes have explicit private paths.
    env = dict(PATH=str(fake) + ':/usr/bin:/bin:/usr/sbin:/sbin',
               HOME=os.environ.get('HOME', ''), LANG='C.UTF-8', LC_ALL='C.UTF-8',
               PYTHONDONTWRITEBYTECODE='1', GIT_CONFIG_GLOBAL='/dev/null',
               GIT_CONFIG_SYSTEM='/dev/null', GIT_CONFIG_NOSYSTEM='1',
               GIT_TERMINAL_PROMPT='0', GIT_NO_LAZY_FETCH='1', GIT_NO_REPLACE_OBJECTS='1',
               TMPDIR=str(tmp), TOKEN_GUARD_CASE=str(case),
               TOKEN_GUARD_DONE_REASON='length' if spec.get('expected') == 'length' else 'stop',
               LOCAL_REVIEW_DATA_DIR=str(case / 'data'), LOCAL_REVIEW_EXAMPLES_FILE='/dev/null',
               LOCAL_REVIEW_REPORT_DIR=str(reports), OLLAMA_HOST='http://127.0.0.1:11434',
               OLLAMA_REVIEW_MODEL='token-guard-fake', OLLAMA_REVIEW_NUM_CTX='16384',
               OLLAMA_REVIEW_NUM_PREDICT='4096', OLLAMA_REVIEW_MAX_DIFF_BYTES='6000',
               OLLAMA_REVIEW_RETRY_ATTEMPTS='0', OLLAMA_REVIEW_JAVA_METHOD_SIDECAR='false',
               OLLAMA_REVIEW_LOCK_DIR=str(tmp / 'review.lock'),
               OLLAMA_REVIEW_TRACE_FILE=str(case / 'trace.tsv'),
               OLLAMA_REVIEW_TIMEOUT_SECONDS='60', OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS='60')
    git = [str(fake / 'git'), '-c', 'protocol.allow=never', '-C', str(repo)]
    setup_log = []

    def setup(args):
        result = subprocess.run(git + args, env=env, cwd=work, capture_output=True, timeout=30)
        setup_log.append(dict(argv=git + args, exit_code=result.returncode,
                              stdout=result.stdout.decode('utf-8', 'replace'),
                              stderr=result.stderr.decode('utf-8', 'replace')))
        (case / 'setup.json').write_text(json.dumps(setup_log, ensure_ascii=False, indent=2))
        if result.returncode:
            raise RuntimeError('Fixture Git setup failed; see ' + str(case / 'setup.json'))

    setup(['init', '-q', '--template=' + str(template)])
    source = repo / relative
    source.parent.mkdir(parents=True)
    source.write_text(spec['before'], encoding='utf-8')
    setup(['add', '.'])
    setup(['-c', 'user.name=token-guard-test', '-c', 'user.email=test@example.invalid',
           '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgSign=false',
           'commit', '-qm', 'test：建立空值保护边界基线'])
    source.write_text(spec['after'], encoding='utf-8')
    variable = spec.get('variable', 'token')
    sink = spec.get('sink', '        return ' + variable + '.length();')
    expected = spec.get('expected', 'finding')
    line = spec['after'].splitlines().index(sink) + 1 if expected != 'clean' else 6
    marker = 'TOKEN_GUARD_' + spec['name'].replace('-', '_').upper()
    response = ('P2 ' + relative + ':' + str(line) + ' - ' + marker + '：null 输入触发空指针\n'
                '证据：size 对 ' + variable + ' 解引用时没有前置 null 保护。\n'
                '影响：契约允许的 null 输入抛出空指针异常，而不是返回 0。\n'
                '修复建议：在解引用之前按契约处理 null。\n'
                '验证方式：断言 size(null) 返回 0，普通非空文本返回长度。\n')
    if expected == 'clean':
        response = clean
    elif expected == 'invalid':
        response = response.split('验证方式：')[0]
    (case / 'response.txt').write_text(response, encoding='utf-8')
    argv = ['/bin/bash', str(core), '--repo', str(repo)]
    (case / 'command.json').write_text(json.dumps(dict(argv=argv, cwd=str(work), env=env),
                                                  ensure_ascii=False, indent=2))
    try:
        result = subprocess.run(argv, env=env, cwd=work, capture_output=True, timeout=90)
        status, stdout, stderr = result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired as exc:
        status, stdout, stderr = 124, exc.stdout or b'', exc.stderr or b''
    (case / 'stdout.txt').write_bytes(stdout)
    (case / 'stderr.txt').write_bytes(stderr)
    (case / 'exit-code.txt').write_text(str(status) + '\n')
    calls_file = case / 'calls.jsonl'
    calls = [json.loads(s) for s in calls_file.read_text().splitlines()] if calls_file.exists() else []
    counts = {tool: sum(c['tool'] == tool for c in calls) for tool in ('curl', 'ollama')}
    output, diagnostic = stdout.decode('utf-8', 'replace'), stderr.decode('utf-8', 'replace')
    problems = []
    if counts != {'curl': 1, 'ollama': 1} or (case / 'unexpected-operation').exists():
        problems.append('expected exactly one fake generate and one exact-tag model probe')
    request_file = case / 'request.json'
    if not request_file.exists() or '+++ b/' + relative not in json.loads(request_file.read_bytes())['prompt']:
        problems.append('actual request did not include target diff')
    if expected == 'finding' and (status != 0 or output != response or clean in output):
        problems.append('concrete candidate must survive unchanged, never become clean')
    if expected == 'clean' and (status != 0 or output.strip() != clean):
        problems.append('canonical clean must remain clean')
    if expected in ('invalid', 'length'):
        message = '模型输出缺少可验证' if expected == 'invalid' else '模型输出因长度限制被截断'
        if status != 1 or stdout or message not in diagnostic:
            problems.append('incomplete/invalid response must fail closed with its diagnostic')
    archives = list(reports.glob('review-*/final-candidates.jsonl'))
    if len(archives) != 1:
        problems.append('expected exactly one private candidate archive')
    else:
        archive = archives[0]
        records = [json.loads(s) for s in archive.read_text().splitlines()]
        if len(records) != 1 or records[0]['final_text'] != response:
            problems.append('archive must preserve the complete original candidate verbatim')
        if archive.resolve().parent.parent != reports.resolve() or str(archive) not in diagnostic:
            problems.append('archive destination must be isolated and explicitly announced')
        if stat.S_IMODE(archive.stat().st_mode) != 0o600 or stat.S_IMODE(archive.parent.stat().st_mode) != 0o700:
            problems.append('archive permissions must remain private')
        if 'NONFINAL_MUST_NOT_BE_EXPOSED' in archive.read_text():
            problems.append('non-final metadata entered candidate archive')
    if 'NONFINAL_MUST_NOT_BE_EXPOSED' in output + diagnostic:
        problems.append('non-final metadata entered stdout/stderr')
    row = dict(case=spec['name'], expected=expected, exit_code=status,
               fake_curl_calls=counts['curl'], fake_ollama_calls=counts['ollama'],
               result='FAIL' if problems else 'PASS', problems=problems)
    (case / 'assessment.json').write_text(json.dumps(row, ensure_ascii=False, indent=2))
    print('{result} {case} exit={exit_code} curl={fake_curl_calls} ollama={fake_ollama_calls}'.format(**row), flush=True)
    if problems:
        print('Full evidence: ' + str(case) + '\n' + '\n'.join(problems), file=sys.stderr, flush=True)
    return row


failed = True
try:
    rows = []
    for spec in cases:
        try:
            rows.append(run_case(spec))
        except Exception as exc:
            row = dict(case=spec['name'], result='FAIL', problems=[str(exc)])
            rows.append(row)
            print('FAIL ' + spec['name'] + ': ' + str(exc), file=sys.stderr, flush=True)
    after_hash = hashlib.sha256(core.read_bytes()).hexdigest()
    failed = any(row['result'] == 'FAIL' for row in rows) or after_hash != core_hash
    summary = dict(core_sha256_before=core_hash, core_sha256_after=after_hash,
                   core_unchanged=after_hash == core_hash, cases=rows,
                   passed=sum(row['result'] == 'PASS' for row in rows), total=len(rows),
                   real_network_or_model_calls=0, source_execution=False)
    (work / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    print('Token guard filtering: {}/{} passed'.format(summary['passed'], summary['total']), flush=True)
finally:
    if failed or os.environ.get('TOKEN_GUARD_KEEP_ARTIFACTS') == '1':
        print('Token guard regression artifacts: ' + str(work), file=sys.stderr, flush=True)
    else:
        shutil.rmtree(work)
raise SystemExit(1 if failed else 0)
PY
