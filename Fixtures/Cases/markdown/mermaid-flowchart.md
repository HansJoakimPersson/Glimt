```mermaid
flowchart TD
  Start[Start] --> Decide{Ready?}
  Decide -->|Yes| Finish(Continue)
  Decide -.->|No| Review[Review]
```
