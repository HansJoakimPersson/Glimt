// Greeting entry point.
object Main {
  def greet(name: String): String = s"Hej $name"
  val answer: Int = 42
  println(greet("Scala"))
}
