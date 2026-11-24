entity broken is
  port (clock : in std_logic);
architecture rtl of broken is
begin
  process(clock) begin
    count <= 42;
