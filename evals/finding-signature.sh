#!/usr/bin/env bash
set -euo pipefail

# Produce a repeatability signature for a review result without comparing the
# model's prose byte-for-byte.  The returned signature preserves the semantic
# finding set (severity, location, risk-family evidence, and MyBatis
# expressions) while collapsing repeated prose for the same root. It never
# changes the result shown to a user and is therefore not a finding filter.
result_file="${1:-}"
[[ -f "$result_file" ]] || {
  echo "用法: finding-signature.sh <review-result>" >&2
  exit 2
}

LC_ALL=C awk '
  function emit(    first, header, lower, families, rest, expression, expressions) {
    if (block == "") return
    first = block
    sub(/\n.*/, "", first)
    if (first ~ /^[[:space:]]*未发现阻塞问题/) {
      print "clean"
      block = ""
      return
    }
    if (first !~ /^[[:space:]]*(P[0-3]|信息)[[:space:]:：]+/) {
      print "invalid"
      block = ""
      return
    }
    header = first
    sub(/[[:space:]]+-.*$/, "", header)
    lower = tolower(block)
    families = ""
    if (lower ~ /tenant|租户|跨租户/) families = families ",tenant"
    if (lower ~ /sql|mybatis|原始替换|\$\{/) families = families ",sql"
    if (lower ~ /ssrf|服务端请求伪造|内网|metadata|url/) families = families ",url"
    if (lower ~ /权限|授权|越权|未授权|preauthorize|requirespermissions/) families = families ",authz"
    if (lower ~ /凭据|密钥|token|密码|secret|credential/) families = families ",credential"
    if (lower ~ /并发|竞态|race|原子|线程/) families = families ",race"
    if (lower ~ /路径遍历|目录逃逸|任意文件|文件名/) families = families ",path"
    if (lower ~ /反序列化|objectinputstream|xxe|外部实体/) families = families ",parser"
    if (lower ~ /命令注入|命令执行|shell/) families = families ",command"
    if (lower ~ /重定向|redirect|cors|跨域/) families = families ",http"
    # Do not classify generic remediation wording such as “迁移到新的授权
    # 机制” as a database/schema migration.  That prose varies between model
    # runs for the same authorization root and would create false signature
    # drift; keep only explicit migration/script/schema evidence.
    if (lower ~ /迁移脚本|数据库升级|schema|migration/) families = families ",migration"
    if (lower ~ /预签名|票据|重放|presign|replay/) families = families ",replay"
    expressions = ""
    rest = block
    while (match(rest, /\$\{[A-Za-z_][A-Za-z0-9_.]*\}/)) {
      expression = substr(rest, RSTART, RLENGTH)
      expressions = expressions "," expression
      rest = substr(rest, RSTART + RLENGTH)
    }
    gsub(/[[:space:]]+/, " ", families)
    # The user-visible contract keeps every model paragraph, including
    # independently worded repeats from separate shards.  Repeatability
    # should compare the semantic finding set rather than the model
    # duplicate prose count: same severity/location/risk-family/expression is
    # one root for the signature, while different locations or families stay
    # distinct.  This affects only the private verifier, never the output.
    signature_key = header "\t" families "\t" expressions
    if (seen_signature[signature_key]++) {
      block = ""
      return
    }
    printf "%04d\t%s\tfamilies=%s\texpressions=%s\n", block_index, header, families, expressions
    block = ""
    block_index++
  }
  {
    if ($0 ~ /^[[:space:]]*(P[0-3]|信息)[[:space:]:：]+/ || $0 ~ /^[[:space:]]*未发现阻塞问题/) emit()
    if (block != "") block = block "\n"
    block = block $0
  }
  END { emit() }
' "$result_file"
