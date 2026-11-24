// Verilog header declarations for a four-bit counter.
localparam integer WIDTH = 4;
wire [WIDTH-1:0] next_count;

/* Enable the counter after reset. */
logic enabled = 1'b1;
