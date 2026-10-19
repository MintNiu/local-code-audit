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
work = Path(tempfile.mkdtemp(prefix='local-review-logging-words-')).resolve()
work.chmod(0o700)
fake = work / 'bin'
fake.mkdir(mode=0o700)
template = work / 'empty-git-template'
template.mkdir(mode=0o700)
relative = 'src/main/java/example/ReviewCase.java'
clean = '未发现阻塞问题'

# Closed child PATH, with caller-installed prerequisites explicitly linked.
# Neither transport substitute can connect to a model or the network.
for tool in ('python3', 'jq', 'rg', 'git'):
    executable = sys.executable if tool == 'python3' else shutil.which(tool)
    if not executable:
        raise SystemExit('Required regression tool unavailable: ' + tool)
    (fake / tool).symlink_to(Path(executable).resolve())
stub = r'''
import json, os, sys
from pathlib import Path
case = Path(os.environ['LOG_WORD_CASE'])
tool, args = Path(sys.argv[0]).name, sys.argv[1:]
with (case / 'calls.jsonl').open('a') as out:
    out.write(json.dumps({'tool': tool, 'args': args}) + '\n')
def require(condition):
    if not condition:
        (case / 'unexpected-operation').touch()
        raise SystemExit('Unexpected fixture operation; no network permitted')
if tool == 'ollama':
    require(args == ['show', 'logging-word-fake'])
    raise SystemExit(0)
require(tool == 'curl')
urls = [arg for arg in args if arg.startswith(('http://', 'https://'))]
require(urls == ['http://127.0.0.1:11434/api/generate'] and '--data-binary' in args)
argument = args[args.index('--data-binary') + 1]
require(argument.startswith('@'))
request_file = Path(argument[1:]).resolve()
request_file.relative_to((case / 'tmp').resolve())
request = json.loads(request_file.read_bytes())
require(request['model'] == 'logging-word-fake' and request['stream'] is False)
require('think' not in request and request['options']['num_ctx'] == 16384)
require(not (case / 'request.json').exists())
(case / 'request.json').write_bytes(request_file.read_bytes())
print(json.dumps({'response': (case / 'response.txt').read_text(encoding='utf-8'),
                  'done': True, 'done_reason': os.environ['LOG_WORD_DONE_REASON'],
                  'thinking': 'NONFINAL_MUST_NOT_BE_EXPOSED'}, ensure_ascii=False))
'''
for name in ('curl', 'ollama'):
    path = fake / name
    path.write_text('#!' + sys.executable + '\n' + stub, encoding='utf-8')
    path.chmod(0o700)


def java(contract, method):
    return ('package example;\n\nfinal class ReviewCase {\n'
            '    // ' + contract + '\n' + method + '}\n')


array_safe = java('values is non-null and non-empty; return its first element.',
                  '    int first(int[] values) {\n        return values[0];\n    }\n')
array_bug = array_safe.replace('values[0]', 'values[1]')
text_safe = java('text is non-null and non-empty; return its first UTF-16 code unit.',
                 '    char first(String text) {\n        return text.charAt(0);\n    }\n')
text_bug = text_safe.replace('charAt(0)', 'charAt(1)')
email_safe = java('Operational stdout is retained; personal email must not be written to it.',
                  '    void record(String email) {\n        System.out.println("recorded");\n    }\n')
email_bug = email_safe.replace('System.out.println("recorded")', 'System.out.println(email)')
name_safe = java('Operational stdout is retained; personal names must not be written to it.',
                 '    void record(String fullName) {\n        System.out.println("recorded");\n    }\n')
name_bug = name_safe.replace('System.out.println("recorded")', 'System.out.println(fullName)')

# These are retention/protocol tests, not independent model-quality samples.
# The two array responses intentionally vary field wording for the same root.
# The generic missing-logging control is deliberately not a proven defect:
# retaining noise is a visibility policy, not a model-quality success.
cases = [
    dict(name='array-evidence', before=array_safe, after=array_bug, sink='        return values[1];',
         title='单元素数组访问越界',
         evidence='values 长度为 1 时仍访问下标 1；没有日志也不改变该越界事实。',
         impact='合法单元素输入抛出异常，不能返回第一个元素。',
         fix='使用下标 0。', verify='断言 first(new int[]{7}) 返回 7。'),
    dict(name='string-impact', before=text_safe, after=text_bug, sink='        return text.charAt(1);',
         title='单字符文本访问越界', evidence='合法文本 a 只有下标 0，当前访问下标 1。',
         impact='合法单字符输入抛出异常；日志记录不能替代契约要求的返回值。',
         fix='使用 charAt(0)。', verify='断言 first("a") 返回 a。'),
    dict(name='array-fix', before=array_safe, after=array_bug, sink='        return values[1];',
         title='首元素读取使用了错误下标', evidence='当前返回 values[1]，不是契约要求的 values[0]。',
         impact='单元素数组越界，多元素数组返回错误元素。',
         fix='改用下标 0；不要把缺少日志当作这个索引缺陷的修复。',
         verify='分别断言单元素和两个不同元素数组的首元素。'),
    dict(name='email-verification', before=email_safe, after=email_bug, sink='        System.out.println(email);',
         title='个人邮箱直接进入持久输出', evidence='record 直接把 email 写到契约规定会保留的 stdout。',
         impact='邮箱被持久保留，违反明确的个人信息输出限制。',
         fix='不要输出个人邮箱，保留不含个人数据的事件说明。',
         verify='捕获日志记录，断言调用 record 后不包含传入的邮箱。'),
    dict(name='name-information', before=name_safe, after=name_bug, sink='        System.out.println(fullName);',
         severity='信息', title='个人姓名进入不应接收个人信息的输出',
         evidence='System.out.println(fullName) 将姓名送入会保留的日志记录。',
         impact='违反源码明确的姓名不得进入持久 stdout 的约束。',
         fix='停止输出姓名，只保留不含个人信息的事件说明。',
         verify='捕获标准输出并断言不含传入的姓名。'),
    dict(name='generic-missing-logging-visible', before=java('Return the first element of a non-empty array.',
         '    int first(int[] values) { return values[0]; }\n'), after=array_safe,
         sink='        return values[0];', expected='visible-noise', severity='信息',
         title='缺少日志', evidence='函数没有日志。', impact='排查调用需要额外信息。',
         fix='补日志。', verify='观察调用。'),
    dict(name='exact-clean', before=java('Return the first element of a non-empty array.',
         '    int first(int[] values) { return values[0]; }\n'), after=array_safe, expected='clean'),
    dict(name='missing-field-with-logging', before=array_safe, after=array_bug,
         sink='        return values[1];', expected='invalid', title='单元素数组访问越界',
         evidence='values[1] 越界；日志记录不能改变该索引事实。',
         impact='合法单元素输入抛出异常。', fix='使用下标 0。'),
    dict(name='length-with-logging', before=text_safe, after=text_bug,
         sink='        return text.charAt(1);', expected='length', title='单字符文本访问越界',
         evidence='charAt(1) 在单字符输入越界，日志记录不改变该事实。',
         impact='合法输入不能得到首字符。', fix='使用 charAt(0)。',
         verify='断言单字符输入的返回值。'),
    dict(name='invalid-range-with-logging', before=array_safe, after=array_bug,
         sink='        return values[1];', line=999, expected='invalid-range', title='单元素数组访问越界',
         evidence='values[1] 越界；日志记录不能改变该索引事实。',
         impact='合法单元素输入抛出异常。', fix='使用下标 0。',
         verify='断言单元素数组返回首元素。'),
]


def run_case(spec):
    case = work / spec['name']
    repo, tmp = case / 'repo', case / 'tmp'
    repo.mkdir(parents=True, mode=0o700)
    tmp.mkdir(mode=0o700)
    reports = case / 'reports'
    # Do not inherit Git/config/template, proxy, model or destination settings.
    # HOME is retained, not repurposed; outputs and locks are explicitly local.
    env = dict(PATH=str(fake) + ':/usr/bin:/bin:/usr/sbin:/sbin',
               HOME=os.environ.get('HOME', ''), LANG='C.UTF-8', LC_ALL='C.UTF-8',
               PYTHONDONTWRITEBYTECODE='1', GIT_CONFIG_GLOBAL='/dev/null',
               GIT_CONFIG_SYSTEM='/dev/null', GIT_CONFIG_NOSYSTEM='1',
               GIT_TERMINAL_PROMPT='0', GIT_NO_LAZY_FETCH='1', GIT_NO_REPLACE_OBJECTS='1',
               TMPDIR=str(tmp), LOG_WORD_CASE=str(case),
               LOG_WORD_DONE_REASON='length' if spec.get('expected') == 'length' else 'stop',
               LOCAL_REVIEW_DATA_DIR=str(case / 'data'), LOCAL_REVIEW_EXAMPLES_FILE='/dev/null',
               LOCAL_REVIEW_REPORT_DIR=str(reports), OLLAMA_HOST='http://127.0.0.1:11434',
               OLLAMA_REVIEW_MODEL='logging-word-fake', OLLAMA_REVIEW_NUM_CTX='16384',
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
    setup(['-c', 'user.name=logging-retention-test', '-c', 'user.email=test@example.invalid',
           '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgSign=false',
           'commit', '-qm', 'test：建立日志措辞保留基线'])
    source.write_text(spec['after'], encoding='utf-8')
    expected = spec.get('expected', 'finding')
    response = clean
    if expected != 'clean':
        line = spec.get('line', spec['after'].splitlines().index(spec['sink']) + 1)
        marker = 'LOG_WORD_' + spec['name'].replace('-', '_').upper()
        response = (spec.get('severity', 'P2') + ' ' + relative + ':' + str(line) + ' - ' + marker + '：' + spec['title'] + '\n'
                    '证据：' + spec['evidence'] + '\n影响：' + spec['impact'] + '\n'
                    '修复建议：' + spec['fix'] + '\n')
        if 'verify' in spec:
            response += '验证方式：' + spec['verify'] + '\n'
    response_bytes = response.encode('utf-8')
    (case / 'response.txt').write_bytes(response_bytes)
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
    if expected in ('finding', 'visible-noise') and (status != 0 or stdout != response_bytes or clean in output):
        problems.append('complete candidate must remain visible byte-for-byte, never become clean')
    if expected == 'clean' and (status != 0 or output.strip() != clean):
        problems.append('canonical clean must remain clean')
    if expected in ('invalid', 'length', 'invalid-range'):
        message = {'invalid': '模型输出缺少可验证', 'length': '模型输出因长度限制被截断',
                   'invalid-range': '模型报告的文件/行号超出当前文件'}[expected]
        if status != 1 or stdout or message not in diagnostic:
            problems.append('invalid/incomplete response must fail closed, not be filtered to clean')
    archives = list(reports.glob('review-*/final-candidates.jsonl'))
    if len(archives) != 1:
        problems.append('expected exactly one private candidate archive')
    else:
        archive = archives[0]
        records = [json.loads(s) for s in archive.read_text().splitlines()]
        if len(records) != 1 or records[0]['final_text'].encode('utf-8') != response_bytes:
            problems.append('archive must preserve the complete original final byte-for-byte')
        if archive.resolve().parent.parent != reports.resolve() or str(archive) not in diagnostic:
            problems.append('archive destination must be isolated and explicitly announced')
        if stat.S_IMODE(archive.stat().st_mode) != 0o600 or stat.S_IMODE(archive.parent.stat().st_mode) != 0o700:
            problems.append('archive permissions must remain private')
        if 'NONFINAL_MUST_NOT_BE_EXPOSED' in archive.read_text():
            problems.append('non-final metadata entered candidate archive')
    if 'NONFINAL_MUST_NOT_BE_EXPOSED' in output + diagnostic:
        problems.append('non-final metadata entered stdout/stderr')
    row = dict(case=spec['name'], expected=expected, exit_code=status,
               source_supported_retention_case=expected == 'finding',
               fake_curl_calls=counts['curl'], fake_ollama_calls=counts['ollama'],
               response_sha256=hashlib.sha256(response_bytes).hexdigest(),
               stdout_sha256=hashlib.sha256(stdout).hexdigest(),
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
                   real_network_or_model_calls=0, source_execution=False,
                   scope='Output retention/protocol only; not model-quality or independent-root scoring.')
    (work / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    print('Logging word retention: {}/{} passed'.format(summary['passed'], summary['total']), flush=True)
finally:
    if failed or os.environ.get('LOG_WORD_KEEP_ARTIFACTS') == '1':
        print('Logging word regression artifacts: ' + str(work), file=sys.stderr, flush=True)
    else:
        shutil.rmtree(work)
raise SystemExit(1 if failed else 0)
PY
