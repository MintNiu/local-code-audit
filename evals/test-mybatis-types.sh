#!/usr/bin/env bash
set -euo pipefail

# Exercise only the type-aware MyBatis collector. No entrypoint, Ollama call,
# model lock, business repository, or network access is involved.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-mybatis-types.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
export TMPDIR="$fixture_root"

for helper in dedup_preflight_blocks collect_mybatis_raw_substitution_preflight; do
  helper_source="$(awk -v helper="$helper" '
    $0 == helper "() {" { in_helper = 1 }
    in_helper { print }
    in_helper && /^}$/ { found = 1; exit }
    END { if (!found) exit 1 }
  ' "$repo_root/bin/local-review.sh")"
  eval "$helper_source"
  declare -F "$helper" >/dev/null
done

dedup_file="$fixture_root/dedup.txt"
printf '%s\n\n%s\n' \
  'P1 src/main/resources/mybatis-mapper/JobMapper.xml:3 - duplicate' \
  'P1 src/main/resources/mybatis-mapper/JobMapper.xml:3 - duplicate' >"$dedup_file"
dedup_preflight_blocks "$dedup_file"
[[ "$(grep -Fc -- '- duplicate' "$dedup_file")" == 1 ]] || {
  printf 'FAIL dedup-preflight-blocks\n' >&2
  cat "$dedup_file" >&2
  exit 1
}
printf 'PASS dedup-preflight-blocks\n'

case_count=0
case_root=""
mapper_path="src/main/resources/mybatis-mapper/JobMapper.xml"
new_case() {
  case_root="$fixture_root/$1"
  mkdir -p "$case_root/src/main/java" "$case_root/src/main/resources/mybatis-mapper"
}
source_file() {
  local path="$1" content="$2"
  mkdir -p "$(dirname "$case_root/$path")"
  printf '%s\n' "$content" >"$case_root/$path"
}
run_case() {
  local name="$1" expression="$2" expected_count="$3" context="${4:-0}"
  local diff_file="$case_root/change.diff" old_file="$case_root/before.xml"
  local output_file="$case_root/findings.txt" raw_diff="$case_root/raw.diff"
  local diff_status=0 actual_count
  # Build the pre-change XML using a literal expression match, not a regex.
  awk -v needle="\${$expression}" -v replacement="#{${expression}}" '
    {
      text = $0
      while ((position = index(text, needle)) > 0)
        text = substr(text, 1, position - 1) replacement substr(text, position + length(needle))
      print text
    }
  ' "$case_root/$mapper_path" >"$old_file"
  diff -U "$context" "$old_file" "$case_root/$mapper_path" >"$raw_diff" || diff_status=$?
  [[ "$diff_status" -eq 1 ]] || {
    printf 'FAIL %s: fixture did not produce one valid diff (status %s)\n' "$name" "$diff_status" >&2
    return 1
  }
  {
    printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n' "$mapper_path" "$mapper_path" "$mapper_path" "$mapper_path"
    awk 'NR > 2 { print }' "$raw_diff"
  } >"$diff_file"
  if [[ "$name" == exact-fqn-primitive-outside-hunk ]] && grep -Fq parameterType "$diff_file"; then
    printf 'FAIL %s: parameterType must be outside the diff hunk\n' "$name" >&2
    return 1
  fi
  : >"$output_file"
  mybatis_safe_index_file="$case_root/safe.tsv"
  : >"$mybatis_safe_index_file"
  collect_mybatis_raw_substitution_preflight "$diff_file" "$output_file" "$case_root"
  actual_count="$(awk '/^P1 .*MyBatis Mapper 将表达式/ { count++ } END { print count + 0 }' "$output_file")"
  if [[ "$actual_count" != "$expected_count" ]]; then
    printf 'FAIL %s: expected %s candidate(s), got %s\n' "$name" "$expected_count" "$actual_count" >&2
    cat "$output_file" >&2
    return 1
  fi
  if [[ "$expected_count" -gt 0 ]] && ! grep -Fq -- "\${$expression}" "$output_file"; then
    printf 'FAIL %s: candidate lost expression %s\n' "$name" "$expression" >&2
    cat "$output_file" >&2
    return 1
  fi
  case_count=$((case_count + 1))
  printf 'PASS %s\n' "$name"
}

numeric_java='package example;
public final class JobParam {
    private int timeout;
    public int getTimeout() { return timeout; }
}'
string_java='package example;
public final class JobParam {
    private String timeout;
    public String getTimeout() { return timeout; }
}'
numeric_xml='<mapper namespace="example.JobMapper">
  <update id="update" parameterType="example.JobParam">
    UPDATE jobs
    SET
      timeout = ${timeout}
    WHERE id = #{id}
  </update>
</mapper>'

new_case exact-fqn-primitive-outside-hunk
source_file src/main/java/example/JobParam.java "$numeric_java"
source_file "$mapper_path" "$numeric_xml"
run_case exact-fqn-primitive-outside-hunk timeout 0

new_case string-getter
source_file src/main/java/example/JobParam.java "$string_java"
source_file "$mapper_path" "$numeric_xml"
run_case string-getter timeout 1

new_case same-class-name-other-package
source_file src/main/java/example/JobParam.java "$string_java"
source_file src/main/java/other/JobParam.java 'package other;
public final class JobParam {
    private int timeout;
    public int getTimeout() { return timeout; }
}'
source_file "$mapper_path" "$numeric_xml"
run_case same-class-name-other-package timeout 1

new_case numeric-field-string-getter
source_file src/main/java/example/JobParam.java 'package example;
public final class JobParam {
    private int timeout;
    private String rawTimeout;
    public String getTimeout() { return rawTimeout; }
}'
source_file "$mapper_path" "$numeric_xml"
run_case numeric-field-string-getter timeout 1

new_case nested-expression
source_file src/main/java/example/JobParam.java 'package example;
public final class JobParam {
    private int timeout;
    private Child child;
    public int getTimeout() { return timeout; }
    public Child getChild() { return child; }
    static final class Child {
        private String timeout;
        public String getTimeout() { return timeout; }
    }
}'
source_file "$mapper_path" '<mapper namespace="example.JobMapper">
  <update id="update" parameterType="example.JobParam">
    UPDATE jobs SET timeout = ${child.timeout} WHERE id = #{id}
  </update>
</mapper>'
run_case nested-expression child.timeout 1

new_case bind-shadows-numeric-getter
source_file src/main/java/example/JobParam.java "$numeric_java"
source_file "$mapper_path" '<mapper namespace="example.JobMapper">
  <update id="update" parameterType="example.JobParam">
    <bind name="timeout" value="rawInput"/>
    UPDATE jobs SET timeout = ${timeout} WHERE id = #{id}
  </update>
</mapper>'
run_case bind-shadows-numeric-getter timeout 1 8

new_case foreach-item-shadows-numeric-getter
source_file src/main/java/example/JobParam.java "$numeric_java"
source_file "$mapper_path" '<mapper namespace="example.JobMapper">
  <update id="update" parameterType="example.JobParam">
    <foreach collection="timeouts" item="timeout" separator=";">
      UPDATE jobs SET timeout = ${timeout} WHERE id = #{id}
    </foreach>
  </update>
</mapper>'
run_case foreach-item-shadows-numeric-getter timeout 1 8

new_case commented-numeric-getter
source_file src/main/java/example/JobParam.java 'package example;
public final class JobParam {
    private String timeout;
    /*
    public int getTimeout() { return 0; }
    */
    public String getTimeout() { return timeout; }
}'
source_file "$mapper_path" "$numeric_xml"
run_case commented-numeric-getter timeout 1

new_case adjacent-statement-unknown-type
source_file src/main/java/example/JobParam.java "$numeric_java"
source_file "$mapper_path" '<mapper namespace="example.JobMapper">
  <update id="numeric" parameterType="example.JobParam">
    UPDATE jobs SET timeout = #{timeout} WHERE id = #{id}
  </update>
  <update id="unknown">
    UPDATE jobs SET timeout = ${timeout} WHERE id = #{id}
  </update>
</mapper>'
run_case adjacent-statement-unknown-type timeout 1 8

new_case unresolved-type-alias
source_file src/main/java/example/JobParam.java "$numeric_java"
source_file "$mapper_path" '<mapper namespace="example.JobMapper">
  <update id="update" parameterType="JobParam">
    UPDATE jobs SET timeout = ${timeout} WHERE id = #{id}
  </update>
</mapper>'
run_case unresolved-type-alias timeout 1 8

printf 'MyBatis type-boundary regression: %s cases passed (no model calls)\n' "$case_count"
