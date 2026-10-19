#!/usr/bin/env bash
set -euo pipefail
python3 -I -B - "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" "${BASH_SOURCE[0]}" "$@" <<'PY'
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

parser = argparse.ArgumentParser(description='Controlled Java-string recognition units; never execute target Java.',
                                 allow_abbrev=False)
parser.add_argument('--helper', help='Absolute path to a trusted helper snapshot; default is the repository helper.')
args = parser.parse_args(sys.argv[3:])
root, test_path = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
helper_path = Path(args.helper) if args.helper else root / 'bin/java-lock-helper-scope.py'
if not helper_path.is_absolute() or not helper_path.is_file():
    raise SystemExit('--helper must be an existing absolute trusted Python helper path')
helper_path = helper_path.resolve()
pin_paths = (helper_path, test_path)
pins_before = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in pin_paths}
spec = importlib.util.spec_from_file_location('_lock_scope_units', str(helper_path))
if spec is None or spec.loader is None:
    raise SystemExit('Cannot import trusted helper snapshot')
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)

field = '    private final java.util.concurrent.locks.ReentrantLock lock = new java.util.concurrent.locks.ReentrantLock();\n'
other_field = '    private final java.util.concurrent.locks.ReentrantLock other = new java.util.concurrent.locks.ReentrantLock();\n'
work_body = '''        lock.lock();
        try {
            visits++;
        } finally {
            release();
        }
'''
leaf = '''
    private void release() {
        lock.unlock();
    }
'''

def fixture(body=work_body, release=leaf, declaration='class LockScope',
            fields=field, params='', throws='', extra=''):
    return ('package example;\n\n' + declaration + ' {\n' + fields +
            '    private int visits;\n\n    void work(' + params + ')' + throws +
            ' {\n' + body + '    }\n' + release + extra + '}\n')

ordinary = fixture()
cases = []

def add(name, source, expected=False, marker='lock.lock();', receiver='lock', line=None):
    # Anchor each unit to its actual acquisition before asking the recognizer;
    # unsupported variants must not all pass just because the line was wrong.
    if line is None:
        line = source.count('\n', 0, source.index(marker)) + 1
    cases.append(dict(name=name, source=source, expected=expected, line=line, receiver=receiver))

# These are fixed source/lexical controls, not independent defect roots, Java
# executions, native model observations, P0/P1 gold or holdout samples.
add('private-leaf', ordinary, True)
add('this-multiline-comments', fixture(body='''        this.lock.lock();
        try {
            visits++;
        } finally {
            this.release(
                /* no arguments */
            );
        }
''', release='''
    private void release() {
        this.lock
            .unlock(
                /* same field */
            );
    }
'''), True)
add('interruptible', fixture(body=work_body.replace('lock.lock();', 'lock.lockInterruptibly();'),
                             throws=' throws InterruptedException'),
    True, marker='lock.lockInterruptibly();')
add('masked-unicode-comments-and-literals', fixture(body='''        lock.lock();
        try {
            // 注释中的 class Hidden 和 throw 不属于代码。
            String note = "lock.lock(); class NotAClass {";
            visits++;
        } finally {
            release();
        }
''', release='''
    private void release() {
        /* 注释中的 throw new IllegalStateException(); */
        lock.unlock();
    }
'''), True)
add('lf-tab-formfeed-whitespace', ordinary.replace('    ', '\t').replace('finally', '\ffinally'), True)

add('missing-helper', fixture(release=''))
add('different-release-field', fixture(fields=field + other_field,
                                       release=leaf.replace('lock.unlock();', 'other.unlock();')))
add('helper-not-called', fixture(body=work_body.replace('release();', 'visits += 0;')))
add('normal-path-release-only', fixture(body='''        lock.lock();
        try {
            visits++;
            release();
        } finally {
            visits += 0;
        }
'''))
add('conditional-finally', fixture(body=work_body.replace('release();', 'if (visits > 0) release();')))
add('throw-before-unlock', fixture(release='''
    private void release() {
        throwBeforeRelease();
        lock.unlock();
    }

    private void throwBeforeRelease() {
        throw new IllegalStateException();
    }
'''))
add('parameter-shadows-field', fixture(params='java.util.concurrent.locks.ReentrantLock lock'))
add('local-shadows-field', fixture(body='''        java.util.concurrent.locks.ReentrantLock lock =
                new java.util.concurrent.locks.ReentrantLock();
''' + work_body))
add('nonprivate-helper', fixture(release=leaf.replace('private void release()', 'void release()')))
add('static-helper', fixture(release=leaf.replace('private void release()', 'private static void release()')))
add('helper-has-parameter', fixture(body=work_body.replace('release();', 'release(1);'),
                                   release=leaf.replace('release()', 'release(int ignored)')))
add('nonprivate-field', fixture(fields=field.replace('private final', 'final')))
add('nonfinal-field', fixture(fields=field.replace('private final', 'private')))
add('static-field', fixture(fields=field.replace('private final', 'private static final')))
add('simple-type-is-unsupported', fixture(fields=field.replace('java.util.concurrent.locks.ReentrantLock',
                                                              'ReentrantLock')))
add('custom-qualified-type', fixture(fields=field.replace('java.util.concurrent.locks.ReentrantLock',
                                                         'example.ReentrantLock')))
add('unqualified-constructor', fixture(fields=field.replace('new java.util.concurrent.locks.ReentrantLock()',
                                                           'new ReentrantLock()')))
add('anonymous-lock-subclass', fixture(fields=field.replace('ReentrantLock();', 'ReentrantLock() {};')))
add('class-inheritance', fixture(declaration='class LockScope extends Parent'))
add('nested-class', fixture(extra='\n    static class Nested {}\n'))
add('second-top-level-class', ordinary + '\nclass Another {}\n')
add('raw-unicode-escape', fixture(release=leaf.replace('lock.unlock();',
                                                     r'// \u000aif (visits > 0) throw new IllegalStateException();' +
                                                     '\n        lock.unlock();')))
add('text-block', fixture(body='''        lock.lock();
        try {
            String note = """
                release();
                """;
        } finally {
            release();
        }
'''))
add('unclosed-string', fixture(release=leaf.replace('lock.unlock();',
                                                   'String note = "unfinished\n        lock.unlock();')))
add('unclosed-character', fixture(release=leaf.replace('lock.unlock();',
                                                      "char note = 'x\n        lock.unlock();")))
add('unclosed-block-comment', ordinary + '\n/* unfinished')
add('orphan-comment-close', ordinary.replace('class LockScope', '*/ class LockScope'))
add('unbalanced-brace', ordinary[:-2])
add('unbalanced-parenthesis', fixture(release=leaf.replace('unlock();', 'unlock(;')))
add('unbalanced-bracket', fixture(body=work_body.replace('visits++;', 'int[] values = new int[1;')))
acquisition_line = ordinary.count('\n', 0, ordinary.index('lock.lock();')) + 1
add('wrong-candidate-line', ordinary, line=acquisition_line + 1)
add('zero-candidate-line', ordinary, line=0)
add('wrong-receiver', ordinary, receiver='other')
add('dotted-receiver-unsupported', ordinary, receiver='this.lock')
add('multiple-acquisitions-in-target', fixture(body=work_body.replace('lock.lock();',
                                                                    'lock.lock();\n        lock.lock();')))
add('extra-method-acquires-field', fixture(body=work_body.replace('visits++;', 'takeAgain();'), extra='''
    private void takeAgain() {
        lock.lock();
    }
'''))
add('extra-method-reads-field', fixture(extra='''
    private void observe() {
        boolean held = lock.isHeldByCurrentThread();
    }
'''))
add('other-field-aliases-lock', fixture(fields=field +
                                       '    private final java.util.concurrent.locks.ReentrantLock alias = lock;\n'))
add('statement-between-acquire-and-try', fixture(body=work_body.replace('lock.lock();',
                                                                      'lock.lock();\n        visits++;')))
add('try-with-resources-unsupported', fixture(body=work_body.replace('try {',
                                                                   'try (AutoCloseable ignored = null) {'),
                                             throws=' throws Exception'))
add('statement-after-finally', fixture(body=work_body + '        visits++;\n'))
add('release-only-in-comment', fixture(body=work_body.replace('release();', '// release();')))
add('release-only-in-literal', fixture(body=work_body.replace('release();', 'String note = "release();";')))
# Every CR is deliberately unsupported, including otherwise valid CRLF. In
# Java a bare CR terminates a line comment; LF-only masking could hide a throw.
add('crlf-source', ordinary.replace('\n', '\r\n'))
add('cr-comment-hides-throw', fixture(release=leaf.replace('lock.unlock();',
    '// comment ends at CR\rif (visits > 0) throw new IllegalStateException();\n        lock.unlock();')))
add('unicode-code-identifier', ordinary.replace('visits', 'visités'))
add('dollar-helper-identifier', ordinary.replace('release', 'release$'))
add('nul-source', ordinary + '\x00')

gate = '''package example;

class GateScope {
    private final java.util.concurrent.locks.ReentrantLock gate = new java.util.concurrent.locks.ReentrantLock();

    void work() {
        gate.lock();
        try {
        } finally {
            release();
        }
    }

    private void release() {
        gate.unlock();
    }
}
'''
# Java may ignore these identifier characters. The receiver argument remains
# the valid ASCII name "gate", and each line is bound to the actual acquisition:
# these are not trivially rejected malformed receiver/line controls.
add('gate-private-leaf-control', gate, True, marker='gate.lock();', receiver='gate')
add('unicode-ignorable-parameter', gate.replace('void work()',
    'void work(java.util.concurrent.locks.ReentrantLock ga\u200cte)'),
    marker='gate.lock();', receiver='gate')
add('unicode-ignorable-other-member', gate.replace('try {\n', 'try {\n            takeAgain();\n').replace('\n}\n',
    '\n    private void takeAgain() { ga\u200cte.lock(); }\n}\n'),
    marker='gate.lock();', receiver='gate')
add('ascii-control-parameter', gate.replace('void work()',
    'void work(java.util.concurrent.locks.ReentrantLock ga\x01te)'),
    marker='gate.lock();', receiver='gate')
add('ascii-control-other-member', gate.replace('try {\n', 'try {\n            takeAgain();\n').replace('\n}\n',
    '\n    private void takeAgain() { ga\x01te.lock(); }\n}\n'),
    marker='gate.lock();', receiver='gate')
add('del-control-parameter', gate.replace('void work()',
    'void work(java.util.concurrent.locks.ReentrantLock ga\x7fte)'),
    marker='gate.lock();', receiver='gate')

passed = 0
for case in cases:
    try:
        actual = helper.proves_release(case['source'], case['line'], case['receiver'])
        error = None
    except Exception as exc:
        actual, error = None, type(exc).__name__ + ': ' + str(exc)
    ok = actual is case['expected'] and error is None
    passed += int(ok)
    print(('PASS ' if ok else 'FAIL ') + case['name'] +
          ' expected=' + ('certified' if case['expected'] else 'not-certified') +
          ' line=' + str(case['line']))
    if not ok:
        # JSON escaping makes hidden CR, Unicode and ASCII controls visible
        # without writing raw terminal controls or executing the source.
        print(json.dumps(dict(case=case['name'], actual=actual, error=error,
                              receiver=case['receiver'], line=case['line'],
                              source=case['source']), ensure_ascii=True), file=sys.stderr)

pins_after = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in pin_paths}
unchanged = pins_before == pins_after
print('Java lock helper scope units: {}/{} passed; helper/test unchanged={}'.format(
    passed, len(cases), str(unchanged).lower()))
print('Scope: controlled recognition units only; no Java, model, network, root-count or quality result.')
if not unchanged:
    print(json.dumps(dict(before=pins_before, after=pins_after), ensure_ascii=True), file=sys.stderr)
raise SystemExit(0 if passed == len(cases) and unchanged else 1)
PY
