"""Compare Java name scoring with the original Python algorithm in a disposable instance."""
import difflib
import json
import os
import random
import subprocess
import unittest
import unicodedata


@unittest.skipUnless(os.environ.get("PI_JAVA_PEX_CONTAINER"), "Requires an isolated Java PEX container")
class JavaNameParity(unittest.TestCase):
    def test_unicode_sequence_parity(self):
        """Pin normalization, tie breaking, repeated runs and supplementary character semantics."""
        pairs = [("Anna", "Ana"), ("tide", "diet"), ("diet", "tide"),
                 ("Straße", "STRASSE"), ("ΟΣ ς", "οσ σ"), ("İ", "i\u0307"),
                 ("ＡＮＮＡ", "anna"), ("é", "e\u0301"), ("张三", "张 三"),
                 ("\x1c\u00a0A  B\u0085", "a b"), ("", "Anna"),
                 ("😀A😀", "😀a"), ("a" * 500, "a" * 499 + "b")]
        rng = random.Random(154)
        alphabet = "abcaΣςßİé😀张 \tＡ"
        for _ in range(600):
            pairs.append(tuple("".join(rng.choice(alphabet) for _ in range(rng.randrange(0, 45))) for j in range(2)))
        expected = []
        for left, right in pairs:
            a = " ".join(unicodedata.normalize("NFKC", left).casefold().split())
            b = " ".join(unicodedata.normalize("NFKC", right).casefold().split())
            expected.append((bool(a and b), difflib.SequenceMatcher(None, a, b, autojunk=False).ratio() if a and b else 0))
        result = self.run_java([{"left": a, "right": b} for a, b in pairs])
        self.assertEqual(len(result), len(pairs))
        for pair, wanted, actual in zip(pairs, expected, result):
            self.assertEqual(actual.get("comparable"), wanted[0], pair)
            self.assertAlmostEqual(actual.get("score"), wanted[1], places=14, msg=str(pair))
            self.assertEqual(actual["implementation"], "java")
            self.assertEqual(actual["algorithmVersion"], "name-v1")

    def test_invalid_and_codepoint_limits(self):
        """Require strict string fields, codepoint bounds, stable errors and no private input echo."""
        rows = self.run_java([{"left": "😀" * 500, "right": "😀" * 500},
                              {"left": "😀" * 501, "right": "a"},
                              {"left": 1, "right": "private sentinel"}, [], {},
                              {"left": None, "right": "a"}, {"left": "a", "right": True}])
        self.assertEqual(rows[0]["score"], 1)
        self.assertEqual(rows[1], {"code": "FIELD_TOO_LONG"})
        for row in rows[2:]:
            self.assertEqual(row, {"code": "INVALID_NAME_INPUT"})

    def run_java(self, rows):
        """Exercise the production Java parser and scorer without substituting a test implementation."""
        container = os.environ["PI_JAVA_PEX_CONTAINER"]
        if not container.startswith("pi-java-pex-"):
            raise RuntimeError("ISOLATED_CONTAINER_REQUIRED")
        result = subprocess.run(["docker", "exec", "-i", container, "java", "-cp",
            "/tmp/pi-java-pex/pi-name-pex.jar:/tmp/pi-java-pex/lib/*:/usr/irissys/dev/java/lib/1.8/*",
            "org.pireview.pex.NameSimilarityOperation"],
            input="".join(json.dumps(x, ensure_ascii=False) + "\n" for x in rows),
            text=True, capture_output=True, timeout=45)
        self.assertEqual(result.returncode, 0, result.stderr)
        return [json.loads(x) for x in result.stdout.splitlines()]


if __name__ == "__main__":
    unittest.main()
