import importlib.util
import json
import unittest
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('format_parity', ROOT / 'scripts/format-parity.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class FormatParityTests(unittest.TestCase):
    def test_pinned_historical_reference_is_intact(self):
        data = json.loads((ROOT / 'scripts/tests/fixtures/reference-parity.json').read_text())
        self.assertEqual(len(data['definitions']), 266)
        self.assertEqual(len(data['revision']), 40)
        self.assertEqual(len(data['sha256']), 64)
        self.assertIn(data['revision'], data['source'])
        for row in data['definitions']:
            self.assertTrue(row['reason'])
        self.assertEqual({x['formatID'] for x in data['markdownReference']['definitions']},
                         {'markdown', 'rmarkdown', 'quarto', 'mdx', 'mdc', 'apib', 'mermaid', 'textbundle'})
        self.assertIn('Reference format definitions: 266', module.report())

    def test_masterlist_is_one_sorted_table_that_passes_check(self):
        document = (ROOT / 'docs/formats/README.md').read_text()
        self.assertEqual(module.check(document), [])
        self.assertEqual(sorted(p.name for p in (ROOT / 'docs/formats').glob('*.md')), ['README.md'])
        self.assertFalse((ROOT / 'scripts/tests/fixtures/format-masterlist.json').exists())
        _, rows = module.parse_masterlist(document)
        self.assertGreater(len(rows), 300)
        self.assertEqual(module.enrich(document), document)

    def test_new_unimplemented_row_survives_repeated_enrich_and_check(self):
        document = (ROOT / 'docs/formats/README.md').read_text()
        row = '| Zz Glimt Probe | `.zzglimt`, `ZZFILE` | Invented format not implemented yet | Missing | — | |'
        added = self._insert_row(document, row)
        once = module.enrich(added)
        twice = module.enrich(once)
        self.assertIn('\n' + row + '\n', twice)
        self.assertEqual(once, twice)
        self.assertEqual(module.check(twice), [])
        self.assertEqual(self._without_summary(twice).replace(row + '\n', ''), self._without_summary(document))

    def test_enrich_only_rewrites_derived_status_cell(self):
        document = (ROOT / 'docs/formats/README.md').read_text()
        line = next(l for l in document.split('\n') if l.startswith('| Swift | '))
        stale = line.replace('| Supported |', '| Missing |')
        self.assertNotEqual(stale, line)
        broken = document.replace(line, stale)
        self.assertIn('Derived Status or summary is stale; run --enrich', module.check(broken))
        self.assertEqual(module.enrich(broken), document)

    def test_manual_status_and_implemented_extensions_are_respected(self):
        document = (ROOT / 'docs/formats/README.md').read_text()
        manual = '| Zz Manual | `.swift` | Manually assessed format | Partial | — | Manual status: test. |'
        derived = '| Zz Routed | `.swift` | Derived format | Missing | — | |'
        enriched = module.enrich(self._insert_row(self._insert_row(document, manual), derived))
        self.assertIn('\n' + manual + '\n', enriched)
        self.assertIn('| Zz Routed | `.swift` | Derived format | Partial |', enriched)

    def test_explain_reports_inspector_and_routing(self):
        catalog = module.load('InspectorCore/Sources/InspectorCore/Resources/formats.json')
        _, rows = module.parse_masterlist((ROOT / 'docs/formats/README.md').read_text())
        swift = next(row for row in rows if row['format'] == 'Swift')
        status, kinds, explanation = module.derive(swift, catalog)
        self.assertEqual((status, kinds), ('Supported', ['source']))
        self.assertIn("own=['.swift']", explanation)

    def test_native_mermaid_renderer_counts_as_specialist_presentation(self):
        catalog = module.load('InspectorCore/Sources/InspectorCore/Resources/formats.json')
        _, rows = module.parse_masterlist((ROOT / 'docs/formats/README.md').read_text())
        mermaid = next(row for row in rows if row['format'] == 'Mermaid source')
        status, kinds, explanation = module.derive(mermaid, catalog)
        self.assertEqual(status, 'Supported')
        self.assertEqual(kinds, ['text'])
        self.assertIn("own=['.mmd', '.mermaid']", explanation)

    def test_implemented_rows_still_require_their_showcase(self):
        document = (ROOT / 'docs/formats/README.md').read_text()
        line = next(l for l in document.split('\n') if l.startswith('| Swift | '))
        cells = line.split(' | ')
        cells[4] = '—'
        problems = module.check(document.replace(line, ' | '.join(cells)))
        self.assertIn('Showcase Showcase/source/swift.swift is not linked from a row for swift', problems)

    def test_reference_parity_does_not_drive_masterlist(self):
        document = (ROOT / 'docs/formats/README.md').read_text()
        load = module.load

        def catalog_only(relative):
            self.assertNotIn('reference-parity', relative)
            return load(relative)

        with mock.patch.object(module, 'load', side_effect=catalog_only):
            self.assertEqual(module.check(document), [])
            self.assertEqual(module.enrich(document), document)

    def test_check_rejects_unsorted_duplicate_and_missing_fixture_rows(self):
        document = (ROOT / 'docs/formats/README.md').read_text()
        row = '| Swift | `.zz` | Duplicate | Missing | [x](../../Fixtures/missing.zz) | |'
        problems = module.check(document.replace('| Swift | ', row + '\n| Swift | ', 1))
        self.assertIn('Duplicate format: swift', problems)
        self.assertIn('Swift: fixture not found ../../Fixtures/missing.zz', problems)
        line = next(l for l in document.split('\n') if l.startswith('| ABAP/4 | '))
        self.assertIn('Rows are not sorted alphabetically by Format', module.check(document.replace(line + '\n', '') + line + '\n'))

    @staticmethod
    def _insert_row(document, row):
        lines = document.split('\n')
        name = row.split('|')[1].strip().casefold()
        index = lines.index('| ' + ' | '.join(module.COLUMNS) + ' |') + 2
        while lines[index].startswith('|') and lines[index].split('|')[1].strip().casefold() < name:
            index += 1
        lines.insert(index, row)
        return '\n'.join(lines)

    @staticmethod
    def _without_summary(document):
        start, end = document.index(module.SUMMARY_START), document.index(module.SUMMARY_END)
        return document[:start] + document[end:]

    def test_every_shipped_showcase_is_catalogued_and_cases_are_separate(self):
        rows = json.loads((ROOT / 'InspectorCore/Sources/InspectorCore/Resources/formats.json').read_text())
        paths = set()
        for row in rows:
            if row['status'] != 'supported':
                self.assertIsNone(row['showcaseFixture'])
                continue
            paths.add(row['showcaseFixture'])
            paths.update(v['path'] for v in row.get('showcaseVariants', []))
        actual = set()
        for path in (ROOT / 'Fixtures/Showcase').rglob('*'):
            relative = path.relative_to(ROOT / 'Fixtures').as_posix()
            if path.name.endswith('.textbundle') and path.is_dir():
                actual.add(relative)
            elif path.is_file() and path.name != ".DS_Store" and not path.name.startswith("._"):
                if not any(parent.suffix == '.textbundle' for parent in path.parents):
                    actual.add(relative)
        self.assertEqual(paths, actual)
        self.assertTrue((ROOT / 'Fixtures/Cases/json/invalid/malformed.json').is_file())
        project = (ROOT / 'Glimt.xcodeproj/project.pbxproj').read_text()
        self.assertIn('lastKnownFileType = folder; path = Showcase;', project)
        self.assertNotIn('path = Cases', project)

if __name__ == '__main__':
    unittest.main()
