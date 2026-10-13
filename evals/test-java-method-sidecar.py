#!/usr/bin/env python3
"""Fast tests for the optional bounded Java method-context sidecar."""

from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


REPO_ROOT = Path(__file__).resolve().parents[1]
SPEC = spec_from_file_location("java_method_sidecar", REPO_ROOT / "bin" / "java-method-sidecar.py")
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Cannot load java-method-sidecar.py")
MODULE = module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


SOURCE = """\
package testcases;

class Guard {
    static Object target(Object input) {
        audit(input);
        if (input == null) {
            return new Object();
        }
        return input;
    }

    static Object next() {
        return new Object();
    }
}
"""


DIFF = """\
diff --git a/src/main/java/testcases/Guard.java b/src/main/java/testcases/Guard.java
index 1111111..2222222 100644
--- a/src/main/java/testcases/Guard.java
+++ b/src/main/java/testcases/Guard.java
@@ -4,4 +4,5 @@ class Guard {
     static Object target(Object input) {
+        audit(input);
         if (input == null) {
             return new Object();
         }
"""


DELETED_FILE_DIFF = """\
diff --git a/src/main/java/testcases/Guard.java b/src/main/java/testcases/Guard.java
index 1111111..2222222 100644
--- a/src/main/java/testcases/Guard.java
+++ b/src/main/java/testcases/Guard.java
@@ -4,1 +4,2 @@ class Guard {
     static Object target(Object input) {
+        audit(input);
diff --git a/src/main/java/testcases/Gone.java b/src/main/java/testcases/Gone.java
deleted file mode 100644
index 3333333..0000000
--- a/src/main/java/testcases/Gone.java
+++ /dev/null
@@ -1,2 +0,0 @@
-final class Gone {}
-
"""


NEW_FILE_SOURCE = """\
package testcases;

final class NewFile {
    static Object first() {
        return new Object();
    }

    static Object target(Object input) {
        return input == null ? new Object() : input;
    }

    static Object next() {
        return new Object();
    }
}
"""


NEW_FILE_DIFF = """\
diff --git a/src/main/java/testcases/NewFile.java b/src/main/java/testcases/NewFile.java
new file mode 100644
--- /dev/null
+++ b/src/main/java/testcases/NewFile.java
@@ -0,0 +1,15 @@
+package testcases;
+
+final class NewFile {
+    static Object first() {
+        return new Object();
+    }
+
+    static Object target(Object input) {
+        return input == null ? new Object() : input;
+    }
+
+    static Object next() {
+        return new Object();
+    }
+}
"""


def new_file_diff(relative: str, source: str) -> str:
    lines = source.splitlines()
    return (
        f"diff --git a/{relative} b/{relative}\n"
        "new file mode 100644\n"
        "--- /dev/null\n"
        f"+++ b/{relative}\n"
        f"@@ -0,0 +1,{len(lines)} @@\n"
        + "".join(f"+{line}\n" for line in lines)
        + ("\\ No newline at end of file\n" if not source.endswith("\n") else "")
    )


class JavaMethodSidecarTest(unittest.TestCase):
    def test_extracts_only_method_containing_added_line(self):
        with tempfile.TemporaryDirectory(prefix="method-sidecar-") as directory:
            root = Path(directory)
            source = root / "src/main/java/testcases/Guard.java"
            source.parent.mkdir(parents=True)
            source.write_text(SOURCE, encoding="utf-8")
            sidecar = MODULE.build_sidecar(root, DIFF)
        self.assertIn("文件: src/main/java/testcases/Guard.java:4-10", sidecar)
        self.assertIn("audit(input);", sidecar)
        self.assertNotIn("static Object next()", sidecar)

    def test_tracks_hunk_line_numbers_and_ignores_deletions(self):
        added = MODULE.added_lines_by_path(DIFF)
        self.assertEqual(added, {"src/main/java/testcases/Guard.java": [5]})

    def test_does_not_leak_added_lines_into_deleted_file_metadata(self):
        added = MODULE.added_lines_by_path(DELETED_FILE_DIFF)
        self.assertEqual(added, {"src/main/java/testcases/Guard.java": [5]})

    def test_finds_middle_method_in_a_complete_new_file_hunk(self):
        with tempfile.TemporaryDirectory(prefix="method-sidecar-new-file-") as directory:
            root = Path(directory)
            source = root / "src/main/java/testcases/NewFile.java"
            source.parent.mkdir(parents=True)
            source.write_text(NEW_FILE_SOURCE, encoding="utf-8")
            spans = MODULE.method_spans(root, "src/main/java/testcases/NewFile.java", list(range(1, 16)))
            sidecar = MODULE.build_sidecar(root, NEW_FILE_DIFF)
        self.assertEqual([(4, 6), (8, 10), (12, 14)], spans)
        self.assertIn("static Object first()", sidecar)
        self.assertIn("static Object target(Object input)", sidecar)
        self.assertIn("static Object next()", sidecar)

    def test_parses_one_file_in_one_batch_for_many_disjoint_added_lines(self):
        with tempfile.TemporaryDirectory(prefix="method-sidecar-batch-") as directory:
            root = Path(directory)
            source = root / "Many.java"
            source.write_text(
                "final class Many {\n"
                + "".join(f"    static int method{index}() {{ return {index}; }}\n" for index in range(80))
                + "}\n",
                encoding="utf-8",
            )
            with patch.object(MODULE.subprocess, "check_output", wraps=MODULE.subprocess.check_output) as batch:
                spans = MODULE.method_spans(root, "Many.java", list(range(2, 82, 2)))
        self.assertEqual([(line, line) for line in range(2, 82, 2)], spans)
        batch.assert_called_once()
        self.assertEqual(batch.call_args.args[0][-2:], ["0", "--all-spans"])

    def test_changed_closing_brace_does_not_include_adjacent_method(self):
        source_text = (
            "final class Adjacent {\n"
            "    static int first() {\n"
            "        return 1;\n"
            "    }\n"
            "    static int next() {\n"
            "        return 2;\n"
            "    }\n"
            "}\n"
        )
        diff = (
            "diff --git a/Adjacent.java b/Adjacent.java\n"
            "--- a/Adjacent.java\n+++ b/Adjacent.java\n"
            "@@ -4 +4 @@\n-    } // old formatting\n+    }\n"
        )
        with tempfile.TemporaryDirectory(prefix="method-sidecar-adjacent-") as directory:
            root = Path(directory)
            (root / "Adjacent.java").write_text(source_text, encoding="utf-8")
            spans = MODULE.method_spans(root, "Adjacent.java", [4])
            sidecar = MODULE.build_sidecar(root, diff)
        self.assertEqual(spans, [(2, 4)])
        self.assertIn("static int first()", sidecar)
        self.assertNotIn("static int next()", sidecar)

    def test_tracks_multiple_hunks_and_treats_triple_plus_source_as_code(self):
        diff = (
            "diff --git a/A.java b/A.java\n"
            "--- a/A.java\n+++ b/A.java\n"
            "@@ -10,2 +10,3 @@\n"
            '     String example = """\n'
            "+++ b/not-a-file.java\n"
            '     """;\n'
            "@@ -20 +21 @@\n-old();\n+newCall();\n"
            "+not-hunk-content\n"
            "diff --git a/B.java b/B.java\n"
            "--- /dev/null\n+++ b/B.java\n"
            "@@ -0,0 +1 @@\n+final class B {}\n"
        )
        self.assertEqual(MODULE.added_lines_by_path(diff), {"A.java": [11, 21], "B.java": [1]})

    def test_ignores_deletion_only_hunk_and_restarts_next_hunk_cursor(self):
        diff = (
            "diff --git a/A.java b/A.java\n"
            "--- a/A.java\n+++ b/A.java\n"
            "@@ -4,2 +3,0 @@\n-oldOne();\n-oldTwo();\n"
            "@@ -9 +7 @@\n-before();\n+after();\n"
            "\\ No newline at end of file\n"
        )
        self.assertEqual(MODULE.added_lines_by_path(diff), {"A.java": [7]})

    def test_omits_whole_method_when_method_budget_is_too_small(self):
        with tempfile.TemporaryDirectory(prefix="method-sidecar-budget-") as directory:
            root = Path(directory)
            source = root / "src/main/java/testcases/Guard.java"
            source.parent.mkdir(parents=True)
            source.write_text(SOURCE, encoding="utf-8")
            sidecar = MODULE.build_sidecar(root, DIFF, max_bytes=6000, max_method_bytes=8)
        self.assertEqual(sidecar, "")

    def test_rejects_symlinked_source(self):
        with tempfile.TemporaryDirectory(prefix="method-sidecar-link-") as directory:
            root = Path(directory)
            real = root / "real/Guard.java"
            real.parent.mkdir(parents=True)
            real.write_text(SOURCE, encoding="utf-8")
            link = root / "src/main/java/testcases/Guard.java"
            link.parent.mkdir(parents=True)
            link.symlink_to(real)
            self.assertEqual(MODULE.build_sidecar(root, DIFF), "")

    def test_rejects_symlinked_parent_directory(self):
        with tempfile.TemporaryDirectory(prefix="method-sidecar-directory-link-") as directory:
            root = Path(directory) / "repo"
            external = Path(directory) / "external"
            root.mkdir()
            external.mkdir()
            (external / "Guard.java").write_text(SOURCE, encoding="utf-8")
            (root / "src").symlink_to(external, target_is_directory=True)
            diff = DIFF.replace("src/main/java/testcases/Guard.java", "src/Guard.java")
            with patch.object(MODULE.subprocess, "check_output") as batch:
                self.assertEqual(MODULE.build_sidecar(root, diff), "")
            batch.assert_not_called()

    def test_rejects_absolute_parent_traversal_and_control_character_paths(self):
        with tempfile.TemporaryDirectory(prefix="method-sidecar-paths-") as directory:
            root = Path(directory) / "repo"
            root.mkdir()
            external = Path(directory) / "Outside.java"
            external.write_text(SOURCE, encoding="utf-8")
            for relative in (str(external), "../Outside.java", "nested/../../Outside.java", "bad\x00.java", "bad\n.java", "bad\r.java"):
                with self.subTest(relative=repr(relative)):
                    self.assertIsNone(MODULE.safe_repo_path(root, relative))

    def test_total_utf8_budget_includes_wrapper_and_keeps_a_fitting_method(self):
        relative = "Guard.java"
        source_text = NEW_FILE_SOURCE.replace("return new Object();", 'return "审计证据";')
        diff = new_file_diff(relative, source_text)
        first_section = "文件: Guard.java:4-6\n" + "".join(source_text.splitlines(keepends=True)[3:6])
        expected = MODULE.SIDECAR_PREFIX + first_section + MODULE.SIDECAR_SUFFIX
        exact_budget = len(expected.encode("utf-8"))
        self.assertGreater(exact_budget, len(expected))
        with tempfile.TemporaryDirectory(prefix="method-sidecar-total-budget-") as directory:
            root = Path(directory)
            (root / relative).write_text(source_text, encoding="utf-8")
            sidecar = MODULE.build_sidecar(root, diff, max_bytes=exact_budget)
            one_byte_short = MODULE.build_sidecar(root, diff, max_bytes=exact_budget - 1)
        self.assertEqual(sidecar, expected)
        self.assertEqual(len(sidecar.encode("utf-8")), exact_budget)
        self.assertNotIn("static Object target", sidecar)
        self.assertNotIn("static Object next", sidecar)
        self.assertEqual(one_byte_short, "")

    def test_large_method_does_not_consume_method_count_budget(self):
        source_text = (
            "final class Sized {\n"
            "    static String large() {\n"
            f'        return "{"x" * 300}";\n'
            "    }\n"
            "    static int small() {\n"
            "        return 1;\n"
            "    }\n"
            "    static int next() {\n"
            "        return 2;\n"
            "    }\n"
            "}\n"
        )
        with tempfile.TemporaryDirectory(prefix="method-sidecar-method-count-") as directory:
            root = Path(directory)
            (root / "Sized.java").write_text(source_text, encoding="utf-8")
            sidecar = MODULE.build_sidecar(
                root, new_file_diff("Sized.java", source_text), max_method_bytes=150, max_methods=1
            )
        self.assertNotIn("static String large", sidecar)
        self.assertIn("static int small", sidecar)
        self.assertNotIn("static int next", sidecar)
        self.assertEqual(sidecar.count("文件: Sized.java:"), 1)

    def test_terminates_method_section_when_source_has_no_final_newline(self):
        # The method itself closes on the physical EOF line. Removing only
        # the class's trailing newline would leave the method newline intact.
        source_text = "final class End {\n    static int last() {\n        return 1;\n    } }"
        self.assertFalse(source_text.endswith("\n"))
        with tempfile.TemporaryDirectory(prefix="method-sidecar-no-newline-") as directory:
            root = Path(directory)
            (root / "End.java").write_text(source_text, encoding="utf-8")
            self.assertEqual(MODULE.method_spans(root, "End.java", [3]), [(2, 4)])
            sidecar = MODULE.build_sidecar(root, new_file_diff("End.java", source_text))
        self.assertIn("文件: End.java:2-4\n", sidecar)
        self.assertTrue(sidecar.endswith("    } }\n" + MODULE.SIDECAR_SUFFIX))


if __name__ == "__main__":
    unittest.main()
