---
title: Glimt Markdown
purpose: Local, read-only preview
features: [headings, tables, tasks, code, alerts, footnotes, definitions, wikilinks, tags, inline styles]
---

# Glimt Markdown

A **bold** thought, an *emphasized* word and ~~a revision~~.[^local] Links such as
[Glimt](https://example.invalid) are readable text; no remote resource is loaded.

## Lists and tasks

- Inspect local files
- Keep the original content

1. Choose a file
2. Adjust its presentation

- [x] Local rendering
- [ ] Human review

## Table

| Format | Preview |
| --- | --- |
| Markdown | Rendered / Source |
| JSON | Tree / Pretty / Raw |

## Definition list

Recovery point objective
: Maximum acceptable data loss measured from the latest recoverable backup.
  The definition may continue on an indented line with *inline styling*.

> Presentation changes the view, never the original document.

Use `let value = 42` inline, or inspect a fenced code sample:

```swift
struct Example {
    let value: Int = 42
    let message = "Hello, Glimt"
}
```

## Links and line breaks

Bundled shortcodes: :smile: :heart: :rocket: :tada: :warning: :thumbsup:.

A bare URL: https://example.invalid/local-preview

An angle autolink: <https://example.invalid/local-preview>

Jump to [inline syntax](#inline-syntax) with a local heading fragment.

These two source lines
share a paragraph under standard line-break behavior.

This line has an explicit hard break.\
The next line stays separate in Rendered.

[^local]: Footnotes are numbered and listed at the end of the document.

## Inline syntax and local notation {#inline-syntax}

==Highlighted text==, H~2~O, and x^2^ stay readable in the rendered view. A hashtag such as #local-preview
and a wikilink such as [[Settings|the settings guide]] remain local text; this preview does not open
external destinations.

### Reference links and escaped characters

The [project description][project] and an email autolink <preview@example.invalid> are listed here.
Escaped punctuation stays literal: \*stars\* and \[brackets\].

[project]: https://example.invalid/project-description

## Alerts and admonitions

> [!NOTE]
> Alerts use the same bounded native preview treatment.

!!! tip "A short tip"
    Short admonitions reuse the alert presentation and preserve this source in Raw.

## Heading levels

### Small heading

#### A deeper heading

The `#inline-syntax` heading anchor is explicit; generated anchors are available for headings without
an explicit identifier.
