with Ada.Text_IO;

procedure Ada_Example is
   -- Ada comments start with two hyphens.
   Message : constant String := "Hello from Ada";
   Answer : constant Integer := 42;
begin
   Ada.Text_IO.Put_Line (Message);
   Ada.Text_IO.Put (Integer'Image (Answer));
end Ada_Example;
