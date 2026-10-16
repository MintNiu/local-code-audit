#!/usr/bin/env python3
"""Persist already sanitized/redacted final text, never raw Ollama envelopes."""
import json
import os
from pathlib import PurePosixPath
import stat
import sys
import uuid


def directory(path, create=False):
    """Walk with directory descriptors: never follow links or replace user paths."""
    if not path.startswith('/') or any(ord(c) < 32 or ord(c) == 127 for c in path):
        raise ValueError('report directory must be an absolute path without controls')
    parts = PurePosixPath(path).parts[1:]
    if '..' in parts or not parts:
        raise ValueError('unsafe report directory')
    descriptor = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in parts:
            if create:
                try:
                    os.mkdir(part, 0o700, dir_fd=descriptor)
                except FileExistsError:
                    pass
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
            info = os.fstat(descriptor)
            # Root-owned sticky temp ancestors are safe for unique private children.
            trusted_temp = info.st_uid == 0 and bool(info.st_mode & stat.S_ISVTX)
            if info.st_uid not in (0, os.getuid()) or (info.st_mode & 0o022 and not trusted_temp):
                raise ValueError('untrusted report directory ancestor')
        info = os.fstat(descriptor)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError('report directory must be owned by this user with mode 0700')
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def create_report(root):
    descriptor = directory(root, create=True)
    try:
        name = 'review-' + uuid.uuid4().hex
        os.mkdir(name, 0o700, dir_fd=descriptor)
        child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
        try:
            output = os.open('final-candidates.jsonl', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=child)
            os.close(output)
        finally:
            os.close(child)
        return str(PurePosixPath(root) / name / 'final-candidates.jsonl')
    finally:
        os.close(descriptor)


def append_report(path, stage, attempt, curl_status, done, reason):
    output_path = PurePosixPath(path)
    descriptor = directory(str(output_path.parent))
    try:
        output = os.open(output_path.name, os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK,
                         dir_fd=descriptor)
        try:
            info = os.fstat(output)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or \
                    stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1:
                raise ValueError('report must be a private single-link regular file')
            record = {'stage': stage, 'attempt': int(attempt), 'curl_status': int(curl_status),
                      'done': {'true': True, 'false': False}.get(done),
                      'done_reason': reason, 'final_text': sys.stdin.read()}
            pending = (json.dumps(record, ensure_ascii=False) + '\n').encode('utf-8')
            while pending:
                count = os.write(output, pending)
                if count <= 0:
                    raise OSError('short report write')
                pending = pending[count:]
            os.fsync(output)
        finally:
            os.close(output)
    finally:
        os.close(descriptor)


def main():
    os.umask(0o077)
    if len(sys.argv) == 3 and sys.argv[1] == 'create':
        print(create_report(sys.argv[2]))
    elif len(sys.argv) == 8 and sys.argv[1] == 'append':
        append_report(*sys.argv[2:])
    else:
        raise ValueError('invalid report helper arguments')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, UnicodeError):
        # Do not echo user-supplied paths or final text in an unsanitized error.
        print('private final-candidate report unavailable', file=sys.stderr)
        sys.exit(1)
