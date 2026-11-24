## quadrant.mmd

```mermaid
quadrantChart
  title Preview quality map
  x-axis Hard to read --> Easy to read
  y-axis Low detail --> High detail
  quadrant-1 Review layout
  quadrant-2 Simplify labels
  quadrant-3 Add context
  quadrant-4 Keep as is
  Flowchart: [0.72, 0.78]
  Sequence: [0.62, 0.64]
  Mindmap: [0.48, 0.83]
```

## radar.mmd

```mermaid
radar-beta
  title Diagram review dimensions
  axis Labels, Contrast, Density, Navigation, Source
  curve Flowchart{4,4,3,2,4}
  curve Sequence{3,4,4,3,4}
  max 5
```

## requirement.mmd

```mermaid
requirementDiagram
  requirement bounded_input {
    id: R1
    text: Input size is bounded
    risk: high
    verifymethod: test
  }
  element markdown_inspector {
    type: software
  }
  markdown_inspector - satisfies -> bounded_input
```

## sankey.mmd

```mermaid
sankey-beta
Markdown,Inspection,12
Markdown,Raw fallback,3
Inspection,Rendered preview,9
Inspection,Raw fallback,3
```

## sequence.mmd

```mermaid
sequenceDiagram
  actor User
  participant Finder
  participant Glimt as Preview Extension
  User->>Finder: Press Space
  Finder->>Glimt: Preview request
  Glimt-->>Finder: Rendered preview
  Finder-->>User: Show result
```

## state.mmd

```mermaid
stateDiagram-v2
  [*] --> Requested
  Requested --> Inspecting : accepted
  Inspecting --> Rendered : supported
  Inspecting --> RawFallback : unsupported
  Rendered --> [*]
  RawFallback --> [*]
```

## swimlanes.mmd

```mermaid
swimlane-beta LR
subgraph Finder
  Select[Select file]
  Preview[Request preview]
end
subgraph Glimt
  Inspect[Inspect bounded input]
  Render[Render diagram]
end
Select --> Preview --> Inspect --> Render
```

## timeline.mmd

```mermaid
timeline
  title Preview lifecycle
  2024 : Add Markdown inspection
  2025 : Add local diagrams
       : Preserve exact source
  2026 : Expand family coverage
```

## tree-view.mmd

```mermaid
treeView-beta
├── src/
│   ├── components/
│   │   ├── Button.tsx
│   │   └── Header.tsx
│   └── index.js
├── docs/
│   └── README.md
├── package.json
└── .gitignore
```

## treemap.mmd

```mermaid
treemap-beta
  "Preview"
    "Text" : 42
    "Markdown" : 30
      "Mermaid" : 12
      "Tables" : 8
    "Structured data" : 28
```

## use-case.mmd

```mermaid
usecase-beta
  direction LR
  actor Reader("Technical reader")
  systemBoundary "Glimt Preview"
    Inspect("Inspect file")
    Source("View source")
    Diagram("View diagram")
  end
  Reader --> Inspect
  Reader --> Source
  Reader --> Diagram
```

## user-journey.mmd

```mermaid
journey
  title Review a Markdown file
  section Choose
    Find a file: 5: User
    Press Space: 4: User
  section Inspect
    Read rendered preview: 5: User
    Switch to source: 3: User
```

## venn.mmd

```mermaid
venn-beta
  set Core [Inspector Core]
  set UI [Preview UI]
  set Shared [Shared model]
  union Core,Shared [Inspection]
  union UI,Shared [Presentation]
```

## wardley.mmd

```mermaid
wardley-beta
  title Local preview components
  anchor User [0.9, 0.8]
  component Finder [0.8, 0.65]
  component Quick Look [0.65, 0.5]
  component Inspector [0.45, 0.35]
  User -> Finder
  Finder -> Quick Look
  Quick Look -> Inspector
```

## xy-chart.mmd

```mermaid
xychart-beta
  title Preview time by input size
  x-axis ["1 KB", "10 KB", "100 KB", "1 MB"]
  y-axis "Milliseconds" 0 --> 300
  line [8, 18, 74, 260]
  bar [5, 14, 58, 210]
```

## zenuml.mmd

```mermaid
zenuml
  title Preview request
  User->Finder.selectFile()
  Finder->Preview.request()
  Preview->Inspector.inspect()
  Inspector-->Preview: model
  Preview-->Finder: renderedContent
```
