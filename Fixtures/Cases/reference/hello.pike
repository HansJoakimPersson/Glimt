// Pike
int main()
{
  array(string) names = ({ "Glimt", "Pike" });
  foreach (names, string name)
    write("Hej %s\n", name);
  return 0;
}
