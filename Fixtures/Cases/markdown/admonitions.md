!!! note
    A note with **bold**, *italic*, ~~strike~~, `code`, ==highlight==, x^2^, Café 😀 and [^n].

    A second note paragraph with soft wrapping content.

> [!TIP]
> A neighboring GitHub alert.

Term beside the alerts
: a simple definition.

!!! tip
    Tip body.

!!! important
    Important body.

!!! warning
    Warning body.

!!! caution
    Caution body.

[^n]: A footnote beside the alerts.

!!! note
     Five spaces are rejected.

!!! tip
      Six spaces are rejected.

!!! important
       Seven spaces are rejected.

!!! warning
        Eight spaces are rejected.

!!! caution
	A leading tab is rejected.

!!! NOTE
    Uppercase kind is rejected.

!!!! note
    Extra marker is rejected.

!!! note Custom
    Custom titles are rejected.

```md
!!! note
    Fenced content is protected.
```

- item
!!! note
    Lazy list continuation is protected.

> quote
!!! note
    Lazy quote continuation is protected.

- item

!!! note
    A blank boundary allows this.

!!! note
    A candidate prefix.
    !!! unknown

!!! warning
    A candidate prefix.
    : standalone colon rejects it.

!!! caution
    A candidate prefix.
    A | B
    --- | ---
