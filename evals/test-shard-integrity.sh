#!/usr/bin/env bash
set -euo pipefail

# Exercise the production splitter without loading the CLI, Git, or Ollama.
# Compare ordered, coordinate-bearing body records, not a particular packing
# layout: a different number of valid shards is not a regression.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-shard-integrity.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

splitter="$(awk '
  /^split_diff_into_chunks\(\) \{$/ { copying = 1; found++ }
  copying { print }
  copying && /^}$/ { copying = 0; ended++ }
  END { if (found != 1 || ended != 1 || copying) exit 1 }
' "$repo_root/bin/local-review.sh")"
# Only the trusted repository function above is evaluated. No fixture text is
# executable, and no top-level part of local-review.sh is sourced.
eval "$splitter"
declare -F split_diff_into_chunks >/dev/null

perl - "$fixture_root" <<'PERL'
use strict;
use warnings;
my ($root) = @ARGV;

sub hunk {
    my ($old, $new, $suffix, @body) = @_;
    my $old_count = grep { /^[ -]/ } @body;
    my $new_count = grep { /^[ +]/ } @body;
    return "\@\@ -$old,$old_count +$new,$new_count \@\@$suffix\n"
        . join('', map { "$_\n" } @body);
}
sub section {
    my ($file, $body, $mode) = @_;
    my $old = $mode && $mode eq 'add' ? '/dev/null' : "a/$file";
    my $new = $mode && $mode eq 'delete' ? '/dev/null' : "b/$file";
    return "diff --git a/$file b/$file\n--- $old\n+++ $new\n$body";
}
sub save {
    my ($name, $text) = @_;
    open my $out, '>:raw', "$root/$name.diff" or die $!;
    print {$out} $text;
    close $out or die $!;
}

# Multiple files, multiple hunks, UTF-8 bytes, repeated body records, and
# lines that look like file headers but are additions/deletions inside hunks.
my @first = (' context-top', '---not-a-file-header', '+++not-a-file-header');
for my $i (1 .. 35) {
    push @first, sprintf('-旧值-%03d-中文', $i), sprintf('+新值-%03d-中文', $i);
    push @first, ' repeated-context' if $i % 7 == 0;
}
save('mixed', 'Review fixture preamble' . "\n"
    . section('Mixed.java', hunk(7, 9, ' method()', @first)
        . hunk(120, 125, ' second()', map { ('-same-line', '+same-line') } 1 .. 12))
    . section('Other.txt', hunk(4, 4, '', ' unchanged', '-before', '+after',
        map { sprintf('+other-%03d', $_) } 1 .. 25)));

save('add-delete',
    section('Added.txt', hunk(0, 1, '', map { sprintf('+added-%03d', $_) } 1 .. 80), 'add')
    . section('Deleted.txt', hunk(1, 0, '', map { sprintf('-deleted-%03d', $_) } 1 .. 80), 'delete'));

# No-newline markers are part of the evidence and must stay associated with
# the preceding body line, including when that pair is at a shard boundary.
save('no-newline', section('NoNewline.txt', hunk(1, 1, '',
    (map { sprintf(' context-%03d', $_) } 1 .. 31),
    '-old-last-line', '\ No newline at end of file',
    '+new-last-line', '\ No newline at end of file')));

# A long but splittable function suffix must be included in the byte budget.
save('long-suffix', section('Long.java', hunk(30, 40, ' function_' . ('x' x 280),
    map { sprintf('+value-%03d', $_) } 1 .. 100)));

# Truly indivisible evidence cannot fit. It must remain intact and explicitly
# mark the result oversized, never silently truncate or claim a valid shard.
save('long-line', section('LongLine.txt', hunk(0, 1, '', '+' . ('x' x 1600)), 'add'));

# Omitting the transport LF of the diff must not drop its last body record.
my $without_lf = section('Transport.txt', hunk(1, 1, '',
    map { sprintf('+transport-%03d', $_) } 1 .. 45));
$without_lf =~ s/\n\z//;
save('transport-no-lf', $without_lf);
PERL

failures=0
cases=0
check_case() {
  local fixture="$1" cap="$2" expect_oversized="${3:-false}"
  local chunks="$fixture_root/${fixture}-${cap}"
  cases=$((cases + 1))
  mkdir -p "$chunks"
  split_diff_into_chunks "$fixture_root/$fixture.diff" "$chunks" "$cap"
  if perl - "$fixture_root/$fixture.diff" "$chunks" "$cap" "$expect_oversized" <<'PERL'
use strict;
use warnings;
my ($input, $dir, $cap, $expected_oversized) = @ARGV;
my @errors;
sub error { push @errors, $_[0] }
sub read_file {
    my ($file) = @_;
    open my $in, '<:raw', $file or die "$file: $!";
    local $/;
    return <$in> // '';
}
sub records {
    my ($text, $label) = @_;
    my (@records, $file, $range, $last_body);
    my ($old, $new, $old_count, $new_count, $old_seen, $new_seen);
    my $finish = sub {
        return unless defined $range;
        error("$label: $range declares $old_count/$new_count lines, body has $old_seen/$new_seen")
            if $old_count != $old_seen || $new_count != $new_seen;
        undef $range;
    };
    for my $line (split /\n/, $text) {
        if ($line =~ /^diff --git a\/(.*?) b\/(.*)$/) {
            $finish->();
            $file = $2;
            undef $last_body;
        } elsif ($line =~ /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(?:.*)$/) {
            $finish->();
            ($old, $old_count, $new, $new_count) = ($1, defined($2) ? $2 : 1, $3, defined($4) ? $4 : 1);
            ($old_seen, $new_seen) = (0, 0);
            $range = $line;
            undef $last_body;
            error("$label: hunk before file header") unless defined $file;
        } elsif (defined $range) {
            my $sign = substr($line, 0, 1);
            if ($sign eq '-' || $sign eq '+' || $sign eq ' ') {
                my $old_at = $sign eq '+' ? '-' : $old++;
                my $new_at = $sign eq '-' ? '-' : $new++;
                $old_seen++ if $sign ne '+';
                $new_seen++ if $sign ne '-';
                $last_body = join("\t", $file // '?', $old_at, $new_at, unpack('H*', $line));
                push @records, "body\t$last_body";
            } elsif ($line eq '\ No newline at end of file') {
                error("$label: detached no-newline marker") unless defined $last_body;
                push @records, 'marker' . "\t" . ($last_body // 'DETACHED');
                undef $last_body;
            } else {
                error("$label: non-diff body line " . unpack('H*', $line));
            }
        }
    }
    $finish->();
    return @records;
}

my @expected = records(read_file($input), 'source');
my @chunks = sort glob "$dir/chunk-*.diff";
error('no chunk produced') unless @chunks;
my $count = read_file("$dir/count");
chomp $count;
error('chunk count sidecar disagrees with actual chunks') unless $count =~ /^\d+$/ && $count == @chunks;
my $oversized = read_file("$dir/oversized");
chomp $oversized;
error("oversized=$oversized, expected $expected_oversized") unless $oversized eq $expected_oversized;
my (@actual, $above_cap);
for my $chunk (@chunks) {
    my $text = read_file($chunk);
    if (length($text) > $cap) {
        $above_cap++;
        error("$chunk exceeds byte cap: " . length($text) . " > $cap") if $expected_oversized eq 'false';
    }
    push @actual, records($text, $chunk);
}
error('expected an indivisible oversized unit, but every chunk fits')
    if $expected_oversized eq 'true' && !$above_cap;
error('oversized evidence lacks diagnostic details')
    if $expected_oversized eq 'true' && read_file("$dir/oversized-details") eq '';
error('ordered body/coordinate/marker record count differs: source=' . @expected . ', chunks=' . @actual)
    if @expected != @actual;
my $limit = @expected < @actual ? scalar(@expected) : scalar(@actual);
for my $i (0 .. $limit - 1) {
    next if $expected[$i] eq $actual[$i];
    error("ordered body/coordinate/marker evidence first differs at record " . ($i + 1));
    last;
}
if (@errors) {
    print STDERR join("\n", @errors), "\n";
    exit 1;
}
PERL
  then
    printf 'PASS %s cap=%s\n' "$fixture" "$cap"
  else
    printf 'FAIL %s cap=%s\n' "$fixture" "$cap" >&2
    failures=$((failures + 1))
  fi
}

for cap in 320 511 1000; do
  check_case mixed "$cap"
  check_case add-delete "$cap"
  check_case no-newline "$cap"
  check_case transport-no-lf "$cap"
done
check_case long-suffix 511
check_case long-suffix 1000
check_case long-line 511 true

if (( failures > 0 )); then
  printf 'shard integrity regression failed: %s/%s cases\n' "$failures" "$cases" >&2
  exit 1
fi
printf 'shard integrity regression passed: %s cases\n' "$cases"
