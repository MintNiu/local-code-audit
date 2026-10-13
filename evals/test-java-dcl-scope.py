#!/usr/bin/env python3
"""Fast structural regressions for the deliberately narrow Java DCL check."""

from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]


def load_module(name: str, filename: str):
    spec = spec_from_file_location(name, REPO_ROOT / "bin" / filename)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load {filename}")
    module = module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


dcl_scope = load_module("java_dcl_scope", "java-dcl-scope.py")
java_window = load_module("java_method_window", "java-method-window.py")


class DclStructureTest(unittest.TestCase):
    def assert_dcl(self, source: str, expected: bool, field: str = "value"):
        # The production contract receives already masked code. Preserve
        # whitespace and offsets exactly as the method-window caller does.
        masked = java_window.mask_non_code(source)
        self.assertIs(dcl_scope.has_dcl(masked, field), expected)

    def test_exact_window_excludes_neighbor_tokens(self):
        source = """
            class Guard {
                private static Object value = null;
                static void previous() {} static Object get() {
                    if (value == null) {
                        synchronized (Guard.class) {
                            if (value == null) { value = new Object(); }
                        }
                    }
                    return value;
                } static void next() {}
            }
        """
        target = next(index for index, line in enumerate(source.splitlines(), 1)
                      if "value = new Object" in line)
        with tempfile.TemporaryDirectory(prefix="dcl-window-") as directory:
            fixture = Path(directory) / "Guard.java"
            fixture.write_text(source, encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(REPO_ROOT / "bin/java-method-window.py"),
                 str(fixture), str(target), "--masked-exact"],
                capture_output=True, text=True, check=True,
            )
        self.assertNotIn("previous", result.stdout)
        self.assertNotIn("next", result.stdout)
        self.assertNotIn("private static", result.stdout)
        self.assertTrue(dcl_scope.has_dcl(result.stdout, "value"))

    def test_recognizes_equivalent_layouts(self):
        methods = {
            "single_line": """
                static Object get() { if (value == null) { synchronized (Guard.class) { if (value == null) { value = new Object(); } } } return value; }
            """,
            "allman_braces": """
                static Object get()
                {
                    if (value == null)
                    {
                        synchronized (Guard.class)
                        {
                            if (value == null)
                            {
                                value = new Object();
                            }
                        }
                    }
                    return value;
                }
            """,
            "multiline_conditions": """
                static Object get() {
                    if (
                        value
                        == null
                    ) {
                        synchronized (
                            Guard.class
                        ) {
                            if (
                                value ==
                                null
                            ) {
                                value =
                                    new Object();
                            }
                        }
                    }
                    return value;
                }
            """,
            "reversed_null_comparison": """
                static Object get() {
                    if (null == value) {
                        synchronized (Guard.class) {
                            if (null == value) { value = new Object(); }
                        }
                    }
                    return value;
                }
            """,
            "ordinary_argument_is_not_parameter_shadowing": """
                static Object get() {
                    if (value == null) {
                        synchronized (Guard.class) {
                            if (value == null) {
                                audit(value);
                                value = new Object();
                            }
                        }
                    }
                    return value;
                }
            """,
            "comments_and_literals_do_not_change_structure": '''
                static Object get() {
                    String label = "} synchronized (fake) { value = new Object();";
                    /* synchronized (fake) { if (value == null) { */
                    if (value == null) {
                        synchronized (Guard.class) {
                            if (value == null) { value = new Object(); }
                        }
                    }
                    // } } } value = new Object();
                    return value;
                }
            ''',
        }
        for name, method in methods.items():
            with self.subTest(name=name):
                self.assert_dcl(method, True)

    def test_annotations_and_unrelated_arrows_preserve_detection(self):
        template = """
            class Guard {
                private static Object value = null;
                %s
                static Object get(%s) {
                    if (value == null) {
                        synchronized (Guard.class) {
                            if (value == null) { value = new Object(); }
                        }
                    }
                    %s
                    return value;
                }
            }
        """
        variants = {
            "annotation_array": ('@Labels({"a", "b"})', "", ""),
            "annotation_value_attribute": ('@SuppressWarnings(value="unused")', "", ""),
            "parameter_annotation_attribute": ("", '@Label(value="other") int id', ""),
            "unrelated_lambda": ("", "", 'Runnable deferred = () -> { audit(); };'),
            "switch_arrow": ("", "int state", 'switch (state) { case 1 -> audit(); default -> audit(); }'),
        }
        with tempfile.TemporaryDirectory(prefix="dcl-annotations-") as directory:
            fixture = Path(directory) / "Guard.java"
            for name, values in variants.items():
                with self.subTest(name=name):
                    source = template % values
                    target = next(index for index, line in enumerate(source.splitlines(), 1)
                                  if "value = new Object" in line)
                    fixture.write_text(source, encoding="utf-8")
                    result = subprocess.run(
                        [sys.executable, str(REPO_ROOT / "bin/java-method-window.py"),
                         str(fixture), str(target), "--masked-exact"],
                        capture_output=True, text=True, check=True,
                    )
                    self.assertTrue(dcl_scope.has_dcl(result.stdout, "value"), result.stdout)

    def test_does_not_join_unrelated_blocks(self):
        methods = {
            "adjacent_synchronized_blocks": """
                static Object get() {
                    if (value == null) {
                        synchronized (Guard.class) {
                            if (value == null) { audit(); }
                        }
                        synchronized (Guard.class) { value = new Object(); }
                    }
                    return value;
                }
            """,
            "assignment_after_inner_if": """
                static Object get() {
                    if (value == null) {
                        synchronized (Guard.class) {
                            if (value == null) { audit(); }
                            value = new Object();
                        }
                    }
                    return value;
                }
            """,
            "assignment_in_inner_else": """
                static Object get() {
                    if (value == null) {
                        synchronized (Guard.class) {
                            if (value == null) { audit(); }
                            else { value = new Object(); }
                        }
                    }
                    return value;
                }
            """,
            "outer_if_already_closed": """
                static Object get() {
                    if (value == null) { audit(); }
                    synchronized (Guard.class) {
                        if (value == null) { value = new Object(); }
                    }
                    return value;
                }
            """,
            "lock_in_outer_else": """
                static Object get() {
                    if (value == null) { audit(); }
                    else {
                        synchronized (Guard.class) {
                            if (value == null) { value = new Object(); }
                        }
                    }
                    return value;
                }
            """,
            "different_inner_field": """
                static Object get() {
                    if (value == null) {
                        synchronized (Guard.class) {
                            if (other == null) { value = new Object(); }
                        }
                    }
                    return value;
                }
            """,
            "different_assignment_receiver": """
                static Object get() {
                    if (value == null) {
                        synchronized (Guard.class) {
                            if (value == null) { other.value = new Object(); }
                        }
                    }
                    return value;
                }
            """,
            "outer_already_inside_lock": """
                static Object get() {
                    synchronized (Guard.class) {
                        if (value == null) {
                            synchronized (Guard.class) {
                                if (value == null) { value = new Object(); }
                            }
                        }
                    }
                    return value;
                }
            """,
        }
        for name, method in methods.items():
            with self.subTest(name=name):
                self.assert_dcl(method, False)

    def test_rejects_deferred_execution_and_shadowing(self):
        bodies = {
            "lambda_assignment": "Runnable init = () -> { value = new Object(); };",
            "anonymous_class_assignment": """
                Runnable init = new Runnable() {
                    public void run() { value = new Object(); }
                };
            """,
            "local_class_assignment": """
                class Init { void run() { value = new Object(); } }
            """,
        }
        for name, body in bodies.items():
            with self.subTest(name=name):
                self.assert_dcl("""
                    static Object get() {
                        if (value == null) {
                            synchronized (Guard.class) {
                                if (value == null) { %s }
                            }
                        }
                        return value;
                    }
                """ % body, False)

        headers_and_prefixes = {
            "parameter": ("static Object get(Object value)", ""),
            "multiline_parameter": ("static Object get(\n final Object value\n)", ""),
            "local_variable": ("static Object get()", "Object value = null;"),
            "local_variable_without_initializer": ("static Object get()", "Object value; value = null;"),
            "synchronized_method": ("static synchronized Object get()", ""),
            "multiline_synchronized_method": ("synchronized\n static Object get()", ""),
        }
        for name, (header, prefix) in headers_and_prefixes.items():
            with self.subTest(name=name):
                self.assert_dcl("""
                    %s {
                        %s
                        if (value == null) {
                            synchronized (Guard.class) {
                                if (value == null) { value = new Object(); }
                            }
                        }
                        return value;
                    }
                """ % (header, prefix), False)

    def test_requires_direct_new_assignment(self):
        assignments = {
            "no_assignment": "audit();",
            "factory_call": "value = create();",
            "plain_alias": "value = existing;",
            "literal_rhs": 'value = "new Object()";',
            "assignment_only_in_comment": "/* value = new Object(); */",
        }
        for name, assignment in assignments.items():
            with self.subTest(name=name):
                self.assert_dcl("""
                    static Object get() {
                        if (value == null) {
                            synchronized (Guard.class) {
                                if (value == null) { %s }
                            }
                        }
                        return value;
                    }
                """ % assignment, False)

    def test_unsupported_or_incomplete_syntax_produces_no_finding(self):
        for method in (
            "",
            "static Object get() { if (value == null) {",
            "static Object get() { if (value == null) synchronized (Guard.class) { if (value == null) value = new Object(); } return value; }",
        ):
            with self.subTest(method=method):
                self.assert_dcl(method, False)


if __name__ == "__main__":
    unittest.main()
