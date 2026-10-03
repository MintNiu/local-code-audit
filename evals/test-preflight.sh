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
export OLLAMA_REVIEW_NUM_CTX=65536
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
# Keep all fixture invocations isolated from a real review running in another
# terminal; the production runner still defaults to its normal global lock.
export OLLAMA_REVIEW_LOCK_DIR="$tmp_dir/ollama.lock"
trap 'rm -rf "$fixture_root"' EXIT

mkdir -p "$fake_bin" "$tmp_dir" "$repo/src/main/java/com/example/api/client" "$repo/src/main/java/com/example/api/dto" "$repo/src/test/java/com/example/api/dto" "$(dirname "$context")"

# The Java method window helper must survive nested parameter annotations,
# checked exceptions, and braces inside strings. This is intentionally tested
# outside the project-shaped preflights because a parser regression would
# otherwise become a silent payment/inventory false negative.
java_window_fixture="$fixture_root/AnnotatedMethod.java"
cat >"$java_window_fixture" <<'EOF'
final class AnnotatedMethod {
    @RequestParam(name = "{")
    private void target(@RequestParam(name = "}") Long id)
            throws IllegalStateException {
        String brace = "}";
        if (id != null) {
            throw new IllegalStateException(brace);
        }
    }

    private void next() {
        String brace = "{";
    }
}
EOF
java_window_target_line="$(grep -n 'throw new IllegalStateException' "$java_window_fixture" | cut -d: -f1)"
java_window_output="$(python3 "$repo_root/bin/java-method-window.py" "$java_window_fixture" "$java_window_target_line")"
printf '%s\n' "$java_window_output" | grep -F 'private void target(' >/dev/null
printf '%s\n' "$java_window_output" | grep -F 'String brace = "}";' >/dev/null
if printf '%s\n' "$java_window_output" | grep -F 'private void next()' >/dev/null; then
  echo 'Java method window helper crossed into the next method' >&2
  exit 1
fi

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
cat >"$repo/application-credential-repeated-default.yml" <<'EOF'
operation-log:
  internal-token: ${GATEWAY_INTERNAL_TOKEN:platform-localhost-shared-internal-token}
gateway:
  internal-token: ${GATEWAY_INTERNAL_TOKEN:platform-localhost-shared-internal-token}
platform:
  job:
    access-token: ${XXL_JOB_ACCESS_TOKEN:${GATEWAY_INTERNAL_TOKEN:platform-localhost-shared-internal-token}}
    internal-token: ${GATEWAY_INTERNAL_TOKEN:platform-localhost-shared-internal-token}
api-resource:
  sync:
    internal-token: ${GATEWAY_INTERNAL_TOKEN:platform-localhost-shared-internal-token}
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
mkdir -p "$repo/sql"
cat >"$repo/sql/client-secret-migration.sql" <<'EOF'
INSERT INTO sys_application (`client_id`, `client_secret`, `status`)
VALUES ('audit-app', 'audit-secret-static', 1);
EOF
cat >"$repo/sql/client-secret-placeholder.sql" <<'EOF'
INSERT INTO sys_application (`client_id`, `client_secret`, `status`)
VALUES ('audit-app', '${AUDIT_CLIENT_SECRET}', 1);
EOF
mkdir -p "$repo/src/main/java/com/example/api/shoppingcart" "$repo/doc"
cat >"$repo/src/main/java/com/example/api/shoppingcart/ShoppingCartApplication.java" <<'EOF'
package com.example.api.shoppingcart;

final class ShoppingCartApplication {
    void list(Long retailerId, Long storeId) {
        // contract context is supplied by the request
    }

    void buildItem(Sku sku) {
        setSalePrice(sku.getRetailPrice());
    }

    void setSalePrice(java.math.BigDecimal value) {
        // fixture sink
    }

    interface Sku {
        java.math.BigDecimal getRetailPrice();
    }
}
EOF
cat >"$repo/doc/shopping-cart.md" <<'EOF'
# Shopping cart

The retailerId and storeId fields are used for real-time pricing (实时取价).
EOF
cat >"$repo/application-prod-username.yml" <<'EOF'
spring:
  cloud:
    nacos:
      username: ${NACOS_USERNAME:nacos}
      password: ${NACOS_PASSWORD:nacos}
EOF
cat >"$repo/application-cluster-platform.yml" <<'EOF'
spring:
  cloud:
    nacos:
      discovery:
        # 按机器名隔离本地集群，但 COMPUTERNAME 只在 Windows 默认存在。
        cluster-name: ${NACOS_DISCOVERY_CLUSTER:${COMPUTERNAME:NY-TEST-LOCAL}}
EOF
cat >"$repo/application-cluster-cross-platform-safe.yml" <<'EOF'
spring:
  cloud:
    nacos:
      discovery:
        cluster-name: ${NACOS_DISCOVERY_CLUSTER:${HOSTNAME:LOCAL}}
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
        String parameterName =
                TOKEN_HEADER;
        String queryName =
                parameterName;
        return request.getParameter(
                queryName
        );
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/QueryTokenInlineCommentAlias.java" <<'EOF'
package com.example.api.client;

import jakarta.servlet.http.HttpServletRequest;

final class QueryTokenInlineCommentAlias {
    private static final String TOKEN_HEADER = "x-token";

    String read(HttpServletRequest request) {
        String queryName = // keep the alias explicit
                TOKEN_HEADER;
        return request.getParameter(queryName);
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
        String queryValue =
                token;
        String finalValue =
                queryValue;
        return "https://internal.example/download?x-token=" + finalValue;
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/UrlSecretInlineCommentAlias.java" <<'EOF'
package com.example.api.client;

final class UrlSecretInlineCommentAlias {
    String build(String token) {
        String queryValue = /* direct credential alias */ token;
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

cat >"$repo/src/main/java/com/example/api/client/SplitDivisionSlashBefore.java" <<'EOF'
package com.example.api.client;

final class SplitDivisionSlashBefore {
    int divide(Integer a, Integer b) {
        return a
            / b;
    }
}
EOF
git -C "$repo" add src/main/java/com/example/api/client/SplitDivisionSlashBefore.java
git -C "$repo" commit -qm split-division-slash-before-base
sed -i '' 's|/ b;|/ b + 1;|' "$repo/src/main/java/com/example/api/client/SplitDivisionSlashBefore.java"

cat >"$repo/src/main/java/com/example/api/client/SplitDivisionSlashAfter.java" <<'EOF'
package com.example.api.client;

final class SplitDivisionSlashAfter {
    int divide(Integer a, Integer b) {
        return a /
            b;
    }
}
EOF
git -C "$repo" add src/main/java/com/example/api/client/SplitDivisionSlashAfter.java
git -C "$repo" commit -qm split-division-slash-after-base
sed -i '' 's|            b;|            b + 1;|' "$repo/src/main/java/com/example/api/client/SplitDivisionSlashAfter.java"

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

cat >"$repo/src/main/java/com/example/api/client/TextBlockDivide.java" <<'EOF'
package com.example.api.client;

final class TextBlockDivide {
    int divide(Integer divisor) {
        String example = """
                a / b
                """;
        return 10 / divisor;
    }
}
EOF
git -C "$repo" add src/main/java/com/example/api/client/TextBlockDivide.java
git -C "$repo" commit -qm text-block-divide-base
sed -i '' 's/a \/ b/a \/ changed/' "$repo/src/main/java/com/example/api/client/TextBlockDivide.java"

cat >"$repo/src/main/java/com/example/api/client/SplitTextBlockDivide.java" <<'EOF'
package com.example.api.client;

final class SplitTextBlockDivide {
    int divide(Integer divisor) {
        String example = """
                line one
                line two
                line three
                line four
                line five
                line six
                line seven
                line eight
                a / b
                line ten
                line eleven
                """;
        return 10 / divisor;
    }
}
EOF
git -C "$repo" add src/main/java/com/example/api/client/SplitTextBlockDivide.java
git -C "$repo" commit -qm split-text-block-divide-base
sed -i '' 's/a \/ b/a \/ changed/' "$repo/src/main/java/com/example/api/client/SplitTextBlockDivide.java"

cat >"$repo/src/main/java/com/example/api/client/SplitBlockCommentDivide.java" <<'EOF'
package com.example.api.client;

final class SplitBlockCommentDivide {
    int divide(Integer divisor) {
        /*
         * comment line one
         * comment line two
         * comment line three
         * comment line four
         * comment line five
         * comment line six
         * comment line seven
         * comment line eight
         * a / b
         * comment line ten
         */
        return 10 / divisor;
    }
}
EOF
git -C "$repo" add src/main/java/com/example/api/client/SplitBlockCommentDivide.java
git -C "$repo" commit -qm split-block-comment-divide-base
sed -i '' 's/a \/ b/a \/ changed/' "$repo/src/main/java/com/example/api/client/SplitBlockCommentDivide.java"

cat >"$repo/src/main/java/com/example/api/client/QueryTokenFalsePositive.java" <<'EOF'
package com.example.api.client;

final class QueryTokenFalsePositive {
    String read(javax.servlet.http.HttpServletRequest request) {
        String first = request.getParameter("tokenizer");
        String second = request.getParameter("authorizationCode");
        return first + second;
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/QueryTokenUppercase.java" <<'EOF'
package com.example.api.client;

final class QueryTokenUppercase {
    String read(javax.servlet.http.HttpServletRequest request) {
        return request.getParameter("X-Token");
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/ReverseGuardDivide.java" <<'EOF'
package com.example.api.client;

final class ReverseGuardDivide {
    int divide(Integer a, Integer b) {
        if (b != 0) return 0;
        return 30 / b;
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/CommentGuardDivide.java" <<'EOF'
package com.example.api.client;

final class CommentGuardDivide {
    int divide(Integer a, Integer b) {
        // if (b == 0) return 0;
        return 30 / b;
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/SafeZeroDivide.java" <<'EOF'
package com.example.api.client;

final class SafeZeroDivide {
    int divide(Integer a, Integer b) {
        if (b == 0) throw new IllegalArgumentException("zero");
        return 30 / b;
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/ChainDivide.java" <<'EOF'
package com.example.api.client;

final class ChainDivide {
    int divide(Integer a, Integer b, Integer c) {
        return a / b / c;
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

cat >"$repo/src/main/java/com/example/api/client/TokenBuilderUserId.java" <<'EOF'
package com.example.api.client;

final class TokenBuilderUserId {
    String build(String userId) {
        return org.springframework.web.util.UriComponentsBuilder
            .fromUriString("https://internal.example/download")
            .queryParam("token", userId)
            .toUriString();
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/FormatUserId.java" <<'EOF'
package com.example.api.client;

final class FormatUserId {
    String build(String userId) {
        return String.format("https://internal.example/download?token=%s", userId);
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/FormatToken.java" <<'EOF'
package com.example.api.client;

final class FormatToken {
    String build(String authToken) {
        return String.format("https://internal.example/download?token=%s", authToken);
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/AppendToken.java" <<'EOF'
package com.example.api.client;

final class AppendToken {
    String build(String authToken) {
        return new StringBuilder("https://internal.example/download?token=")
            .append(authToken)
            .toString();
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/AppendUserId.java" <<'EOF'
package com.example.api.client;

final class AppendUserId {
    String build(String userId) {
        return new StringBuilder("https://internal.example/download?token=")
            .append(userId)
            .toString();
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/CrossLineToken.java" <<'EOF'
package com.example.api.client;

final class CrossLineToken {
    String build(String authToken) {
        return "https://internal.example/download?token=" +
            authToken;
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/CrossLineUserId.java" <<'EOF'
package com.example.api.client;

final class CrossLineUserId {
    String build(String userId) {
        return "https://internal.example/download?token=" +
            userId;
    }
}
EOF

cat >"$repo/src/main/java/com/example/api/client/QueryTokenAliasReassigned.java" <<'EOF'
package com.example.api.client;

final class QueryTokenAliasReassigned {
    String read(javax.servlet.http.HttpServletRequest request) {
        String parameterName = TOKEN_HEADER;
        parameterName = "safe";
        return request.getParameter(parameterName);
    }

    private static final String TOKEN_HEADER = "x-token";
}
EOF

cat >"$repo/src/main/java/com/example/api/client/UrlSecretAliasReassigned.java" <<'EOF'
package com.example.api.client;

final class UrlSecretAliasReassigned {
    String build(String token, String resourceId) {
        String queryValue = token;
        queryValue = resourceId;
        return "https://internal.example/download?x-token=" + queryValue;
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

# Signature recovery must stay within the method that contains the changed
# division.  The previous method has an Integer parameter with the same name,
# but the changed method uses a primitive int and must remain clean.
cat >"$repo/src/main/java/com/example/api/client/PreviousMethodScopeDivide.java" <<'EOF'
package com.example.api.client;

final class PreviousMethodScopeDivide {
    int old(Integer denominator) {
        return 10 / denominator;
    }

    int current(int denominator) {
        return 100 / denominator;
    }
}
EOF
git -C "$repo" add src/main/java/com/example/api/client/PreviousMethodScopeDivide.java
git -C "$repo" commit -qm previous-method-scope-divide-base
sed -i '' 's/return 100 \/ denominator;/return 200 \/ denominator;/' \
  "$repo/src/main/java/com/example/api/client/PreviousMethodScopeDivide.java"

# Two changed methods in one hunk must keep boxed-Integer evidence scoped to
# the containing method. The primitive method uses the same parameter names
# but must not inherit the previous method's java-divide finding.
cat >"$repo/src/main/java/com/example/api/client/SameHunkMethodScopeDivide.java" <<'EOF'
package com.example.api.client;

final class SameHunkMethodScopeDivide {
    int boxed(Integer a, Integer b) {
        return 10 / b;
    }

    int primitive(int a, int b) {
        return 100 / b;
    }
}
EOF
git -C "$repo" add src/main/java/com/example/api/client/SameHunkMethodScopeDivide.java
git -C "$repo" commit -qm same-hunk-method-scope-divide-base
sed -i '' -e 's/return 10 \/ b;/return 20 \/ b;/' -e 's/return 100 \/ b;/return 200 \/ b;/' \
  "$repo/src/main/java/com/example/api/client/SameHunkMethodScopeDivide.java"

# Fully-qualified return types are common in generated or deliberately
# explicit Java code. Signature recovery must still recognize the containing
# method instead of falling back to a previous method or file scope.
cat >"$repo/src/main/java/com/example/api/client/QualifiedReturnDivide.java" <<'EOF'
package com.example.api.client;

final class QualifiedReturnDivide {
    java.lang.Integer divide(Integer a, Integer b) {
        return 10 / b;
    }
}
EOF
git -C "$repo" add src/main/java/com/example/api/client/QualifiedReturnDivide.java
git -C "$repo" commit -qm qualified-return-divide-base
sed -i '' 's/return 10 \/ b;/return 20 \/ b;/' \
  "$repo/src/main/java/com/example/api/client/QualifiedReturnDivide.java"

cat >"$repo/src/main/java/com/example/api/client/InlineAnnotatedDivide.java" <<'EOF'
package com.example.api.client;

final class InlineAnnotatedDivide {
    @Deprecated(since = "fixture") java.lang.Integer divide(Integer a, Integer b) {
        return 10 / b;
    }
}
EOF
git -C "$repo" add src/main/java/com/example/api/client/InlineAnnotatedDivide.java
git -C "$repo" commit -qm inline-annotated-divide-base
sed -i '' 's/return 10 \/ b;/return 20 \/ b;/' \
  "$repo/src/main/java/com/example/api/client/InlineAnnotatedDivide.java"

cat >"$repo/src/main/java/com/example/api/client/InlineArrayAnnotatedDivide.java" <<'EOF'
package com.example.api.client;

final class InlineArrayAnnotatedDivide {
    @SuppressWarnings({"unused", "fixture"}) java.lang.Integer divide(Integer a, Integer b) {
        return 10 / b;
    }
}
EOF
git -C "$repo" add src/main/java/com/example/api/client/InlineArrayAnnotatedDivide.java
git -C "$repo" commit -qm inline-array-annotated-divide-base
sed -i '' 's/return 10 \/ b;/return 20 \/ b;/' \
  "$repo/src/main/java/com/example/api/client/InlineArrayAnnotatedDivide.java"

# Complex denominators are intentionally left to the model.  Reducing a
# ternary expression to its first identifier would report a false zero-risk
# even though the changed code explicitly substitutes a non-zero value.
cat >"$repo/src/main/java/com/example/api/client/TernarySafeDivide.java" <<'EOF'
package com.example.api.client;

final class TernarySafeDivide {
    int divide(Integer a, Integer b) {
        return a / (b == 0 ? 1 : b);
    }
}
EOF
git -C "$repo" add src/main/java/com/example/api/client/TernarySafeDivide.java
git -C "$repo" commit -qm ternary-safe-divide-base
sed -i '' 's/b == 0 ? 1 : b/b == 0 ? 2 : b/' \
  "$repo/src/main/java/com/example/api/client/TernarySafeDivide.java"

cat >"$repo/src/main/java/com/example/api/client/Client.java" <<'EOF'
package com.example.api.client;

import com.example.api.dto.MissingDTO;

public interface Client {
    MissingDTO call(MissingDTO request);
}
EOF

cat >"$repo/src/main/java/com/example/api/client/MultipleMissing.java" <<'EOF'
package com.example.api.client;

import com.example.api.dto.MissingAlpha;
import com.example.api.dto.MissingBeta;

public interface MultipleMissing {
    MissingAlpha call(MissingBeta request);
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
grep -F 'P1 src/main/java/com/example/api/client/MultipleMissing.java:3,4' "$capture" >/dev/null || {
  echo 'multiple missing imports were not aggregated with all affected lines' >&2
  cat "$capture" >&2
  exit 1
}
grep -F '删除一个类、过滤器、配置或适配器本身不是缺陷证据' "$capture" >/dev/null || {
  echo 'missing deleted-file evidence boundary in review prompt' >&2
  cat "$capture" >&2
  exit 1
}
grep -F '只要输出了任意一个 P0、P1、P2、P3 或信息问题，就禁止再附带' "$capture" >/dev/null || {
  echo 'missing mixed-clean output protocol in review prompt' >&2
  cat "$capture" >&2
  exit 1
}
grep -F '不得把“文档/README 与代码一致”“实现正确”“无需额外修复”“符合契约”' "$capture" >/dev/null || {
  echo 'missing non-finding documentation summary boundary in review prompt' >&2
  cat "$capture" >&2
  exit 1
}
grep -F '在线会话 token 返回预检边界' "$capture" >/dev/null || {
  echo 'missing raw session token response boundary in review prompt' >&2
  cat "$capture" >&2
  exit 1
}
grep -F '销售寻货目标仓预检边界' "$capture" >/dev/null || {
  echo 'missing sales-stock warehouse ownership boundary in review prompt' >&2
  cat "$capture" >&2
  exit 1
}
grep -F 'MissingAlpha（第 3 行）' "$capture" >/dev/null || {
  echo 'aggregated build finding omitted the first missing type' >&2
  cat "$capture" >&2
  exit 1
}
grep -F 'MissingBeta（第 4 行）' "$capture" >/dev/null || {
  echo 'aggregated build finding omitted the second missing type' >&2
  cat "$capture" >&2
  exit 1
}
multiple_missing_count="$(grep -o 'P1 src/main/java/com/example/api/client/MultipleMissing.java:' "$capture" | wc -l | tr -d '[:space:]')"
[[ "$multiple_missing_count" == 1 ]] || {
  echo 'multiple missing imports were counted as repeated root causes' >&2
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
grep -F 'P1 src/main/java/com/example/api/client/QueryTokenInlineCommentAlias.java' "$capture" >/dev/null || {
  echo 'missing query-token inline-comment alias preflight' >&2
  cat "$capture" >&2
  exit 1
}
grep -F 'P1 src/main/java/com/example/api/client/UrlSecretInlineCommentAlias.java' "$capture" >/dev/null || {
  echo 'missing URL credential inline-comment alias preflight' >&2
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
grep -F 'P1 src/main/java/com/example/api/client/FormatToken.java' "$capture" >/dev/null || {
  echo 'missing String.format URL credential preflight' >&2
  cat "$capture" >&2
  exit 1
}
for url_builder_fixture in AppendToken CrossLineToken; do
  grep -F "P1 src/main/java/com/example/api/client/${url_builder_fixture}.java" "$capture" >/dev/null || {
    echo "missing cross-line URL credential preflight for ${url_builder_fixture}" >&2
    cat "$capture" >&2
    exit 1
  }
done
if grep -F 'P1 src/main/java/com/example/api/client/TokenBuilderUserId.java' "$capture" >/dev/null || \
   grep -F 'P1 src/main/java/com/example/api/client/FormatUserId.java' "$capture" >/dev/null || \
   grep -F 'P1 src/main/java/com/example/api/client/AppendUserId.java' "$capture" >/dev/null || \
   grep -F 'P1 src/main/java/com/example/api/client/CrossLineUserId.java' "$capture" >/dev/null; then
  echo 'URL builder preflight treated an ordinary user id as a credential' >&2
  cat "$capture" >&2
  exit 1
fi
if grep -F 'P1 src/main/java/com/example/api/client/QueryTokenAliasReassigned.java' "$capture" >/dev/null || \
   grep -F 'P1 src/main/java/com/example/api/client/UrlSecretAliasReassigned.java' "$capture" >/dev/null; then
  echo 'URL alias preflight kept a stale secret alias after reassignment' >&2
  cat "$capture" >&2
  exit 1
fi
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
# The fake transport stores JSON, so prompt newlines are escaped rather than
# appearing as physical lines; count the exact finding prefix in the payload.
repeated_default_count="$(grep -o 'P1 application-credential-repeated-default.yml:' "$capture" | wc -l | tr -d '[:space:]')"
[[ "$repeated_default_count" == "5" ]] || {
  echo 'repeated hardcoded credential findings were collapsed or missed' >&2
  cat "$capture" >&2
  exit 1
}
grep -F 'P1 application-credential-remote-default.yml' "$capture" >/dev/null || {
  echo 'missing remote JDBC/service default credential preflight' >&2
  cat "$capture" >&2
  exit 1
}
grep -F 'P1 sql/client-secret-migration.sql:' "$capture" >/dev/null || {
  echo 'missing SQL client_secret literal preflight' >&2
  cat "$capture" >&2
  exit 1
}
if grep -F 'P1 sql/client-secret-placeholder.sql:' "$capture" >/dev/null; then
  echo 'SQL client_secret placeholder was incorrectly reported as a literal credential' >&2
  cat "$capture" >&2
  exit 1
fi
grep -F 'P1 src/main/java/com/example/api/shoppingcart/ShoppingCartApplication.java:' "$capture" >/dev/null || {
  echo 'missing shopping-cart price-tier preflight' >&2
  cat "$capture" >&2
  exit 1
}

logical_warehouse_repo="$fixture_root/logical-warehouse-sku-repo"
logical_capture="$fixture_root/logical-request.json"
mkdir -p "$logical_warehouse_repo/src/main/java/com/bit/erp/application/warehouse" \
  "$logical_warehouse_repo/src/main/java/com/bit/erp/repository/warehouse" \
  "$logical_warehouse_repo/src/main/java/com/bit/erp/domain/warehouse"
git -C "$logical_warehouse_repo" init -q
git -C "$logical_warehouse_repo" config user.email test@example.invalid
git -C "$logical_warehouse_repo" config user.name preflight-logical-warehouse-sku
cat >"$logical_warehouse_repo/src/main/java/com/bit/erp/application/warehouse/LogicalWarehouseApplication.java" <<'EOF'
package com.bit.erp.application.warehouse;

final class LogicalWarehouseApplication {
    private final LogicalWarehouseSkuRepository logicalWarehouseSkuRepository = new LogicalWarehouseSkuRepository();

    void replace(Long logicalWarehouseId, java.util.List<Object> lines) {
        logicalWarehouseSkuRepository.save(logicalWarehouseId, lines);
    }
}
EOF
cat >"$logical_warehouse_repo/src/main/java/com/bit/erp/repository/warehouse/LogicalWarehouseSkuRepository.java" <<'EOF'
package com.bit.erp.repository.warehouse;

final class LogicalWarehouseSkuRepository {
    void save(Long logicalWarehouseId, java.util.List<Object> lines) {
        deleteByLogicalWarehouseId(logicalWarehouseId);
        insert(lines);
    }

    void deleteByLogicalWarehouseId(Long logicalWarehouseId) {}
    void insert(java.util.List<Object> lines) {}
}
EOF
cat >"$logical_warehouse_repo/src/main/java/com/bit/erp/domain/warehouse/ErpLogicalWarehouseSku.java" <<'EOF'
package com.bit.erp.domain.warehouse;

final class ErpLogicalWarehouseSku {
    private Integer occupiedQuantity;
}
EOF
git -C "$logical_warehouse_repo" add .
git -C "$logical_warehouse_repo" commit -qm logical-warehouse-sku-base
sed -i '' 's/logicalWarehouseSkuRepository.save(logicalWarehouseId, lines);/logicalWarehouseSkuRepository.replace(logicalWarehouseId, lines);/' \
  "$logical_warehouse_repo/src/main/java/com/bit/erp/application/warehouse/LogicalWarehouseApplication.java"
logical_warehouse_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$logical_capture" \
  "$repo_root/bin/local-review.sh" --repo "$logical_warehouse_repo")"
printf '%s\n' "$logical_warehouse_output" | grep -F '替换逻辑仓 SKU 明细前无条件删除旧行' >/dev/null || {
  echo 'missing logical-warehouse occupied SKU preflight' >&2
  printf '%s\n' "$logical_warehouse_output" >&2
  exit 1
}
for logical_warehouse_field in '影响：' '修复建议：' '验证方式：'; do
  logical_warehouse_field_count="$(printf '%s\n' "$logical_warehouse_output" | grep -c "$logical_warehouse_field" || true)"
  [[ "$logical_warehouse_field_count" -eq 1 ]] || {
    echo "logical-warehouse preflight field count mismatch for $logical_warehouse_field: $logical_warehouse_field_count" >&2
    printf '%s\n' "$logical_warehouse_output" >&2
    exit 1
  }
done
sed -i '' 's/void deleteByLogicalWarehouseId(Long logicalWarehouseId) {}/void deleteByLogicalWarehouseId(Long logicalWarehouseId) { if (occupiedQuantity > 0) throw new IllegalStateException(); }/' \
  "$logical_warehouse_repo/src/main/java/com/bit/erp/repository/warehouse/LogicalWarehouseSkuRepository.java"
guarded_logical_warehouse_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$logical_capture" \
  "$repo_root/bin/local-review.sh" --repo "$logical_warehouse_repo")"
if printf '%s\n' "$guarded_logical_warehouse_output" | grep -F '替换逻辑仓 SKU 明细前无条件删除旧行' >/dev/null; then
  echo 'logical-warehouse preflight reported a repository with an occupied-row guard' >&2
  printf '%s\n' "$guarded_logical_warehouse_output" >&2
  exit 1
fi

sales_return_repo="$fixture_root/sales-return-idempotency-repo"
sales_return_capture="$fixture_root/sales-return-idempotency-request.json"
mkdir -p "$sales_return_repo/src/main/java/com/bit/erp/application/salesreturn" \
  "$sales_return_repo/sql"
git -C "$sales_return_repo" init -q
git -C "$sales_return_repo" config user.email test@example.invalid
git -C "$sales_return_repo" config user.name preflight-sales-return-idempotency
cat >"$sales_return_repo/src/main/java/com/bit/erp/application/salesreturn/SalesReturnApplication.java" <<'EOF'
package com.bit.erp.application.salesreturn;

final class SalesReturnApplication {
    public SalesReturnApplicationVO createAndSubmit(CreateDTO dto) {
        Long tenantId = 1L;
        String requestNo = dto.requestNo();
        ErpSalesReturnOrder existing = returnRepository.findByRequestNo(tenantId, requestNo);
        ErpSalesReturnOrder order = buildOrder(dto);
        returnRepository.save(order);
        return toVO(order);
    }

    private final ReturnRepository returnRepository = new ReturnRepository();
    private ErpSalesReturnOrder buildOrder(CreateDTO dto) { return new ErpSalesReturnOrder(); }
    private SalesReturnApplicationVO toVO(ErpSalesReturnOrder order) { return new SalesReturnApplicationVO(); }
    record CreateDTO(String requestNo) {}
    static final class SalesReturnApplicationVO {}
    static final class ErpSalesReturnOrder {}
    static final class ReturnRepository {
        ErpSalesReturnOrder findByRequestNo(Long tenantId, String requestNo) { return null; }
        void save(ErpSalesReturnOrder order) {}
    }
}
EOF
cat >"$sales_return_repo/sql/platform_erp.sql" <<'EOF'
CREATE TABLE erp_sales_return_order (
  tenant_id BIGINT NOT NULL,
  request_no VARCHAR(64) NOT NULL,
  is_deleted TINYINT NOT NULL,
  UNIQUE KEY uk_sales_return_order_request_tenant (tenant_id, request_no, is_deleted)
);
EOF
git -C "$sales_return_repo" add .
git -C "$sales_return_repo" commit -qm sales-return-idempotency-base
sed -i '' 's/findByRequestNo(tenantId, requestNo);/findByRequestNo(tenantId, requestNo); \/\/ changed/' \
  "$sales_return_repo/src/main/java/com/bit/erp/application/salesreturn/SalesReturnApplication.java"
sales_return_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$sales_return_capture" \
  "$repo_root/bin/local-review.sh" --repo "$sales_return_repo")"
printf '%s\n' "$sales_return_output" | grep -F '退货创建并提交在租户级唯一 requestNo 前只做普通查询' >/dev/null || {
  echo 'missing sales-return idempotency race preflight' >&2
  printf '%s\n' "$sales_return_output" >&2
  exit 1
}
for sales_return_field in '影响：' '修复建议：' '验证方式：'; do
  sales_return_field_count="$(printf '%s\n' "$sales_return_output" | grep -c "$sales_return_field" || true)"
  [[ "$sales_return_field_count" -eq 1 ]] || {
    echo "sales-return idempotency preflight field count mismatch for $sales_return_field: $sales_return_field_count" >&2
    printf '%s\n' "$sales_return_output" >&2
    exit 1
  }
done
sed -i '' 's/findByRequestNo(tenantId, requestNo); \/\/ changed/findByRequestNoForUpdate(tenantId, requestNo); \/\/ changed/' \
  "$sales_return_repo/src/main/java/com/bit/erp/application/salesreturn/SalesReturnApplication.java"
guarded_sales_return_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$sales_return_capture" \
  "$repo_root/bin/local-review.sh" --repo "$sales_return_repo")"
if printf '%s\n' "$guarded_sales_return_output" | grep -F '退货创建并提交在租户级唯一 requestNo 前只做普通查询' >/dev/null; then
  echo 'sales-return idempotency preflight reported a flow with request-row locking' >&2
  printf '%s\n' "$guarded_sales_return_output" >&2
  exit 1
fi

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P1 application-prod-username.yml:4 - 配置文件新增了疑似硬编码凭据。\\n影响：凭据可能泄漏。\\n修复建议：改用运行时注入。\\n验证方式：检查生产配置。\\n\\nP1 application-prod-username.yml:5 - 配置文件新增了疑似硬编码凭据。\\n影响：凭据可能泄漏。\\n修复建议：改用运行时注入。\\n验证方式：检查生产配置。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
username_default_output="$(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
if printf '%s\n' "$username_default_output" | grep -F 'P1 application-prod-username.yml:4' >/dev/null; then
  echo 'username-only default was incorrectly reported as a credential finding' >&2
  printf '%s\n' "$username_default_output" >&2
  exit 1
fi
printf '%s\n' "$username_default_output" | grep -F 'P1 application-prod-username.yml:5' >/dev/null || {
  echo 'password default was hidden while filtering username-only credential finding' >&2
  printf '%s\n' "$username_default_output" >&2
  exit 1
}
grep -F 'P2 application-cluster-platform.yml:' "$capture" >/dev/null || {
  echo 'missing cross-platform Nacos cluster fallback preflight' >&2
  cat "$capture" >&2
  exit 1
}
cluster_fallback_count="$(grep -o 'P2 application-cluster-platform.yml:' "$capture" | wc -l | tr -d '[:space:]')"
[[ "$cluster_fallback_count" == 1 ]] || {
  echo 'cross-platform Nacos finding was duplicated instead of exact-deduplicated' >&2
  cat "$capture" >&2
  exit 1
}
if grep -F 'P2 application-cluster-cross-platform-safe.yml:' "$capture" >/dev/null; then
  echo 'cross-platform Nacos preflight reported an explicit HOSTNAME fallback' >&2
  cat "$capture" >&2
  exit 1
fi
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

# Removing insecure defaults and requiring runtime environment variables is
# intentional fail-closed behavior. A model must not turn the absence of a
# deployment variable into a speculative startup/connectivity P1; concrete
# credential, tenancy, or compatibility evidence must still remain visible.
cat >"$repo/application-fail-closed.yml" <<'EOF'
spring:
  cloud:
    nacos:
      username: ${NACOS_USERNAME}
      password: ${NACOS_PASSWORD}
  datasource:
    username: ${PLATFORM_DB_USERNAME}
    password: ${PLATFORM_DB_PASSWORD}
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P1 application-fail-closed.yml:4-5 - 默认值被移除，缺少环境变量时服务无法启动。影响：配置缺失可能导致连接失败。修复建议：保留默认值或增加回退。验证方式：不设置环境变量启动服务。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
fail_closed_output="$(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
if printf '%s\n' "$fail_closed_output" | grep -F 'application-fail-closed.yml:' >/dev/null; then
  echo 'fail-closed configuration removal was incorrectly reported as a finding' >&2
  printf '%s\n' "$fail_closed_output" >&2
  exit 1
fi
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P1 application-fail-closed.yml:4-5 - 默认值被移除，同时跨租户配置被错误共享。影响：租户边界可能被绕过。修复建议：按租户隔离配置并继续要求运行时凭据。验证方式：用两个租户分别启动并核对配置。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
fail_closed_independent_output="$(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
printf '%s\n' "$fail_closed_independent_output" | grep -F 'P1 application-fail-closed.yml:' >/dev/null || {
  echo 'fail-closed filter hid an independent tenant finding' >&2
  printf '%s\n' "$fail_closed_independent_output" >&2
  exit 1
}
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
if grep -F 'P1 src/main/java/com/example/api/client/TextBlockDivide.java' "$capture" >/dev/null; then
  echo 'Java division preflight reported a text-block-only expression' >&2
  exit 1
fi
if grep -F 'P1 src/main/java/com/example/api/client/SplitTextBlockDivide.java' "$capture" >/dev/null; then
  echo 'Java division preflight lost source text-block state across hunks' >&2
  exit 1
fi
if grep -F 'P1 src/main/java/com/example/api/client/SplitBlockCommentDivide.java' "$capture" >/dev/null; then
  echo 'Java division preflight lost source block-comment state across hunks' >&2
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
[[ "$duplicate_security_count" -ge 2 ]] || {
  echo 'security preflight or model finding was hidden' >&2
  printf '%s\n' "$duplicate_security_output" >&2
  exit 1
}

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P1 src/main/java/com/example/api/client/QueryTokenProxy.java:3-4 - 认证令牌从 URL 查询参数读取，可能进入日志。影响：凭据泄露。修复建议：只用请求头。验证方式：检查日志。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
broad_duplicate_output="$(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned "$repo_root/bin/local-review.sh" --repo "$repo")"
broad_duplicate_count="$(printf '%s\n' "$broad_duplicate_output" | grep -F 'P1 src/main/java/com/example/api/client/QueryTokenProxy.java:' | wc -l | tr -d ' ')"
[[ "$broad_duplicate_count" -ge 2 ]] || {
  echo 'broad model URL-token finding or exact preflight finding was hidden' >&2
  printf '%s\n' "$broad_duplicate_output" >&2
  exit 1
}
printf '%s\n' "$broad_duplicate_output" | grep -F 'QueryTokenProxy.java:3-4' >/dev/null || {
  echo 'broad model URL-token finding was hidden' >&2
  printf '%s\n' "$broad_duplicate_output" >&2
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
[[ "$duplicate_credential_count" -ge 3 ]] || {
  echo 'credential preflight or model findings were hidden' >&2
  printf '%s\n' "$duplicate_credential_output" >&2
  exit 1
}

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P2 application-credential.yml:3 - 凭据风险的低严重度描述。影响：凭据可能泄露。修复建议：改用密钥管理。验证方式：检查配置。\\n\\nP1 application-credential.yml:3 - 同一凭据风险的高严重度描述。影响：凭据会泄露。修复建议：立即轮换并移除。验证方式：检查历史和构建产物。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
severity_order_output="$(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
severity_order_count="$(printf '%s\n' "$severity_order_output" | grep -F 'application-credential.yml:3' | wc -l | tr -d ' ')"
[[ "$severity_order_count" -ge 3 ]] || {
  echo 'model severity variants or preflight finding were hidden' >&2
  printf '%s\n' "$severity_order_output" >&2
  exit 1
}
printf '%s\n' "$severity_order_output" | grep -F 'P2 application-credential.yml:3' >/dev/null || {
  echo 'lower-severity model finding was hidden' >&2
  printf '%s\n' "$severity_order_output" >&2
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
[[ "$independent_credential_count" -ge 3 ]] || {
  echo 'independent credential risk families or preflight finding were hidden' >&2
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
  java_division_block="$(printf '%s\n' "$java_division_output" | sed -n "${java_division_line},$((java_division_line + 4))p")"
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
if printf '%s\n' "$java_division_output" | grep -F 'P1 src/main/java/com/example/api/client/PreviousMethodScopeDivide.java:' >/dev/null; then
  echo 'Java division preflight borrowed an Integer signature from a previous method' >&2
  printf '%s\n' "$java_division_output" >&2
  exit 1
fi
same_hunk_method_count="$(printf '%s\n' "$java_division_output" | grep -c 'P1 src/main/java/com/example/api/client/SameHunkMethodScopeDivide.java:' || true)"
[[ "$same_hunk_method_count" -eq 2 ]] || {
  echo 'Java division preflight did not keep boxed-Integer findings scoped to the method' >&2
  printf '%s\n' "$java_division_output" >&2
  exit 1
}
if printf '%s\n' "$java_division_output" | grep -F 'P1 src/main/java/com/example/api/client/SameHunkMethodScopeDivide.java:9' >/dev/null; then
  echo 'Java division preflight borrowed boxed-Integer evidence into a primitive method' >&2
  printf '%s\n' "$java_division_output" >&2
  exit 1
fi
printf '%s\n' "$java_division_output" | grep -F 'P1 src/main/java/com/example/api/client/QualifiedReturnDivide.java:' >/dev/null || {
  echo 'Java division preflight missed a fully-qualified return type signature' >&2
  printf '%s\n' "$java_division_output" >&2
  exit 1
}
printf '%s\n' "$java_division_output" | grep -F 'P1 src/main/java/com/example/api/client/InlineAnnotatedDivide.java:' >/dev/null || {
  echo 'Java division preflight missed an inline-annotated method signature' >&2
  printf '%s\n' "$java_division_output" >&2
  exit 1
}
printf '%s\n' "$java_division_output" | grep -F 'P1 src/main/java/com/example/api/client/InlineArrayAnnotatedDivide.java:' >/dev/null || {
  echo 'Java division preflight missed an inline array-annotated method signature' >&2
  printf '%s\n' "$java_division_output" >&2
  exit 1
}
if printf '%s\n' "$java_division_output" | grep -F 'P1 src/main/java/com/example/api/client/TernarySafeDivide.java:' >/dev/null; then
  echo 'Java division preflight treated a guarded ternary denominator as a bare variable' >&2
  printf '%s\n' "$java_division_output" >&2
  exit 1
fi
if printf '%s\n' "$java_division_output" | grep -F 'P1 src/main/java/com/example/api/client/QueryTokenFalsePositive.java' >/dev/null; then
  echo 'URL-token preflight reported a parameter-name prefix false positive' >&2
  printf '%s\n' "$java_division_output" >&2
  exit 1
fi
printf '%s\n' "$java_division_output" | grep -F 'P1 src/main/java/com/example/api/client/QueryTokenUppercase.java' >/dev/null || {
  echo 'URL-token preflight missed case-insensitive X-Token' >&2
  printf '%s\n' "$java_division_output" >&2
  exit 1
}
for reverse_guard_fixture in ReverseGuardDivide CommentGuardDivide; do
  printf '%s\n' "$java_division_output" | grep -F "P1 src/main/java/com/example/api/client/${reverse_guard_fixture}.java" >/dev/null || {
    echo "missing Java division preflight for ${reverse_guard_fixture}" >&2
    printf '%s\n' "$java_division_output" >&2
    exit 1
  }
  printf '%s\n' "$java_division_output" | grep -F "P1 src/main/java/com/example/api/client/${reverse_guard_fixture}.java:" | grep -F '除法分母未见非零保护' >/dev/null || {
    echo "zero-risk guard was incorrectly suppressed for ${reverse_guard_fixture}" >&2
    printf '%s\n' "$java_division_output" >&2
    exit 1
  }
done
if printf '%s\n' "$java_division_output" | grep -F 'P1 src/main/java/com/example/api/client/SafeZeroDivide.java:' | grep -F '除法分母未见非零保护' >/dev/null; then
  echo 'true zero guard did not suppress the deterministic zero-risk finding' >&2
  printf '%s\n' "$java_division_output" >&2
  exit 1
fi
chain_division_count="$(printf '%s\n' "$java_division_output" | grep -c 'P1 src/main/java/com/example/api/client/ChainDivide.java:' || true)"
[[ "$chain_division_count" -ge 4 ]] || {
  echo 'Java division preflight missed one side of a chained division' >&2
  printf '%s\n' "$java_division_output" >&2
  exit 1
}
for split_division_fixture in SplitDivisionSlashBefore SplitDivisionSlashAfter; do
  printf '%s\n' "$java_division_output" | grep -F "P1 src/main/java/com/example/api/client/${split_division_fixture}.java:" >/dev/null || {
    echo "Java division preflight missed a cross-line division in ${split_division_fixture}" >&2
    printf '%s\n' "$java_division_output" >&2
    exit 1
  }
done

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

# An unchanged alias can be outside the diff context.  The current source
# snapshot must still resolve it when the newly added query read uses it.
cat >"$repo/src/main/java/com/example/api/client/PreExistingQueryTokenAlias.java" <<'EOF'
package com.example.api.client;

final class PreExistingQueryTokenAlias {
    private static final String TOKEN_HEADER = "x-token";

    String read(javax.servlet.http.HttpServletRequest request) {
        String parameterName = TOKEN_HEADER;
        int one = 1;
        int two = 2;
        int three = 3;
        int four = 4;
        int five = 5;
        return request.getParameter("safe");
    }
}
EOF
git -C "$repo" add src/main/java/com/example/api/client/PreExistingQueryTokenAlias.java
git -C "$repo" commit -qm pre-existing-query-token-alias-base
sed -i '' 's/return request.getParameter("safe");/return request.getParameter(parameterName);/' \
  "$repo/src/main/java/com/example/api/client/PreExistingQueryTokenAlias.java"
preexisting_query_token_alias_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
printf '%s\n' "$preexisting_query_token_alias_output" | grep -F 'P1 src/main/java/com/example/api/client/PreExistingQueryTokenAlias.java:' >/dev/null || {
  echo 'source snapshot did not recover an unchanged query-token alias' >&2
  printf '%s\n' "$preexisting_query_token_alias_output" >&2
  exit 1
}

cat >"$repo/src/main/java/com/example/api/client/PreExistingUppercaseQueryTokenAlias.java" <<'EOF'
package com.example.api.client;

final class PreExistingUppercaseQueryTokenAlias {
    private static final String TOKEN_HEADER = "X-Token";

    String read(javax.servlet.http.HttpServletRequest request) {
        String parameterName = TOKEN_HEADER;
        int one = 1;
        int two = 2;
        int three = 3;
        int four = 4;
        int five = 5;
        return request.getParameter("safe");
    }
}
EOF
git -C "$repo" add src/main/java/com/example/api/client/PreExistingUppercaseQueryTokenAlias.java
git -C "$repo" commit -qm pre-existing-uppercase-query-token-alias-base
sed -i '' 's/return request.getParameter("safe");/return request.getParameter(parameterName);/' \
  "$repo/src/main/java/com/example/api/client/PreExistingUppercaseQueryTokenAlias.java"
preexisting_uppercase_query_token_alias_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
printf '%s\n' "$preexisting_uppercase_query_token_alias_output" | grep -F 'P1 src/main/java/com/example/api/client/PreExistingUppercaseQueryTokenAlias.java:' >/dev/null || {
  echo 'source snapshot missed an uppercase X-Token alias' >&2
  printf '%s\n' "$preexisting_uppercase_query_token_alias_output" >&2
  exit 1
}

cat >"$repo/src/main/java/com/example/api/client/PreExistingUrlSecretAlias.java" <<'EOF'
package com.example.api.client;

final class PreExistingUrlSecretAlias {
    String build(String token) {
        String queryValue = token;
        int one = 1;
        int two = 2;
        int three = 3;
        int four = 4;
        int five = 5;
        return "https://internal.example/download?id=resource";
    }
}
EOF
git -C "$repo" add src/main/java/com/example/api/client/PreExistingUrlSecretAlias.java
git -C "$repo" commit -qm pre-existing-url-secret-alias-base
sed -i '' 's/return "https:\/\/internal.example\/download?id=resource";/return "https:\/\/internal.example\/download?x-token=" + queryValue;/' \
  "$repo/src/main/java/com/example/api/client/PreExistingUrlSecretAlias.java"
preexisting_url_secret_alias_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
printf '%s\n' "$preexisting_url_secret_alias_output" | grep -F 'P1 src/main/java/com/example/api/client/PreExistingUrlSecretAlias.java:' >/dev/null || {
  echo 'source snapshot did not recover an unchanged URL secret alias' >&2
  printf '%s\n' "$preexisting_url_secret_alias_output" >&2
  exit 1
}

# Alias state must survive separate unified-diff hunks in one file: the
# constant/parameter alias can be changed in one hunk while the query read is
# changed much farther away.  This is the shape that previously made
# java-token-url findings depend on hunk boundaries.
cat >"$repo/src/main/java/com/example/api/client/CrossHunkTokenAlias.java" <<'EOF'
package com.example.api.client;

final class CrossHunkTokenAlias {
    private static final String TOKEN_HEADER = "x-token";

    String read(javax.servlet.http.HttpServletRequest request) {
        String parameterName = "safe";
        int one = 1;
        int two = 2;
        int three = 3;
        int four = 4;
        int five = 5;
        int six = 6;
        int seven = 7;
        int eight = 8;
        return request.getParameter("safe");
    }
    String unrelated(javax.servlet.http.HttpServletRequest request) {
        String parameterName = "safe";
        int nine = 9;
        int ten = 10;
        int eleven = 11;
        int twelve = 12;
        return request.getParameter("safe");
    }
}
EOF
git -C "$repo" add src/main/java/com/example/api/client/CrossHunkTokenAlias.java
git -C "$repo" commit -qm cross-hunk-token-base
perl -0pi -e 's/String parameterName = "safe";/String parameterName = TOKEN_HEADER;/; s/return request\.getParameter\("safe"\);/return request.getParameter(parameterName);/' \
  "$repo/src/main/java/com/example/api/client/CrossHunkTokenAlias.java"
cross_hunk_token_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
cross_hunk_token_count="$(printf '%s\n' "$cross_hunk_token_output" | grep -c 'P1 src/main/java/com/example/api/client/CrossHunkTokenAlias.java:' || true)"
if [[ "$cross_hunk_token_count" != "1" ]]; then
  echo 'cross-hunk query-token alias was not carried through the file' >&2
  printf '%s\n' "$cross_hunk_token_output" >&2
  exit 1
fi

# Method-scoped aliases must also survive wrapped Java signatures and a brace
# on the following line.  The second method deliberately reuses the same
# local variable name with an ordinary value; reporting it would recreate the
# cross-method false positive that motivated method-scoped alias tracking.
cat >"$repo/src/main/java/com/example/api/client/WrappedTokenAlias.java" <<'EOF'
package com.example.api.client;

final class WrappedTokenAlias {
    private static final String TOKEN_HEADER = "x-token";

    String first(
            javax.servlet.http.HttpServletRequest request
    )
    {
        String json = """
                {"nested": {"token": "safe"}}
                """;
        String marker = "{";
        String commentMarker = "/* not code */";
        String parameterName = "safe";
        return request.getParameter("safe");
    }

    String second(
            javax.servlet.http.HttpServletRequest request
    )
    {
        String json = """
                {"nested": {"token": "safe"}}
                """;
        String marker = "{";
        String commentMarker = "/* not code */";
        String parameterName = "safe";
        return request.getParameter("safe");
    }
}
EOF
git -C "$repo" add src/main/java/com/example/api/client/WrappedTokenAlias.java
git -C "$repo" commit -qm wrapped-token-alias-base
cat >"$repo/src/main/java/com/example/api/client/WrappedTokenAlias.java" <<'EOF'
package com.example.api.client;

final class WrappedTokenAlias {
    private static final String TOKEN_HEADER = "x-token";

    String first(
            javax.servlet.http.HttpServletRequest request
    )
    {
        String json = """
                {"nested": {"token": "safe"}}
                """;
        String marker = "{";
        String commentMarker = "/* not code */";
        String parameterName = TOKEN_HEADER;
        return request.getParameter(parameterName);
    }

    String second(
            javax.servlet.http.HttpServletRequest request
    )
    {
        String json = """
                {"nested": {"token": "safe"}}
                """;
        String marker = "{";
        String commentMarker = "/* not code */";
        String parameterName = "safe";
        return request.getParameter("safe");
    }
}
EOF
wrapped_token_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
wrapped_token_count="$(printf '%s\n' "$wrapped_token_output" | grep -c 'P1 src/main/java/com/example/api/client/WrappedTokenAlias.java:' || true)"
if [[ "$wrapped_token_count" != "1" ]]; then
  echo 'wrapped-signature query-token alias scope was not isolated' >&2
  printf '%s\n' "$wrapped_token_output" >&2
  exit 1
fi

cat >"$repo/src/main/java/com/example/api/client/QualifiedReturnTokenAlias.java" <<'EOF'
package com.example.api.client;

final class QualifiedReturnTokenAlias {
    private static final String TOKEN_HEADER = "x-token";

    java.lang.String first(javax.servlet.http.HttpServletRequest request) {
        String parameterName = "safe";
        return request.getParameter("safe");
    }

    java.lang.String second(javax.servlet.http.HttpServletRequest request) {
        String parameterName = "safe";
        return request.getParameter("safe");
    }
}
EOF
git -C "$repo" add src/main/java/com/example/api/client/QualifiedReturnTokenAlias.java
git -C "$repo" commit -qm qualified-return-token-base
perl -0pi -e 's/(java\.lang\.String first\([^}]+?String parameterName = )"safe"/$1TOKEN_HEADER/; s/(java\.lang\.String first\([^}]+?return request\.getParameter\()"safe"/$1parameterName/; s/(java\.lang\.String second\([^}]+?return request\.getParameter\()"safe"/$1parameterName/' \
  "$repo/src/main/java/com/example/api/client/QualifiedReturnTokenAlias.java"
qualified_return_token_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
qualified_return_token_count="$(printf '%s\n' "$qualified_return_token_output" | grep -c 'P1 src/main/java/com/example/api/client/QualifiedReturnTokenAlias.java:' || true)"
if [[ "$qualified_return_token_count" != "1" ]]; then
  echo 'fully-qualified return type token alias scope was not isolated' >&2
  printf '%s\n' "$qualified_return_token_output" >&2
  exit 1
fi

cat >"$repo/src/main/java/com/example/api/client/InlineArrayAnnotatedTokenAlias.java" <<'EOF'
package com.example.api.client;

final class InlineArrayAnnotatedTokenAlias {
    private static final String TOKEN_HEADER = "x-token";

    @SuppressWarnings({"unused", "fixture"}) java.lang.String first(javax.servlet.http.HttpServletRequest request) {
        String parameterName = "safe";
        return request.getParameter("safe");
    }

    @SuppressWarnings({"unused", "fixture"}) java.lang.String second(javax.servlet.http.HttpServletRequest request) {
        String parameterName = "safe";
        return request.getParameter("safe");
    }
}
EOF
git -C "$repo" add src/main/java/com/example/api/client/InlineArrayAnnotatedTokenAlias.java
git -C "$repo" commit -qm inline-array-annotated-token-base
perl -0pi -e 's/(java\.lang\.String first\([^}]+?String parameterName = )"safe"/$1TOKEN_HEADER/; s/(java\.lang\.String first\([^}]+?return request\.getParameter\()"safe"/$1parameterName/; s/(java\.lang\.String second\([^}]+?return request\.getParameter\()"safe"/$1parameterName/' \
  "$repo/src/main/java/com/example/api/client/InlineArrayAnnotatedTokenAlias.java"
inline_array_annotated_token_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
inline_array_annotated_token_count="$(printf '%s\n' "$inline_array_annotated_token_output" | grep -c 'P1 src/main/java/com/example/api/client/InlineArrayAnnotatedTokenAlias.java:' || true)"
if [[ "$inline_array_annotated_token_count" != "1" ]]; then
  echo 'inline array annotation token alias scope was not isolated' >&2
  printf '%s\n' "$inline_array_annotated_token_output" >&2
  exit 1
fi

# A class-level constant may alias TOKEN_HEADER and be consumed inside a
# method.  Keep that high-confidence constant available across method scopes;
# otherwise a refactor from the literal `TOKEN_HEADER` to `QUERY_NAME` would
# silently lose the finding.
cat >"$repo/src/main/java/com/example/api/client/FieldTokenAlias.java" <<'EOF'
package com.example.api.client;

final class FieldTokenAlias {
    private static final String TOKEN_HEADER = "x-token";
    private static final String QUERY_NAME = TOKEN_HEADER;

    String read(javax.servlet.http.HttpServletRequest request) {
        return request.getParameter("safe");
    }
}
EOF
git -C "$repo" add src/main/java/com/example/api/client/FieldTokenAlias.java
git -C "$repo" commit -qm field-token-alias-base
sed -i '' 's/request.getParameter("safe")/request.getParameter(QUERY_NAME)/' \
  "$repo/src/main/java/com/example/api/client/FieldTokenAlias.java"
field_token_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
field_token_count="$(printf '%s\n' "$field_token_output" | grep -c 'P1 src/main/java/com/example/api/client/FieldTokenAlias.java:' || true)"
if [[ "$field_token_count" != "1" ]]; then
  echo 'class-level token alias was not carried into the method scope' >&2
  printf '%s\n' "$field_token_output" >&2
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

# An explicit downstream service context can prove a tenant boundary even
# when the main repository only contains a declarative internal client.  The
# deterministic preflight must report claim/ack methods that omit the tenant
# header when the context shows tenant-bearing outbox data and ignoreTenant
# access.  A context without the bypass evidence must remain clean.
workflow_context_dir="$fixture_root/downstream/workflow"
mkdir -p "$workflow_context_dir"
cat >"$repo/src/main/java/com/example/api/client/WorkflowClient.java" <<'EOF'
package com.example.api.client;

import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.service.annotation.HttpExchange;
import org.springframework.web.service.annotation.PostExchange;

@HttpExchange("/workflow/v1/internal")
interface WorkflowClient {
    @PostExchange("/events/claims")
    Object claimEvents(@RequestHeader("X-Gateway-Token") String token,
                       @RequestBody Object request);

    @PostExchange("/events/{eventId}/ack")
    Object acknowledge(@RequestHeader("X-Gateway-Token") String token,
                       @PathVariable Long eventId,
                       @RequestBody Object request);
}
EOF
cat >"$repo/src/main/java/com/example/api/client/TenantSafeWorkflowClient.java" <<'EOF'
package com.example.api.client;

import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.service.annotation.HttpExchange;
import org.springframework.web.service.annotation.PostExchange;

@HttpExchange("/workflow/v1/internal")
interface TenantSafeWorkflowClient {
    @PostExchange("/events/claims")
    Object claimEvents(@RequestHeader("X-Gateway-Token") String token,
                       @RequestHeader("X-Tenant-Id") Long tenantId,
                       @RequestBody Object request);
}
EOF
cat >"$workflow_context_dir/WorkflowController.java" <<'EOF'
package downstream.workflow;

final class WorkflowController {
    Object claim(String token, Object request) { return service.claim(request); }
    Object ack(String token, Long eventId, Object request) { return service.ack(eventId, request); }
    private final WorkflowService service = new WorkflowService();
}
EOF
cat >"$workflow_context_dir/WorkflowService.java" <<'EOF'
package downstream.workflow;

final class WorkflowService {
    Object claim(Object request) {
        return ignoreTenant(() -> outbox.selectByApplicationCode(request));
    }
    Object ack(Long eventId, Object request) {
        return ignoreTenant(() -> outbox.updateById(eventId, request));
    }
    private <T> T ignoreTenant(java.util.function.Supplier<T> action) { return action.get(); }
    private final WorkflowOutbox outbox = new WorkflowOutbox();
}
EOF
cat >"$workflow_context_dir/WorkflowOutbox.java" <<'EOF'
package downstream.workflow;

final class WorkflowOutbox {
    Long tenantId;
    Object selectByApplicationCode(Object request) { return null; }
    Object updateById(Long eventId, Object request) { return null; }
}
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
workflow_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo" \
  --context "$workflow_context_dir/WorkflowController.java" \
  --context "$workflow_context_dir/WorkflowService.java" \
  --context "$workflow_context_dir/WorkflowOutbox.java")"
workflow_count="$(printf '%s\n' "$workflow_output" | grep -c 'WorkflowClient.java:' || true)"
[[ "$workflow_count" == "2" ]] || {
  echo 'context tenant preflight missed claim/ack methods without tenant header' >&2
  printf '%s\n' "$workflow_output" >&2
  exit 1
}
if printf '%s\n' "$workflow_output" | grep -F 'TenantSafeWorkflowClient.java:' >/dev/null; then
  echo 'context tenant preflight reported a client that already carries X-Tenant-Id' >&2
  printf '%s\n' "$workflow_output" >&2
  exit 1
fi
# The endpoint annotation and gateway header may be unchanged context while a
# DTO/parameter line inside the same method is the only added line.  Recover
# that method from context, but still require an actual added line before
# emitting a finding.
git -C "$repo" add src/main/java/com/example/api/client/WorkflowClient.java
git -C "$repo" commit -qm workflow-client-context-base -- src/main/java/com/example/api/client/WorkflowClient.java
sed -i '' 's/@PathVariable Long eventId/@PathVariable Integer eventId/' \
  "$repo/src/main/java/com/example/api/client/WorkflowClient.java"
partial_workflow_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo" \
  --context "$workflow_context_dir/WorkflowController.java" \
  --context "$workflow_context_dir/WorkflowService.java" \
  --context "$workflow_context_dir/WorkflowOutbox.java")"
partial_workflow_count="$(printf '%s\n' "$partial_workflow_output" | grep -c 'WorkflowClient.java:' || true)"
[[ "$partial_workflow_count" == "1" ]] || {
  echo 'context tenant preflight missed a changed method whose endpoint was context-only' >&2
  printf '%s\n' "$partial_workflow_output" >&2
  exit 1
}
cat >"$workflow_context_dir/WorkflowSafeService.java" <<'EOF'
package downstream.workflow;

final class WorkflowSafeService {
    Long tenantId;
    Object claim(Object request) { return outbox.selectByTenant(tenantId, request); }
    private final WorkflowOutbox outbox = new WorkflowOutbox();
}
EOF
safe_workflow_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo" \
  --context "$workflow_context_dir/WorkflowSafeService.java")"
if printf '%s\n' "$safe_workflow_output" | grep -F 'WorkflowClient.java:' >/dev/null; then
  echo 'context tenant preflight reported a client without ignoreTenant evidence' >&2
  printf '%s\n' "$safe_workflow_output" >&2
  exit 1
fi
no_context_workflow_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
if printf '%s\n' "$no_context_workflow_output" | grep -F 'WorkflowClient.java:' >/dev/null; then
  echo 'context tenant preflight ran without explicit downstream context' >&2
  printf '%s\n' "$no_context_workflow_output" >&2
  exit 1
fi

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

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"   \u001b[0m  ","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
if PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo" >/dev/null 2>&1; then
  echo 'blank/ control-only response was incorrectly converted to clean' >&2
  exit 1
fi

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"未发现阻塞问题","done":true,"done_reason":"error"}\n'
EOF
chmod +x "$fake_bin/curl"
if PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo" >/dev/null 2>&1; then
  echo 'done_reason=error response was incorrectly accepted' >&2
  exit 1
fi

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"response":"未发现阻塞问题","done":true}'
EOF
chmod +x "$fake_bin/curl"
if PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo" >/dev/null 2>&1; then
  echo 'missing done_reason response was incorrectly accepted' >&2
  exit 1
fi

lock_repo="$fixture_root/lock-repo"
mkdir -p "$lock_repo/src/main/java/com/example/api/client"
git -C "$lock_repo" init -q
git -C "$lock_repo" config user.email test@example.invalid
git -C "$lock_repo" config user.name preflight-test
cat >"$lock_repo/src/main/java/com/example/api/client/LockOnly.java" <<'EOF'
package com.example.api.client;

final class LockOnly {
    void load() {
        // baseline
    }
}
EOF
git -C "$lock_repo" add .
git -C "$lock_repo" commit -qm lock-base
cat >"$lock_repo/src/main/java/com/example/api/client/LockOnly.java" <<'EOF'
package com.example.api.client;

import org.springframework.transaction.annotation.Transactional;

final class LockOnly {
    private final LockRepository repository = null;

    @Transactional
    void load() {
        repository.findByIdForUpdate(1L);
    }
}
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}'
EOF
chmod +x "$fake_bin/curl"
lock_only_output="$(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$lock_repo")"
[[ "$lock_only_output" == '未发现阻塞问题' ]] || {
  echo 'prompt-only lock evidence turned a clean review into empty/non-clean output' >&2
  printf '%s\n' "$lock_only_output" >&2
  exit 1
}

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

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P1 src/main/java/com/example/api/client/Consumer.java:1,999 - 逗号范围越界示例。\\n影响：示例影响。\\n修复建议：示例修复。\\n验证方式：示例验证。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
if PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo" >/dev/null 2>&1; then
  echo 'comma-separated out-of-range finding was incorrectly accepted' >&2
  exit 1
fi

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P1 src/main/java/com/example/api/client/Other.java:999 - 错误路径示例，影响 Consumer.java。\\n影响：示例影响。\\n修复建议：示例修复。\\n验证方式：示例验证。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
if PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo" >/dev/null 2>&1; then
  echo 'finding with an unrelated first-line path was incorrectly accepted' >&2
  exit 1
fi

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

# A unique bare basename is accepted as a location alias, but it must still
# use the aliased file's real line count for range validation.
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P1 Consumer.java:999 - 裸文件名行号越界。\\n影响：示例影响。\\n修复建议：示例修复。\\n验证方式：示例验证。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
bare_basename_range_error="$fixture_root/bare-basename-line-range-error"
if PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo" > /dev/null 2>"$bare_basename_range_error"; then
  echo 'out-of-range bare basename finding was incorrectly accepted' >&2
  exit 1
fi
grep -F '行号超出当前文件范围' "$bare_basename_range_error" >/dev/null || {
  echo 'bare basename line-range validation did not explain the rejected location' >&2
  cat "$bare_basename_range_error" >&2
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

mkdir -p "$repo/sql"
cat >"$repo/sql/platform_file.sql" <<'EOF'
CREATE DATABASE IF NOT EXISTS `platform_db_file`;
USE `platform_db_file`;
CREATE TABLE `sys_file` (`id` bigint);
EOF
cat >"$repo/sql/schema_variant.sql" <<'EOF'
CREATE SCHEMA IF NOT EXISTS `schema_a`;
USE `schema_a`;
CREATE TABLE `schema_table` (`id` bigint);
EOF
git -C "$repo" add sql/platform_file.sql sql/schema_variant.sql
git -C "$repo" commit -qm sql-schema-base
sed -i '' 's/CREATE DATABASE IF NOT EXISTS `platform_db_file`/CREATE DATABASE IF NOT EXISTS `platform_file`/' "$repo/sql/platform_file.sql"
sed -i '' 's/USE `schema_a`/USE `schema_b`/' "$repo/sql/schema_variant.sql"
cat >"$repo/sql/safe_schema.sql" <<'EOF'
CREATE DATABASE IF NOT EXISTS `safe_db`; -- keep the existing schema
USE `safe_db`; -- execute below in the same schema
EOF
cat >"$repo/sql/multiple_schema.sql" <<'EOF'
CREATE DATABASE IF NOT EXISTS `first_db`;
USE `second_db`;
CREATE DATABASE IF NOT EXISTS `third_db`;
USE `fourth_db`;
EOF
cat >"$repo/sql/create_only.sql" <<'EOF'
CREATE DATABASE IF NOT EXISTS `created_only`;
EOF
sql_schema_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned "$repo_root/bin/local-review.sh" --repo "$repo")"
printf '%s\n' "$sql_schema_output" | grep -F 'SQL 创建的数据库名与后续 USE 目标不一致' >/dev/null || {
  echo 'missing SQL CREATE/USE schema mismatch preflight' >&2
  printf '%s\n' "$sql_schema_output" >&2
  exit 1
}
for expected_schema_path in platform_file.sql schema_variant.sql; do
  printf '%s\n' "$sql_schema_output" | grep -F "$expected_schema_path" >/dev/null || {
    echo "missing SQL schema preflight finding for: $expected_schema_path" >&2
    printf '%s\n' "$sql_schema_output" >&2
    exit 1
  }
done
for safe_schema_path in safe_schema.sql multiple_schema.sql create_only.sql; do
  if printf '%s\n' "$sql_schema_output" | grep -F "$safe_schema_path" >/dev/null; then
    echo "SQL schema preflight reported a negative fixture: $safe_schema_path" >&2
    printf '%s\n' "$sql_schema_output" >&2
    exit 1
  fi
done

cat >"$repo/sql/trigger_migration.sql" <<'EOF'
DROP TRIGGER IF EXISTS trg_example_forbid_delete;
CREATE TRIGGER trg_example_forbid_delete
BEFORE DELETE ON example_table
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'history cannot be deleted';
END;
EOF
cat >"$repo/sql/safe_trigger.sql" <<'EOF'
DROP TRIGGER IF EXISTS trg_safe_forbid_delete;
CREATE TRIGGER trg_safe_forbid_delete
BEFORE DELETE ON safe_table
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'history cannot be deleted';
END;
EOF
git -C "$repo" add sql/trigger_migration.sql sql/safe_trigger.sql
git -C "$repo" commit -qm trigger-base
sed -i '' 's/CREATE TRIGGER trg_example_forbid_delete/CREATE TRIGGER prefixtrg_example_forbid_delete/' "$repo/sql/trigger_migration.sql"
sql_trigger_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned "$repo_root/bin/local-review.sh" --repo "$repo")"
printf '%s\n' "$sql_trigger_output" | grep -F 'SQL 迁移删除的触发器名称与重新创建的名称不一致' >/dev/null || {
  echo 'missing SQL trigger rename mismatch preflight' >&2
  printf '%s\n' "$sql_trigger_output" >&2
  exit 1
}
printf '%s\n' "$sql_trigger_output" | grep -F 'trigger_migration.sql' >/dev/null || {
  echo 'missing SQL trigger mismatch path' >&2
  printf '%s\n' "$sql_trigger_output" >&2
  exit 1
}
if printf '%s\n' "$sql_trigger_output" | grep -F 'safe_trigger.sql' >/dev/null; then
  echo 'SQL trigger preflight reported a safe same-name replacement' >&2
  printf '%s\n' "$sql_trigger_output" >&2
  exit 1
fi

mkdir -p "$repo/sql/migration"
cat >"$repo/sql/migration/V20260927__existing_database.sql" <<'EOF'
-- Migration applies to existing platform_file_db database.
ALTER TABLE old_table ADD COLUMN uploaded_at TIMESTAMP;
EOF
git -C "$repo" add sql/migration/V20260927__existing_database.sql
git -C "$repo" commit -qm migration-delete-base
python3 - <<'PY' "$repo/sql/migration/V20260927__existing_database.sql"
from pathlib import Path
import sys
Path(sys.argv[1]).unlink()
PY
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"response":"P1 sql/migration/V20260927__existing_database.sql:1-2 - 删除迁移脚本会导致已有数据库升级路径中断。\n影响：模型重复描述。\n修复建议：模型重复修复。\n验证方式：模型重复验证。","done":true,"done_reason":"stop"}'
EOF
chmod +x "$fake_bin/curl"
migration_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned "$repo_root/bin/local-review.sh" --repo "$repo")"
printf '%s\n' "$migration_output" | grep -F '删除版本化迁移脚本会中断已有数据库升级路径' >/dev/null || {
  echo 'missing deleted versioned-migration preflight' >&2
  printf '%s\n' "$migration_output" >&2
  exit 1
}
if [[ "$(printf '%s\n' "$migration_output" | grep -c 'sql/migration/V20260927__existing_database.sql')" -lt 2 ]]; then
  echo 'migration model or preflight finding was hidden' >&2
  printf '%s\n' "$migration_output" >&2
  exit 1
fi

# The migration-deletion case intentionally exercises malformed model output;
# restore the hermetic clean response before the following schema-snapshot
# assertions so that their result is attributable only to the new preflight.
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
printf '%s\n' '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}'
EOF
chmod +x "$fake_bin/curl"

# An existing CREATE TABLE IF NOT EXISTS snapshot does not upgrade deployed
# databases.  When the same commit adds a mapped Java property but no
# versioned migration, the deterministic preflight must surface one P1; a
# commit that includes a migration is the safe counterexample.
schema_snapshot_repo="$fixture_root/schema-snapshot-repo"
mkdir -p "$schema_snapshot_repo/sql" "$schema_snapshot_repo/src/main/java/example/inspection"
git -C "$schema_snapshot_repo" init -q
git -C "$schema_snapshot_repo" config user.email test@example.invalid
git -C "$schema_snapshot_repo" config user.name preflight-schema-snapshot
cat >"$schema_snapshot_repo/README.md" <<'EOF'
Existing databases must be upgraded with idempotent sql/migration scripts.
CREATE TABLE IF NOT EXISTS is only for empty-database initialization and does
not add columns to an existing table.
EOF
cat >"$schema_snapshot_repo/sql/platform_erp.sql" <<'EOF'
CREATE TABLE IF NOT EXISTS `erp_sales_return_inspection` (
    `id` BIGINT NOT NULL,
    PRIMARY KEY (`id`)
);
EOF
cat >"$schema_snapshot_repo/src/main/java/example/inspection/Inspection.java" <<'EOF'
package example.inspection;

final class Inspection {
    private Long id;
}
EOF
git -C "$schema_snapshot_repo" add .
git -C "$schema_snapshot_repo" commit -qm schema-snapshot-base
python3 - "$schema_snapshot_repo/sql/platform_erp.sql" "$schema_snapshot_repo/src/main/java/example/inspection/Inspection.java" <<'PY'
from pathlib import Path
import sys

schema = Path(sys.argv[1])
schema.write_text(schema.read_text().replace(
    '    `id` BIGINT NOT NULL,',
    '    `id` BIGINT NOT NULL,\n    `request_no` VARCHAR(64) DEFAULT NULL,',
    1,
))
java = Path(sys.argv[2])
java.write_text(java.read_text().replace(
    '    private Long id;',
    '    private Long id;\n    private String requestNo;',
    1,
))
PY
schema_snapshot_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$schema_snapshot_repo")"
printf '%s\n' "$schema_snapshot_output" | grep -F '已有表 schema 快照新增字段或索引' >/dev/null || {
  echo 'missing existing-schema snapshot migration preflight' >&2
  printf '%s\n' "$schema_snapshot_output" >&2
  exit 1
}
printf '%s\n' "$schema_snapshot_output" | grep -F 'sql/platform_erp.sql:' >/dev/null || {
  echo 'missing schema snapshot migration location' >&2
  printf '%s\n' "$schema_snapshot_output" >&2
  exit 1
}
if [[ "$(printf '%s\n' "$schema_snapshot_output" | grep -c '已有表 schema 快照新增字段或索引')" -ne 1 ]]; then
  echo 'schema snapshot migration preflight duplicated the same root' >&2
  printf '%s\n' "$schema_snapshot_output" >&2
  exit 1
fi

mkdir -p "$schema_snapshot_repo/sql/migration"
cat >"$schema_snapshot_repo/sql/migration/V20261002__inspection_request_no.sql" <<'EOF'
ALTER TABLE erp_sales_return_inspection ADD COLUMN request_no VARCHAR(64);
EOF
git -C "$schema_snapshot_repo" add sql/migration/V20261002__inspection_request_no.sql
git -C "$schema_snapshot_repo" commit -qm schema-snapshot-migration
python3 - "$schema_snapshot_repo/sql/platform_erp.sql" "$schema_snapshot_repo/src/main/java/example/inspection/Inspection.java" <<'PY'
from pathlib import Path
import sys

schema = Path(sys.argv[1])
schema.write_text(schema.read_text().replace(
    '`request_no` VARCHAR(64) DEFAULT NULL,',
    '`request_no` VARCHAR(64) DEFAULT NULL,\n    `attempt_no` INT DEFAULT NULL,',
    1,
))
java = Path(sys.argv[2])
java.write_text(java.read_text().replace(
    'private String requestNo;',
    'private String requestNo;\n    private Integer attemptNo;',
    1,
))
PY
schema_snapshot_safe_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$schema_snapshot_repo")"
if printf '%s\n' "$schema_snapshot_safe_output" | grep -F '已有表 schema 快照新增字段或索引' >/dev/null; then
  echo 'schema snapshot migration preflight reported a diff with an explicit migration' >&2
  printf '%s\n' "$schema_snapshot_safe_output" >&2
  exit 1
fi

cat >"$repo/src/main/java/com/example/api/client/GuardedClientProperties.java" <<'EOF'
package com.example.api.client;

import lombok.Data;

@Data
public class GuardedClientProperties {
    private String baseUrl = "http://localhost:8092";
    private String gatewayInternalToken;
    private String fileInternalToken;
}
EOF
cat >"$repo/src/main/java/com/example/api/client/GuardedClientAutoConfiguration.java" <<'EOF'
package com.example.api.client;

import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnClass;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.web.client.RestClient;
import org.springframework.web.service.invoker.HttpServiceProxyFactory;

@AutoConfiguration
@ConditionalOnClass({RestClient.class, HttpServiceProxyFactory.class})
@EnableConfigurationProperties(GuardedClientProperties.class)
public class GuardedClientAutoConfiguration {
    @Bean
    Object client(GuardedClientProperties properties) {
        if (properties.getGatewayInternalToken() == null
                || properties.getGatewayInternalToken().isBlank()) {
            throw new IllegalStateException("gateway token required");
        }
        if (properties.getFileInternalToken() == null
                || properties.getFileInternalToken().length() < 32) {
            throw new IllegalStateException("file token required");
        }
        return RestClient.builder().baseUrl(properties.getBaseUrl()).build();
    }
}
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"response":"P1 src/main/java/com/example/api/client/GuardedClientAutoConfiguration.java:1-24 - RestClient 和 HttpServiceProxyFactory 类型在当前提交中缺少。\n影响：可能无法构建。\n修复建议：补充依赖。\n验证方式：执行构建。\n\nP1 src/main/java/com/example/api/client/GuardedClientAutoConfiguration.java:16-20 - properties 参数缺少 null 检查。\n影响：可能 NPE。\n修复建议：增加检查。\n验证方式：传入 null。\n\nP1 src/main/java/com/example/api/client/GuardedClientAutoConfiguration.java:21-24 - gatewayInternalToken 和 fileInternalToken 缺少 null/空值检查。\n影响：可能 NPE。\n修复建议：增加检查。\n验证方式：传入空值。\n\nP1 src/main/java/com/example/api/client/GuardedClientAutoConfiguration.java:24 - baseUrl 缺少默认值和空值检查。\n影响：可能失败。\n修复建议：增加检查。\n验证方式：传入空值。","done":true,"done_reason":"stop"}'
EOF
chmod +x "$fake_bin/curl"
guarded_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned "$repo_root/bin/local-review.sh" --repo "$repo")"
if printf '%s\n' "$guarded_output" | grep -F 'GuardedClientAutoConfiguration.java' >/dev/null; then
  echo 'cross-file guard/default/ConditionalOnClass contradictions were not filtered' >&2
  printf '%s\n' "$guarded_output" >&2
  exit 1
fi

# A correlated tenant predicate inside an EXISTS subquery is direct evidence
# of tenant scoping. A generic model warning about missing isolation must not
# survive when the changed mapper visibly compares inner and outer tenant_id.
mkdir -p "$repo/src/main/resources"
cat >"$repo/src/main/resources/TenantScopedMapper.xml" <<'EOF'
<select id="findSelectable">
  SELECT * FROM hr_employment employment
  WHERE EXISTS (
    SELECT 1 FROM hr_assignment selectable_primary
    WHERE selectable_primary.tenant_id = employment.tenant_id
      AND selectable_primary.employment_id = employment.id
  )
</select>
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"response":"P2 src/main/resources/TenantScopedMapper.xml:4-6 - EXISTS 子查询未显式限制租户隔离，可能返回其他租户数据。\n影响：跨租户查询可能泄漏数据。\n修复建议：增加 tenant_id 约束。\n验证方式：使用两个租户执行查询。","done":true,"done_reason":"stop"}'
EOF
chmod +x "$fake_bin/curl"
tenant_guard_output="$(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo" 2>/dev/null)"
if printf '%s\n' "$tenant_guard_output" | grep -F 'TenantScopedMapper.xml' >/dev/null; then
  echo 'correlated tenant predicate did not filter the contradictory finding' >&2
  printf '%s\n' "$tenant_guard_output" >&2
  exit 1
fi

cat >"$repo/src/main/java/com/example/api/client/PresignedReplay.java" <<'EOF'
final class PresignedReplay {
    private final Store store;
    private final Sessions sessions;

    Ticket issue(String objectKey) {
        return store.presignPut(objectKey, 900);
    }

    void accept(Ticket ticket) {
        if (ticket.expiresAt().isAfter(java.time.Instant.now())) {
            store.put(ticket, ticket.objectKey());
        }
    }

    void cancel(String objectKey, long id) {
        store.delete(objectKey);
        sessions.markCancelled(id);
    }

    void cleanupExpired() {
        for (Session session : sessions.findActiveExpired()) {
            store.delete(session.objectKey());
        }
    }

    interface Store {
        Ticket presignPut(String key, long ttl);
        void put(Ticket ticket, String key);
        void delete(String key);
    }

    interface Sessions { Iterable<Session> findActiveExpired(); void markCancelled(long id); }
    interface Session { String objectKey(); }
    record Ticket(String objectKey, java.time.Instant expiresAt) {}
}
EOF
presigned_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned "$repo_root/bin/local-review.sh" --repo "$repo")"
printf '%s\n' "$presigned_output" | grep -F '取消后仍可重放有效的预签名上传票据' >/dev/null || {
  echo 'missing presigned-ticket replay preflight' >&2
  printf '%s\n' "$presigned_output" >&2
  exit 1
}

# Native ObjectInputStream on an HTTP request body is a separate high-impact
# root cause. The preflight must upgrade it to one P1 and the clean reader
# counterpart must remain untouched.
deserialization_repo="$fixture_root/deserialization-repo"
mkdir -p "$deserialization_repo/src/main/java/example"
git -C "$deserialization_repo" init -q
git -C "$deserialization_repo" config user.email test@example.invalid
git -C "$deserialization_repo" config user.name preflight-deserialization-test
cat >"$deserialization_repo/src/main/java/example/ImportEndpoint.java" <<'EOF'
package example;

final class ImportEndpoint {
    String read() { return "base"; }
}
EOF
git -C "$deserialization_repo" add .
git -C "$deserialization_repo" commit -qm base
cat >"$deserialization_repo/src/main/java/example/ImportEndpoint.java" <<'EOF'
package example;

import jakarta.servlet.http.HttpServletRequest;
import java.io.IOException;
import java.io.ObjectInputStream;

final class ImportEndpoint {
    Object read(HttpServletRequest request) throws IOException, ClassNotFoundException {
        try (ObjectInputStream input = new ObjectInputStream(request.getInputStream())) {
            return input.readObject();
        }
    }
}
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}'
EOF
chmod +x "$fake_bin/curl"
deserialization_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$deserialization_repo")"
printf '%s\n' "$deserialization_output" | grep -F '不可信 HTTP 输入直接进入 Java 原生反序列化' >/dev/null || {
  echo 'missing unsafe-deserialization preflight' >&2
  printf '%s\n' "$deserialization_output" >&2
  exit 1
}
deserialization_count="$(printf '%s\n' "$deserialization_output" | grep -Fc '反序列化远程代码执行风险')"
[[ "$deserialization_count" == 1 ]] || {
  echo "unsafe-deserialization preflight was duplicated (count=$deserialization_count)" >&2
  printf '%s\n' "$deserialization_output" >&2
  exit 1
}

deserialization_safe_repo="$fixture_root/deserialization-safe-repo"
mkdir -p "$deserialization_safe_repo/src/main/java/example"
git -C "$deserialization_safe_repo" init -q
git -C "$deserialization_safe_repo" config user.email test@example.invalid
git -C "$deserialization_safe_repo" config user.name preflight-deserialization-safe-test
cat >"$deserialization_safe_repo/src/main/java/example/ImportEndpoint.java" <<'EOF'
package example;

final class ImportEndpoint {
    String read() { return "base"; }
}
EOF
git -C "$deserialization_safe_repo" add .
git -C "$deserialization_safe_repo" commit -qm base
cat >"$deserialization_safe_repo/src/main/java/example/ImportEndpoint.java" <<'EOF'
package example;

import jakarta.servlet.http.HttpServletRequest;
import java.io.BufferedReader;
import java.io.IOException;

final class ImportEndpoint {
    String read(HttpServletRequest request) throws IOException {
        try (BufferedReader reader = request.getReader()) {
            return reader.readLine();
        }
    }
}
EOF
deserialization_safe_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$deserialization_safe_repo")"
if printf '%s\n' "$deserialization_safe_output" | grep -F '反序列化远程代码执行风险' >/dev/null; then
  echo 'safe HTTP reader triggered unsafe-deserialization preflight' >&2
  printf '%s\n' "$deserialization_safe_output" >&2
  exit 1
fi

# Default DOM parsing of an HTTP XML body must be treated as XXE unless the
# source explicitly disables DOCTYPE/external entities and external access.
xxe_repo="$fixture_root/xxe-repo"
mkdir -p "$xxe_repo/src/main/java/example"
git -C "$xxe_repo" init -q
git -C "$xxe_repo" config user.email test@example.invalid
git -C "$xxe_repo" config user.name preflight-xxe-test
cat >"$xxe_repo/src/main/java/example/ImportXmlEndpoint.java" <<'EOF'
package example;

final class ImportXmlEndpoint {
    String read() { return "base"; }
}
EOF
git -C "$xxe_repo" add .
git -C "$xxe_repo" commit -qm base
cat >"$xxe_repo/src/main/java/example/ImportXmlEndpoint.java" <<'EOF'
package example;

import jakarta.servlet.http.HttpServletRequest;
import java.io.IOException;
import java.io.InputStream;
import javax.xml.parsers.DocumentBuilderFactory;
import org.w3c.dom.Document;
import org.xml.sax.SAXException;
import static java.util.Objects.requireNonNull;

final class ImportXmlEndpoint {
    Document parse(HttpServletRequest request) throws IOException, SAXException {
        DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
        return factory.newDocumentBuilder().parse(request.getInputStream());
    }
}
EOF
xxe_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$xxe_repo")"
printf '%s\n' "$xxe_output" | grep -F 'XML 解析器直接处理不可信 HTTP XML' >/dev/null || {
  echo 'missing XXE preflight' >&2
  printf '%s\n' "$xxe_output" >&2
  exit 1
}
xxe_count="$(printf '%s\n' "$xxe_output" | grep -Fc '存在 XXE 风险')"
[[ "$xxe_count" == 1 ]] || {
  echo "XXE preflight was duplicated (count=$xxe_count)" >&2
  printf '%s\n' "$xxe_output" >&2
  exit 1
}

xxe_safe_repo="$fixture_root/xxe-safe-repo"
mkdir -p "$xxe_safe_repo/src/main/java/example"
git -C "$xxe_safe_repo" init -q
git -C "$xxe_safe_repo" config user.email test@example.invalid
git -C "$xxe_safe_repo" config user.name preflight-xxe-safe-test
cat >"$xxe_safe_repo/src/main/java/example/ImportXmlEndpoint.java" <<'EOF'
package example;

final class ImportXmlEndpoint {
    String read() { return "base"; }
}
EOF
git -C "$xxe_safe_repo" add .
git -C "$xxe_safe_repo" commit -qm base
cat >"$xxe_safe_repo/src/main/java/example/ImportXmlEndpoint.java" <<'EOF'
package example;

import jakarta.servlet.http.HttpServletRequest;
import java.io.IOException;
import javax.xml.parsers.DocumentBuilderFactory;
import org.w3c.dom.Document;
import org.xml.sax.SAXException;

final class ImportXmlEndpoint {
    Document parse(HttpServletRequest request) throws IOException, SAXException {
        if (request.getContentLengthLong() > 1_048_576L) {
            throw new IOException("XML body too large");
        }
        DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
        factory.setNamespaceAware(true);
        factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
        factory.setFeature("http://xml.org/sax/features/external-general-entities", false);
        factory.setFeature("http://xml.org/sax/features/external-parameter-entities", false);
        factory.setXIncludeAware(false);
        factory.setExpandEntityReferences(false);
        InputStream body = requireNonNull(request.getInputStream(), "request body");
        return factory.newDocumentBuilder().parse(body);
    }
}
EOF
xxe_safe_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$xxe_safe_repo")"
if printf '%s\n' "$xxe_safe_output" | grep -F '存在 XXE 风险' >/dev/null; then
  echo 'safe XML hardening triggered XXE preflight' >&2
  printf '%s\n' "$xxe_safe_output" >&2
  exit 1
fi

# URL allowlists must compare parsed hosts, not raw string prefixes.
url_allowlist_repo="$fixture_root/url-allowlist-repo"
mkdir -p "$url_allowlist_repo/src/main/java/com/example/security"
git -C "$url_allowlist_repo" init -q
git -C "$url_allowlist_repo" config user.email test@example.invalid
git -C "$url_allowlist_repo" config user.name preflight-url-allowlist-test
cat >"$url_allowlist_repo/src/main/java/com/example/security/UrlFetcher.java" <<'EOF'
package com.example.security;

final class UrlFetcher {
    String fetch(String url) throws Exception {
        return "blocked";
    }
}
EOF
git -C "$url_allowlist_repo" add .
git -C "$url_allowlist_repo" commit -qm base
python3 - "$url_allowlist_repo/src/main/java/com/example/security/UrlFetcher.java" <<'PY'
from pathlib import Path
path = Path(__import__('sys').argv[1])
path.write_text('''package com.example.security;

import java.net.URL;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;

final class UrlFetcher {
    private static final Set<String> DOMAIN_WHITE_LIST = new HashSet<>(Arrays.asList("https://trusted.example"));

    String fetch(String url) throws Exception {
        for (String prefix : DOMAIN_WHITE_LIST) {
            if (url.startsWith(prefix)) {
                return new URL(url).openStream().toString();
            }
        }
        return "blocked-by-default";
    }
}
''')
PY
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}'
EOF
chmod +x "$fake_bin/curl"
url_allowlist_capture="$fixture_root/url-allowlist-capture"
url_allowlist_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$url_allowlist_capture" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$url_allowlist_repo")"
printf '%s\n' "$url_allowlist_output" | grep -F 'URL 白名单使用 startsWith 前缀匹配' >/dev/null || {
  echo 'missing URL-prefix allowlist SSRF preflight' >&2
  printf '%s\n' "$url_allowlist_output" >&2
  cat "$url_allowlist_capture" >&2 || true
  exit 1
}

# A permission-helper migration must not leave sibling job/log endpoints
# without resource-level authorization.
xxl_permission_repo="$fixture_root/xxl-permission-repo"
mkdir -p "$xxl_permission_repo/src/main/java/com/xxl/job/admin/controller"
git -C "$xxl_permission_repo" init -q
git -C "$xxl_permission_repo" config user.email test@example.invalid
git -C "$xxl_permission_repo" config user.name preflight-xxl-permission-test
cat >"$xxl_permission_repo/src/main/java/com/xxl/job/admin/controller/JobInfoController.java" <<'EOF'
package com.xxl.job.admin.controller;

final class JobInfoController {
    private final XxlJobService xxlJobService = null;

    @RequestMapping("/pageList")
    Object pageList(int jobGroup) { return xxlJobService.pageList(jobGroup); }
    @RequestMapping("/remove")
    Object remove(int id) { return xxlJobService.remove(id); }
    @RequestMapping("/stop")
    Object stop(int id) { return xxlJobService.stop(id); }
    @RequestMapping("/start")
    Object start(int id) { return xxlJobService.start(id); }
}
EOF
git -C "$xxl_permission_repo" add .
git -C "$xxl_permission_repo" commit -qm base
python3 - "$xxl_permission_repo/src/main/java/com/xxl/job/admin/controller/JobInfoController.java" <<'PY'
from pathlib import Path
path = Path(__import__('sys').argv[1])
text = path.read_text()
text = text.replace('final class JobInfoController {', 'import com.xxl.job.admin.controller.interceptor.PermissionInterceptor;\n\nfinal class JobInfoController {')
text = text.replace('Object pageList(int jobGroup)', 'Object pageList(HttpServletRequest request, int jobGroup)')
text = text.replace('Object remove(int id)', 'Object remove(HttpServletRequest request, int id)')
path.write_text(text)
PY
xxl_permission_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$xxl_permission_repo")"
printf '%s\n' "$xxl_permission_output" | grep -F '权限拦截器重构后仍有同类任务/日志入口未执行' >/dev/null || {
  echo 'missing xxl-job permission migration completeness preflight' >&2
  printf '%s\n' "$xxl_permission_output" >&2
  exit 1
}

# MyBatis `${...}` in a scalar SQL assignment is textual substitution, not a
# bound parameter.  The fake model returns clean so this assertion exercises
# the deterministic preflight and its final merge path.
mybatis_raw_repo="$fixture_root/mybatis-raw-substitution-repo"
mkdir -p "$mybatis_raw_repo/src/main/resources/mybatis-mapper"
git -C "$mybatis_raw_repo" init -q
git -C "$mybatis_raw_repo" config user.email test@example.invalid
git -C "$mybatis_raw_repo" config user.name preflight-mybatis-test
cat >"$mybatis_raw_repo/src/main/resources/mybatis-mapper/JobMapper.xml" <<'EOF'
<mapper namespace="example.JobMapper">
  <update id="update">
    UPDATE jobs SET executor_timeout = #{executorTimeout}, retry_count = #{retryCount} WHERE id = #{id}
  </update>
</mapper>
EOF
git -C "$mybatis_raw_repo" add .
git -C "$mybatis_raw_repo" commit -qm base
sed -i.bak \
  -e 's/executor_timeout = #{executorTimeout}/executor_timeout = ${executorTimeout}/' \
  -e 's/retry_count = #{retryCount}/retry_count = ${retryCount}/' \
  "$mybatis_raw_repo/src/main/resources/mybatis-mapper/JobMapper.xml"
rm -f "$mybatis_raw_repo/src/main/resources/mybatis-mapper/JobMapper.xml.bak"
mybatis_raw_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$mybatis_raw_repo")"
printf '%s\n' "$mybatis_raw_output" | grep -F 'MyBatis Mapper 将表达式' >/dev/null || {
  echo 'missing MyBatis raw substitution SQL injection preflight' >&2
  printf '%s\n' "$mybatis_raw_output" >&2
  exit 1
}
mybatis_raw_count="$(printf '%s\n' "$mybatis_raw_output" | grep -Fc 'MyBatis Mapper 将表达式')"
[[ "$mybatis_raw_count" == 2 ]] || {
  echo "MyBatis raw substitution preflight dropped a finding (count=$mybatis_raw_count)" >&2
  printf '%s\n' "$mybatis_raw_output" >&2
  exit 1
}

# A primitive numeric property is bound by the web layer before MyBatis and
# cannot carry an arbitrary SQL fragment.  The type-aware preflight must not
# classify this shape as an injection solely because the mapper uses `${...}`.
mybatis_numeric_repo="$fixture_root/mybatis-numeric-property-repo"
mkdir -p "$mybatis_numeric_repo/src/main/java/example" "$mybatis_numeric_repo/src/main/resources/mybatis-mapper"
git -C "$mybatis_numeric_repo" init -q
git -C "$mybatis_numeric_repo" config user.email test@example.invalid
git -C "$mybatis_numeric_repo" config user.name preflight-mybatis-numeric-test
cat >"$mybatis_numeric_repo/src/main/java/example/NumericParam.java" <<'EOF'
package example;

public final class NumericParam {
    private int timeout;

    public int getTimeout() {
        return timeout;
    }
}
EOF
cat >"$mybatis_numeric_repo/src/main/resources/mybatis-mapper/NumericMapper.xml" <<'EOF'
<mapper namespace="example.NumericMapper">
  <update id="update" parameterType="example.NumericParam">
    UPDATE jobs SET timeout = #{timeout} WHERE id = #{id}
  </update>
</mapper>
EOF
git -C "$mybatis_numeric_repo" add .
git -C "$mybatis_numeric_repo" commit -qm base
sed -i.bak 's/timeout = #{timeout}/timeout = ${timeout}/' \
  "$mybatis_numeric_repo/src/main/resources/mybatis-mapper/NumericMapper.xml"
rm -f "$mybatis_numeric_repo/src/main/resources/mybatis-mapper/NumericMapper.xml.bak"
mybatis_numeric_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$mybatis_numeric_repo")"
if printf '%s\n' "$mybatis_numeric_output" | grep -F 'MyBatis Mapper 将表达式' >/dev/null; then
  echo 'numeric MyBatis property was incorrectly reported as SQL injection' >&2
  printf '%s\n' "$mybatis_numeric_output" >&2
  exit 1
fi
printf '%s\n' "$mybatis_numeric_output" | grep -F '未发现阻塞问题' >/dev/null || {
  echo 'numeric MyBatis safe boundary did not remain clean' >&2
  printf '%s\n' "$mybatis_numeric_output" >&2
  exit 1
}

# The model may still repeat the old `${...}` heuristic even when the
# deterministic type evidence is safe.  The review contract requires every
# model finding to remain visible; type evidence is context for human review,
# not a silent model-output filter.
cat >"$fixture_root/model-mybatis-numeric-false-positive.txt" <<'EOF'
P1 src/main/resources/mybatis-mapper/NumericMapper.xml:3 - MyBatis Mapper 将表达式 ${timeout} 直接文本拼接到 SQL 赋值，存在 SQL 注入风险。
影响：请求输入可能改变 SQL 结构。
修复建议：改用 MyBatis #{timeout} 参数绑定。
验证方式：使用 SQL 片段执行 Mapper 集成测试。
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
response_file="${OLLAMA_FAKE_RESPONSE_FILE:?}"
jq -cn --arg response "$(cat "$response_file")" \
  '{response:$response,done:true,done_reason:"stop"}'
EOF
chmod +x "$fake_bin/curl"
mybatis_numeric_model_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" \
  OLLAMA_FAKE_RESPONSE_FILE="$fixture_root/model-mybatis-numeric-false-positive.txt" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$mybatis_numeric_repo")"
printf '%s\n' "$mybatis_numeric_model_output" | grep -F 'MyBatis Mapper 将表达式' >/dev/null || {
  echo 'numeric MyBatis model finding was hidden' >&2
  printf '%s\n' "$mybatis_numeric_model_output" >&2
  exit 1
}

cat >"$fixture_root/model-mybatis-numeric-hardening.txt" <<'EOF'
P3 src/main/resources/mybatis-mapper/NumericMapper.xml:3 - MyBatis 数值属性仍使用 ${timeout}，建议统一使用参数绑定以降低维护风险。
影响：当前输入类型限制了 SQL 片段注入，但文本替换形式增加后续类型变更风险。
修复建议：改用 MyBatis #{timeout} 参数绑定。
验证方式：执行类型变更和 Mapper 集成回归测试。
EOF
mybatis_numeric_hardening_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" \
  OLLAMA_FAKE_RESPONSE_FILE="$fixture_root/model-mybatis-numeric-hardening.txt" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$mybatis_numeric_repo")"
printf '%s\n' "$mybatis_numeric_hardening_output" | grep -F 'P3 ' >/dev/null || {
  echo 'numeric MyBatis hardening information was hidden' >&2
  printf '%s\n' "$mybatis_numeric_hardening_output" >&2
  exit 1
}

cat >"$fixture_root/model-mybatis-numeric-independent-root.txt" <<'EOF'
P1 src/main/resources/mybatis-mapper/NumericMapper.xml:3 - MyBatis 数值表达式 ${timeout} 需要改用绑定，同时该变更缺少租户隔离。
影响：除 SQL 维护风险外，跨租户请求可能读取或修改其他租户数据。
修复建议：改用 MyBatis #{timeout}，并补充 tenant_id 约束。
验证方式：执行跨租户隔离集成测试和 Mapper 回归测试。
EOF
mybatis_numeric_independent_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" \
  OLLAMA_FAKE_RESPONSE_FILE="$fixture_root/model-mybatis-numeric-independent-root.txt" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$mybatis_numeric_repo")"
printf '%s\n' "$mybatis_numeric_independent_output" | grep -F '租户隔离' >/dev/null || {
  echo 'independent tenant root was hidden with a safe numeric MyBatis expression' >&2
  printf '%s\n' "$mybatis_numeric_independent_output" >&2
  exit 1
}

# Restore the clean fake response before the mixed-expression preflight case.
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}'
EOF
chmod +x "$fake_bin/curl"

# A mixed mapper line must retain the unsafe text property even when the same
# model block also mentions the safe numeric property.
mybatis_mixed_repo="$fixture_root/mybatis-mixed-property-repo"
mkdir -p "$mybatis_mixed_repo/src/main/java/example" "$mybatis_mixed_repo/src/main/resources/mybatis-mapper"
git -C "$mybatis_mixed_repo" init -q
git -C "$mybatis_mixed_repo" config user.email test@example.invalid
git -C "$mybatis_mixed_repo" config user.name preflight-mybatis-mixed-test
cat >"$mybatis_mixed_repo/src/main/java/example/MixedParam.java" <<'EOF'
package example;

public final class MixedParam {
    private int timeout;
    private String label;

    public int getTimeout() { return timeout; }
    public String getLabel() { return label; }
}
EOF
cat >"$mybatis_mixed_repo/src/main/resources/mybatis-mapper/MixedMapper.xml" <<'EOF'
<mapper namespace="example.MixedMapper">
  <update id="update" parameterType="example.MixedParam">
    UPDATE jobs SET timeout = ${timeout}, label = ${label} WHERE id = #{id}
  </update>
</mapper>
EOF
git -C "$mybatis_mixed_repo" add .
git -C "$mybatis_mixed_repo" commit -qm base
sed -i.bak 's/timeout = \${timeout}/timeout = #{timeout}/' \
  "$mybatis_mixed_repo/src/main/resources/mybatis-mapper/MixedMapper.xml"
rm -f "$mybatis_mixed_repo/src/main/resources/mybatis-mapper/MixedMapper.xml.bak"
mybatis_mixed_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" \
  "$repo_root/bin/local-review.sh" --repo "$mybatis_mixed_repo")"
printf '%s\n' "$mybatis_mixed_output" | grep -F '${label}' >/dev/null || {
  echo 'mixed MyBatis line lost the unsafe text property' >&2
  printf '%s\n' "$mybatis_mixed_output" >&2
  exit 1
}

# A lock-context scan failure must not be swallowed and converted into a
# successful clean review. The fake perl affects only the bounded lock scans;
# the review must fail before it sends a model request.
lock_failure_repo="$fixture_root/lock-scan-failure-repo"
mkdir -p "$lock_failure_repo/src/main/java/com/example/lock"
git -C "$lock_failure_repo" init -q
git -C "$lock_failure_repo" config user.email test@example.invalid
git -C "$lock_failure_repo" config user.name preflight-lock-test
cat >"$lock_failure_repo/src/main/java/com/example/lock/LockService.java" <<'EOF'
package com.example.lock;

final class LockService {
    void update() {
        repository.findForUpdate();
    }

    interface Repository { void findForUpdate(); }
}
EOF
git -C "$lock_failure_repo" add .
git -C "$lock_failure_repo" commit -qm base
python3 - "$lock_failure_repo/src/main/java/com/example/lock/LockService.java" <<'PY'
from pathlib import Path
path = Path(__import__('sys').argv[1])
path.write_text(path.read_text().replace('void update()', '@org.springframework.transaction.annotation.Transactional\n    void update()'))
PY
cat >"$fake_bin/perl" <<'EOF'
#!/usr/bin/env bash
exit 2
EOF
chmod +x "$fake_bin/perl"
if PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$lock_failure_repo" >"$fixture_root/lock-failure.stdout" 2>"$fixture_root/lock-failure.stderr"; then
  echo 'lock scan failure was incorrectly accepted as a successful review' >&2
  cat "$fixture_root/lock-failure.stdout" >&2
  cat "$fixture_root/lock-failure.stderr" >&2
  exit 1
fi
grep -F '跨事务/行锁文本索引扫描超时或失败' "$fixture_root/lock-failure.stderr" >/dev/null || {
  echo 'lock scan failure did not fail closed with a diagnostic' >&2
  cat "$fixture_root/lock-failure.stderr" >&2
  exit 1
}

# High-confidence security boundaries that are easy for a small model to miss
# are covered by deterministic preflight plus safe counterparts. The fake
# Ollama response stays clean so these assertions exercise the wrapper rules.
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
rm -f "$fake_bin/perl"
open_redirect_repo="$fixture_root/open-redirect-repo"
mkdir -p "$open_redirect_repo/src"
git -C "$open_redirect_repo" init -q
git -C "$open_redirect_repo" config user.email test@example.invalid
git -C "$open_redirect_repo" config user.name preflight-open-redirect-test
cat >"$open_redirect_repo/src/RedirectController.java" <<'EOF'
import java.net.URI;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;

final class RedirectController {
    @GetMapping("/continue")
    ResponseEntity<Void> continueTo(@RequestParam String next) {
        return ResponseEntity.status(302).location(URI.create("/home")).build();
    }
}
EOF
git -C "$open_redirect_repo" add .
git -C "$open_redirect_repo" commit -qm base
sed -i.bak 's#URI.create("/home")#URI.create(next)#' "$open_redirect_repo/src/RedirectController.java"
rm -f "$open_redirect_repo/src/RedirectController.java.bak"
open_redirect_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$open_redirect_repo")"
printf '%s\n' "$open_redirect_output" | grep -F '不可信跳转目标直接进入重定向响应' >/dev/null || {
  echo 'missing open-redirect preflight' >&2
  printf '%s\n' "$open_redirect_output" >&2
  exit 1
}

cors_repo="$fixture_root/cors-repo"
mkdir -p "$cors_repo/src"
git -C "$cors_repo" init -q
git -C "$cors_repo" config user.email test@example.invalid
git -C "$cors_repo" config user.name preflight-cors-test
cat >"$cors_repo/src/CorsConfig.java" <<'EOF'
import org.springframework.web.servlet.config.annotation.CorsRegistry;

final class CorsConfig {
    void configure(CorsRegistry registry) {
        registry.addMapping("/**").allowedOrigins("https://app.example.com").allowCredentials(true);
    }
}
EOF
git -C "$cors_repo" add .
git -C "$cors_repo" commit -qm base
sed -i.bak 's#allowedOrigins("https://app.example.com")#allowedOriginPatterns("*")#' "$cors_repo/src/CorsConfig.java"
rm -f "$cors_repo/src/CorsConfig.java.bak"
cors_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$cors_repo")"
printf '%s\n' "$cors_output" | grep -F 'CORS 允许任意 Origin' >/dev/null || {
  echo 'missing wildcard-credentials CORS preflight' >&2
  printf '%s\n' "$cors_output" >&2
  exit 1
}

weak_hash_repo="$fixture_root/weak-password-hash-repo"
mkdir -p "$weak_hash_repo/src"
git -C "$weak_hash_repo" init -q
git -C "$weak_hash_repo" config user.email test@example.invalid
git -C "$weak_hash_repo" config user.name preflight-weak-password-hash-test
cat >"$weak_hash_repo/src/PasswordHasher.java" <<'EOF'
import java.security.MessageDigest;

final class PasswordHasher {
    String hash(String password) throws Exception {
        return MessageDigest.getInstance("SHA-256").digest(password.getBytes()).toString();
    }
}
EOF
git -C "$weak_hash_repo" add .
git -C "$weak_hash_repo" commit -qm base
sed -i.bak 's#"SHA-256"#"MD5"#' "$weak_hash_repo/src/PasswordHasher.java"
rm -f "$weak_hash_repo/src/PasswordHasher.java.bak"
weak_hash_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$weak_hash_repo")"
printf '%s\n' "$weak_hash_output" | grep -F '密码直接使用快速哈希算法' >/dev/null || {
  echo 'missing weak-password-hash preflight' >&2
  printf '%s\n' "$weak_hash_output" >&2
  exit 1
}

# Business-integrity preflights: fail-open authorization, singleton
# check-then-act, and an external payment side effect before local commit.
rm -f "$fake_bin/perl"
fail_open_repo="$fixture_root/fail-open-repo"
mkdir -p "$fail_open_repo/src"
git -C "$fail_open_repo" init -q
git -C "$fail_open_repo" config user.email test@example.invalid
git -C "$fail_open_repo" config user.name preflight-fail-open-test
cat >"$fail_open_repo/src/AdminEndpoint.java" <<'EOF'
final class AdminEndpoint {
    private final Authorizer authorizer;

    boolean allowed(Object request) {
        try {
            return authorizer.check(request);
        } catch (RuntimeException ex) {
            return false;
        }
    }

    interface Authorizer { boolean check(Object request); }
}
EOF
git -C "$fail_open_repo" add .
git -C "$fail_open_repo" commit -qm base
sed -i.bak 's/return false;/return true;/' "$fail_open_repo/src/AdminEndpoint.java"
rm -f "$fail_open_repo/src/AdminEndpoint.java.bak"
fail_open_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  "$repo_root/bin/local-review.sh" --repo "$fail_open_repo")"
printf '%s\n' "$fail_open_output" | grep -F '授权异常路径默认放行' >/dev/null || {
  echo 'missing fail-open authorization preflight' >&2
  printf '%s\n' "$fail_open_output" >&2
  exit 1
}

race_repo="$fixture_root/check-then-act-repo"
mkdir -p "$race_repo/src"
git -C "$race_repo" init -q
git -C "$race_repo" config user.email test@example.invalid
git -C "$race_repo" config user.name preflight-check-then-act-test
cat >"$race_repo/src/JobClaimService.java" <<'EOF'
import java.util.concurrent.atomic.AtomicBoolean;
import org.springframework.stereotype.Service;

@Service
final class JobClaimService {
    private final AtomicBoolean claimed = new AtomicBoolean();

    boolean claim() {
        return claimed.compareAndSet(false, true);
    }
}
EOF
git -C "$race_repo" add .
git -C "$race_repo" commit -qm base
python3 - "$race_repo/src/JobClaimService.java" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
path.write_text('''import org.springframework.stereotype.Service;

@Service
final class JobClaimService {
    private boolean claimed;

    boolean claim() {
        if (!claimed) {
            claimed = true;
            return true;
        }
        return false;
    }
}
''')
PY
race_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  "$repo_root/bin/local-review.sh" --repo "$race_repo")"
printf '%s\n' "$race_output" | grep -F '共享可变状态存在 check-then-act 竞态' >/dev/null || {
  echo 'missing check-then-act preflight' >&2
  printf '%s\n' "$race_output" >&2
  exit 1
}

partial_repo="$fixture_root/partial-side-effect-repo"
mkdir -p "$partial_repo/src"
git -C "$partial_repo" init -q
git -C "$partial_repo" config user.email test@example.invalid
git -C "$partial_repo" config user.name preflight-partial-side-effect-test
cat >"$partial_repo/src/PaymentService.java" <<'EOF'
final class PaymentService {
    void create(OrderRequest request) {
        savePending(request.amount());
        outbox(request.amount());
    }

    void savePending(long amount) {}
    void outbox(long amount) {}
    record OrderRequest(long amount) {}
}
EOF
git -C "$partial_repo" add .
git -C "$partial_repo" commit -qm base
cat >"$partial_repo/src/PaymentService.java" <<'EOF'
import org.springframework.transaction.annotation.Transactional;

final class PaymentService {
    private final PaymentGateway gateway;
    private final OrderRepository orders;

    @Transactional
    void create(OrderRequest request) {
        gateway.charge(request.cardToken(), request.amount());
        orders.save(request.amount());
    }

    interface PaymentGateway { void charge(String cardToken, long amount); }
    interface OrderRepository { void save(long amount); }
    record OrderRequest(String cardToken, long amount) {}
}
EOF
partial_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  "$repo_root/bin/local-review.sh" --repo "$partial_repo")"
printf '%s\n' "$partial_output" | grep -F '事务内先执行外部副作用再保存本地状态' >/dev/null || {
  echo 'missing partial-side-effect preflight' >&2
  printf '%s\n' "$partial_output" >&2
  exit 1
}

# The three business-integrity detectors must not combine evidence from
# separate methods in one large hunk. Keep the fake model clean so these
# assertions exercise only the deterministic boundary checks.
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}'
EOF
chmod +x "$fake_bin/curl"

race_boundary_repo="$fixture_root/check-then-act-method-boundary-repo"
mkdir -p "$race_boundary_repo/src"
git -C "$race_boundary_repo" init -q
git -C "$race_boundary_repo" config user.email test@example.invalid
git -C "$race_boundary_repo" config user.name preflight-check-then-act-boundary-test
cat >"$race_boundary_repo/src/JobClaimService.java" <<'EOF'
import org.springframework.stereotype.Service;

@Service
final class JobClaimService {
    private boolean claimed;

    boolean check() {
        if (!claimed) {
            return true;
        }
        return false;
    }

    void mark() {
        claimed = false;
    }
}
EOF
git -C "$race_boundary_repo" add .
git -C "$race_boundary_repo" commit -qm base
sed -i.bak 's/claimed = false;/claimed = true;/' "$race_boundary_repo/src/JobClaimService.java"
rm -f "$race_boundary_repo/src/JobClaimService.java.bak"
race_boundary_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  "$repo_root/bin/local-review.sh" --repo "$race_boundary_repo")"
if printf '%s\n' "$race_boundary_output" | grep -F '共享可变状态存在 check-then-act 竞态' >/dev/null; then
  echo 'check-then-act preflight combined separate methods' >&2
  printf '%s\n' "$race_boundary_output" >&2
  exit 1
fi

partial_boundary_repo="$fixture_root/partial-side-effect-method-boundary-repo"
mkdir -p "$partial_boundary_repo/src"
git -C "$partial_boundary_repo" init -q
git -C "$partial_boundary_repo" config user.email test@example.invalid
git -C "$partial_boundary_repo" config user.name preflight-partial-side-effect-boundary-test
cat >"$partial_boundary_repo/src/PaymentService.java" <<'EOF'
import org.springframework.transaction.annotation.Transactional;

final class PaymentService {
    private final PaymentGateway gateway;
    private final OrderRepository orders;

    @Transactional
    void chargeExternal(String token, long amount) {
        gateway.charge(token, amount);
    }

    void persist(long amount) {
        orders.delete(amount);
    }

    interface PaymentGateway { void charge(String token, long amount); }
    interface OrderRepository { void delete(long amount); void save(long amount); }
}
EOF
git -C "$partial_boundary_repo" add .
git -C "$partial_boundary_repo" commit -qm base
sed -i.bak 's/orders.delete(amount)/orders.save(amount)/' "$partial_boundary_repo/src/PaymentService.java"
rm -f "$partial_boundary_repo/src/PaymentService.java.bak"
partial_boundary_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  "$repo_root/bin/local-review.sh" --repo "$partial_boundary_repo")"
if printf '%s\n' "$partial_boundary_output" | grep -F '事务内先执行外部副作用再保存本地状态' >/dev/null; then
  echo 'partial-side-effect preflight combined separate methods' >&2
  printf '%s\n' "$partial_boundary_output" >&2
  exit 1
fi

fail_open_boundary_repo="$fixture_root/fail-open-method-boundary-repo"
mkdir -p "$fail_open_boundary_repo/src"
git -C "$fail_open_boundary_repo" init -q
git -C "$fail_open_boundary_repo" config user.email test@example.invalid
git -C "$fail_open_boundary_repo" config user.name preflight-fail-open-boundary-test
cat >"$fail_open_boundary_repo/src/AdminEndpoint.java" <<'EOF'
final class AdminEndpoint {
    private final Authorizer authorizer;
    private final Config config;

    boolean allowed(Object request) {
        try {
            return authorizer.check(request);
        } catch (RuntimeException ex) {
            return false;
        }
    }

    boolean featureEnabled() {
        try {
            return config.read();
        } catch (RuntimeException ex) {
            return false;
        }
    }

    interface Authorizer { boolean check(Object request); }
    interface Config { boolean read(); }
}
EOF
git -C "$fail_open_boundary_repo" add .
git -C "$fail_open_boundary_repo" commit -qm base
python3 - "$fail_open_boundary_repo/src/AdminEndpoint.java" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
old = "return config.read();\n        } catch (RuntimeException ex) {\n            return false;"
new = "return config.read();\n        } catch (RuntimeException ex) {\n            return true;"
if old not in text:
    raise SystemExit("boundary fixture mutation anchor missing")
path.write_text(text.replace(old, new, 1))
PY
fail_open_boundary_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  "$repo_root/bin/local-review.sh" --repo "$fail_open_boundary_repo")"
if printf '%s\n' "$fail_open_boundary_output" | grep -F '授权异常路径默认放行' >/dev/null; then
  echo 'fail-open preflight combined separate methods' >&2
  printf '%s\n' "$fail_open_boundary_output" >&2
  exit 1
fi

reactive_fail_open_repo="$fixture_root/reactive-fail-open-repo"
mkdir -p "$reactive_fail_open_repo/src"
git -C "$reactive_fail_open_repo" init -q
git -C "$reactive_fail_open_repo" config user.email test@example.invalid
git -C "$reactive_fail_open_repo" config user.name preflight-reactive-fail-open-test
cat >"$reactive_fail_open_repo/src/SecurityGateway.java" <<'EOF'
import reactor.core.publisher.Mono;

final class SecurityGateway {
    Mono<Boolean> isSecurityContextCurrent() {
        return Mono.just(false).onErrorResume(error -> Mono.just(false));
    }

    Mono<Boolean> isApiPermissionAllowed() {
        return Mono.empty().defaultIfEmpty(false);
    }

    Mono<Boolean> isAnonymousApi() {
        return Mono.just(false).onErrorResume(error -> Mono.just(false));
    }

    Mono<Boolean> isFeatureEnabled() {
        return Mono.empty().defaultIfEmpty(false);
    }
}
EOF
git -C "$reactive_fail_open_repo" add .
git -C "$reactive_fail_open_repo" commit -qm base
python3 - "$reactive_fail_open_repo/src/SecurityGateway.java" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    "return Mono.just(false).onErrorResume(error -> Mono.just(false));",
    "return Mono.just(false).onErrorResume(error -> Mono.just(true));",
    1,
)
text = text.replace(
    "return Mono.empty().defaultIfEmpty(false);",
    "return Mono.empty().defaultIfEmpty(true);",
    1,
)
path.write_text(text)
PY
reactive_fail_open_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  "$repo_root/bin/local-review.sh" --repo "$reactive_fail_open_repo")"
reactive_fail_open_count="$(printf '%s\n' "$reactive_fail_open_output" | grep -c 'Reactor 鉴权异常路径默认放行' || true)"
if [[ "$reactive_fail_open_count" -ne 2 ]]; then
  echo "expected two reactive fail-open findings, got $reactive_fail_open_count" >&2
  printf '%s\n' "$reactive_fail_open_output" >&2
  exit 1
fi
for reactive_field in '影响：' '修复建议：' '验证方式：' '来源：确定性预检（代码证据，非模型原文）'; do
  reactive_field_count="$(printf '%s\n' "$reactive_fail_open_output" | grep -c "$reactive_field" || true)"
  if [[ "$reactive_field_count" -ne 2 ]]; then
    echo "expected two complete reactive fail-open fields for $reactive_field, got $reactive_field_count" >&2
    printf '%s\n' "$reactive_fail_open_output" >&2
    exit 1
  fi
done
if printf '%s\n' "$reactive_fail_open_output" | grep -F 'isAnonymousApi' >/dev/null; then
  echo 'reactive fail-open preflight reported safe anonymous fallback' >&2
  printf '%s\n' "$reactive_fail_open_output" >&2
  exit 1
fi
if printf '%s\n' "$reactive_fail_open_output" | grep -F 'isFeatureEnabled' >/dev/null; then
  echo 'reactive fail-open preflight reported non-security fallback' >&2
  printf '%s\n' "$reactive_fail_open_output" >&2
  exit 1
fi

xxl_repo="$fixture_root/xxl-reliability-repo"
mkdir -p "$xxl_repo/xxl-job-core/src/main/java/com/xxl/job/core/context" \
  "$xxl_repo/xxl-job-core/src/main/java/com/xxl/job/core/biz/model" \
  "$xxl_repo/xxl-job-core/src/main/java/com/xxl/job/core/handler/impl" \
  "$xxl_repo/xxl-job-core/src/main/java/com/xxl/job/core/thread"
git -C "$xxl_repo" init -q
git -C "$xxl_repo" config user.email test@example.invalid
git -C "$xxl_repo" config user.name preflight-xxl-reliability-test
cat >"$xxl_repo/xxl-job-core/src/main/java/com/xxl/job/core/context/XxlJobHelper.java" <<'EOF'
package com.xxl.job.core.context;

final class XxlJobHelper {
    public static String getJobParam() {
        XxlJobContext context = XxlJobContext.current();
        if (context == null) {
            return null;
        }
        return context.getJobParam();
    }
}
EOF
cat >"$xxl_repo/xxl-job-core/src/main/java/com/xxl/job/core/context/XxlJobContext.java" <<'EOF'
package com.xxl.job.core.context;

final class XxlJobContext {
    static XxlJobContext current() { return null; }
    String getJobParam() { return null; }
}
EOF
cat >"$xxl_repo/xxl-job-core/src/main/java/com/xxl/job/core/biz/model/ReturnT.java" <<'EOF'
package com.xxl.job.core.biz.model;

public class ReturnT<T> {
    private String msg;
    public String getMsg() { return msg; }
    public void setMsg(String msg) { this.msg = msg; }
}
EOF
cat >"$xxl_repo/xxl-job-core/src/main/java/com/xxl/job/core/handler/impl/ScriptJobHandler.java" <<'EOF'
package com.xxl.job.core.handler.impl;

final class ScriptJobHandler {
    void execute() {
        String[] scriptParams = new String[1];
        scriptParams[0] = "";
    }
}
EOF
cat >"$xxl_repo/xxl-job-core/src/main/java/com/xxl/job/core/thread/JobThread.java" <<'EOF'
package com.xxl.job.core.thread;

import com.xxl.job.core.biz.model.ReturnT;

final class JobThread {
    void run(ReturnT<String> executeResult) {
        if (executeResult == null) {
            return;
        }
    }
}
EOF
git -C "$xxl_repo" add .
git -C "$xxl_repo" commit -qm base
python3 - "$xxl_repo/xxl-job-core/src/main/java/com/xxl/job/core/handler/impl/ScriptJobHandler.java" "$xxl_repo/xxl-job-core/src/main/java/com/xxl/job/core/thread/JobThread.java" <<'PY'
from pathlib import Path
import sys
script, job_thread = map(Path, sys.argv[1:])
script.write_text(script.read_text().replace('scriptParams[0] = "";',
    'scriptParams[0] = XxlJobHelper.getJobParam();'))
job_thread.write_text(job_thread.read_text().replace('''        if (executeResult == null) {
            return;
        }''', '''        executeResult.setMsg((executeResult!=null&&executeResult.getMsg().length()>50000)
                ? executeResult.getMsg().substring(0, 50000).concat("...") : executeResult.getMsg());'''))
PY
xxl_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  "$repo_root/bin/local-review.sh" --repo "$xxl_repo")"
printf '%s\n' "$xxl_output" | grep -F 'XxlJobHelper.getJobParam()' >/dev/null || {
  echo 'missing XXL-JOB nullable job parameter preflight' >&2
  printf '%s\n' "$xxl_output" >&2
  exit 1
}
printf '%s\n' "$xxl_output" | grep -F 'ReturnT.msg' >/dev/null || {
  echo 'missing XXL-JOB nullable result message preflight' >&2
  printf '%s\n' "$xxl_output" >&2
  exit 1
}
xxl_p1_count="$(printf '%s\n' "$xxl_output" | grep -c '^P1 ' || true)"
[[ "$xxl_p1_count" -eq 2 ]] || {
  echo "XXL-JOB nullable preflight emitted duplicate or malformed blocks: $xxl_p1_count" >&2
  printf '%s\n' "$xxl_output" >&2
  exit 1
}
for xxl_field in '影响：' '修复建议：' '验证方式：' '来源：确定性预检（代码证据，非模型原文）'; do
  xxl_field_count="$(printf '%s\n' "$xxl_output" | grep -c "$xxl_field" || true)"
  [[ "$xxl_field_count" -eq 2 ]] || {
    echo "XXL-JOB nullable preflight field count mismatch for $xxl_field: $xxl_field_count" >&2
    printf '%s\n' "$xxl_output" >&2
    exit 1
  }
done

sales_stock_repo="$fixture_root/sales-stock-owner-repo"
mkdir -p "$sales_stock_repo/src/main/java/example/erp"
git -C "$sales_stock_repo" init -q
git -C "$sales_stock_repo" config user.email test@example.invalid
git -C "$sales_stock_repo" config user.name preflight-sales-stock-owner
cat >"$sales_stock_repo/src/main/java/example/erp/SalesStockSearchApplication.java" <<'EOF'
package example.erp;

final class SalesStockSearchApplication {
    private final LogicalWarehouseRepository logicalWarehouseRepository = new LogicalWarehouseRepository();

    void confirm(Long id, SearchEntity entity) {
        resolveTargetWarehouse(entity, id);
    }

    private Warehouse resolveTargetWarehouse(SearchEntity entity, Long targetLogicalWarehouseId) {
        Long actualId = targetLogicalWarehouseId == null ? entity.getDefaultLogicalWarehouseId() : targetLogicalWarehouseId;
        Warehouse warehouse = logicalWarehouseRepository.findById(actualId);
        if (warehouse == null || warehouse.status != 1) throw new IllegalStateException();
        return warehouse;
    }

    static final class SearchEntity {
        Long getSupplierId() { return 1L; }
        Long getDefaultLogicalWarehouseId() { return 2L; }
    }
    static final class Warehouse { int status; }
    static final class LogicalWarehouseRepository {
        Warehouse findById(Long id) { return new Warehouse(); }
    }
}
EOF
git -C "$sales_stock_repo" add .
git -C "$sales_stock_repo" commit -qm sales-stock-owner-base
sed -i '' 's/Warehouse warehouse = logicalWarehouseRepository.findById(actualId);/Warehouse warehouse = logicalWarehouseRepository.findById(actualId); \/\/ changed/' \
  "$sales_stock_repo/src/main/java/example/erp/SalesStockSearchApplication.java"
sales_stock_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" \
  "$repo_root/bin/local-review.sh" --repo "$sales_stock_repo")"
printf '%s\n' "$sales_stock_output" | grep -F '销售寻货目标逻辑仓只按请求 ID 查询并校验存在/启用状态' >/dev/null || {
  echo 'sales-stock warehouse ownership preflight missed the fixture' >&2
  printf '%s\n' "$sales_stock_output" >&2
  exit 1
}
sed -i '' 's/resolveTargetWarehouse/resolveDirectTargetWarehouse/g' \
  "$sales_stock_repo/src/main/java/example/erp/SalesStockSearchApplication.java"
direct_sales_stock_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" \
  "$repo_root/bin/local-review.sh" --repo "$sales_stock_repo")"
printf '%s\n' "$direct_sales_stock_output" | grep -F '销售寻货目标逻辑仓只按请求 ID 查询并校验存在/启用状态' >/dev/null || {
  echo 'sales-stock direct target warehouse preflight missed the resolver variant' >&2
  printf '%s\n' "$direct_sales_stock_output" >&2
  exit 1
}

role_scope_repo="$fixture_root/role-api-scope-repo"
mkdir -p "$role_scope_repo/src/main/java/com/example/system"
git -C "$role_scope_repo" init -q
git -C "$role_scope_repo" config user.email test@example.invalid
git -C "$role_scope_repo" config user.name preflight-role-api-scope-test
cat >"$role_scope_repo/src/main/java/com/example/system/ApiResourceApplication.java" <<'EOF'
package com.example.system;

final class ApiResourceApplication {
    private final RoleApiMapper roleApiMapper = new RoleApiMapper();

    void assignRoleApis(Long roleId, java.util.List<Long> apiIds) {
        resolveRoleTenantId(roleId);
        validateAssignableApis(apiIds);
        for (Long apiId : apiIds) {
            roleApiMapper.insert(roleId, apiId);
        }
    }

    private Long resolveRoleTenantId(Long roleId) {
        TenantOperationGuard.assertCurrentTenant(roleId);
        return roleId;
    }

    private void validateAssignableApis(java.util.List<Long> apiIds) {
        java.util.List<Long> activeApplicationIds = activeApplicationIds(null);
        if (activeApplicationIds.isEmpty()) {
            throw new IllegalStateException();
        }
        roleApiMapper.select(apiIds, activeApplicationIds);
    }

    private java.util.List<Long> activeApplicationIds(Long applicationId) {
        return java.util.List.of(1L);
    }

    static final class RoleApiMapper {
        void insert(Long roleId, Long apiId) {}
        void select(java.util.List<Long> apiIds, java.util.List<Long> applicationIds) {}
    }
    static final class TenantOperationGuard {
        static void assertCurrentTenant(Long tenantId) {}
    }
}
EOF
git -C "$role_scope_repo" add .
git -C "$role_scope_repo" commit -qm base
sed -i.bak 's/java.util.List<Long> activeApplicationIds = activeApplicationIds(null);/java.util.List<Long> activeApplicationIds = activeApplicationIds(null); \/\/ changed/' \
  "$role_scope_repo/src/main/java/com/example/system/ApiResourceApplication.java"
rm -f "$role_scope_repo/src/main/java/com/example/system/ApiResourceApplication.java.bak"
role_scope_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  "$repo_root/bin/local-review.sh" --repo "$role_scope_repo")"
printf '%s\n' "$role_scope_output" | grep -F '角色 API 授权校验只验证 API 所属应用是否全局有效' >/dev/null || {
  echo 'missing role/API tenant scope preflight' >&2
  printf '%s\n' "$role_scope_output" >&2
  exit 1
}
for role_scope_field in '影响：' '修复建议：' '验证方式：'; do
  role_scope_field_count="$(printf '%s\n' "$role_scope_output" | grep -c "$role_scope_field" || true)"
  [[ "$role_scope_field_count" -eq 1 ]] || {
    echo "role/API preflight field count mismatch for $role_scope_field: $role_scope_field_count" >&2
    printf '%s\n' "$role_scope_output" >&2
    exit 1
  }
done

# Returning raw online-session tokens in an OnlineUserVO is a credential
# disclosure even when the endpoint itself checks permissions. The narrow
# preflight requires the DTO, repository assignment, and API return shape;
# ordinary header transport and masked identifiers are out of scope.
session_token_repo="$fixture_root/session-token-repo"
mkdir -p "$session_token_repo/src/main/java/example/auth"
git -C "$session_token_repo" init -q
git -C "$session_token_repo" config user.email test@example.invalid
git -C "$session_token_repo" config user.name preflight-session-token
cat >"$session_token_repo/src/main/java/example/auth/OnlineUserVO.java" <<'EOF'
package example.auth;

public class OnlineUserVO {
    private String userId;
}
EOF
cat >"$session_token_repo/src/main/java/example/auth/OnlineSessionRepository.java" <<'EOF'
package example.auth;

public class OnlineSessionRepository {
    public OnlineUserVO build(String token) {
        OnlineUserVO vo = new OnlineUserVO();
        return vo;
    }
}
EOF
cat >"$session_token_repo/src/main/java/example/auth/OnlineController.java" <<'EOF'
package example.auth;

import java.util.List;

public class OnlineController {
    public Result<List<OnlineUserVO>> users() {
        return null;
    }
}
EOF
git -C "$session_token_repo" add .
git -C "$session_token_repo" commit -qm session-token-base
sed -i '' 's/private String userId;/private String userId; private String token;/' \
  "$session_token_repo/src/main/java/example/auth/OnlineUserVO.java"
sed -i '' 's/OnlineUserVO vo = new OnlineUserVO();/OnlineUserVO vo = new OnlineUserVO(); vo.setToken(token);/' \
  "$session_token_repo/src/main/java/example/auth/OnlineSessionRepository.java"
session_token_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" \
  "$repo_root/bin/local-review.sh" --repo "$session_token_repo")"
printf '%s\n' "$session_token_output" | grep -F '在线会话查询返回对象直接携带原始 session token' >/dev/null || {
  echo 'raw session token response preflight missed the DTO/repository/API fixture' >&2
  printf '%s\n' "$session_token_output" >&2
  exit 1
}

# A one-time SSO authorization code must be consumed atomically.  A plain
# GET followed by DELETE lets two concurrent exchanges observe the same code
# before either request removes it.  The fixture starts from an atomic
# getAndDelete implementation and changes only the consumption sequence so
# the deterministic preflight is exercised through the diff, not the whole
# repository snapshot.
sso_auth_code_repo="$fixture_root/sso-auth-code-repo"
mkdir -p "$sso_auth_code_repo/src/main/java/example/sso"
git -C "$sso_auth_code_repo" init -q
git -C "$sso_auth_code_repo" config user.email test@example.invalid
git -C "$sso_auth_code_repo" config user.name preflight-sso-auth-code
cat >"$sso_auth_code_repo/src/main/java/example/sso/SsoController.java" <<'EOF'
package example.sso;

final class SsoController {
    private final RedisUtil redisUtil = new RedisUtil();

    String exchangeCode(String code) {
        String key = RedisKeyUtil.getSsoAuthorizationCodeKey(code);
        Object cached = redisUtil.getAndDelete(key);
        return cached == null ? null : "/sso/token";
    }

    static final class RedisUtil {
        Object getAndDelete(String key) { return key; }
    }

    static final class RedisKeyUtil {
        static String getSsoAuthorizationCodeKey(String code) { return code; }
    }
}
EOF
git -C "$sso_auth_code_repo" add .
git -C "$sso_auth_code_repo" commit -qm sso-auth-code-base
python3 - "$sso_auth_code_repo/src/main/java/example/sso/SsoController.java" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = '        Object cached = redisUtil.getAndDelete(key);'
new = '        Object cached = redisUtil.get(key);\n        redisUtil.delete(key);'
if old not in text:
    raise SystemExit('SSO authorization-code fixture mutation anchor missing')
path.write_text(text.replace(old, new, 1))
PY
sso_auth_code_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  "$repo_root/bin/local-review.sh" --repo "$sso_auth_code_repo")"
printf '%s\n' "$sso_auth_code_output" | grep -F '一次性授权码先读取后删除，消费过程非原子，存在并发重放风险' >/dev/null || {
  echo 'SSO authorization-code non-atomic preflight missed the positive fixture' >&2
  printf '%s\n' "$sso_auth_code_output" >&2
  exit 1
}
sso_auth_code_p1_count="$(printf '%s\n' "$sso_auth_code_output" | grep -c '^P1 ' || true)"
[[ "$sso_auth_code_p1_count" -eq 1 ]] || {
  echo "SSO authorization-code preflight emitted duplicate or malformed blocks: $sso_auth_code_p1_count" >&2
  printf '%s\n' "$sso_auth_code_output" >&2
  exit 1
}
for sso_auth_code_field in '影响：' '修复建议：' '验证方式：' '来源：确定性预检（代码证据，非模型原文）'; do
  sso_auth_code_field_count="$(printf '%s\n' "$sso_auth_code_output" | grep -c "$sso_auth_code_field" || true)"
  [[ "$sso_auth_code_field_count" -eq 1 ]] || {
    echo "SSO authorization-code preflight field count mismatch for $sso_auth_code_field: $sso_auth_code_field_count" >&2
    printf '%s\n' "$sso_auth_code_output" >&2
    exit 1
  }
done

# The same endpoint remains clean when the atomic operation is retained.  A
# changed comment proves the negative assertion is evaluated against the
# resulting diff rather than merely matching a repository-wide keyword.
sso_auth_code_safe_repo="$fixture_root/sso-auth-code-safe-repo"
mkdir -p "$sso_auth_code_safe_repo/src/main/java/example/sso"
git -C "$sso_auth_code_safe_repo" init -q
git -C "$sso_auth_code_safe_repo" config user.email test@example.invalid
git -C "$sso_auth_code_safe_repo" config user.name preflight-sso-auth-code-safe
cp "$sso_auth_code_repo/src/main/java/example/sso/SsoController.java" \
  "$sso_auth_code_safe_repo/src/main/java/example/sso/SsoController.java"
# Restore the safe operation in the copied source; the positive repository is
# intentionally left untouched for the assertion above.
python3 - "$sso_auth_code_safe_repo/src/main/java/example/sso/SsoController.java" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    '        Object cached = redisUtil.get(key);\n        redisUtil.delete(key);',
    '        Object cached = redisUtil.getAndDelete(key);',
    1,
)
path.write_text(text)
PY
git -C "$sso_auth_code_safe_repo" add .
git -C "$sso_auth_code_safe_repo" commit -qm sso-auth-code-safe-base
python3 - "$sso_auth_code_safe_repo/src/main/java/example/sso/SsoController.java" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = '        String key = RedisKeyUtil.getSsoAuthorizationCodeKey(code);'
new = '        String key = RedisKeyUtil.getSsoAuthorizationCodeKey(code); // safe atomic consume'
if old not in text:
    raise SystemExit('SSO safe fixture mutation anchor missing')
path.write_text(text.replace(old, new, 1))
PY
sso_auth_code_safe_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  "$repo_root/bin/local-review.sh" --repo "$sso_auth_code_safe_repo")"
if printf '%s\n' "$sso_auth_code_safe_output" | grep -F '一次性授权码先读取后删除，消费过程非原子，存在并发重放风险' >/dev/null; then
  echo 'SSO authorization-code preflight reported the safe atomic fixture' >&2
  printf '%s\n' "$sso_auth_code_safe_output" >&2
  exit 1
fi

# A pending payment-voucher count followed by save is a database
# check-then-insert race when the table has no uniqueness guard. The positive
# fixture keeps the changed count call in the diff and uses a complete schema
# snapshot so the preflight must correlate Java and SQL evidence.
payment_voucher_repo="$fixture_root/payment-voucher-race-repo"
mkdir -p "$payment_voucher_repo/src/main/java/example/order" "$payment_voucher_repo/sql"
git -C "$payment_voucher_repo" init -q
git -C "$payment_voucher_repo" config user.email test@example.invalid
git -C "$payment_voucher_repo" config user.name preflight-payment-voucher
cat >"$payment_voucher_repo/src/main/java/example/order/SalesOrderApplication.java" <<'EOF'
package example.order;

final class SalesOrderApplication {
    void submit(Long orderId) {
        return;
    }
}
EOF
cat >"$payment_voucher_repo/sql/platform_erp.sql" <<'EOF'
CREATE TABLE IF NOT EXISTS `erp_sales_payment_voucher` (
  `id` bigint NOT NULL,
  `order_id` bigint NOT NULL,
  `status` varchar(32) NOT NULL
) ENGINE=InnoDB;
EOF
git -C "$payment_voucher_repo" add .
git -C "$payment_voucher_repo" commit -qm payment-voucher-base
cat >"$payment_voucher_repo/src/main/java/example/order/SalesOrderApplication.java" <<'EOF'
package example.order;

final class SalesOrderApplication {
    void submit(Long orderId) {
        PaymentVoucher pending = buildPendingVoucher(orderId);
        salesPaymentVoucherRepository.save(pending);
    }

    PaymentVoucher buildPendingVoucher(Long orderId) {
        if (salesPaymentVoucherRepository.countPendingByOrderId(orderId) > 0) return null;
        return new PaymentVoucher(orderId);
    }
    interface PaymentVoucherRepository {
        long countPendingByOrderId(Long orderId);
        void save(PaymentVoucher voucher);
    }
    private final PaymentVoucherRepository salesPaymentVoucherRepository = null;
    static final class PaymentVoucher {
        PaymentVoucher(Long orderId) {}
    }
}
EOF
payment_voucher_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  "$repo_root/bin/local-review.sh" --repo "$payment_voucher_repo")"
printf '%s\n' "$payment_voucher_output" | grep -F '销售订单提交先 countPendingByOrderId 再插入待确认支付凭证' >/dev/null || {
  echo 'payment-voucher race preflight missed the positive fixture' >&2
  printf '%s\n' "$payment_voucher_output" >&2
  exit 1
}
payment_voucher_p1_count="$(printf '%s\n' "$payment_voucher_output" | grep -c '^P1 .*销售订单提交先 countPendingByOrderId' || true)"
[[ "$payment_voucher_p1_count" -eq 1 ]] || {
  echo "payment-voucher preflight emitted duplicate or malformed blocks: $payment_voucher_p1_count" >&2
  printf '%s\n' "$payment_voucher_output" >&2
  exit 1
}
for payment_voucher_field in '影响：' '修复建议：' '验证方式：' '来源：确定性预检（代码证据，非模型原文）'; do
  payment_voucher_field_count="$(printf '%s\n' "$payment_voucher_output" | grep -c "$payment_voucher_field" || true)"
  [[ "$payment_voucher_field_count" -eq 1 ]] || {
    echo "payment-voucher preflight field count mismatch for $payment_voucher_field: $payment_voucher_field_count" >&2
    printf '%s\n' "$payment_voucher_output" >&2
    exit 1
  }
done

# A database uniqueness guard and an explicit row-lock path make the same
# shape safe; a changed comment ensures the negative assertion still uses the
# resulting source and schema rather than a repository-wide keyword search.
payment_voucher_safe_repo="$fixture_root/payment-voucher-safe-repo"
mkdir -p "$payment_voucher_safe_repo/src/main/java/example/order" "$payment_voucher_safe_repo/sql"
git -C "$payment_voucher_safe_repo" init -q
git -C "$payment_voucher_safe_repo" config user.email test@example.invalid
git -C "$payment_voucher_safe_repo" config user.name preflight-payment-voucher-safe
cat >"$payment_voucher_safe_repo/src/main/java/example/order/SalesOrderApplication.java" <<'EOF'
package example.order;

final class SalesOrderApplication {
    void submit(Long orderId) {
        return;
    }
}
EOF
cat >"$payment_voucher_safe_repo/sql/platform_erp.sql" <<'EOF'
CREATE TABLE IF NOT EXISTS `erp_sales_payment_voucher` (
  `id` bigint NOT NULL,
  `order_id` bigint NOT NULL,
  `status` varchar(32) NOT NULL,
  UNIQUE KEY `uk_voucher_order` (`order_id`)
) ENGINE=InnoDB;
EOF
git -C "$payment_voucher_safe_repo" add .
git -C "$payment_voucher_safe_repo" commit -qm payment-voucher-safe-base
cat >"$payment_voucher_safe_repo/src/main/java/example/order/SalesOrderApplication.java" <<'EOF'
package example.order;

final class SalesOrderApplication {
    void submit(Long orderId) {
        PaymentVoucher pending = buildPendingVoucher(orderId);
        salesPaymentVoucherRepository.save(pending);
    }

    PaymentVoucher buildPendingVoucher(Long orderId) {
        orderRepository.findByIdForUpdate(orderId);
        if (salesPaymentVoucherRepository.countPendingByOrderId(orderId) > 0) return null;
        return new PaymentVoucher(orderId);
    }
    interface PaymentVoucherRepository {
        long countPendingByOrderId(Long orderId);
        void save(PaymentVoucher voucher);
    }
    interface OrderRepository {
        Object findByIdForUpdate(Long orderId);
    }
    private final PaymentVoucherRepository salesPaymentVoucherRepository = null;
    private final OrderRepository orderRepository = null;
    static final class PaymentVoucher {
        PaymentVoucher(Long orderId) {}
    }
}
EOF
payment_voucher_safe_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  "$repo_root/bin/local-review.sh" --repo "$payment_voucher_safe_repo")"
if printf '%s\n' "$payment_voucher_safe_output" | grep -F '销售订单提交先 countPendingByOrderId 再插入待确认支付凭证' >/dev/null; then
  echo 'payment-voucher race preflight reported the safe fixture' >&2
  printf '%s\n' "$payment_voucher_safe_output" >&2
  exit 1
fi

# Inventory confirmation must not read a stock snapshot and then write it
# back through an ordinary update. The fixture is intentionally limited to a
# confirmation method so page/detail reads do not satisfy the rule.
inventory_stock_repo="$fixture_root/inventory-stock-race-repo"
mkdir -p "$inventory_stock_repo/src/main/java/example/warehouse"
git -C "$inventory_stock_repo" init -q
git -C "$inventory_stock_repo" config user.email test@example.invalid
git -C "$inventory_stock_repo" config user.name preflight-inventory-stock
cat >"$inventory_stock_repo/src/main/java/example/warehouse/InventoryAdjustmentApplication.java" <<'EOF'
package example.warehouse;

final class InventoryAdjustmentApplication {
    void confirm() {
        return;
    }
}
EOF
git -C "$inventory_stock_repo" add .
git -C "$inventory_stock_repo" commit -qm inventory-stock-base
cat >"$inventory_stock_repo/src/main/java/example/warehouse/InventoryAdjustmentApplication.java" <<'EOF'
package example.warehouse;

final class InventoryAdjustmentApplication {
    void confirm() {
        applyNoSerialAdjustment();
    }

    private void applyNoSerialAdjustment() {
        String note = "}";
        String unrelated = "InventoryTransactionService";
        var stocks = logicalWarehouseSkuRepository.listByLogicalWarehouseIdAndSkuId(1L, 2L);
        inventoryTransactionService.transferNoSerialStock(1L, 2L, 1);
        var stock = logicalWarehouseSkuRepository.findNoSerialByLogicalWarehouseIdAndSkuId(1L, 2L);
        logicalWarehouseSkuRepository.update(stock);
    }

    private final StockRepository logicalWarehouseSkuRepository = null;
    interface StockRepository {
        Object listByLogicalWarehouseIdAndSkuId(Long warehouseId, Long skuId);
        Object findNoSerialByLogicalWarehouseIdAndSkuId(Long warehouseId, Long skuId);
        void update(Object stock);
    }
    interface InventoryTransactionService {
        void transferNoSerialStock(Long warehouseId, Long skuId, int quantity);
    }
    private final InventoryTransactionService inventoryTransactionService = null;
}
EOF
inventory_stock_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  "$repo_root/bin/local-review.sh" --repo "$inventory_stock_repo")"
printf '%s\n' "$inventory_stock_output" | grep -F '库存调整或非实物调拨确认先读后写库存' >/dev/null || {
  echo 'inventory stock race preflight missed the positive fixture' >&2
  printf '%s\n' "$inventory_stock_output" >&2
  exit 1
}
inventory_stock_p1_count="$(printf '%s\n' "$inventory_stock_output" | grep -c '^P1 .*库存调整或非实物调拨确认先读后写库存' || true)"
[[ "$inventory_stock_p1_count" -eq 1 ]] || {
  echo "inventory stock preflight emitted duplicate or malformed blocks: $inventory_stock_p1_count" >&2
  printf '%s\n' "$inventory_stock_output" >&2
  exit 1
}

# An atomic-only confirmation path has no direct repository read/write
# candidate. A generic class name, string, or mixed atomic-plus-ordinary
# method must not suppress a real finding (the positive fixture above keeps
# the mixed shape and must still report).
inventory_stock_safe_repo="$fixture_root/inventory-stock-safe-repo"
mkdir -p "$inventory_stock_safe_repo/src/main/java/example/warehouse"
git -C "$inventory_stock_safe_repo" init -q
git -C "$inventory_stock_safe_repo" config user.email test@example.invalid
git -C "$inventory_stock_safe_repo" config user.name preflight-inventory-stock-safe
cat >"$inventory_stock_safe_repo/src/main/java/example/warehouse/InventoryAdjustmentApplication.java" <<'EOF'
package example.warehouse;

final class InventoryAdjustmentApplication {
    void confirm() {
        return;
    }
}
EOF
git -C "$inventory_stock_safe_repo" add .
git -C "$inventory_stock_safe_repo" commit -qm inventory-stock-safe-base
cat >"$inventory_stock_safe_repo/src/main/java/example/warehouse/InventoryAdjustmentApplication.java" <<'EOF'
package example.warehouse;

final class InventoryAdjustmentApplication {
    void confirm() {
        applyNoSerialAdjustment();
    }

    private void applyNoSerialAdjustment() {
        inventoryTransactionService.transferNoSerialStock(1L, 2L, 1);
    }
    interface InventoryTransactionService {
        void transferNoSerialStock(Long warehouseId, Long skuId, int quantity);
    }
    private final InventoryTransactionService inventoryTransactionService = null;
}
EOF
inventory_stock_safe_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  "$repo_root/bin/local-review.sh" --repo "$inventory_stock_safe_repo")"
if printf '%s\n' "$inventory_stock_safe_output" | grep -F '库存调整或非实物调拨确认先读后写库存' >/dev/null; then
  echo 'inventory stock race preflight reported the safe fixture' >&2
  printf '%s\n' "$inventory_stock_safe_output" >&2
  exit 1
fi

# A lock in the submitting caller is valid even when buildPendingVoucher only
# performs the count. This guards the cross-method evidence path and keeps the
# uniqueness schema check independent from application locking.
payment_voucher_caller_safe_repo="$fixture_root/payment-voucher-caller-safe-repo"
mkdir -p "$payment_voucher_caller_safe_repo/src/main/java/example/order" "$payment_voucher_caller_safe_repo/sql"
git -C "$payment_voucher_caller_safe_repo" init -q
git -C "$payment_voucher_caller_safe_repo" config user.email test@example.invalid
git -C "$payment_voucher_caller_safe_repo" config user.name preflight-payment-voucher-caller-safe
cat >"$payment_voucher_caller_safe_repo/src/main/java/example/order/SalesOrderApplication.java" <<'EOF'
package example.order;

final class SalesOrderApplication {
    void submit(Long orderId) {
        return;
    }
}
EOF
cat >"$payment_voucher_caller_safe_repo/sql/platform_erp.sql" <<'EOF'
CREATE TABLE IF NOT EXISTS `erp_sales_payment_voucher` (
  `id` bigint NOT NULL,
  `order_id` bigint NOT NULL,
  `status` varchar(32) NOT NULL
) ENGINE=InnoDB;
EOF
git -C "$payment_voucher_caller_safe_repo" add .
git -C "$payment_voucher_caller_safe_repo" commit -qm payment-voucher-caller-safe-base
cat >"$payment_voucher_caller_safe_repo/src/main/java/example/order/SalesOrderApplication.java" <<'EOF'
package example.order;

final class SalesOrderApplication {
    void submit(Long orderId) {
        orderRepository.findByIdForUpdate(orderId);
        PaymentVoucher pending = this.preparePendingVoucher(orderId);
        salesPaymentVoucherRepository.save(pending);
    }

    PaymentVoucher preparePendingVoucher(Long orderId) {
        return this.buildPendingVoucher(orderId);
    }

    PaymentVoucher buildPendingVoucher(Long orderId) {
        if (salesPaymentVoucherRepository.countPendingByOrderId(orderId) > 0) return null;
        return new PaymentVoucher(orderId);
    }
    interface PaymentVoucherRepository {
        long countPendingByOrderId(Long orderId);
        void save(PaymentVoucher voucher);
    }
    interface OrderRepository {
        Object findByIdForUpdate(Long orderId);
    }
    private final PaymentVoucherRepository salesPaymentVoucherRepository = null;
    private final OrderRepository orderRepository = null;
    static final class PaymentVoucher {
        PaymentVoucher(Long orderId) {}
    }
}
EOF
payment_voucher_caller_safe_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  "$repo_root/bin/local-review.sh" --repo "$payment_voucher_caller_safe_repo")"
if printf '%s\n' "$payment_voucher_caller_safe_output" | grep -F '销售订单提交先 countPendingByOrderId 再插入待确认支付凭证' >/dev/null; then
  echo 'payment-voucher race preflight reported the safe caller-lock fixture' >&2
  printf '%s\n' "$payment_voucher_caller_safe_output" >&2
  exit 1
fi

# Operation-log tenant and audit identity checks are scoped to the migration
# shape that excludes sys_log from the generic tenant interceptor.
log_tenant_repo="$fixture_root/log-tenant-audit-repo"
mkdir -p "$log_tenant_repo/nacos-config" "$log_tenant_repo/src/main/java/com/bit/log/controller" "$log_tenant_repo/src/main/java/com/bit/log/repository"
git -C "$log_tenant_repo" init -q
git -C "$log_tenant_repo" config user.email test@example.invalid
git -C "$log_tenant_repo" config user.name preflight-log-tenant
printf '%s\n' '# log tenant audit fixture' >"$log_tenant_repo/README.md"
git -C "$log_tenant_repo" add .
git -C "$log_tenant_repo" commit -qm log-tenant-audit-base
cat >"$log_tenant_repo/nacos-config/platform-log.yml" <<'EOF'
tenant:
  ignore-tables:
    - sys_log
EOF
cat >"$log_tenant_repo/src/main/java/com/bit/log/controller/LogController.java" <<'EOF'
package com.bit.log.controller;

final class LogController {
    Object create(LogCreateDTO dto) { return service.create(dto); }
    Object page(LogQueryDTO query) { return service.page(query); }
    Object clean(LogQueryDTO query) { return service.clean(query); }
    void export(LogQueryDTO query) { service.export(query); }
    private final LogApplicationService service = null;
    interface LogApplicationService {
        Object create(LogCreateDTO dto);
        Object page(LogQueryDTO query);
        Object clean(LogQueryDTO query);
        void export(LogQueryDTO query);
    }
    static final class LogCreateDTO {}
    static final class LogQueryDTO {}
}
EOF
cat >"$log_tenant_repo/src/main/java/com/bit/log/repository/LogRepository.java" <<'EOF'
package com.bit.log.repository;

final class LogRepository {
    void create(LogCreateDTO dto) {
        SysLog log = BeanUtil.copyProperties(dto, SysLog.class);
        sysLogMapper.insert(log);
    }
    void page(LogQueryDTO query) {
        sysLogMapper.selectPage(new LambdaQueryWrapper<SysLog>()
            .eq(query.getTenantId() != null, SysLog::getTenantId, query.getTenantId()));
    }
    void list(LogQueryDTO query) {
        sysLogMapper.selectList(new LambdaQueryWrapper<SysLog>()
            .eq(query.getTenantId() != null, SysLog::getTenantId, query.getTenantId()));
    }
    void clean(LogQueryDTO query) {
        sysLogMapper.delete(new LambdaQueryWrapper<SysLog>()
            .eq(query.getTenantId() != null, SysLog::getTenantId, query.getTenantId()));
    }
    interface Mapper {
        void insert(SysLog log);
        void selectPage(Object wrapper);
        void selectList(Object wrapper);
        void delete(Object wrapper);
    }
    private final Mapper sysLogMapper = null;
    static final class SysLog { static Long getTenantId(SysLog value) { return null; } }
    static final class LogCreateDTO {}
    static final class LogQueryDTO { Long getTenantId() { return null; } }
    static final class BeanUtil { static SysLog copyProperties(Object dto, Class<SysLog> type) { return null; } }
    static final class LambdaQueryWrapper<T> { LambdaQueryWrapper<T> eq(boolean c, Object k, Object v) { return this; } }
}
EOF
log_tenant_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  "$repo_root/bin/local-review.sh" --repo "$log_tenant_repo")"
printf '%s\n' "$log_tenant_output" | grep -F '操作日志表被显式排除通用租户拦截' >/dev/null || {
  echo 'log tenant audit preflight missed the positive tenant-scope fixture' >&2
  printf '%s\n' "$log_tenant_output" >&2
  exit 1
}
printf '%s\n' "$log_tenant_output" | grep -F '操作日志创建直接将客户端 DTO 复制到实体' >/dev/null || {
  echo 'log tenant audit preflight missed the positive audit-identity fixture' >&2
  printf '%s\n' "$log_tenant_output" >&2
  exit 1
}
log_tenant_p1_count="$(printf '%s\n' "$log_tenant_output" | grep -c '^P1 .*操作日志' || true)"
[[ "$log_tenant_p1_count" -eq 2 ]] || {
  echo "log tenant audit preflight emitted duplicate or malformed blocks: $log_tenant_p1_count" >&2
  printf '%s\n' "$log_tenant_output" >&2
  exit 1
}

# Removing the explicit sys_log exclusion must keep the log-specific rule off.
log_tenant_safe_repo="$fixture_root/log-tenant-audit-safe-repo"
cp -R "$log_tenant_repo" "$log_tenant_safe_repo"
sed -i.bak 's/ignore-tables:/enabled: true #/' "$log_tenant_safe_repo/nacos-config/platform-log.yml"
sed -i.bak '/    - sys_log/d' "$log_tenant_safe_repo/nacos-config/platform-log.yml"
rm -f "$log_tenant_safe_repo/nacos-config/platform-log.yml.bak"
log_tenant_safe_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  "$repo_root/bin/local-review.sh" --repo "$log_tenant_safe_repo")"
if printf '%s\n' "$log_tenant_safe_output" | grep -F '操作日志表被显式排除通用租户拦截' >/dev/null || \
   printf '%s\n' "$log_tenant_safe_output" | grep -F '操作日志创建直接将客户端 DTO 复制到实体' >/dev/null; then
  echo 'log tenant audit preflight reported the safe configuration fixture' >&2
  printf '%s\n' "$log_tenant_safe_output" >&2
  exit 1
fi

# XXL-JOB admin logs must not serialize complete glue or job configuration
# objects.  ID-only operation logs remain valid and form the negative case.
job_log_repo="$fixture_root/job-sensitive-log-repo"
mkdir -p "$job_log_repo/xxl-job-admin/src/main/java/com/xxl/job/admin/controller/biz" "$job_log_repo/xxl-job-admin/src/main/java/com/xxl/job/admin/service/impl"
git -C "$job_log_repo" init -q
git -C "$job_log_repo" config user.email test@example.invalid
git -C "$job_log_repo" config user.name preflight-job-sensitive-log
printf '%s\n' '# job sensitive log fixture' >"$job_log_repo/README.md"
git -C "$job_log_repo" add .
git -C "$job_log_repo" commit -qm job-sensitive-log-base
cat >"$job_log_repo/xxl-job-admin/src/main/java/com/xxl/job/admin/controller/biz/JobCodeController.java" <<'EOF'
package com.xxl.job.admin.controller.biz;
final class JobCodeController {
    void update(XxlJobLogGlue xxlJobLogGlue) {
        logger.info(">>>>>>>>>>> xxl-job operation log: type = {}, content = {}", "jobcode-update", GsonTool.toJson(xxlJobLogGlue));
    }
    Object logger = null;
}
EOF
cat >"$job_log_repo/xxl-job-admin/src/main/java/com/xxl/job/admin/service/impl/XxlJobServiceImpl.java" <<'EOF'
package com.xxl.job.admin.service.impl;
final class XxlJobServiceImpl {
    void add(XxlJobInfo jobInfo) {
        logger.info(">>>>>>>>>>> xxl-job operation log: type = {}, content = {}", "jobinfo-save", GsonTool.toJson(jobInfo));
    }
    Object logger = null;
}
EOF
job_log_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  "$repo_root/bin/local-review.sh" --repo "$job_log_repo")"
printf '%s\n' "$job_log_output" | grep -F '直接序列化 XxlJobLogGlue' >/dev/null || {
  echo 'job sensitive log preflight missed the glue fixture' >&2
  printf '%s\n' "$job_log_output" >&2
  exit 1
}
printf '%s\n' "$job_log_output" | grep -F '直接序列化完整任务配置对象' >/dev/null || {
  echo 'job sensitive log preflight missed the job config fixture' >&2
  printf '%s\n' "$job_log_output" >&2
  exit 1
}
job_log_p1_count="$(printf '%s\n' "$job_log_output" | grep -c '^P1 .*XXL-JOB 操作日志' || true)"
[[ "$job_log_p1_count" -eq 2 ]] || {
  echo "job sensitive log preflight emitted duplicate or malformed blocks: $job_log_p1_count" >&2
  printf '%s\n' "$job_log_output" >&2
  exit 1
}

job_log_safe_repo="$fixture_root/job-sensitive-log-safe-repo"
cp -R "$job_log_repo" "$job_log_safe_repo"
sed -i.bak 's/GsonTool.toJson(xxlJobLogGlue)/xxlJobLogGlue.getId()/' "$job_log_safe_repo/xxl-job-admin/src/main/java/com/xxl/job/admin/controller/biz/JobCodeController.java"
sed -i.bak 's/GsonTool.toJson(jobInfo)/jobInfo.getId()/' "$job_log_safe_repo/xxl-job-admin/src/main/java/com/xxl/job/admin/service/impl/XxlJobServiceImpl.java"
rm -f "$job_log_safe_repo/xxl-job-admin/src/main/java/com/xxl/job/admin/controller/biz/JobCodeController.java.bak" "$job_log_safe_repo/xxl-job-admin/src/main/java/com/xxl/job/admin/service/impl/XxlJobServiceImpl.java.bak"
job_log_safe_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  "$repo_root/bin/local-review.sh" --repo "$job_log_safe_repo")"
if printf '%s\n' "$job_log_safe_output" | grep -F 'XXL-JOB 操作日志直接序列化' >/dev/null; then
  echo 'job sensitive log preflight reported the id-only safe fixture' >&2
  printf '%s\n' "$job_log_safe_output" >&2
  exit 1
fi

# A newly exposed workflow gateway route must be covered by the same
# business-application mapping used by the tenant authorization filter.
workflow_scope_repo="$fixture_root/workflow-scope-repo"
mkdir -p "$workflow_scope_repo/nacos-config" "$workflow_scope_repo/src/main/java/com/bit/gateway/filter"
git -C "$workflow_scope_repo" init -q
git -C "$workflow_scope_repo" config user.email test@example.invalid
git -C "$workflow_scope_repo" config user.name preflight-workflow-scope
cat >"$workflow_scope_repo/nacos-config/platform-gateway.yml" <<'EOF'
spring:
  cloud:
    gateway:
      routes: []
EOF
cat >"$workflow_scope_repo/src/main/java/com/bit/gateway/filter/SaTokenAuthGlobalFilter.java" <<'EOF'
final class SaTokenAuthGlobalFilter {
    static final java.util.Map<String, String> BUSINESS_APPLICATION_BY_PATH_PREFIX =
        java.util.Map.of("/system/", "system");
    boolean allowed(Long principalTenantId, Long targetTenantId, String applicationCode) {
        return principalTenantId.equals(targetTenantId) && applicationCode == null;
    }
    boolean authorize(Long principalTenantId) {
        return allowed(principalTenantId, principalTenantId, null);
    }
    boolean isInternalOnlyPath(String path) { return path.startsWith("/workflow/v1/internal/**"); }
    String resolveBusinessApplicationCode(String path) {
        return BUSINESS_APPLICATION_BY_PATH_PREFIX.entrySet().stream()
            .filter(entry -> path.startsWith(entry.getKey()))
            .map(java.util.Map.Entry::getValue).findFirst().orElse(null);
    }
}
EOF
git -C "$workflow_scope_repo" add .
git -C "$workflow_scope_repo" commit -qm workflow-scope-base
cat >"$workflow_scope_repo/nacos-config/platform-gateway.yml" <<'EOF'
spring:
  cloud:
    gateway:
      routes:
        - id: workflow
          uri: lb://workflow
          predicates:
            - Path=/workflow/**
EOF
workflow_scope_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  "$repo_root/bin/local-review.sh" --repo "$workflow_scope_repo")"
workflow_scope_marker='新增 /workflow/** 网关路由未加入业务应用租户映射'
printf '%s\n' "$workflow_scope_output" | grep -F "$workflow_scope_marker" >/dev/null || {
  echo 'workflow application scope preflight missed the vulnerable route fixture' >&2
  printf '%s\n' "$workflow_scope_output" >&2
  exit 1
}
workflow_scope_p1_count="$(printf '%s\n' "$workflow_scope_output" | grep -c '^P1 .*新增 /workflow/\*\* 网关路由未加入业务应用租户映射' || true)"
[[ "$workflow_scope_p1_count" -eq 1 ]] || {
  echo "workflow application scope preflight emitted duplicate or malformed blocks: $workflow_scope_p1_count" >&2
  printf '%s\n' "$workflow_scope_output" >&2
  exit 1
}
for workflow_scope_field in '影响：' '修复建议：' '验证方式：' '证据行：'; do
  [[ "$(printf '%s\n' "$workflow_scope_output" | grep -cF "$workflow_scope_field" || true)" -eq 1 ]] || {
    echo "workflow application scope preflight omitted field: $workflow_scope_field" >&2
    printf '%s\n' "$workflow_scope_output" >&2
    exit 1
  }
done

workflow_scope_safe_repo="$fixture_root/workflow-scope-safe-repo"
cp -R "$workflow_scope_repo" "$workflow_scope_safe_repo"
perl -0pi -e 's/"\/system\/", "system"\);/"\/system\/", "system", "\/workflow\/", "workflow");/' \
  "$workflow_scope_safe_repo/src/main/java/com/bit/gateway/filter/SaTokenAuthGlobalFilter.java"
workflow_scope_safe_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  "$repo_root/bin/local-review.sh" --repo "$workflow_scope_safe_repo")"
if printf '%s\n' "$workflow_scope_safe_output" | grep -F "$workflow_scope_marker" >/dev/null; then
  echo 'workflow application scope preflight reported the explicitly mapped safe fixture' >&2
  printf '%s\n' "$workflow_scope_safe_output" >&2
  exit 1
fi

# Provider login must not resolve an external identity globally and then issue
# a session for the matched tenant.  The positive fixture changes both the
# application and mapper files so the location gate sees a real login diff.
sso_scope_repo="$fixture_root/sso-provider-scope-repo"
mkdir -p "$sso_scope_repo/src/main/java/com/bit/auth/application" "$sso_scope_repo/src/main/java/com/bit/auth/mapper"
git -C "$sso_scope_repo" init -q
git -C "$sso_scope_repo" config user.email test@example.invalid
git -C "$sso_scope_repo" config user.name preflight-sso-provider-scope
cat >"$sso_scope_repo/src/main/java/com/bit/auth/application/SsoProviderLoginApplication.java" <<'EOF'
package com.bit.auth.application;
final class SsoProviderLoginApplication {}
EOF
cat >"$sso_scope_repo/src/main/java/com/bit/auth/mapper/SysExternalIdentityMapper.java" <<'EOF'
package com.bit.auth.mapper;
interface SysExternalIdentityMapper {}
EOF
git -C "$sso_scope_repo" add .
git -C "$sso_scope_repo" commit -qm sso-provider-scope-base
cat >"$sso_scope_repo/src/main/java/com/bit/auth/application/SsoProviderLoginApplication.java" <<'EOF'
package com.bit.auth.application;
final class SsoProviderLoginApplication {
    LoginResult login(SsoProviderLoginDTO dto) {
        Binding binding = identityMapper.findByProviderCodeAndTerminalTypeAndExternalUserId(
            dto.providerCode(), dto.terminalType(), dto.externalUserId());
        return loginService.login(binding.getUserId(), binding.getTenantId());
    }
    private final SysExternalIdentityMapper identityMapper = null;
    private final LoginService loginService = null;
}
EOF
cat >"$sso_scope_repo/src/main/java/com/bit/auth/mapper/SysExternalIdentityMapper.java" <<'EOF'
package com.bit.auth.mapper;
@InterceptorIgnore(tenantLine = "true")
interface SysExternalIdentityMapper {
    @Select("SELECT user_id, tenant_id FROM sys_external_identity WHERE provider_code = #{providerCode} AND terminal_type = #{terminalType} AND external_user_id = #{externalUserId}")
    Binding findByProviderCodeAndTerminalTypeAndExternalUserId(String providerCode, String terminalType, String externalUserId);
}
EOF
sso_scope_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  "$repo_root/bin/local-review.sh" --repo "$sso_scope_repo")"
sso_scope_marker='第三方登录绑定按外部身份查询未带租户边界'
printf '%s\n' "$sso_scope_output" | grep -F "$sso_scope_marker" >/dev/null || {
  echo 'sso provider scope preflight missed the vulnerable binding fixture' >&2
  printf '%s\n' "$sso_scope_output" >&2
  exit 1
}
sso_scope_p1_count="$(printf '%s\n' "$sso_scope_output" | grep -c '^P1 .*第三方登录绑定按外部身份查询未带租户边界' || true)"
[[ "$sso_scope_p1_count" -eq 1 ]] || {
  echo "sso provider scope preflight emitted duplicate or malformed blocks: $sso_scope_p1_count" >&2
  printf '%s\n' "$sso_scope_output" >&2
  exit 1
}
for sso_scope_field in '影响：' '修复建议：' '验证方式：' '证据行：' '来源：确定性预检'; do
  [[ "$(printf '%s\n' "$sso_scope_output" | grep -cF "$sso_scope_field" || true)" -eq 1 ]] || {
    echo "sso provider scope preflight omitted field: $sso_scope_field" >&2
    printf '%s\n' "$sso_scope_output" >&2
    exit 1
  }
done

sso_scope_safe_repo="$fixture_root/sso-provider-scope-safe-repo"
cp -R "$sso_scope_repo" "$sso_scope_safe_repo"
perl -0pi -e 's/external_user_id = #\{externalUserId\}/external_user_id = #{externalUserId} AND tenant_id = #{tenantId}/' \
  "$sso_scope_safe_repo/src/main/java/com/bit/auth/mapper/SysExternalIdentityMapper.java"
perl -0pi -e 's/dto\.externalUserId\(\)\);/dto.externalUserId(), dto.tenantId());\n        assertTenantMembership(binding);/' \
  "$sso_scope_safe_repo/src/main/java/com/bit/auth/application/SsoProviderLoginApplication.java"
sso_scope_safe_output="$(PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  "$repo_root/bin/local-review.sh" --repo "$sso_scope_safe_repo")"
if printf '%s\n' "$sso_scope_safe_output" | grep -F "$sso_scope_marker" >/dev/null; then
  echo 'sso provider scope preflight reported the tenant-scoped safe fixture' >&2
  printf '%s\n' "$sso_scope_safe_output" >&2
  exit 1
fi

# Configuration report retention uses a fresh fixture. The add-dto commit
# above already committed earlier config files, so they are not valid changed
# paths here; testing their silent removal would bypass the location gate.
bash "$repo_root/evals/test-config-findings.sh"

printf 'preflight regression passed\n'
