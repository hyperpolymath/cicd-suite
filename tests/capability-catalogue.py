#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Catalogue inventory, generation, navigation and negative-control tests."""
import copy
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("atlas", ROOT / "scripts/build-capability-catalogue.py")
atlas = importlib.util.module_from_spec(spec)
spec.loader.exec_module(atlas)


class CatalogueTests(unittest.TestCase):
    def setUp(self):
        self.data = json.loads((ROOT / "catalogue/capabilities.json").read_text())

    def test_complete_inventory(self):
        atlas.validate(self.data)
        self.assertEqual(len(self.data["capabilities"]), len(list((ROOT / "actions").glob("*/action.yml"))))

    def test_readme_counts_and_catalogue_entrypoint(self):
        readme = (ROOT / "README.adoc").read_text()
        self.assertIn("link:CATALOGUE.adoc[", readme)
        pattern = rf"\*{len(self.data['capabilities'])} composite actions\s+in {len(self.data['clades'])} clades\*"
        self.assertRegex(readme, pattern)

    def test_negative_controls(self):
        def dropped(d):
            d["capabilities"].pop()

        def duplicate(d):
            d["capabilities"].append(copy.deepcopy(d["capabilities"][0]))

        def unknown_clade(d):
            d["capabilities"][0]["clade"] = "imaginary"

        def unknown_status(d):
            d["capabilities"][0]["status"] = "certified-perfect"

        def unknown_nature(d):
            d["capabilities"][0]["nature"] = "magic"

        def escaped_path(d):
            d["capabilities"][0]["workflow"] = "../outside.yml"

        def missing_target(d):
            d["capabilities"][0]["workflow"] = ".github/workflows/absent.yml"

        def misleading_stub(d):
            next(e for e in d["capabilities"] if e["status"] == "stub")["status"] = "enforcing"

        def empty_boundary(d):
            d["capabilities"][0]["limitations"] = " "

        def future_schema(d):
            d["schema_version"] = 99

        def empty_clade(d):
            d["clades"].append(dict(id="empty", title="Empty", summary="No entries"))

        for mutant in (dropped, duplicate, unknown_clade, unknown_status,
                       unknown_nature, escaped_path, missing_target, misleading_stub,
                       empty_boundary, future_schema, empty_clade):
            with self.subTest(mutant=mutant.__name__):
                data = copy.deepcopy(self.data)
                mutant(data)
                with self.assertRaises(ValueError):
                    atlas.validate(data)

    def stage_targets(self, root):
        for entry in self.data["capabilities"]:
            for field in ("path", "workflow", "template"):
                if field in entry:
                    target = root / entry[field]
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.touch()

    def test_uncatalogued_new_action_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.stage_targets(root)
            atlas.validate(self.data, root)
            extra = root / "actions/uncatalogued-check/action.yml"
            extra.parent.mkdir()
            extra.touch()
            with self.assertRaisesRegex(ValueError, "inventory drift"):
                atlas.validate(self.data, root)

    def test_symlink_escape_rejected(self):
        with tempfile.TemporaryDirectory() as tmp, tempfile.TemporaryDirectory() as outside:
            root = Path(tmp)
            self.stage_targets(root)
            target = root / self.data["capabilities"][0]["path"]
            target.unlink()
            external = Path(outside) / "action.yml"
            external.touch()
            target.symlink_to(external)
            with self.assertRaisesRegex(ValueError, "escaping"):
                atlas.validate(self.data, root)

    def test_generation_deterministic_and_links_resolve(self):
        pages = atlas.render(self.data)
        self.assertEqual(pages, atlas.render(copy.deepcopy(self.data)))
        for page, text in pages.items():
            for target in re.findall(r"link:([^\[]+)\[", text):
                with self.subTest(page=page, target=target):
                    self.assertTrue((ROOT / page).parent.joinpath(target).is_file())
        anchors = set(re.findall(r"\[\[([^\]]+)\]\]", pages["CATALOGUE.adoc"]))
        for target in re.findall(r"<<([^,>]+),", pages["CATALOGUE.adoc"]):
            self.assertIn(target, anchors)

    def test_stale_page_rejected_by_cli(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.stage_targets(root)
            inventory = root / "catalogue/capabilities.json"
            inventory.parent.mkdir(parents=True, exist_ok=True)
            inventory.write_text(json.dumps(self.data))
            for name, text in atlas.render(self.data).items():
                page = root / name
                page.parent.mkdir(parents=True, exist_ok=True)
                page.write_text(text)
            (root / "CATALOGUE.adoc").write_text("stale content")
            with mock.patch.object(atlas, "ROOT", root), mock.patch.object(sys, "argv", ["catalogue", "--check"]):
                with self.assertRaises(SystemExit) as result:
                    atlas.main()
                self.assertEqual(result.exception.code, 1)

    def test_committed_pages_current(self):
        subprocess.run([sys.executable, str(ROOT / "scripts/build-capability-catalogue.py"), "--check"], check=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
