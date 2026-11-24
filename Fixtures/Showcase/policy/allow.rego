package glimt.preview

import rego.v1

# Deny unless a rule below allows the request.
default allow := false

allow if {
    input.user == "alice"
    input.age >= 42
}
