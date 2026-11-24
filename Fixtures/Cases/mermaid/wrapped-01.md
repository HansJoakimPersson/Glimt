## agentflow.mmd

```mermaid
agentflow TB
  flow reviewer["Review Agent"]
    changes["Gather changes"]@{ shape: input }
    analyse["Analyse diff"]@{ shape: task }
    inspect["run_linter"]@{ shape: tool }
    decision["Clean?"]@{ shape: decision }

    changes --> analyse --> inspect --> decision
  end
```

## architecture.mmd

```mermaid
architecture-beta
  group client(cloud)[Client]
  group preview(server)[Preview]
  service finder(browser)[Finder] in client
  service extension(server)[Quick Look] in preview
  service core(database)[Inspector Core] in preview
  finder:R --> L:extension
  extension:B --> T:core
```

## block.mmd

```mermaid
block-beta
  columns 3
  user("Reader") space:1 finder("Finder")
  space:1 preview("Glimt Preview") space:1
  user --> finder
  finder --> preview
```

## c4.mmd

```mermaid
C4Context
  title Local preview context
  Person(reader, "Reader", "Inspects local files")
  System(finder, "Finder", "Requests Quick Look")
  System_Ext(glimt, "Glimt", "Renders bounded previews")
  Rel(reader, finder, "selects file")
  Rel(finder, glimt, "requests preview")
```

## class.mmd

```mermaid
classDiagram
  class PreviewRequest {
    +URL file
    +String contentType
    +cancel()
  }
  class InspectionResult {
    +String rawText
    +String detectedFormat
  }
  PreviewRequest --> InspectionResult : produces
  InspectionResult <|-- MarkdownResult
```

## cynefin.mmd

```mermaid
cynefin-beta
  title Input handling
  clear
    "Known text format"
  complicated
    "Structured file"
  complex
    "Unknown content"
  chaotic
    "Malformed input"
```

## entity-relationship.mmd

```mermaid
erDiagram
  DOCUMENT ||--o{ PREVIEW_REQUEST : receives
  PREVIEW_REQUEST ||--|| INSPECTION : creates
  INSPECTION ||--o{ DIAGNOSTIC : reports
  DOCUMENT {
    string name
    string content_type
  }
```

## event-modeling.mmd

```mermaid
eventmodeling
  tf 01 ui SelectFile
  tf 02 cmd RequestPreview
  tf 03 evt PreviewRequested
  tf 04 cmd InspectDocument
  tf 05 evt DocumentInspected
  tf 06 ui ShowPreview
```

## flowchart.mmd

```mermaid
flowchart LR
  Request[Open Markdown] --> Inspect{Supported text?}
  Inspect -->|yes| Parse[Build preview model]
  Parse --> Render[Render locally]
  Inspect -->|no| Raw[Keep source visible]
  Render --> Preview[Show Quick Look]
```

## gantt.mmd

```mermaid
gantt
  title Preview delivery
  dateFormat YYYY-MM-DD
  axisFormat %b %d
  section Core
    Inspect source :done, core, 2026-01-05, 2d
    Build preview model :active, model, after core, 3d
  section Review
    Check narrow layout :review, after model, 2d
```

## git-graph.mmd

```mermaid
gitGraph
  commit id: "preview base"
  branch mermaid-fixtures
  checkout mermaid-fixtures
  commit id: "add family fixtures"
  checkout main
  commit id: "keep existing work"
  merge mermaid-fixtures
```

## ishikawa.mmd

```mermaid
ishikawa-beta
  Readable diagrams
    Layout
      Long labels
      Dense edges
    Content
      Many nodes
      Mixed directions
    Accessibility
      Missing descriptions
      Small text
```

## kanban.mmd

```mermaid
kanban
  column0[Planned]
    fixture[Add diagram fixtures]
  column1[In review]
    bounds[Check source limits]
  column2[Done]
    inventory[Map all families]
```

## mindmap.mmd

```mermaid
mindmap
root((Markdown preview))
  Content
    Headings
    Tables
  Diagrams
    Flowchart
    Sequence
  Safety
    Bounded input
    Raw fallback
```

## packet.mmd

```mermaid
packet-beta
  0-7: "Magic"
  8-15: "Version"
  16-31: "Content length"
  32-63: "Payload prefix"
```

## pie.mmd

```mermaid
pie title Preview outcome
  "Rendered" : 7
  "Raw" : 3
```
