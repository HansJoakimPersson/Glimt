module counter(input logic clock, output logic [3:0] count);
  always_ff @(posedge clock) begin
    count <= count + 1;
  end
endmodule
