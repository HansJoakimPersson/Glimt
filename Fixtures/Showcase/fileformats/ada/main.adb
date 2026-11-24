with Ada.Text_IO;

procedure Main is
   Message : constant String := "Hello from Ada";
   Count   : constant Integer := 42;
begin
   Ada.Text_IO.Put_Line (Message);
   Ada.Text_IO.Put_Line (Integer'Image (Count));
end Main;
