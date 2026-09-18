#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Keep this deterministic regression hermetic; a user's private few-shot file
# must not change the request-size preflight or the expected assertions.
export LOCAL_REVIEW_EXAMPLES_FILE=/dev/null
export OLLAMA_REVIEW_MAX_DIFF_BYTES=60000
# The fixture intentionally contains several independent division cases; keep
# the fake review request above the normal 16k budget so this test exercises
# preflight output rather than the input-budget rejection path.
export OLLAMA_REVIEW_NUM_CTX=32768
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-preflight-test.XXXXXX")"
fake_bin="$fixture_root/bin"
repo="$fixture_root/repo"
context="$fixture_root/downstream/Downstream.java"
module_context="$fixture_root/downstream/ModuleDownstream.java"
capture="$fixture_root/request.json"
review_output="$fixture_root/review-output.txt"
resolved_model_capture="$fixture_root/resolved-model.txt"
show_log="$fixture_root/ollama-show.log"
tmp_dir="$fixture_root/tmp"
trap 'rm -rf "$fixture_root"' EXIT

mkdir -p "$fake_bin" "$tmp_dir" "$repo/src/main/java/com/example/api/client" "$repo/src/main/java/com/example/api/dto" "$repo/src/test/java/com/example/api/dto" "$(dirname "$context")"

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${OLLAMA_SHOW_LOG:-/dev/null}"
exit 0
EOF

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
previous=""
for argument in "$@"; do
  if [[ "$previous" == "-d" ]]; then
    printf '%s' "$argument" >"$LOCAL_REVIEW_CAPTURE"
  elif [[ "$previous" == "--data-binary" && "$argument" == @* ]]; then
    cp "${argument#@}" "$LOCAL_REVIEW_CAPTURE"
  fi
  previous="$argument"
done
printf '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"

PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" OLLAMA_SHOW_LOG="$show_log" \
  OLLAMA_REVIEW_PROBE_TIMEOUT_SECONDS=invalid \
  "$repo_root/bin/local-review.sh" --help >/dev/null
[[ ! -s "$show_log" ]] || {
  echo '--help unexpectedly contacted Ollama' >&2
  cat "$show_log" >&2
  exit 1
}
if PATH="$fake_bin:$PATH" "$repo_root/bin/local-review.sh" --base '--output=/tmp/local-review-option-injection' --help >/dev/null 2>&1; then
  echo '--base accepted a Git option-like value' >&2
  exit 1
fi

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name preflight-test

cat >"$repo/src/main/java/com/example/api/client/Client.java" <<'EOF'
package com.example.api.client;

public interface Client {}
EOF
cat >"$repo/src/test/java/com/example/api/dto/MissingDTO.java" <<'EOF'
package com.example.api.dto;

final class MissingDTO {}
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base

PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" OLLAMA_SHOW_LOG="$show_log" \
  "$repo_root/bin/local-review.sh" --repo "$repo" >"$review_output"
[[ ! -s "$show_log" ]] || {
  echo 'clean repository unexpectedly contacted Ollama' >&2
  cat "$show_log" >&2
  exit 1
}
: >"$show_log"

cat >"$fake_bin/textconv" <<'EOF'
#!/usr/bin/env bash
touch "${TEXTCONV_MARKER:?}"
cat "$1"
EOF
chmod +x "$fake_bin/textconv"
git -C "$repo" config diff.evil.textconv "$fake_bin/textconv"
printf '*.bin diff=evil\n' >"$repo/.gitattributes"
printf 'base binary-like content\n' >"$repo/sample.bin"
git -C "$repo" add .gitattributes sample.bin
git -C "$repo" commit -qm textconv-base
printf 'changed binary-like content\n' >"$repo/sample.bin"
rm -f "$fixture_root/textconv.marker"

mkdir -p "$repo/module-a/src/main/java/com/example/api/client" "$repo/module-a/src/test/java/com/example/api/dto"
cat >"$repo/module-a/src/main/java/com/example/api/client/ModuleClient.java" <<'EOF'
package com.example.api.client;

public interface ModuleClient {}
EOF
cat >"$repo/module-a/src/test/java/com/example/api/dto/ModuleMissing.java" <<'EOF'
package com.example.api.dto;

final class ModuleMissing {}
EOF
git -C "$repo" add module-a
git -C "$repo" commit -qm module-base
cat >"$repo/module-a/src/main/java/com/example/api/client/ModuleClient.java" <<'EOF'
package com.example.api.client;

import com.example.api.dto.ModuleMissing;

public interface ModuleClient {
    ModuleMissing call();
}
EOF

# Configuration fixtures exercise the deterministic hardcoded-credential rule.
# Keep the literal values synthetic; the scanner must report the lines without
# echoing either value into the request or terminal output.
cat >"$repo/application-credential.yml" <<'EOF'
storage:
  endpoint: https://oss.example.invalid
  access-key-id: AKID_9f8e7d6c5b4a3210
  access-key-secret: S3cr3t_9f8e7d6c5b4a3210
EOF
cat >"$repo/application-credential-safe.yml" <<'EOF'
storage:
  endpoint: https://oss.example.invalid
  access-key-id: ${OSS_ACCESS_KEY_ID}
  password: ${DB_PASSWORD:}
  # access-key-secret: AKID_comment_should_not_trigger
EOF
cat >"$repo/application-credential.json" <<'EOF'
{
  "storage": {
    "endpoint": "https://oss.example.invalid",
    "api-key": "JSON_ApiKey_9f8e7d6c5b4a3210",
    "name": "ordinary-value"
  }
}
EOF
cat >"$repo/application-credential-inline.json" <<'EOF'
{"endpoint":"https://oss.example.invalid","api-key":"INLINE_ApiKey_9f8e7d6c5b4a3210","name":"ordinary-value"}
EOF
cat >"$repo/application-credential-weak-default.yml" <<'EOF'
nacos:
  server-addr: 192.168.30.241:8848
  password: ${NACOS_PASSWORD:nacos}
  safe-password: ${NACOS_SAFE_PASSWORD:}
EOF
cat >"$repo/application-credential-long-default.yml" <<'EOF'
operation-log:
  endpoint: http://localhost:8093/log/v1/logs
  internal-token: ${GATEWAY_INTERNAL_TOKEN:platform-dev-shared-internal-token}
  safe-token: ${SAFE_TOKEN:short-example}
EOF
cat >"$repo/application-credential-remote-default.yml" <<'EOF'
spring:
  datasource:
    url: jdbc:mysql://${DB_HOST:192.168.30.241}:${DB_PORT:3306}/platform_file
    username: ${DB_USERNAME:root}
    password: ${DB_PASSWORD:wanzhiTestPlatform}
cache:
  host: ${REDIS_HOST:192.168.30.241}
  password: ${REDIS_PASSWORD:wanzhiTestRedisPlatform}
EOF

cat >"$repo/src/main/java/com/example/api/client/TokenProxy.java" <<'EOF'
package com.example.api.client;

final class TokenProxy {
    String forward(String token) {
        return "https://internal.example/data?x-token=" + token;
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/QueryTokenProxy.java" <<'EOF'
package com.example.api.client;

import jakarta.servlet.http.HttpServletRequest;

final class QueryTokenProxy {
    String read(HttpServletRequest request) {
        return request.getParameter("x-token");
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/QueryTokenParamAlias.java" <<'EOF'
package com.example.api.client;

import jakarta.servlet.http.HttpServletRequest;

final class QueryTokenParamAlias {
    private static final String TOKEN_HEADER = "x-token";

    String read(HttpServletRequest request) {
        String parameterName = TOKEN_HEADER;
        return request.getParameter(parameterName);
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/QueryTokenAlias.java" <<'EOF'
package com.example.api.client;

final class QueryTokenAlias {
    String build(String authToken, String signature, String credential) {
        return "https://internal.example/download?code=" + credential + "&auth=" + authToken + "&sig=" + signature;
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/UrlSecretAlias.java" <<'EOF'
package com.example.api.client;

final class UrlSecretAlias {
    String build(String token) {
        String queryValue = token;
        return "https://internal.example/download?x-token=" + queryValue;
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/Divide.java" <<'EOF'
package com.example.api.client;

final class Divide {
    int divide(Integer a, Integer b) {
        return "a/b=" + (a / b);
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/UnrelatedDivide.java" <<'EOF'
package com.example.api.client;

final class UnrelatedDivide {
    int divide(Integer unused) {
        return 10 / 2;
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/SingleDivide.java" <<'EOF'
package com.example.api.client;

final class SingleDivide {
    int divide(Integer divisor) {
        return 10 / divisor;
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/CommentOnly.java" <<'EOF'
package com.example.api.client;

// request.getParameter("x-token") is documentation, not executable code.
final class CommentOnly {}
EOF

cat >"$repo/src/main/java/com/example/api/client/BlockCommentOnly.java" <<'EOF'
package com.example.api.client;

final class BlockCommentOnly {
    int divide(Integer a, Integer b) {
        /*
         * Example expression: a / b
         */
        return 1;
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/SsrfPreflight.java" <<'EOF'
package com.example.api.client;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.web.client.RestTemplate;

final class SsrfPreflight {
    String fetch(HttpServletRequest request) {
        String target = request.getParameter("url");
        return new RestTemplate().getForObject(target, String.class);
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/SsrfSafe.java" <<'EOF'
package com.example.api.client;

import java.net.URI;
import java.util.Set;
import org.springframework.web.client.RestTemplate;

final class SsrfSafe {
    private static final Set<String> ALLOWED_HOSTS = Set.of("api.internal.example");

    String fetch(String target) {
        URI uri = URI.create(target);
        if (!"https".equalsIgnoreCase(uri.getScheme()) || !ALLOWED_HOSTS.contains(uri.getHost())) {
            throw new IllegalArgumentException("unsupported target");
        }
        return new RestTemplate().getForObject(uri, String.class);
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/PathTraversalPreflight.java" <<'EOF'
package com.example.api.client;

import java.nio.file.Files;
import java.nio.file.Path;

final class PathTraversalPreflight {
    String read(Path root, String filename) throws Exception {
        Path target = root.resolve(filename);
        return Files.readString(target);
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/PathTraversalSafe.java" <<'EOF'
package com.example.api.client;

import java.nio.file.Files;
import java.nio.file.Path;

final class PathTraversalSafe {
    String read(Path root, String filename) throws Exception {
        Path canonicalRoot = root.toAbsolutePath().normalize();
        Path target = canonicalRoot.resolve(filename).normalize();
        if (!target.startsWith(canonicalRoot)) throw new IllegalArgumentException("path escapes root");
        return Files.readString(target);
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/SsrfContext.java" <<'EOF'
package com.example.api.client;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.web.client.RestTemplate;

final class SsrfContext {
    String fetch(HttpServletRequest request) {
        String target = request.getParameter("url");
        return target;
    }
}
EOF
git -C "$repo" add src/main/java/com/example/api/client/SsrfContext.java
git -C "$repo" commit -qm ssrf-context-base
perl -0pi -e 's/return target;/return new RestTemplate().getForObject(target, String.class);/' "$repo/src/main/java/com/example/api/client/SsrfContext.java"

cat >"$repo/src/main/java/com/example/api/client/SsrfOnlySource.java" <<'EOF'
package com.example.api.client;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.web.client.RestTemplate;

final class SsrfOnlySource {
    String fetch(HttpServletRequest request) {
        String target = "https://fixed.example";
        return new RestTemplate().getForObject(target, String.class);
    }
}
EOF
git -C "$repo" add src/main/java/com/example/api/client/SsrfOnlySource.java
git -C "$repo" commit -qm ssrf-source-base
sed -i '' 's/String target = "https:\/\/fixed.example";/String target = request.getParameter("url");/' "$repo/src/main/java/com/example/api/client/SsrfOnlySource.java"

cat >"$repo/src/main/java/com/example/api/client/SsrfCrossHunk.java" <<'EOF'
package com.example.api.client;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.web.client.RestTemplate;

final class SsrfCrossHunk {
    String fetch(HttpServletRequest request) {
        String target = "https://fixed.example";
        int one = 1;
        int two = 2;
        int three = 3;
        int four = 4;
        int five = 5;
        int six = 6;
        int seven = 7;
        int eight = 8;
        return target;
    }
}
EOF
git -C "$repo" add src/main/java/com/example/api/client/SsrfCrossHunk.java
git -C "$repo" commit -qm ssrf-cross-hunk-base
perl -0pi -e 's/String target = "https:\/\/fixed.example";/String target = request.getParameter("url");/; s/return target;/return new RestTemplate().getForObject(target, String.class);/' "$repo/src/main/java/com/example/api/client/SsrfCrossHunk.java"

cat >"$repo/src/main/java/com/example/api/client/SsrfAlias.java" <<'EOF'
package com.example.api.client;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.web.client.RestTemplate;

final class SsrfAlias {
    String fetch(HttpServletRequest request) {
        String endpoint = request.getParameter("endpoint");
        return new RestTemplate().getForObject(endpoint, String.class);
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/SsrfGuardAfter.java" <<'EOF'
package com.example.api.client;

import jakarta.servlet.http.HttpServletRequest;
import java.util.Set;
import org.springframework.web.client.RestTemplate;

final class SsrfGuardAfter {
    private static final Set<String> ALLOWED_HOSTS = Set.of("api.internal.example");

    String fetch(HttpServletRequest request) {
        String target = request.getParameter("url");
        String result = new RestTemplate().getForObject(target, String.class);
        if (!ALLOWED_HOSTS.contains(java.net.URI.create(target).getHost())) {
            throw new IllegalArgumentException("unsupported target");
        }
        return result;
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/TokenBuilder.java" <<'EOF'
package com.example.api.client;

final class TokenBuilder {
    String build(String bearerToken) {
        return org.springframework.web.util.UriComponentsBuilder
            .fromUriString("https://internal.example/download")
            .queryParam("token", bearerToken)
            .toUriString();
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/TokenBuilderSafe.java" <<'EOF'
package com.example.api.client;

final class TokenBuilderSafe {
    String build(String resourceId) {
        return org.springframework.web.util.UriComponentsBuilder
            .fromUriString("https://internal.example/download")
            .queryParam("id", resourceId)
            .toUriString();
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/PathAliasPreflight.java" <<'EOF'
package com.example.api.client;

import java.nio.file.Files;
import java.nio.file.Path;

final class PathAliasPreflight {
    String read(Path root, String userInput) throws Exception {
        Path target = Path.of(root.toString(), userInput);
        return Files.readString(target);
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/PathAliasSafe.java" <<'EOF'
package com.example.api.client;

import java.nio.file.Files;
import java.nio.file.Path;

final class PathAliasSafe {
    String read(Path root, String resourceId) throws Exception {
        Path target = Path.of(root.toString(), resourceId).normalize();
        if (!target.startsWith(root.toAbsolutePath().normalize())) throw new IllegalArgumentException("path escapes root");
        return Files.readString(target);
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/LongMethodDivide.java" <<'EOF'
package com.example.api.client;

final class LongMethodDivide {
    int divide(Integer divisor) {
        int first = 1;
        int second = 2;
        int third = 3;
        int fourth = 4;
        int fifth = 5;
        int sixth = 6;
        int seventh = 7;
        int eighth = 8;
        int ninth = 9;
        int tenth = 10;
        int eleventh = 11;
        int twelfth = 12;
        return 10 / divisor;
    }
}
EOF

git -C "$repo" add src/main/java/com/example/api/client/LongMethodDivide.java
git -C "$repo" commit -qm long-method-base
perl -0pi -e 's/return 10 \/ divisor;/return 20 \/ divisor;/' "$repo/src/main/java/com/example/api/client/LongMethodDivide.java"

cat >"$repo/src/main/java/com/example/api/client/LongDivide.java" <<'EOF'
package com.example.api.client;

final class LongDivide {
    int divide(Integer divisor) {
        int first = 1;
        int second = 2;
        int third = 3;
        int fourth = 4;
        int fifth = 5;
        int sixth = 6;
        int seventh = 7;
        int eighth = 8;
        return 10 / divisor;
    }
}
EOF
# Commit the fixture's original method first, then change only the division.
# The default three-line diff context no longer contains the Integer
# signature; the deterministic preflight must recover it from the checkout.
git -C "$repo" add src/main/java/com/example/api/client/LongDivide.java
git -C "$repo" commit -qm long-divide-base
sed -i '' 's/return 10 \/ divisor;/return 20 \/ divisor;/' "$repo/src/main/java/com/example/api/client/LongDivide.java"

cat >"$repo/src/main/java/com/example/api/client/MultiDivide.java" <<'EOF'
package com.example.api.client;

final class MultiDivide {
    int divide(Integer a, Integer b) {
        int first = 1;
        return 10 / a;
    }
}
EOF
git -C "$repo" add src/main/java/com/example/api/client/MultiDivide.java
git -C "$repo" commit -qm multi-divide-base
perl -0pi -e 's/int first = 1;/int first = a \/ b;/; s/return 10 \/ a;/return 20 \/ a;/' "$repo/src/main/java/com/example/api/client/MultiDivide.java"

cat >"$repo/src/main/java/com/example/api/client/GuardedDivide.java" <<'EOF'
package com.example.api.client;

final class GuardedDivide {
    int divide(Integer a, Integer b) {
        if (a != null) System.out.println(a);
        if (b != 0) System.out.println(b);
        return 10 / b;
    }
}
EOF
git -C "$repo" add src/main/java/com/example/api/client/GuardedDivide.java
git -C "$repo" commit -qm guarded-divide-base
sed -i '' 's/return 10 \/ b;/return 20 \/ b;/' "$repo/src/main/java/com/example/api/client/GuardedDivide.java"

cat >"$repo/src/main/java/com/example/api/client/ExpressionDivide.java" <<'EOF'
package com.example.api.client;

final class ExpressionDivide {
    int divide(Integer a, Integer b) {
        consume(a / b);
        return a;
    }

    private void consume(int value) {}
}
EOF
git -C "$repo" add src/main/java/com/example/api/client/ExpressionDivide.java
git -C "$repo" commit -qm expression-divide-base
sed -i '' 's/consume(a \/ b);/consume(a \/ b + 1);/' "$repo/src/main/java/com/example/api/client/ExpressionDivide.java"

cat >"$repo/src/main/java/com/example/api/client/Client.java" <<'EOF'
package com.example.api.client;

import com.example.api.dto.MissingDTO;

public interface Client {
    MissingDTO call(MissingDTO request);
}
EOF

cat >"$fake_bin/fsmonitor" <<'EOF'
#!/usr/bin/env bash
touch "${FSMONITOR_MARKER:-/dev/null}"
printf 'token\n'
exit 0
EOF
chmod +x "$fake_bin/fsmonitor"
git -C "$repo" config core.fsmonitor "$fake_bin/fsmonitor"
rm -f "$fixture_root/fsmonitor.marker"

PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" LOCAL_REVIEW_RESOLVED_MODEL_FILE="$resolved_model_capture" OLLAMA_SHOW_LOG="$show_log" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  TEXTCONV_MARKER="$fixture_root/textconv.marker" FSMONITOR_MARKER="$fixture_root/fsmonitor.marker" \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  "$repo_root/bin/local-review.sh" --repo "$repo" >/dev/null
grep -F '当前提交快照缺少仓库内类型 com.example.api.dto.MissingDTO' "$capture" >/dev/null || {
  echo 'missing deterministic MissingDTO preflight' >&2
  cat "$capture" >&2
  exit 1
}
grep -F '当前提交快照缺少仓库内类型 com.example.api.dto.ModuleMissing' "$capture" >/dev/null
grep -F '凭据值被拼接到 URL 查询参数或路径中' "$capture" >/dev/null
grep -F 'P1 src/main/java/com/example/api/client/QueryTokenAlias.java' "$capture" >/dev/null
grep -F 'P1 src/main/java/com/example/api/client/UrlSecretAlias.java' "$capture" >/dev/null || {
  echo 'missing URL credential alias preflight' >&2
  cat "$capture" >&2
  exit 1
}
grep -F 'P1 src/main/java/com/example/api/client/QueryTokenParamAlias.java' "$capture" >/dev/null || {
  echo 'missing query-token parameter alias preflight' >&2
  cat "$capture" >&2
  exit 1
}
grep -F '认证令牌从 URL 查询参数读取' "$capture" >/dev/null
grep -F 'P1 src/main/java/com/example/api/client/SsrfPreflight.java' "$capture" >/dev/null
grep -F '服务端请求伪造' "$capture" >/dev/null
grep -F 'P1 src/main/java/com/example/api/client/SsrfContext.java' "$capture" >/dev/null
for ssrf_fixture in SsrfOnlySource SsrfAlias SsrfGuardAfter; do
  grep -F "P1 src/main/java/com/example/api/client/${ssrf_fixture}.java" "$capture" >/dev/null || {
    echo "missing SSRF preflight for ${ssrf_fixture}" >&2
    cat "$capture" >&2
    exit 1
  }
done
grep -F 'P1 src/main/java/com/example/api/client/SsrfCrossHunk.java' "$capture" >/dev/null || {
  echo 'missing cross-hunk SSRF preflight' >&2
  cat "$capture" >&2
  exit 1
}
grep -F 'P1 src/main/java/com/example/api/client/TokenBuilder.java' "$capture" >/dev/null || {
  echo 'missing token builder URL preflight' >&2
  cat "$capture" >&2
  exit 1
}
grep -F 'P1 src/main/java/com/example/api/client/PathAliasPreflight.java' "$capture" >/dev/null || {
  echo 'missing path API alias preflight' >&2
  cat "$capture" >&2
  exit 1
}
grep -F 'P1 src/main/java/com/example/api/client/PathTraversalPreflight.java' "$capture" >/dev/null || {
  echo 'missing path traversal preflight' >&2
  cat "$capture" >&2
  exit 1
}
grep -F '路径遍历' "$capture" >/dev/null
grep -F 'P1 application-credential.yml' "$capture" >/dev/null || {
  echo 'missing hardcoded credential preflight' >&2
  cat "$capture" >&2
  exit 1
}
grep -F 'P1 application-credential.json' "$capture" >/dev/null || {
  echo 'missing JSON hardcoded credential preflight' >&2
  cat "$capture" >&2
  exit 1
}
grep -F 'P1 application-credential-inline.json' "$capture" >/dev/null || {
  echo 'missing inline JSON hardcoded credential preflight' >&2
  cat "$capture" >&2
  exit 1
}
grep -F 'P1 application-credential-weak-default.yml' "$capture" >/dev/null || {
  echo 'missing weak default credential preflight' >&2
  cat "$capture" >&2
  exit 1
}
grep -F 'P1 application-credential-long-default.yml' "$capture" >/dev/null || {
  echo 'missing long default credential preflight' >&2
  cat "$capture" >&2
  exit 1
}
grep -F 'P1 application-credential-remote-default.yml' "$capture" >/dev/null || {
  echo 'missing remote JDBC/service default credential preflight' >&2
  cat "$capture" >&2
  exit 1
}
if grep -F 'P1 application-credential-safe.yml' "$capture" >/dev/null; then
  echo 'hardcoded credential preflight reported placeholder/comment negative fixture' >&2
  cat "$capture" >&2
  exit 1
fi
if grep -F 'AKID_9f8e7d6c5b4a3210' "$review_output" >/dev/null || \
   grep -F 'S3cr3t_9f8e7d6c5b4a3210' "$review_output" >/dev/null || \
   grep -F 'JSON_ApiKey_9f8e7d6c5b4a3210' "$review_output" >/dev/null || \
   grep -F 'INLINE_ApiKey_9f8e7d6c5b4a3210' "$review_output" >/dev/null; then
  echo 'hardcoded credential value leaked into review output' >&2
  exit 1
fi
grep -F 'P1 src/main/java/com/example/api/client/SingleDivide.java' "$capture" >/dev/null
grep -F 'P1 src/main/java/com/example/api/client/LongMethodDivide.java' "$capture" >/dev/null
grep -F 'P1 src/main/java/com/example/api/client/LongDivide.java' "$capture" >/dev/null
if grep -F 'P1 src/main/java/com/example/api/client/UnrelatedDivide.java' "$capture" >/dev/null; then
  echo 'Java division preflight reported unrelated constant division' >&2
  exit 1
fi
if grep -F 'P1 src/main/java/com/example/api/client/CommentOnly.java' "$capture" >/dev/null; then
  echo 'security preflight reported a comment-only token reference' >&2
  exit 1
fi
if grep -F 'P1 src/main/java/com/example/api/client/BlockCommentOnly.java' "$capture" >/dev/null; then
  echo 'Java division preflight reported a block-comment-only expression' >&2
  exit 1
fi
if grep -F 'P1 src/main/java/com/example/api/client/SsrfSafe.java' "$capture" >/dev/null || \
   grep -F 'P1 src/main/java/com/example/api/client/PathTraversalSafe.java' "$capture" >/dev/null || \
   grep -F 'P1 src/main/java/com/example/api/client/TokenBuilderSafe.java' "$capture" >/dev/null || \
   grep -F 'P1 src/main/java/com/example/api/client/PathAliasSafe.java' "$capture" >/dev/null; then
  echo 'security preflight reported a guarded SSRF/path traversal negative fixture' >&2
  exit 1
fi

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
previous=""
for argument in "$@"; do
  if [[ "$previous" == "--data-binary" && "$argument" == @* ]]; then
    cp "${argument#@}" "$LOCAL_REVIEW_CAPTURE"
  fi
  previous="$argument"
done
printf '{"response":"P1 src/main/java/com/example/api/client/QueryTokenProxy.java:7 - 认证令牌从 URL 查询参数读取，可能进入日志。影响：凭据泄露。修复建议：只用请求头。验证方式：检查日志。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
duplicate_security_output="$(PATH="$fake_bin:$PATH" LOCAL_REVIEW_CAPTURE="$capture" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
duplicate_security_count="$(printf '%s\n' "$duplicate_security_output" | grep -F 'P1 src/main/java/com/example/api/client/QueryTokenProxy.java:7' | wc -l | tr -d ' ')"
[[ "$duplicate_security_count" == "1" ]] || {
  echo 'security preflight and model duplicate were not collapsed' >&2
  printf '%s\n' "$duplicate_security_output" >&2
  exit 1
}

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P1 src/main/java/com/example/api/client/QueryTokenProxy.java:7 - 认证令牌从 URL 查询参数读取，同时未校验 tenantId，可能造成跨租户访问。影响：凭据可能进入日志，租户边界也可能被绕过。修复建议：仅使用受保护请求头并校验 tenantId。验证方式：检查日志并用两个租户执行请求。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
mixed_security_output="$(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
if ! printf '%s\n' "$mixed_security_output" | grep -Eiq 'tenantId|跨租户|租户边界'; then
  echo 'mixed URL-token and tenant finding was incorrectly discarded as a duplicate' >&2
  printf '%s\n' "$mixed_security_output" >&2
  exit 1
fi

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P1 application-credential.yml:3 - 明文 AccessKey 已提交。影响：凭据泄露。修复建议：改用无默认值的环境变量。验证方式：检查配置与历史。\\n\\nP1 application-credential.yml:3 - 同一凭据暴露风险的另一种描述。影响：凭据泄露。修复建议：轮换凭据。验证方式：检查配置历史。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
duplicate_credential_output="$(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
duplicate_credential_count="$(printf '%s\n' "$duplicate_credential_output" | grep -F 'application-credential.yml:3' | wc -l | tr -d ' ')"
[[ "$duplicate_credential_count" == "1" ]] || {
  echo 'credential preflight and model duplicate were not collapsed' >&2
  printf '%s\n' "$duplicate_credential_output" >&2
  exit 1
}

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P1 application-credential.yml:3 - 明文 AccessKey 已提交。影响：凭据泄露。修复建议：改用无默认值的环境变量。验证方式：检查配置与历史。\\n\\nP1 application-credential.yml:3 - token 被拼接到 URL 查询参数。影响：令牌可能进入访问日志。修复建议：改用请求头。验证方式：检查最终请求 URI。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
independent_credential_output="$(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
independent_credential_count="$(printf '%s\n' "$independent_credential_output" | grep -c '^P1 application-credential.yml:3' || true)"
[[ "$independent_credential_count" == "2" ]] || {
  echo 'independent credential risk families at one location were incorrectly merged' >&2
  printf '%s\n' "$independent_credential_output" >&2
  exit 1
}

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
previous=""
for argument in "$@"; do
  if [[ "$previous" == "-d" ]]; then
    printf '%s' "$argument" >"$LOCAL_REVIEW_CAPTURE"
  elif [[ "$previous" == "--data-binary" && "$argument" == @* ]]; then
    cp "${argument#@}" "$LOCAL_REVIEW_CAPTURE"
  fi
  previous="$argument"
done
printf '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"

java_division_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
for java_division_header in 'Integer 包装类型参与除法时未见非空保护' '除法分母未见非零保护'; do
  java_division_line="$(printf '%s\n' "$java_division_output" | grep -n "Divide.java:.* - $java_division_header" | head -1 | cut -d: -f1)"
  [[ -n "$java_division_line" ]] || {
    echo "missing Java division preflight header: $java_division_header" >&2
    printf '%s\n' "$java_division_output" >&2
    exit 1
  }
  java_division_block="$(printf '%s\n' "$java_division_output" | sed -n "${java_division_line},$((java_division_line + 3))p")"
  if ! grep -Fq '影响：' <<<"$java_division_block" || \
     ! grep -Fq '修复建议：' <<<"$java_division_block" || \
     ! grep -Fq '验证方式：' <<<"$java_division_block"; then
    echo "Java division preflight finding fields were not kept in one block: $java_division_header" >&2
    printf '%s\n' "$java_division_output" >&2
    exit 1
  fi
done
multi_division_count="$(printf '%s\n' "$java_division_output" | grep -c 'P1 src/main/java/com/example/api/client/MultiDivide.java:' || true)"
[[ "$multi_division_count" -ge 4 ]] || {
  echo 'Java division preflight collapsed independent divisions in one hunk' >&2
  printf '%s\n' "$java_division_output" >&2
  exit 1
}
guarded_division_count="$(printf '%s\n' "$java_division_output" | grep -c 'P1 src/main/java/com/example/api/client/GuardedDivide.java:' || true)"
[[ "$guarded_division_count" -ge 2 ]] || {
  echo 'Java division preflight treated unrelated logging comparisons as guards' >&2
  printf '%s\n' "$java_division_output" >&2
  exit 1
}
expression_division_count="$(printf '%s\n' "$java_division_output" | grep -c 'P1 src/main/java/com/example/api/client/ExpressionDivide.java:' || true)"
[[ "$expression_division_count" -ge 2 ]] || {
  echo 'Java division preflight missed division inside a method call expression' >&2
  printf '%s\n' "$java_division_output" >&2
  exit 1
}

# A vulnerable division that is already present in the parent must not be
# reported again merely because a later, unrelated line changed in the same
# hunk.  Context lines are evidence for guards/signatures, not new findings.
cat >"$repo/src/main/java/com/example/api/client/PreExistingContextDivide.java" <<'EOF'
package com.example.api.client;

final class PreExistingContextDivide {
    int divide(Integer divisor) {
        return 10 / divisor;
    }

    int changedLater() {
        return 1;
    }
}
EOF
git -C "$repo" add src/main/java/com/example/api/client/PreExistingContextDivide.java
git -C "$repo" commit -qm pre-existing-divide-base
sed -i '' 's/return 1;/return 2;/' "$repo/src/main/java/com/example/api/client/PreExistingContextDivide.java"
preexisting_division_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
if printf '%s\n' "$preexisting_division_output" | grep -F 'PreExistingContextDivide.java:' >/dev/null; then
  echo 'Java division preflight reported an unchanged, pre-existing division' >&2
  printf '%s\n' "$preexisting_division_output" >&2
  exit 1
fi

cat >"$repo/src/main/java/com/example/api/client/PreExistingQueryToken.java" <<'EOF'
package com.example.api.client;

final class PreExistingQueryToken {
    String read(javax.servlet.http.HttpServletRequest request) {
        return request.getParameter("x-token");
    }

    String changedLater() {
        return "old";
    }
}
EOF
git -C "$repo" add src/main/java/com/example/api/client/PreExistingQueryToken.java
git -C "$repo" commit -qm pre-existing-query-token-base
sed -i '' 's/return "old";/return "new";/' "$repo/src/main/java/com/example/api/client/PreExistingQueryToken.java"
preexisting_query_token_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
if printf '%s\n' "$preexisting_query_token_output" | grep -F 'PreExistingQueryToken.java:' >/dev/null; then
  echo 'URL-token preflight reported an unchanged, pre-existing query-token read' >&2
  printf '%s\n' "$preexisting_query_token_output" >&2
  exit 1
fi

grep -Fx 'devstral-small-2-review-tuned' "$resolved_model_capture" >/dev/null
[[ ! -e "$fixture_root/textconv.marker" ]] || {
  echo 'git diff executed a configured textconv filter' >&2
  exit 1
}
[[ ! -e "$fixture_root/fsmonitor.marker" ]] || {
  echo 'git status executed a configured fsmonitor hook' >&2
  exit 1
}
[[ "$(wc -l <"$show_log" | tr -d ' ')" == "1" ]] || {
  echo 'automatic model selection performed a redundant model probe' >&2
  cat "$show_log" >&2
  exit 1
}
if find "$tmp_dir" -maxdepth 1 -name 'local-review-untracked.*' -print -quit | grep -q .; then
  echo 'untracked diff temporary file was not cleaned up' >&2
  exit 1
fi

PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo" --model custom-review-model >/dev/null
grep -F 'custom-review-model' "$capture" >/dev/null || {
  echo '--model override was replaced by automatic model selection' >&2
  exit 1
}
: >"$show_log"

cat >"$repo/src/main/java/com/example/api/dto/DeletedDTO.java" <<'EOF'
package com.example.api.dto;

public record DeletedDTO(String value) {}
EOF
git -C "$repo" add .
git -C "$repo" commit -qm add-dto
cat >"$repo/src/main/java/com/example/api/client/Consumer.java" <<'EOF'
package com.example.api.client;

import com.example.api.dto.DeletedDTO;

final class Consumer {
    DeletedDTO value;
}
EOF
cat >"$context" <<'EOF'
package com.example.downstream;

import com.example.api.dto.DeletedDTO;

final class Downstream {
    DeletedDTO value;
}
EOF
git -C "$repo" rm -q src/main/java/com/example/api/dto/DeletedDTO.java

PATH="$fake_bin:$PATH" LOCAL_REVIEW_CAPTURE="$capture" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo" --context "$context" >/dev/null
grep -F '当前提交删除类型 com.example.api.dto.DeletedDTO' "$capture" >/dev/null
grep -F '仓库内文件 src/main/java/com/example/api/client/Consumer.java' "$capture" >/dev/null

mkdir -p "$repo/module-b/src/main/java/com/example/api/dto"
cat >"$repo/module-b/src/main/java/com/example/api/dto/ModuleDeletedDTO.java" <<'EOF'
package com.example.api.dto;

public record ModuleDeletedDTO(String value) {}
EOF
git -C "$repo" add module-b/src/main/java/com/example/api/dto/ModuleDeletedDTO.java
git -C "$repo" commit -qm module-dto-base
cat >"$module_context" <<'EOF'
package com.example.downstream;

import com.example.api.dto.ModuleDeletedDTO;

final class ModuleDownstream {
    ModuleDeletedDTO value;
}
EOF
git -C "$repo" rm -q module-b/src/main/java/com/example/api/dto/ModuleDeletedDTO.java

PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo" --context "$module_context" >/dev/null
grep -F '当前提交删除类型 com.example.api.dto.ModuleDeletedDTO' "$capture" >/dev/null

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P0 src/main/java/com/example/api/client/Client.java:1-93 - 文件内容不完整，缺少类声明和字段定义，导致无法验证代码逻辑是否正确。\\n\\n影响：无法确定代码是否符合项目规则。\\n\\n修复建议：提供完整的文件内容。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
if ! shard_output="$(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"; then
  echo 'unsupported shard-boundary finding caused review failure' >&2
  exit 1
fi
if printf '%s\n' "$shard_output" | grep -F '文件内容不完整' >/dev/null; then
  echo 'unsupported shard-boundary finding was not filtered' >&2
  printf '%s\n' "$shard_output" >&2
  exit 1
fi
if ! printf '%s\n' "$shard_output" | grep -F '当前提交快照缺少仓库内类型' >/dev/null; then
  echo 'deterministic build preflight finding was dropped' >&2
  printf '%s\n' "$shard_output" >&2
  exit 1
fi

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P1 module-b/src/main/java/com/example/api/dto/ModuleDeletedDTO.java:1 - 文件内容不完整，但当前代码明确把未校验的 tenantId 传入跨租户查询。\\n行号：1\\n影响：可能读取其他租户数据。\\n修复建议：增加 tenantId 约束。\\n验证方式：用两个租户数据执行查询并断言不可越权。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
mixed_output="$(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo" 2>/dev/null)"
if ! printf '%s\n' "$mixed_output" | grep -F 'tenantId' >/dev/null; then
  echo 'mixed incomplete-context finding was incorrectly filtered' >&2
  printf '%s\n' "$mixed_output" >&2
  exit 1
fi

cat >"$repo/src/main/java/com/example/api/client/GuardedDTO.java" <<'EOF'
package com.example.api.client;

final class GuardedDTO {
    String name(InputDTO dto) {
        return dto == null ? null : dto.getName();
    }
}
EOF
cat >"$repo/src/main/java/com/example/api/client/UnguardedDTO.java" <<'EOF'
package com.example.api.client;

final class UnguardedDTO {
    String name(InputDTO dto) {
        return dto.getName();
    }
}
EOF
git -C "$repo" add src/main/java/com/example/api/client/GuardedDTO.java src/main/java/com/example/api/client/UnguardedDTO.java
git -C "$repo" commit -qm dto-guard-base
perl -0pi -e 's/dto\.getName\(\);/dto.getName().trim();/' "$repo/src/main/java/com/example/api/client/GuardedDTO.java"
perl -0pi -e 's/dto\.getName\(\);/dto.getName().trim();/' "$repo/src/main/java/com/example/api/client/UnguardedDTO.java"
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P1 src/main/java/com/example/api/client/UnguardedDTO.java:5 - dto 可能为空导致 NPE。\\n影响：空输入会使请求失败。\\n修复建议：增加空值校验。\\n验证方式：使用 null 输入测试。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
cross_file_filter_output="$(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
if ! printf '%s\n' "$cross_file_filter_output" | grep -F 'UnguardedDTO.java:5' >/dev/null; then
  echo 'a guard in another file incorrectly filtered an actionable DTO finding' >&2
  printf '%s\n' "$cross_file_filter_output" >&2
  exit 1
fi

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P1 src/main/java/com/example/api/client/Consumer.java:5 - Authorization: Bearer super-secret-token-value; \\\"Authorization\\\": \\\"Basic basic-secret-value\\\"\\n影响：凭据可能进入审查输出。\\n修复建议：轮换并移除凭据。\\n验证方式：确认输出不包含原始凭据。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
redacted_output="$(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
[[ "$redacted_output" == *'Authorization: Bearer <REDACTED>'* ]] || {
  echo 'Authorization bearer value was not redacted' >&2
  printf '%s\n' "$redacted_output" >&2
  exit 1
}
[[ "$redacted_output" == *'"Authorization": "Basic <REDACTED>"'* ]] || {
  echo 'JSON Basic authorization value was not redacted' >&2
  printf '%s\n' "$redacted_output" >&2
  exit 1
}
[[ "$redacted_output" != *'super-secret-token-value'* ]] || {
  echo 'raw Authorization bearer value leaked in review output' >&2
  exit 1
}
[[ "$redacted_output" != *'basic-secret-value'* ]] || {
  echo 'raw Basic authorization value leaked in review output' >&2
  exit 1
}

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P1 src/main/java/com/example/api/client/Consumer.java:5 - 字面量令牌 platform-dev-shared-internal-token；影响：凭据泄露。修复建议：轮换。验证方式：检查配置。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
literal_token_output="$(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
[[ "$literal_token_output" == *'字面量令牌 <REDACTED>'* ]] || {
  echo 'natural-language literal token value was not redacted' >&2
  printf '%s\n' "$literal_token_output" >&2
  exit 1
}
[[ "$literal_token_output" != *'platform-dev-shared-internal-token'* ]] || {
  echo 'natural-language literal token leaked into output' >&2
  printf '%s\n' "$literal_token_output" >&2
  exit 1
}

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P1 src/main/java/com/example/api/client/UnguardedDTO.java:5 - 凭据泄漏：真实凭据仍存在（<REDACTED>和FY84ZhmB4nGmmUeBKpgJYAXUE87lI9）\\n影响：凭据泄露。\\n修复建议：轮换。\\n验证方式：检查配置。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
natural_credential_output="$(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
[[ "$natural_credential_output" == *'凭据泄漏：真实凭据仍存在（<REDACTED>和<REDACTED>）'* ]] || {
  echo 'natural-language credential value was not redacted' >&2
  printf '%s\n' "$natural_credential_output" >&2
  exit 1
}
[[ "$natural_credential_output" != *'FY84ZhmB4nGmmUeBKpgJYAXUE87lI9'* ]] || {
  echo 'natural-language credential leaked into output' >&2
  printf '%s\n' "$natural_credential_output" >&2
  exit 1
}

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P1 src/main/java/com/example/api/client/UnguardedDTO.java:5 - 凭据泄漏：两个值（<REDACTED>和Qz9alpha0123456789BetaGamma）\\n影响：凭据泄露。\\n修复建议：轮换。\\n验证方式：检查配置。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
generic_credential_output="$(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
[[ "$generic_credential_output" == *'凭据泄漏：两个值（<REDACTED>和<REDACTED>）'* ]] || {
  echo 'generic long credential fallback was not redacted' >&2
  printf '%s\n' "$generic_credential_output" >&2
  exit 1
}
[[ "$generic_credential_output" != *'Qz9alpha0123456789BetaGamma'* ]] || {
  echo 'generic long credential leaked into output' >&2
  exit 1
}

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P1 src/main/java/com/example/api/client/Consumer.java:5 - \\u001b[31mANSI marker\\u001b[0m remains visible\\n影响：示例影响。\\n修复建议：示例修复。\\n验证方式：示例验证。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
safe_output="$(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
if printf '%s' "$safe_output" | LC_ALL=C grep -q $'\033'; then
  echo 'ANSI escape sequence leaked in review output' >&2
  exit 1
fi
[[ "$safe_output" == *'ANSI marker'* ]] || {
  echo 'ANSI sanitization removed the finding text' >&2
  exit 1
}

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P1 src/main/java/com/example/api/client/Consumer.java:5 - Unicode replacement \uFFFD marker。影响：示例影响。修复建议：示例修复。验证方式：示例验证。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
unicode_output="$(LC_ALL=en_US.UTF-8 PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
[[ "$unicode_output" == *'Unicode replacement'* ]] || {
  echo 'non-ASCII model output was rejected by locale-sensitive filtering' >&2
  printf '%s\n' "$unicode_output" >&2
  exit 1
}

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P1 src/main/java/com/example/api/client/Consumer.java:5 - https://oss.example.test/upload?X-Amz-Credential=AKID_EXAMPLE&X-Amz-Signature=signature-secret-value&X-Amz-Security-Token=session-secret-value\\n影响：示例影响。\\n修复建议：示例修复。\\n验证方式：示例验证。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
url_safe_output="$(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
[[ "$url_safe_output" == *'X-Amz-Credential=<REDACTED>'* ]] || {
  echo 'presigned URL credential was not redacted' >&2
  exit 1
}
[[ "$url_safe_output" == *'X-Amz-Signature=<REDACTED>'* ]] || {
  echo 'presigned URL signature was not redacted' >&2
  exit 1
}
[[ "$url_safe_output" == *'X-Amz-Security-Token=<REDACTED>'* ]] || {
  echo 'presigned URL security token was not redacted' >&2
  exit 1
}
[[ "$url_safe_output" != *'signature-secret-value'* && "$url_safe_output" != *'session-secret-value'* ]] || {
  echo 'raw presigned URL credential leaked in review output' >&2
  exit 1
}

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"未发现阻塞问题。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
marker_output="$(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo" 2>/dev/null)"
if printf '%s\n' "$marker_output" | grep -F '未发现阻塞问题。' >/dev/null; then
  echo 'clean marker with punctuation was not removed when preflight findings existed' >&2
  printf '%s\n' "$marker_output" >&2
  exit 1
fi
if ! printf '%s\n' "$marker_output" | grep -F '当前提交快照缺少仓库内类型' >/dev/null; then
  echo 'preflight finding disappeared when model returned a punctuated clean marker' >&2
  printf '%s\n' "$marker_output" >&2
  exit 1
fi

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P2 src/main/java/com/example/api/client/Consumer.java:5 - 低严重度示例问题。\\n影响：低严重度影响。\\n修复建议：低严重度修复。\\n验证方式：低严重度验证。\\nP0 src/main/java/com/example/api/client/Consumer.java:6 - 高严重度示例问题。\\n影响：高严重度影响。\\n修复建议：高严重度修复。\\n验证方式：高严重度验证。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
single_sorted_output="$(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 "$repo_root/bin/local-review.sh" --repo "$repo")"
single_p0_line="$(printf '%s\n' "$single_sorted_output" | grep -n '^P0 ' | head -n1 | cut -d: -f1)"
single_p2_line="$(printf '%s\n' "$single_sorted_output" | grep -n '^P2 ' | head -n1 | cut -d: -f1)"
if [[ -z "$single_p0_line" || -z "$single_p2_line" || "$single_p0_line" -ge "$single_p2_line" ]]; then
  echo 'single-request findings were not globally sorted by severity' >&2
  printf '%s\n' "$single_sorted_output" >&2
  exit 1
fi

sort_repo="$fixture_root/sort-repo"
mkdir -p "$sort_repo/src"
git -C "$sort_repo" init -q
git -C "$sort_repo" config user.email test@example.invalid
git -C "$sort_repo" config user.name preflight-test
: >"$sort_repo/src/A.java"
: >"$sort_repo/src/B.java"
for i in {1..12}; do
  printf 'class A { int value = 1; } // baseline line %02d\n' "$i" >>"$sort_repo/src/A.java"
  printf 'class B { int value = 1; } // baseline line %02d\n' "$i" >>"$sort_repo/src/B.java"
done
git -C "$sort_repo" add .
git -C "$sort_repo" commit -qm sort-base
: >"$sort_repo/src/A.java"
: >"$sort_repo/src/B.java"
for i in {1..12}; do
  printf 'class A { int value = 2; } // changed line %02d\n' "$i" >>"$sort_repo/src/A.java"
  printf 'class B { int value = 2; } // changed line %02d\n' "$i" >>"$sort_repo/src/B.java"
done
cat >"$sort_repo/application.yml" <<'EOF'
storage:
  endpoint: https://oss.example.invalid
  access-key-id: CHUNK_AKID_9f8e7d6c5b4a3210
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
previous=""
request_file=""
for argument in "$@"; do
  if [[ "$previous" == "--data-binary" && "$argument" == @* ]]; then
    request_file="${argument#@}"
  fi
  previous="$argument"
done
prompt="$(jq -r '.prompt' "$request_file")"
if printf '%s\n' "$prompt" | grep -q '^diff --git a/src/A.java'; then
  printf '{"response":"P2 src/A.java:1 - 低严重度示例问题。\\n影响：低严重度影响。\\n修复建议：低严重度修复。\\n验证方式：低严重度验证。","done":true,"done_reason":"stop"}\n'
else
  printf '{"response":"P0 src/B.java:1 - 高严重度示例问题。\\n影响：高严重度影响。\\n修复建议：高严重度修复。\\n验证方式：高严重度验证。","done":true,"done_reason":"stop"}\n'
fi
EOF
chmod +x "$fake_bin/curl"
sorted_output="$(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=1000 OLLAMA_REVIEW_CHUNK_NUM_PREDICT=512 \
  OLLAMA_REVIEW_CHUNK_TIMEOUT_SECONDS=30 OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS=120 \
  "$repo_root/bin/local-review.sh" --repo "$sort_repo")"
p0_line="$(printf '%s\n' "$sorted_output" | grep -n '^P0 ' | head -n1 | cut -d: -f1)"
p2_line="$(printf '%s\n' "$sorted_output" | grep -n '^P2 ' | head -n1 | cut -d: -f1)"
if [[ -z "$p0_line" || -z "$p2_line" || "$p0_line" -ge "$p2_line" ]]; then
  echo 'aggregated findings were not globally sorted by severity' >&2
  printf '%s\n' "$sorted_output" >&2
  exit 1
fi
chunk_credential_count="$(printf '%s\n' "$sorted_output" | grep -c '^P1 application.yml:3 - 配置文件新增了疑似硬编码凭据。' | tr -d ' ')"
[[ "$chunk_credential_count" -ge 1 ]] || {
  echo 'chunked security preflight finding disappeared' >&2
  printf '%s\n' "$sorted_output" >&2
  exit 1
}
if printf '%s\n' "$sorted_output" | awk 'BEGIN { RS="" } /^P1 application\.yml:3 / { if ($0 !~ /影响：/ || $0 !~ /修复建议：/ || $0 !~ /验证方式：/) exit 1 }'; then
  :
else
  echo 'chunked preflight finding lost required fields' >&2
  printf '%s\n' "$sorted_output" >&2
  exit 1
fi

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P1 src/main/java/com/example/api/client/Client.java:5 - 缺少完整审计字段。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
if PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo" >/dev/null 2>&1; then
  echo 'finding without impact/fix/verification fields was incorrectly accepted' >&2
  exit 1
fi

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P1 src/main/java/com/example/api/client/Client.java:5 - incomplete","done":false,"done_reason":"length"}\n'
EOF
chmod +x "$fake_bin/curl"
if PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo" >/dev/null 2>&1; then
  echo 'done=false response was incorrectly accepted' >&2
  exit 1
fi

if PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  OLLAMA_REVIEW_NUM_CTX=4096 OLLAMA_REVIEW_NUM_PREDICT=512 \
  OLLAMA_REVIEW_INPUT_RESERVE_TOKENS=256 \
  "$repo_root/bin/local-review.sh" --repo "$repo" >/dev/null 2>&1; then
  echo 'over-budget prompt was sent instead of rejected before Ollama' >&2
  exit 1
fi

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P1 src/main/java/com/example/api/client/Consumer.java:999 - 行号越界示例。\\n影响：示例影响。\\n修复建议：示例修复。\\n验证方式：示例验证。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
if PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo" >/dev/null 2>&1; then
  echo 'out-of-range finding line was incorrectly accepted' >&2
  exit 1
fi

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P1 src/main/java/com/example/api/client/Consumer.java:1 - 同行字段示例。影响：示例影响。修复建议：示例修复。验证方式：示例验证。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
compact_output="$(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
printf '%s\n' "$compact_output" | grep -F '同行字段示例' >/dev/null || {
  echo 'valid single-line finding fields were incorrectly rejected' >&2
  printf '%s\n' "$compact_output" >&2
  exit 1
}

retry_count_file="$fixture_root/retry-count"
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count=0
if [[ -f "${RETRY_COUNT_FILE:?}" ]]; then
  count="$(<"$RETRY_COUNT_FILE")"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$RETRY_COUNT_FILE"
if (( count < 3 )); then
  exit 56
fi
printf '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" RETRY_COUNT_FILE="$retry_count_file" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned OLLAMA_REVIEW_RETRY_ATTEMPTS=2 \
  "$repo_root/bin/local-review.sh" --repo "$repo" >/dev/null
[[ "$(<"$retry_count_file")" == "3" ]] || {
  echo 'transient Ollama failures were not retried within the configured limit' >&2
  cat "$retry_count_file" >&2
  exit 1
}

budget_context="$fixture_root/oversized-context.txt"
budget_curl_marker="$fixture_root/budget-curl.marker"
awk 'BEGIN { for (i = 0; i < 30000; i++) printf "context-%06d\n", i }' >"$budget_context"
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
touch "${BUDGET_CURL_MARKER:?}"
exit 99
EOF
chmod +x "$fake_bin/curl"
if PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" BUDGET_CURL_MARKER="$budget_curl_marker" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo" --context "$budget_context" >/dev/null 2>"$fixture_root/budget-error.log"; then
  echo 'over-budget prompt was sent or unexpectedly accepted' >&2
  exit 1
fi
grep -F '超过可用预算' "$fixture_root/budget-error.log" >/dev/null || {
  echo 'over-budget prompt did not report the input budget' >&2
  cat "$fixture_root/budget-error.log" >&2
  exit 1
}
[[ ! -e "$budget_curl_marker" ]] || {
  echo 'over-budget prompt contacted Ollama instead of failing closed' >&2
  exit 1
}

line_range_error="$fixture_root/line-range-error"
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P1 src/main/java/com/example/api/client/Consumer.java:999 - 行号超出文件范围的示例问题。\\n影响：示例影响。\\n修复建议：示例修复。\\n验证方式：示例验证。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
if PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo" > /dev/null 2>"$line_range_error"; then
  echo 'out-of-range finding line was incorrectly accepted' >&2
  exit 1
fi
grep -F '行号超出当前文件范围' "$line_range_error" >/dev/null || {
  echo 'line-range validation did not explain the rejected location' >&2
  cat "$line_range_error" >&2
  exit 1
}

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 99
EOF
chmod +x "$fake_bin/curl"
model_failure_error="$fixture_root/model-failure-error"
if PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  OLLAMA_REVIEW_RETRY_ATTEMPTS=0 \
  "$repo_root/bin/local-review.sh" --repo "$repo" >/dev/null 2>"$model_failure_error"; then
  echo 'model failure was incorrectly accepted' >&2
  exit 1
fi
grep -F '以下是已确定的预检发现' "$model_failure_error" >/dev/null || {
  echo 'deterministic preflight findings were hidden after model failure' >&2
  cat "$model_failure_error" >&2
  exit 1
}
grep -F '当前提交快照缺少仓库内类型 com.example.api.dto.DeletedDTO' "$model_failure_error" >/dev/null || {
  echo 'build preflight diagnostic was missing after model failure' >&2
  cat "$model_failure_error" >&2
  exit 1
}

cat >"$repo/src/main/java/com/example/api/client/StorageDelete.java" <<'EOF'
package com.example.api.client;

final class StorageDelete {
    private final FileRepository fileRepository;
    private final FileStorageService fileStorageService;

    void delete(Long id) {
        SysFile file = fileRepository.getRequired(id);
        fileRepository.delete(id);
        fileStorageService.delete(file.getObjectKey());
    }
}
EOF
git -C "$repo" add src/main/java/com/example/api/client/StorageDelete.java
git -C "$repo" commit -qm storage-delete-base
sed -i '' '/fileStorageService.delete(file.getObjectKey());/d' "$repo/src/main/java/com/example/api/client/StorageDelete.java"
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
storage_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned "$repo_root/bin/local-review.sh" --repo "$repo")"
printf '%s\n' "$storage_output" | grep -F '删除文件元数据时移除了对象存储清理' >/dev/null || {
  echo 'missing storage-delete lifecycle preflight' >&2
  printf '%s\n' "$storage_output" >&2
  exit 1
}

printf 'preflight regression passed\n'
