# Flowchart and Math {#overview}

This *representative* document combines **CommonMark**, ~~GFM~~, inline math $x^2 + \alpha_i$,
and a local rendering path. Inline `$x^2$` stays code.

Return to the [overview](#overview) after reviewing the diagrams.

> A block quote keeps its ordinary Markdown meaning beside native attachments.

- [ ] Review the first item
- [x] Confirm the completed item

The note below has a reference[^rendering].

[^rendering]: Footnotes keep their text and number references by first use.

!!! note
    This admonition sits beside ordinary Markdown and keeps its readable body.

```swift
let literal = "```mermaid flowchart TD A --> B``` and $x^2$ stay code"
```

Display math stays centered and native:

$$
\frac{a}{b} = \sqrt{x}
$$

```mermaid
flowchart TD
  Start[Start] --> Decide{Ready?}
  Decide -->|Yes| Finish(Continue)
  Decide -.->|No| Review[<script>literal text</script>]
```

![Local image](pixel.png)

| Result | Formula |
|---|---|
| Done | $\sqrt{x}$ |

```mermaid
sequenceDiagram
participant Browser as Client
participant API as Service
Browser->>API: Load <script>literal text</script>
API-->>Browser: 200 OK
```

```mermaid
graph LR
  Source[Input] ==> Output[Rendered]
```

```mermaid
classDiagram
  class Order {
    +String résumé
    +submitWithLongUnicodeLabel(東京) 🚀
  }
  Order <|-- SpecialOrder : inherits
  Order --> Account : ownership relation covering shared, delegated and archived customer accounts
```

```mermaid
stateDiagram-v2
  [*] --> Idle
  Idle --> Active : démarre 🚀
  Active --> [*] : terminé
```

## After the diagrams

This heading and its navigation remain intact.
