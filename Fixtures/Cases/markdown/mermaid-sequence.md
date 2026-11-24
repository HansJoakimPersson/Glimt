# Request flow

```mermaid
sequenceDiagram
participant Browser as Client
participant API as Service
Browser->>API: GET /items
API-->>Browser: 200 OK
```
