## Greeting helpers.

import std/strformat

type
  Greeting = object
    name: string

proc greet(person: Greeting): string =
  let answer = 42
  result = fmt"Hello, {person.name}! ({answer})"

when isMainModule:
  echo greet(Greeting(name: "Glimt"))
