define method greet (name :: <string>) => ()
  if (empty?(name))
    format-out("Hello, stranger\n");
end method;
