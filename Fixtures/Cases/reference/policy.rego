package glimt.authz

import rego.v1

# Rego
default allow := false

allow if {
    input.user.role == "admin"
}
