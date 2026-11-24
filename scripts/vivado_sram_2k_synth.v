// =============================================================================
// Module      : sram_2k_macro (Vivado FPGA Behavioral BRAM Model)
// Description : Synthesizable synchronous single-port BRAM model (1024 x 32-bit)
//               matching sram_ctrl.v port interface for Vivado verification.
//               Simulation uses sim/sram_2k_macro.v.
// =============================================================================
`default_nettype none

module sram_2k_macro (
    input  wire        CLK,
    input  wire        CEN,
    input  wire        WEN,
    input  wire [9:0]  A,
    input  wire [31:0] D,
    output reg  [31:0] Q
);
    (* ram_style = "block" *) reg [31:0] mem [0:1023];

    always @(posedge CLK) begin
        if (!CEN) begin
            if (!WEN) begin
                mem[A] <= D;
            end else begin
                Q <= mem[A];
            end
        end
    end
endmodule

`default_nettype wire
