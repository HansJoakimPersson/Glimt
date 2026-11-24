// Pony
actor Main
  new create(env: Env) =>
    for i in Range(0, 3) do
      env.out.print("Hej " + i.string())
    end
