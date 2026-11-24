entity counter is
  port (clock : in std_logic; count : out integer);
end entity;
architecture rtl of counter is
begin
  process(clock) begin
    count <= 42;
  end process;
end architecture;
