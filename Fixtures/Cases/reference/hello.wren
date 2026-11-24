// Wren
class Greeter {
  construct new(name) { _name = name }
  hello() { System.print("Hej %(_name)") }
}
Greeter.new("Glimt").hello()
