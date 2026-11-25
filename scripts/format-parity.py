#!/usr/bin/env python3
"""Report parity links and verify or enrich the manually maintained format masterlist.

docs/formats/README.md owns the format register. Every column except Status is manual. Status is
derived from the catalog (formats.json) unless the Comment cell contains "Manual status".
reference-parity.json is historical evidence only; it never affects the masterlist or its statuses.

  python3 scripts/format-parity.py            parity report
  python3 scripts/format-parity.py --check    verify the masterlist; exit 1 on problems
  python3 scripts/format-parity.py --enrich   rewrite only derived Status cells and the summary block
  python3 scripts/format-parity.py --explain  print status, inspectors and routing behind every row
"""
import collections
import json
import re
import sys
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'Fixtures'
MASTERLIST = ROOT / 'docs/formats/README.md'
MASTERLIST_STATUSES = ('Supported', 'Partial', 'Recognized (Raw)', 'Missing', 'Excluded')
COLUMNS = ('Format', 'Extensions', 'Description', 'Status', 'Fixtures', 'Comment')
STATUS_COLUMN = COLUMNS.index('Status')
MANUAL_STATUS = 'Manual status'
SUMMARY_START = '<!-- derived: summary -->'
SUMMARY_END = '<!-- /derived -->'


def load(relative):
    return json.loads((ROOT / relative).read_text())


def report():
    catalog = load('InspectorCore/Sources/InspectorCore/Resources/formats.json')
    matrix = load('scripts/tests/fixtures/reference-parity.json')
    definitions = matrix['definitions']
    ids = {row['id'] for row in catalog}
    assert len(ids) == len(catalog), 'Duplicate FormatID'
    assert len({row['reference'] for row in definitions}) == len(definitions), 'Duplicate reference'
    allowed = {'SUPPORTED', 'PLANNED', 'REPLACED_BY_BETTER_GLIMT_INSPECTOR', 'EXCLUDED_WITH_REASON'}
    for row in definitions:
        assert row['status'] in allowed and row['reason']
        assert set(row['formatIDs']) <= ids, row['reference']
    for row in catalog:
        if row['status'] == 'supported':
            path = row['showcaseFixture']
            assert path.startswith('Showcase/') and '..' not in path
            fixture = FIXTURES / path
            assert fixture.is_file() or fixture.is_dir(), path
    counts = collections.Counter(row['status'] for row in definitions)
    linked = {id for row in definitions for id in row['formatIDs']}
    linked.update(matrix['markdownReference']['formatIDs'])
    additional = [row for row in catalog if row['id'] not in linked]
    lines = [f"Reference format definitions: {len(definitions)}",
             f"Complete reference parity: {counts['SUPPORTED'] + counts['REPLACED_BY_BETTER_GLIMT_INSPECTOR']}",
             f"  Source/text: {counts['SUPPORTED']}",
             f"  Replaced by semantic inspector: {counts['REPLACED_BY_BETTER_GLIMT_INSPECTOR']}",
             f"Planned reference definitions: {counts['PLANNED']}",
             f"Explicit exclusions: {counts['EXCLUDED_WITH_REASON']}",
             f"Glimt product formats supported: {sum(row['status'] == 'supported' for row in catalog)}",
             f"Glimt-specific additional targets: {len(additional)} (supported: {sum(row['status'] == 'supported' for row in additional)})"]
    return '\n'.join(lines)


# MARK: - Masterlist parsing


def _split_cells(line):
    """Split a table line into raw cells, keeping each cell's original text and spacing."""
    return re.split(r'(?<!\\)\|', line.strip())[1:-1]


def parse_masterlist(text):
    """Return (lines, rows) where each row knows its line index and stripped cell values."""
    lines = text.split('\n')
    header = '| ' + ' | '.join(COLUMNS) + ' |'
    starts = [i for i, line in enumerate(lines) if line.strip() == header]
    if len(starts) != 1:
        raise ValueError(f'Expected exactly one masterlist table, found {len(starts)}')
    rows = []
    index = starts[0] + 2
    while index < len(lines) and lines[index].startswith('|'):
        cells = [cell.strip() for cell in _split_cells(lines[index])]
        rows.append({'line': index, 'cells': cells, **_interpret(cells)})
        index += 1
    return lines, rows


def _interpret(cells):
    if len(cells) != len(COLUMNS):
        return {'format': cells[0] if cells else '', 'invalid': f'{len(cells)} cells'}
    name, names, _, status, fixtures, comment = cells
    katalog = re.search(r'Catalog: ((?:`[^`]+`(?:, )?)+)', comment)
    return {
        'format': name,
        'names': [token.lower() for token in re.findall(r'`([^`]+)`', names)],
        'status': status,
        'fixtures': [unquote(path) for path in re.findall(r'\]\(([^)]+)\)', fixtures)],
        'formatIDs': re.findall(r'`([^`]+)`', katalog.group(1)) if katalog else [],
        'manual': MANUAL_STATUS in comment,
        'comment': comment,
    }

# MARK: - Derived status


def _routes(catalog):
    routes = collections.defaultdict(list)
    for row in catalog:
        if row['status'] != 'supported':
            continue
        for extension in row['extensions']:
            routes['.' + extension.lower()].append(row['id'])
        for filename in row['exactFilenames']:
            routes[filename.lower()].append(row['id'])
    return routes


def derive(row, catalog):
    """Derive (status, inspection kinds, routing explanation) from catalog routing, or None for manual rows."""
    if row['manual'] or not (row['names'] or row['formatIDs']):
        return None
    by_id = {entry['id']: entry for entry in catalog}
    routes = _routes(catalog)
    own = [id for id in row['formatIDs'] if id in by_id and by_id[id]['status'] == 'supported']
    # A text-backed format may still have a dedicated native presentation, such as the
    # MermaidKit renderer for Mermaid source. Count that as specialist support for this register.
    semantic = lambda ids: [id for id in ids if by_id[id]['inspectionKind'] != 'text'
                            or 'rendered' in by_id[id].get('representations', [])]
    native, foreign, raw, unrouted, providers = [], [], [], [], []
    for name in row['names']:
        ids = routes.get(name, [])
        hit = [id for id in ids if id in own]
        if hit:
            (native if semantic(hit) else raw).append(name)
            providers += hit
        elif semantic(ids):
            foreign.append(f'{name}→{",".join(dict.fromkeys(semantic(ids)))}')
            providers += semantic(ids)
        elif ids:
            raw.append(name)
            providers += ids
        else:
            unrouted.append(name)
    if not row['names']:
        native, raw, providers = semantic(own), [id for id in own if id not in semantic(own)], own
    if native and not (foreign or raw or unrouted):
        status = 'Supported'
    elif native or foreign:
        status = 'Partial'
    elif raw:
        status = 'Recognized (Raw)'
    else:
        status = 'Missing'
    kinds = sorted({by_id[id]['inspectionKind'] for id in providers})
    explanation = f'own={native} via-other={foreign} raw={raw} unrouted={unrouted}'
    return status, kinds, explanation


# MARK: - Check and enrich


def _summary(rows):
    counts = collections.Counter(row['status'] for row in rows)
    return [SUMMARY_START,
            '| Rows | ' + ' | '.join(MASTERLIST_STATUSES) + ' |',
            '|---|' + '---|' * len(MASTERLIST_STATUSES),
            f'| {len(rows)} | ' + ' | '.join(str(counts[s]) for s in MASTERLIST_STATUSES) + ' |',
            SUMMARY_END]


def enrich(text, catalog=None):
    """Rewrite derived Status cells and the summary block. Every other byte is left untouched."""
    catalog = catalog or load('InspectorCore/Sources/InspectorCore/Resources/formats.json')
    lines, rows = parse_masterlist(text)
    for row in rows:
        derived = derive(row, catalog) if 'invalid' not in row else None
        if derived is None:
            continue
        status = derived[0]
        cells = _split_cells(lines[row['line']])
        cells[STATUS_COLUMN] = f' {status} '
        lines[row['line']] = '|' + '|'.join(cells) + '|'
        row['status'] = status
    if SUMMARY_START in lines and SUMMARY_END in lines:
        start, end = lines.index(SUMMARY_START), lines.index(SUMMARY_END)
        lines[start:end + 1] = _summary(rows)
    return '\n'.join(lines)


def check(text, catalog=None):
    """Return a list of problems; an empty list means the masterlist is consistent and enriched."""
    catalog = catalog or load('InspectorCore/Sources/InspectorCore/Resources/formats.json')
    by_id = {entry['id']: entry for entry in catalog}
    problems = []
    try:
        _, rows = parse_masterlist(text)
    except ValueError as error:
        return [str(error)]
    if SUMMARY_START not in text or SUMMARY_END not in text:
        problems.append('Summary markers are missing')
    names = [row['format'].casefold() for row in rows]
    if names != sorted(names):
        problems.append('Rows are not sorted alphabetically by Format')
    for name, count in collections.Counter(names).items():
        if count > 1:
            problems.append(f'Duplicate format: {name}')
    linked = collections.Counter()
    linked_fixtures = collections.defaultdict(set)
    for row in rows:
        label = row['format'] or f"line {row['line'] + 1}"
        if 'invalid' in row:
            problems.append(f"{label}: {row['invalid']}, expected {len(COLUMNS)}")
            continue
        if not row['format'] or not row['cells'][2]:
            problems.append(f'{label}: Format and Description are required')
        if row['status'] not in MASTERLIST_STATUSES:
            problems.append(f"{label}: unknown status {row['status']!r}")
        if row['status'] == 'Excluded' and not row['manual'] and (row['names'] or row['formatIDs']):
            problems.append(f'{label}: Excluded requires "{MANUAL_STATUS}"')
        for id in row['formatIDs']:
            linked[id] += 1
            if id not in by_id:
                problems.append(f'{label}: unknown catalog id {id}')
        for path in row['fixtures']:
            target = (MASTERLIST.parent / path).resolve()
            if not target.is_relative_to(FIXTURES) or not (target.is_file() or target.is_dir()):
                problems.append(f'{label}: fixture not found {path}')
        for id in row['formatIDs']:
            linked_fixtures[id].update(row['fixtures'])
    for entry in catalog:
        if entry['status'] != 'supported':
            continue
        if entry['id'] not in linked:
            problems.append(f"Supported catalog id {entry['id']} is not linked from any row")
        elif '../../Fixtures/' + entry['showcaseFixture'] not in linked_fixtures[entry['id']]:
            problems.append(f"Showcase {entry['showcaseFixture']} is not linked from a row for {entry['id']}")
    if not problems and enrich(text, catalog) != text:
        problems.append('Derived Status or summary is stale; run --enrich')
    return problems


if __name__ == '__main__':
    if '--enrich' in sys.argv:
        MASTERLIST.write_text(enrich(MASTERLIST.read_text()))
    if '--explain' in sys.argv:
        catalog = load('InspectorCore/Sources/InspectorCore/Resources/formats.json')
        for row in parse_masterlist(MASTERLIST.read_text())[1]:
            derived = derive(row, catalog)
            if derived is None:
                print(f"{row['format']}: {row['status']} ({MANUAL_STATUS.lower() if row['manual'] else 'no route'})")
                continue
            status, kinds, explanation = derived
            print(f"{row['format']}: {status} inspector={','.join(kinds) or '-'} {explanation}")
    if '--check' in sys.argv:
        problems = check(MASTERLIST.read_text())
        print('\n'.join(problems) or 'Masterlist OK')
        sys.exit(1 if problems else 0)
    if len(sys.argv) == 1:
        print(report())
