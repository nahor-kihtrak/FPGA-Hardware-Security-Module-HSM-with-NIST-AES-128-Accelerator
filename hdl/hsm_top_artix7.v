`timescale 1ns / 1ps

// ============================================================================
// TOP LEVEL: HARDWARE SECURITY MODULE (HSM) - BULLETPROOF UART HANDSHAKE
// ============================================================================
module hsm_top_artix7(
    input         clk,            // 50 MHz Clock (PIN N11)
    input  [15:0] sw,             // 16 Slide Switches
    input  [4:0]  pb,             // Push Buttons (pb[0] = Reset)
    output [15:0] led,            // 16 Diagnostic LEDs
    output [3:0]  digit,          // 7-Segment Digit Enable (Active Low)
    output [7:0]  Seven_Seg,      // 7-Segment Cathodes (Active Low)
    input         usb_uart_rxd,   // PIN D4 (RX from PC)
    output        usb_uart_txd,   // PIN C4 (TX to PC)
    output [7:0]  lcd_data,       // 16x2 LCD Data Pins
    output        lcd_e,          // 16x2 LCD Enable Pin
    output        lcd_rs          // 16x2 LCD Register Select
);

    // Reset Synchronizer
    reg [1:0] rst_sync = 2'b00;
    always @(posedge clk) rst_sync <= {rst_sync[0], pb[0]};
    wire reset_n = ~rst_sync[1];

    // UART Controller (115200 Baud @ 50 MHz)
    wire [7:0] uart_rx_byte;
    wire       uart_rx_valid;
    wire       uart_rx_ready;
    reg  [7:0] uart_tx_byte;
    reg        uart_tx_start;
    wire       uart_tx_busy;

    uart_rx #(.CLK_FREQ(50000000), .BAUD_RATE(115200)) U_RX (
        .clk(clk), .rst_n(reset_n),
        .rx(usb_uart_rxd),
        .data_out(uart_rx_byte),
        .valid(uart_rx_valid),
        .ready(uart_rx_ready)
    );

    uart_tx #(.CLK_FREQ(50000000), .BAUD_RATE(115200)) U_TX (
        .clk(clk), .rst_n(reset_n),
        .tx_start(uart_tx_start),
        .data_in(uart_tx_byte),
        .tx(usb_uart_txd),
        .busy(uart_tx_busy)
    );

    // Timing-Closed NIST FIPS-197 AES-128 Engine
    reg  [127:0] aes_block_in;
    reg  [127:0] aes_key_in;
    reg          aes_start;
    reg          aes_mode;
    wire [127:0] aes_block_out;
    wire         aes_done;
    wire         aes_busy;

    aes128_fips197_engine U_AES (
        .clk(clk), .rst_n(reset_n),
        .start(aes_start),
        .enc_dec(aes_mode),
        .key(aes_key_in),
        .data_in(aes_block_in),
        .data_out(aes_block_out),
        .busy(aes_busy),
        .done(aes_done)
    );

    // Robust Protocol State Machine
    localparam S_IDLE            = 4'd0,
               S_RECV_LEN        = 4'd1,
               S_RECV_DATA       = 4'd2,
               S_START_AES       = 4'd3,
               S_EXEC_AES        = 4'd4,
               S_TX_BYTE         = 4'd5,
               S_WAIT_BUSY_HIGH  = 4'd6,
               S_WAIT_BUSY_LOW   = 4'd7;

    reg [3:0]  state;
    reg [7:0]  cmd_reg;
    reg [7:0]  len_reg;
    reg [3:0]  byte_idx;
    reg [7:0]  data_buf[0:15];
    reg [15:0] total_blocks;
    reg [23:0] watchdog_cnt;

    // Output packet buffer (1 ACK byte + 16 data bytes)
    reg [7:0]  tx_packet[0:16];
    reg [4:0]  tx_idx;
    reg [4:0]  tx_total;

    assign uart_rx_ready = (state == S_IDLE || state == S_RECV_LEN || state == S_RECV_DATA);

    integer i;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= S_IDLE;
            cmd_reg <= 8'd0;
            len_reg <= 8'd0;
            byte_idx <= 4'd0;
            aes_start <= 1'b0;
            aes_mode <= 1'b0;
            aes_key_in <= 128'h000102030405060708090a0b0c0d0e0f;
            aes_block_in <= 128'd0;
            uart_tx_start <= 1'b0;
            uart_tx_byte <= 8'd0;
            total_blocks <= 16'd0;
            watchdog_cnt <= 24'd0;
            tx_idx <= 5'd0;
            tx_total <= 5'd0;
            for (i=0; i<16; i=i+1) data_buf[i] <= 8'd0;
            for (i=0; i<17; i=i+1) tx_packet[i] <= 8'd0;
        end else begin
            aes_start <= 1'b0;
            uart_tx_start <= 1'b0;

            // Auto-timeout Watchdog (100ms)
            if (state != S_IDLE) begin
                if (watchdog_cnt < 24'd5000000) begin
                    watchdog_cnt <= watchdog_cnt + 1'b1;
                end else begin
                    state <= S_IDLE;
                    watchdog_cnt <= 24'd0;
                end
            end else begin
                watchdog_cnt <= 24'd0;
            end

            case (state)
                S_IDLE: begin
                    byte_idx <= 4'd0;
                    if (uart_rx_valid) begin
                        cmd_reg <= uart_rx_byte;
                        if (uart_rx_byte == 8'h04) begin // PING (0x04)
                            tx_packet[0] <= 8'h55;
                            tx_total <= 5'd1;
                            tx_idx <= 5'd0;
                            state <= S_TX_BYTE;
                        end else begin
                            state <= S_RECV_LEN;
                        end
                    end
                end

                S_RECV_LEN: begin
                    if (uart_rx_valid) begin
                        len_reg <= uart_rx_byte;
                        byte_idx <= 4'd0;
                        state <= S_RECV_DATA;
                    end
                end

                S_RECV_DATA: begin
                    if (uart_rx_valid) begin
                        data_buf[byte_idx] <= uart_rx_byte;
                        if (byte_idx == 4'd15) begin
                            if (cmd_reg == 8'h01) begin // SET_KEY
                                aes_key_in <= {data_buf[0], data_buf[1], data_buf[2], data_buf[3],
                                               data_buf[4], data_buf[5], data_buf[6], data_buf[7],
                                               data_buf[8], data_buf[9], data_buf[10], data_buf[11],
                                               data_buf[12], data_buf[13], data_buf[14], uart_rx_byte};
                                tx_packet[0] <= 8'hAA; // ACK Key Burn
                                tx_total <= 5'd1;
                                tx_idx <= 5'd0;
                                state <= S_TX_BYTE;
                            end else if (cmd_reg == 8'h02 || cmd_reg == 8'h03) begin // ENC / DEC
                                state <= S_START_AES;
                            end else begin
                                state <= S_IDLE;
                            end
                        end else begin
                            byte_idx <= byte_idx + 1'b1;
                        end
                    end
                end

                S_START_AES: begin
                    aes_block_in <= {data_buf[0], data_buf[1], data_buf[2], data_buf[3],
                                     data_buf[4], data_buf[5], data_buf[6], data_buf[7],
                                     data_buf[8], data_buf[9], data_buf[10], data_buf[11],
                                     data_buf[12], data_buf[13], data_buf[14], data_buf[15]};
                    aes_mode <= (cmd_reg == 8'h03);
                    aes_start <= 1'b1;
                    state <= S_EXEC_AES;
                end

                S_EXEC_AES: begin
                    if (aes_done) begin
                        total_blocks <= total_blocks + 1'b1;
                        // Assemble return packet: Byte 0 = ACK (0xAA), Bytes 1..16 = Result Data
                        tx_packet[0]  <= 8'hAA;
                        tx_packet[1]  <= aes_block_out[127:120];
                        tx_packet[2]  <= aes_block_out[119:112];
                        tx_packet[3]  <= aes_block_out[111:104];
                        tx_packet[4]  <= aes_block_out[103:96];
                        tx_packet[5]  <= aes_block_out[95:88];
                        tx_packet[6]  <= aes_block_out[87:80];
                        tx_packet[7]  <= aes_block_out[79:72];
                        tx_packet[8]  <= aes_block_out[71:64];
                        tx_packet[9]  <= aes_block_out[63:56];
                        tx_packet[10] <= aes_block_out[55:48];
                        tx_packet[11] <= aes_block_out[47:40];
                        tx_packet[12] <= aes_block_out[39:32];
                        tx_packet[13] <= aes_block_out[31:24];
                        tx_packet[14] <= aes_block_out[23:16];
                        tx_packet[15] <= aes_block_out[15:8];
                        tx_packet[16] <= aes_block_out[7:0];
                        tx_total <= 5'd17;
                        tx_idx <= 5'd0;
                        state <= S_TX_BYTE;
                    end
                end

                // Step 1 of Handshake: Load byte and pulse tx_start
                S_TX_BYTE: begin
                    if (!uart_tx_busy) begin
                        uart_tx_byte <= tx_packet[tx_idx];
                        uart_tx_start <= 1'b1;
                        state <= S_WAIT_BUSY_HIGH;
                    end
                end

                // Step 2 of Handshake: Wait for transmitter to assert busy
                S_WAIT_BUSY_HIGH: begin
                    if (uart_tx_busy) begin
                        state <= S_WAIT_BUSY_LOW;
                    end
                end

                // Step 3 of Handshake: Wait for byte to finish transmitting completely
                S_WAIT_BUSY_LOW: begin
                    if (!uart_tx_busy) begin
                        if (tx_idx + 1'b1 == tx_total) begin
                            state <= S_IDLE; // Packet complete!
                        end else begin
                            tx_idx <= tx_idx + 1'b1;
                            state <= S_TX_BYTE; // Send next byte
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // Diagnostic LEDs
    assign led[0]    = (state != S_IDLE);
    assign led[1]    = aes_busy;
    assign led[7:2]  = {2'b0, state};
    assign led[15:8] = cmd_reg;

    // 7-Segment Display Controller
    reg [16:0] clk_div = 0;
    always @(posedge clk) clk_div <= clk_div + 1'b1;

    reg [3:0] nibble;
    reg [3:0] an_reg;
    reg [6:0] seg_hex;

    always @(*) begin
        case (clk_div[16:15])
            2'b00: begin an_reg = 4'b1110; nibble = total_blocks[3:0];   end
            2'b01: begin an_reg = 4'b1101; nibble = total_blocks[7:4];   end
            2'b10: begin an_reg = 4'b1011; nibble = total_blocks[11:8];  end
            2'b11: begin an_reg = 4'b0111; nibble = total_blocks[15:12]; end
        endcase
    end
    assign digit = an_reg;

    always @(*) begin
        case (nibble)
            4'h0: seg_hex = 7'b1000000; 4'h1: seg_hex = 7'b1111001;
            4'h2: seg_hex = 7'b0100100; 4'h3: seg_hex = 7'b0110000;
            4'h4: seg_hex = 7'b0011001; 4'h5: seg_hex = 7'b0010010;
            4'h6: seg_hex = 7'b0000010; 4'h7: seg_hex = 7'b1111000;
            4'h8: seg_hex = 7'b0000000; 4'h9: seg_hex = 7'b0010000;
            4'hA: seg_hex = 7'b0001000; 4'hB: seg_hex = 7'b0000011;
            4'hC: seg_hex = 7'b1000110; 4'hD: seg_hex = 7'b0100001;
            4'hE: seg_hex = 7'b0000110; 4'hF: seg_hex = 7'b0001110;
        endcase
    end
    assign Seven_Seg = {1'b1, seg_hex};

    // 16x2 LCD Controller
    lcd_controller_16x2 U_LCD (
        .clk(clk),
        .rst_n(reset_n),
        .cmd_mode(cmd_reg),
        .is_busy(state != S_IDLE),
        .total_count(total_blocks),
        .lcd_data(lcd_data),
        .lcd_e(lcd_e),
        .lcd_rs(lcd_rs)
    );

endmodule


// ============================================================================
// DYNAMIC 16x2 LCD CONTROLLER
// ============================================================================
module lcd_controller_16x2(
    input            clk,
    input            rst_n,
    input      [7:0] cmd_mode,
    input            is_busy,
    input     [15:0] total_count,
    output reg [7:0] lcd_data,
    output reg       lcd_e,
    output reg       lcd_rs
);
    reg [20:0] clk_cnt;
    reg [5:0]  state_idx;
    reg [23:0] spin_cnt;
    reg [1:0]  spinner_phase;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spin_cnt <= 0;
            spinner_phase <= 0;
        end else begin
            if (spin_cnt < 24'd6000000) spin_cnt <= spin_cnt + 1'b1;
            else begin
                spin_cnt <= 0;
                spinner_phase <= spinner_phase + 1'b1;
            end
        end
    end

    function [7:0] hex_to_ascii(input [3:0] h);
        hex_to_ascii = (h < 4'hA) ? (8'h30 + h) : (8'h41 + (h - 4'hA));
    endfunction

    function [7:0] get_spinner(input [1:0] sp);
        case (sp)
            2'b00: get_spinner = "|";
            2'b01: get_spinner = "/";
            2'b10: get_spinner = "-";
            2'b11: get_spinner = "\\";
        endcase
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_cnt <= 0;
            state_idx <= 0;
            lcd_data <= 8'h00;
            lcd_e <= 0;
            lcd_rs <= 0;
        end else begin
            if (clk_cnt < 21'd250000) begin
                clk_cnt <= clk_cnt + 1'b1;
                if (clk_cnt == 21'd50000)  lcd_e <= 1'b1;
                if (clk_cnt == 21'd150000) lcd_e <= 1'b0;
            end else begin
                clk_cnt <= 0;
                case (state_idx)
                    6'd0:  begin lcd_rs <= 0; lcd_data <= 8'h38; end
                    6'd1:  begin lcd_rs <= 0; lcd_data <= 8'h0C; end
                    6'd2:  begin lcd_rs <= 0; lcd_data <= 8'h01; end
                    6'd3:  begin lcd_rs <= 0; lcd_data <= 8'h06; end

                    // Line 1: Header
                    6'd4:  begin lcd_rs <= 0; lcd_data <= 8'h80; end
                    6'd5:  begin lcd_rs <= 1; lcd_data <= (cmd_mode==8'h02 && is_busy) ? "[" : (cmd_mode==8'h03 && is_busy) ? "[" : "H"; end
                    6'd6:  begin lcd_rs <= 1; lcd_data <= (cmd_mode==8'h02 && is_busy) ? "E" : (cmd_mode==8'h03 && is_busy) ? "D" : "S"; end
                    6'd7:  begin lcd_rs <= 1; lcd_data <= (cmd_mode==8'h02 && is_busy) ? "N" : (cmd_mode==8'h03 && is_busy) ? "E" : "M"; end
                    6'd8:  begin lcd_rs <= 1; lcd_data <= (cmd_mode==8'h02 && is_busy) ? "C" : (cmd_mode==8'h03 && is_busy) ? "C" : ":"; end
                    6'd9:  begin lcd_rs <= 1; lcd_data <= (cmd_mode==8'h02 && is_busy) ? "R" : (cmd_mode==8'h03 && is_busy) ? "R" : " "; end
                    6'd10: begin lcd_rs <= 1; lcd_data <= (cmd_mode==8'h02 && is_busy) ? "Y" : (cmd_mode==8'h03 && is_busy) ? "Y" : "A"; end
                    6'd11: begin lcd_rs <= 1; lcd_data <= (cmd_mode==8'h02 && is_busy) ? "P" : (cmd_mode==8'h03 && is_busy) ? "P" : "E"; end
                    6'd12: begin lcd_rs <= 1; lcd_data <= (cmd_mode==8'h02 && is_busy) ? "T" : (cmd_mode==8'h03 && is_busy) ? "T" : "S"; end
                    6'd13: begin lcd_rs <= 1; lcd_data <= (cmd_mode==8'h02 && is_busy) ? "]" : (cmd_mode==8'h03 && is_busy) ? "]" : "-"; end
                    6'd14: begin lcd_rs <= 1; lcd_data <= is_busy ? " " : "1"; end
                    6'd15: begin lcd_rs <= 1; lcd_data <= is_busy ? " " : "2"; end
                    6'd16: begin lcd_rs <= 1; lcd_data <= is_busy ? " " : "8"; end
                    6'd17: begin lcd_rs <= 1; lcd_data <= is_busy ? " " : " "; end
                    6'd18: begin lcd_rs <= 1; lcd_data <= is_busy ? " " : " "; end
                    6'd19: begin lcd_rs <= 1; lcd_data <= is_busy ? " " : " "; end
                    6'd20: begin lcd_rs <= 1; lcd_data <= is_busy ? get_spinner(spinner_phase) : "*"; end

                    // Line 2: Processed Blocks
                    6'd21: begin lcd_rs <= 0; lcd_data <= 8'hC0; end
                    6'd22: begin lcd_rs <= 1; lcd_data <= "B"; end
                    6'd23: begin lcd_rs <= 1; lcd_data <= "L"; end
                    6'd24: begin lcd_rs <= 1; lcd_data <= "K"; end
                    6'd25: begin lcd_rs <= 1; lcd_data <= ":"; end
                    6'd26: begin lcd_rs <= 1; lcd_data <= hex_to_ascii(total_count[15:12]); end
                    6'd27: begin lcd_rs <= 1; lcd_data <= hex_to_ascii(total_count[11:8]);  end
                    6'd28: begin lcd_rs <= 1; lcd_data <= hex_to_ascii(total_count[7:4]);   end
                    6'd29: begin lcd_rs <= 1; lcd_data <= hex_to_ascii(total_count[3:0]);   end
                    6'd30: begin lcd_rs <= 1; lcd_data <= " "; end
                    6'd31: begin lcd_rs <= 1; lcd_data <= "["; end
                    6'd32: begin lcd_rs <= 1; lcd_data <= is_busy ? "B" : "O"; end
                    6'd33: begin lcd_rs <= 1; lcd_data <= is_busy ? "U" : "K"; end
                    6'd34: begin lcd_rs <= 1; lcd_data <= is_busy ? "S" : "]"; end
                    6'd35: begin lcd_rs <= 1; lcd_data <= is_busy ? "Y" : " "; end
                    6'd36: begin lcd_rs <= 1; lcd_data <= is_busy ? "]" : " "; end
                    6'd37: begin lcd_rs <= 1; lcd_data <= " "; end

                    default: state_idx <= 6'd4;
                endcase

                if (state_idx < 6'd37) state_idx <= state_idx + 1'b1;
                else state_idx <= 6'd4;
            end
        end
    end
endmodule


// ============================================================================
// TIMING-OPTIMIZED NIST FIPS-197 AES-128 ENGINE
// ============================================================================
module aes128_fips197_engine(
    input          clk,
    input          rst_n,
    input          start,
    input          enc_dec,
    input  [127:0] key,
    input  [127:0] data_in,
    output reg [127:0] data_out,
    output         busy,
    output reg     done
);
    localparam ST_IDLE    = 3'd0,
               ST_EXP_KEY = 3'd1,
               ST_EXEC    = 3'd2;

    reg [2:0]   engine_state;
    reg [3:0]   round;
    reg [3:0]   exp_step;
    reg [127:0] state_reg;
    reg [127:0] round_keys[0:10];
    reg [127:0] active_key;
    reg         key_cached;
    reg         mode_r;

    assign busy = (engine_state != ST_IDLE);

    // Encryption Datapath Wires
    wire [127:0] enc_sb_out, enc_sr_out, enc_mc_out;
    aes_subbytes_128   U_ENC_SB (.in(state_reg),  .out(enc_sb_out));
    aes_shiftrows_128  U_ENC_SR (.in(enc_sb_out), .out(enc_sr_out));
    aes_mixcolumns_128 U_ENC_MC (.in(enc_sr_out), .out(enc_mc_out));

    // Decryption Datapath Wires
    wire [127:0] dec_isr_out, dec_isb_out, dec_ark_out, dec_imc_out;
    aes_inv_shiftrows_128  U_DEC_ISR (.in(state_reg),   .out(dec_isr_out));
    aes_inv_subbytes_128   U_DEC_ISB (.in(dec_isr_out), .out(dec_isb_out));
    assign dec_ark_out = dec_isb_out ^ round_keys[10 - (round + 1)];
    aes_inv_mixcolumns_128 U_DEC_IMC (.in(dec_ark_out), .out(dec_imc_out));

    function [7:0] rcon(input [3:0] r);
        case(r)
            4'd1: rcon = 8'h01; 4'd2: rcon = 8'h02; 4'd3: rcon = 8'h04; 4'd4: rcon = 8'h08;
            4'd5: rcon = 8'h10; 4'd6: rcon = 8'h20; 4'd7: rcon = 8'h40; 4'd8: rcon = 8'h80;
            4'd9: rcon = 8'h1b; 4'd10:rcon = 8'h36; default: rcon = 8'h00;
        endcase
    endfunction

    function [31:0] sub_word(input [31:0] w);
        reg [7:0] b0, b1, b2, b3;
        begin
            b0 = sbox_func(w[31:24]);
            b1 = sbox_func(w[23:16]);
            b2 = sbox_func(w[15:8]);
            b3 = sbox_func(w[7:0]);
            sub_word = {b0, b1, b2, b3};
        end
    endfunction

    function [127:0] expand_one_key(input [127:0] prev_k, input [3:0] r_idx);
        reg [31:0] w0, w1, w2, w3, t;
        begin
            w0 = prev_k[127:96];
            w1 = prev_k[95:64];
            w2 = prev_k[63:32];
            w3 = prev_k[31:0];
            t  = sub_word({w3[23:0], w3[31:24]}) ^ {rcon(r_idx), 24'h000000};
            w0 = w0 ^ t;
            w1 = w1 ^ w0;
            w2 = w2 ^ w1;
            w3 = w3 ^ w2;
            expand_one_key = {w0, w1, w2, w3};
        end
    endfunction

    function [7:0] sbox_func(input [7:0] in);
        case (in[7:4])
            4'h0: case(in[3:0]) 4'h0: sbox_func=8'h63; 4'h1: sbox_func=8'h7c; 4'h2: sbox_func=8'h77; 4'h3: sbox_func=8'h7b; 4'h4: sbox_func=8'hf2; 4'h5: sbox_func=8'h6b; 4'h6: sbox_func=8'h6f; 4'h7: sbox_func=8'hc5; 4'h8: sbox_func=8'h30; 4'h9: sbox_func=8'h01; 4'ha: sbox_func=8'h67; 4'hb: sbox_func=8'h2b; 4'hc: sbox_func=8'hfe; 4'hd: sbox_func=8'hd7; 4'he: sbox_func=8'hab; 4'hf: sbox_func=8'h76; endcase
            4'h1: case(in[3:0]) 4'h0: sbox_func=8'hca; 4'h1: sbox_func=8'h82; 4'h2: sbox_func=8'hc9; 4'h3: sbox_func=8'h7d; 4'h4: sbox_func=8'hfa; 4'h5: sbox_func=8'h59; 4'h6: sbox_func=8'h47; 4'h7: sbox_func=8'hf0; 4'h8: sbox_func=8'had; 4'h9: sbox_func=8'hd4; 4'ha: sbox_func=8'ha2; 4'hb: sbox_func=8'haf; 4'hc: sbox_func=8'h9c; 4'hd: sbox_func=8'ha4; 4'he: sbox_func=8'h72; 4'hf: sbox_func=8'hc0; endcase
            4'h2: case(in[3:0]) 4'h0: sbox_func=8'hb7; 4'h1: sbox_func=8'hfd; 4'h2: sbox_func=8'h93; 4'h3: sbox_func=8'h26; 4'h4: sbox_func=8'h36; 4'h5: sbox_func=8'h3f; 4'h6: sbox_func=8'hf7; 4'h7: sbox_func=8'hcc; 4'h8: sbox_func=8'h34; 4'h9: sbox_func=8'ha5; 4'ha: sbox_func=8'he5; 4'hb: sbox_func=8'hf1; 4'hc: sbox_func=8'h71; 4'hd: sbox_func=8'hd8; 4'he: sbox_func=8'h31; 4'hf: sbox_func=8'h15; endcase
            4'h3: case(in[3:0]) 4'h0: sbox_func=8'h04; 4'h1: sbox_func=8'hc7; 4'h2: sbox_func=8'h23; 4'h3: sbox_func=8'hc3; 4'h4: sbox_func=8'h18; 4'h5: sbox_func=8'h96; 4'h6: sbox_func=8'h05; 4'h7: sbox_func=8'h9a; 4'h8: sbox_func=8'h07; 4'h9: sbox_func=8'h12; 4'ha: sbox_func=8'h80; 4'hb: sbox_func=8'he2; 4'hc: sbox_func=8'heb; 4'hd: sbox_func=8'h27; 4'he: sbox_func=8'hb2; 4'hf: sbox_func=8'h75; endcase
            4'h4: case(in[3:0]) 4'h0: sbox_func=8'h09; 4'h1: sbox_func=8'h83; 4'h2: sbox_func=8'h2c; 4'h3: sbox_func=8'h1a; 4'h4: sbox_func=8'h1b; 4'h5: sbox_func=8'h6e; 4'h6: sbox_func=8'h5a; 4'h7: sbox_func=8'ha0; 4'h8: sbox_func=8'h52; 4'h9: sbox_func=8'h3b; 4'ha: sbox_func=8'hd6; 4'hb: sbox_func=8'hb3; 4'hc: sbox_func=8'h29; 4'hd: sbox_func=8'he3; 4'he: sbox_func=8'h2f; 4'hf: sbox_func=8'h84; endcase
            4'h5: case(in[3:0]) 4'h0: sbox_func=8'h53; 4'h1: sbox_func=8'hd1; 4'h2: sbox_func=8'h00; 4'h3: sbox_func=8'hed; 4'h4: sbox_func=8'h20; 4'h5: sbox_func=8'hfc; 4'h6: sbox_func=8'hb1; 4'h7: sbox_func=8'h5b; 4'h8: sbox_func=8'h6a; 4'h9: sbox_func=8'hcb; 4'ha: sbox_func=8'hbe; 4'hb: sbox_func=8'h39; 4'hc: sbox_func=8'h4a; 4'hd: sbox_func=8'h4c; 4'he: sbox_func=8'h58; 4'hf: sbox_func=8'hcf; endcase
            4'h6: case(in[3:0]) 4'h0: sbox_func=8'hd0; 4'h1: sbox_func=8'hef; 4'h2: sbox_func=8'haa; 4'h3: sbox_func=8'hfb; 4'h4: sbox_func=8'h43; 4'h5: sbox_func=8'h4d; 4'h6: sbox_func=8'h33; 4'h7: sbox_func=8'h85; 4'h8: sbox_func=8'h45; 4'h9: sbox_func=8'hf9; 4'ha: sbox_func=8'h02; 4'hb: sbox_func=8'h7f; 4'hc: sbox_func=8'h50; 4'hd: sbox_func=8'h3c; 4'he: sbox_func=8'h9f; 4'hf: sbox_func=8'ha8; endcase
            4'h7: case(in[3:0]) 4'h0: sbox_func=8'h51; 4'h1: sbox_func=8'ha3; 4'h2: sbox_func=8'h40; 4'h3: sbox_func=8'h8f; 4'h4: sbox_func=8'h92; 4'h5: sbox_func=8'h9d; 4'h6: sbox_func=8'h38; 4'h7: sbox_func=8'hf5; 4'h8: sbox_func=8'hbc; 4'h9: sbox_func=8'hb6; 4'ha: sbox_func=8'hda; 4'hb: sbox_func=8'h21; 4'hc: sbox_func=8'h10; 4'hd: sbox_func=8'hff; 4'he: sbox_func=8'hf3; 4'hf: sbox_func=8'hd2; endcase
            4'h8: case(in[3:0]) 4'h0: sbox_func=8'hcd; 4'h1: sbox_func=8'h0c; 4'h2: sbox_func=8'h13; 4'h3: sbox_func=8'hec; 4'h4: sbox_func=8'h5f; 4'h5: sbox_func=8'h97; 4'h6: sbox_func=8'h44; 4'h7: sbox_func=8'h17; 4'h8: sbox_func=8'hc4; 4'h9: sbox_func=8'ha7; 4'ha: sbox_func=8'h7e; 4'hb: sbox_func=8'h3d; 4'hc: sbox_func=8'h64; 4'hd: sbox_func=8'h5d; 4'he: sbox_func=8'h19; 4'hf: sbox_func=8'h73; endcase
            4'h9: case(in[3:0]) 4'h0: sbox_func=8'h60; 4'h1: sbox_func=8'h81; 4'h2: sbox_func=8'h4f; 4'h3: sbox_func=8'hdc; 4'h4: sbox_func=8'h22; 4'h5: sbox_func=8'h2a; 4'h6: sbox_func=8'h90; 4'h7: sbox_func=8'h88; 4'h8: sbox_func=8'h46; 4'h9: sbox_func=8'hee; 4'ha: sbox_func=8'hb8; 4'hb: sbox_func=8'h14; 4'hc: sbox_func=8'hde; 4'hd: sbox_func=8'h5e; 4'he: sbox_func=8'h0b; 4'hf: sbox_func=8'hdb; endcase
            4'ha: case(in[3:0]) 4'h0: sbox_func=8'he0; 4'h1: sbox_func=8'h32; 4'h2: sbox_func=8'h3a; 4'h3: sbox_func=8'h0a; 4'h4: sbox_func=8'h49; 4'h5: sbox_func=8'h06; 4'h6: sbox_func=8'h24; 4'h7: sbox_func=8'h5c; 4'h8: sbox_func=8'hc2; 4'h9: sbox_func=8'hd3; 4'ha: sbox_func=8'hac; 4'hb: sbox_func=8'h62; 4'hc: sbox_func=8'h91; 4'hd: sbox_func=8'h95; 4'he: sbox_func=8'he4; 4'hf: sbox_func=8'h79; endcase
            4'hb: case(in[3:0]) 4'h0: sbox_func=8'he7; 4'h1: sbox_func=8'hc8; 4'h2: sbox_func=8'h37; 4'h3: sbox_func=8'h6d; 4'h4: sbox_func=8'h8d; 4'h5: sbox_func=8'hd5; 4'h6: sbox_func=8'h4e; 4'h7: sbox_func=8'ha9; 4'h8: sbox_func=8'h6c; 4'h9: sbox_func=8'h56; 4'ha: sbox_func=8'hf4; 4'hb: sbox_func=8'hea; 4'hc: sbox_func=8'h65; 4'hd: sbox_func=8'h7a; 4'he: sbox_func=8'hae; 4'hf: sbox_func=8'h08; endcase
            4'hc: case(in[3:0]) 4'h0: sbox_func=8'hba; 4'h1: sbox_func=8'h78; 4'h2: sbox_func=8'h25; 4'h3: sbox_func=8'h2e; 4'h4: sbox_func=8'h1c; 4'h5: sbox_func=8'ha6; 4'h6: sbox_func=8'hb4; 4'h7: sbox_func=8'hc6; 4'h8: sbox_func=8'he8; 4'h9: sbox_func=8'hdd; 4'ha: sbox_func=8'h74; 4'hb: sbox_func=8'h1f; 4'hc: sbox_func=8'h4b; 4'hd: sbox_func=8'hbd; 4'he: sbox_func=8'h8b; 4'hf: sbox_func=8'h8a; endcase
            4'hd: case(in[3:0]) 4'h0: sbox_func=8'h70; 4'h1: sbox_func=8'h3e; 4'h2: sbox_func=8'hb5; 4'h3: sbox_func=8'h66; 4'h4: sbox_func=8'h48; 4'h5: sbox_func=8'h03; 4'h6: sbox_func=8'hf6; 4'h7: sbox_func=8'h0e; 4'h8: sbox_func=8'h61; 4'h9: sbox_func=8'h35; 4'ha: sbox_func=8'h57; 4'hb: sbox_func=8'hb9; 4'hc: sbox_func=8'h86; 4'hd: sbox_func=8'hc1; 4'he: sbox_func=8'h1d; 4'hf: sbox_func=8'h9e; endcase
            4'he: case(in[3:0]) 4'h0: sbox_func=8'he1; 4'h1: sbox_func=8'hf8; 4'h2: sbox_func=8'h98; 4'h3: sbox_func=8'h11; 4'h4: sbox_func=8'h69; 4'h5: sbox_func=8'hd9; 4'h6: sbox_func=8'h8e; 4'h7: sbox_func=8'h94; 4'h8: sbox_func=8'h9b; 4'h9: sbox_func=8'h1e; 4'ha: sbox_func=8'h87; 4'hb: sbox_func=8'he9; 4'hc: sbox_func=8'hce; 4'hd: sbox_func=8'h55; 4'he: sbox_func=8'h28; 4'hf: sbox_func=8'hdf; endcase
            4'hf: case(in[3:0]) 4'h0: sbox_func=8'h8c; 4'h1: sbox_func=8'ha1; 4'h2: sbox_func=8'h89; 4'h3: sbox_func=8'h0d; 4'h4: sbox_func=8'hbf; 4'h5: sbox_func=8'he6; 4'h6: sbox_func=8'h42; 4'h7: sbox_func=8'h68; 4'h8: sbox_func=8'h41; 4'h9: sbox_func=8'h99; 4'ha: sbox_func=8'h2d; 4'hb: sbox_func=8'h0f; 4'hc: sbox_func=8'hb0; 4'hd: sbox_func=8'h54; 4'he: sbox_func=8'hbb; 4'hf: sbox_func=8'h16; endcase
        endcase
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            engine_state <= ST_IDLE;
            round <= 4'd0;
            exp_step <= 4'd1;
            key_cached <= 1'b0;
            active_key <= 128'd0;
            state_reg <= 128'd0;
            data_out <= 128'd0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;

            case (engine_state)
                ST_IDLE: begin
                    if (start) begin
                        mode_r <= enc_dec;
                        if (!key_cached || (key != active_key)) begin
                            active_key <= key;
                            round_keys[0] <= key;
                            exp_step <= 4'd1;
                            engine_state <= ST_EXP_KEY;
                        end else begin
                            round <= 4'd0;
                            state_reg <= (!enc_dec) ? (data_in ^ round_keys[0]) : (data_in ^ round_keys[10]);
                            engine_state <= ST_EXEC;
                        end
                    end
                end

                ST_EXP_KEY: begin
                    round_keys[exp_step] <= expand_one_key(round_keys[exp_step - 1], exp_step);
                    if (exp_step == 4'd10) begin
                        key_cached <= 1'b1;
                        round <= 4'd0;
                        state_reg <= (!mode_r) ? (data_in ^ round_keys[0]) : (data_in ^ expand_one_key(round_keys[9], 4'd10));
                        engine_state <= ST_EXEC;
                    end else begin
                        exp_step <= exp_step + 1'b1;
                    end
                end

                ST_EXEC: begin
                    if (!mode_r) begin
                        // Forward Encryption (Rounds 1 to 10)
                        if (round < 4'd9) begin
                            state_reg <= enc_mc_out ^ round_keys[round + 1];
                            round <= round + 1'b1;
                        end else if (round == 4'd9) begin
                            state_reg <= enc_sr_out ^ round_keys[10];
                            round <= 4'd10;
                        end else begin
                            data_out <= state_reg;
                            done <= 1'b1;
                            engine_state <= ST_IDLE;
                        end
                    end else begin
                        // Inverse Decryption (Rounds 1 to 10)
                        if (round < 4'd9) begin
                            state_reg <= dec_imc_out;
                            round <= round + 1'b1;
                        end else if (round == 4'd9) begin
                            state_reg <= dec_isb_out ^ round_keys[0];
                            round <= 4'd10;
                        end else begin
                            data_out <= state_reg;
                            done <= 1'b1;
                            engine_state <= ST_IDLE;
                        end
                    end
                end

                default: engine_state <= ST_IDLE;
            endcase
        end
    end
endmodule

// ============================================================================
// AES S-BOX & INVERSE S-BOX MODULES
// ============================================================================
module aes_subbytes_128(input [127:0] in, output [127:0] out);
    genvar i;
    generate
        for (i=0; i<16; i=i+1) begin: G_SB
            sbox SB(.in(in[8*i +: 8]), .out(out[8*i +: 8]));
        end
    endgenerate
endmodule

module aes_inv_subbytes_128(input [127:0] in, output [127:0] out);
    genvar i;
    generate
        for (i=0; i<16; i=i+1) begin: G_ISB
            inv_sbox ISB(.in(in[8*i +: 8]), .out(out[8*i +: 8]));
        end
    endgenerate
endmodule

module sbox(input [7:0] in, output reg [7:0] out);
    always @(*) begin
        case (in[7:4])
            4'h0: case(in[3:0]) 4'h0: out=8'h63; 4'h1: out=8'h7c; 4'h2: out=8'h77; 4'h3: out=8'h7b; 4'h4: out=8'hf2; 4'h5: out=8'h6b; 4'h6: out=8'h6f; 4'h7: out=8'hc5; 4'h8: out=8'h30; 4'h9: out=8'h01; 4'ha: out=8'h67; 4'hb: out=8'h2b; 4'hc: out=8'hfe; 4'hd: out=8'hd7; 4'he: out=8'hab; 4'hf: out=8'h76; endcase
            4'h1: case(in[3:0]) 4'h0: out=8'hca; 4'h1: out=8'h82; 4'h2: out=8'hc9; 4'h3: out=8'h7d; 4'h4: out=8'hfa; 4'h5: out=8'h59; 4'h6: out=8'h47; 4'h7: out=8'hf0; 4'h8: out=8'had; 4'h9: out=8'hd4; 4'ha: out=8'ha2; 4'hb: out=8'haf; 4'hc: out=8'h9c; 4'hd: out=8'ha4; 4'he: out=8'h72; 4'hf: out=8'hc0; endcase
            4'h2: case(in[3:0]) 4'h0: out=8'hb7; 4'h1: out=8'hfd; 4'h2: out=8'h93; 4'h3: out=8'h26; 4'h4: out=8'h36; 4'h5: out=8'h3f; 4'h6: out=8'hf7; 4'h7: out=8'hcc; 4'h8: out=8'h34; 4'h9: out=8'ha5; 4'ha: out=8'he5; 4'hb: out=8'hf1; 4'hc: out=8'h71; 4'hd: out=8'hd8; 4'he: out=8'h31; 4'hf: out=8'h15; endcase
            4'h3: case(in[3:0]) 4'h0: out=8'h04; 4'h1: out=8'hc7; 4'h2: out=8'h23; 4'h3: out=8'hc3; 4'h4: out=8'h18; 4'h5: out=8'h96; 4'h6: out=8'h05; 4'h7: out=8'h9a; 4'h8: out=8'h07; 4'h9: out=8'h12; 4'ha: out=8'h80; 4'hb: out=8'he2; 4'hc: out=8'heb; 4'hd: out=8'h27; 4'he: out=8'hb2; 4'hf: out=8'h75; endcase
            4'h4: case(in[3:0]) 4'h0: out=8'h09; 4'h1: out=8'h83; 4'h2: out=8'h2c; 4'h3: out=8'h1a; 4'h4: out=8'h1b; 4'h5: out=8'h6e; 4'h6: out=8'h5a; 4'h7: out=8'ha0; 4'h8: out=8'h52; 4'h9: out=8'h3b; 4'ha: out=8'hd6; 4'hb: out=8'hb3; 4'hc: out=8'h29; 4'hd: out=8'he3; 4'he: out=8'h2f; 4'hf: out=8'h84; endcase
            4'h5: case(in[3:0]) 4'h0: out=8'h53; 4'h1: out=8'hd1; 4'h2: out=8'h00; 4'h3: out=8'hed; 4'h4: out=8'h20; 4'h5: out=8'hfc; 4'h6: out=8'hb1; 4'h7: out=8'h5b; 4'h8: out=8'h6a; 4'h9: out=8'hcb; 4'ha: out=8'hbe; 4'hb: out=8'h39; 4'hc: out=8'h4a; 4'hd: out=8'h4c; 4'he: out=8'h58; 4'hf: out=8'hcf; endcase
            4'h6: case(in[3:0]) 4'h0: out=8'hd0; 4'h1: out=8'hef; 4'h2: out=8'haa; 4'h3: out=8'hfb; 4'h4: out=8'h43; 4'h5: out=8'h4d; 4'h6: out=8'h33; 4'h7: out=8'h85; 4'h8: out=8'h45; 4'h9: out=8'hf9; 4'ha: out=8'h02; 4'hb: out=8'h7f; 4'hc: out=8'h50; 4'hd: out=8'h3c; 4'he: out=8'h9f; 4'hf: out=8'ha8; endcase
            4'h7: case(in[3:0]) 4'h0: out=8'h51; 4'h1: out=8'ha3; 4'h2: out=8'h40; 4'h3: out=8'h8f; 4'h4: out=8'h92; 4'h5: out=8'h9d; 4'h6: out=8'h38; 4'h7: out=8'hf5; 4'h8: out=8'hbc; 4'h9: out=8'hb6; 4'ha: out=8'hda; 4'hb: out=8'h21; 4'hc: out=8'h10; 4'hd: out=8'hff; 4'he: out=8'hf3; 4'hf: out=8'hd2; endcase
            4'h8: case(in[3:0]) 4'h0: out=8'hcd; 4'h1: out=8'h0c; 4'h2: out=8'h13; 4'h3: out=8'hec; 4'h4: out=8'h5f; 4'h5: out=8'h97; 4'h6: out=8'h44; 4'h7: out=8'h17; 4'h8: out=8'hc4; 4'h9: out=8'ha7; 4'ha: out=8'h7e; 4'hb: out=8'h3d; 4'hc: out=8'h64; 4'hd: out=8'h5d; 4'he: out=8'h19; 4'hf: out=8'h73; endcase
            4'h9: case(in[3:0]) 4'h0: out=8'h60; 4'h1: out=8'h81; 4'h2: out=8'h4f; 4'h3: out=8'hdc; 4'h4: out=8'h22; 4'h5: out=8'h2a; 4'h6: out=8'h90; 4'h7: out=8'h88; 4'h8: out=8'h46; 4'h9: out=8'hee; 4'ha: out=8'hb8; 4'hb: out=8'h14; 4'hc: out=8'hde; 4'hd: out=8'h5e; 4'he: out=8'h0b; 4'hf: out=8'hdb; endcase
            4'ha: case(in[3:0]) 4'h0: out=8'he0; 4'h1: out=8'h32; 4'h2: out=8'h3a; 4'h3: out=8'h0a; 4'h4: out=8'h49; 4'h5: out=8'h06; 4'h6: out=8'h24; 4'h7: out=8'h5c; 4'h8: out=8'hc2; 4'h9: out=8'hd3; 4'ha: out=8'hac; 4'hb: out=8'h62; 4'hc: out=8'h91; 4'hd: out=8'h95; 4'he: out=8'he4; 4'hf: out=8'h79; endcase
            4'hb: case(in[3:0]) 4'h0: out=8'he7; 4'h1: out=8'hc8; 4'h2: out=8'h37; 4'h3: out=8'h6d; 4'h4: out=8'h8d; 4'h5: out=8'hd5; 4'h6: out=8'h4e; 4'h7: out=8'ha9; 4'h8: out=8'h6c; 4'h9: out=8'h56; 4'ha: out=8'hf4; 4'hb: out=8'hea; 4'hc: out=8'h65; 4'hd: out=8'h7a; 4'he: out=8'hae; 4'hf: out=8'h08; endcase
            4'hc: case(in[3:0]) 4'h0: out=8'hba; 4'h1: out=8'h78; 4'h2: out=8'h25; 4'h3: out=8'h2e; 4'h4: out=8'h1c; 4'h5: out=8'ha6; 4'h6: out=8'hb4; 4'h7: out=8'hc6; 4'h8: out=8'he8; 4'h9: out=8'hdd; 4'ha: out=8'h74; 4'hb: out=8'h1f; 4'hc: out=8'h4b; 4'hd: out=8'hbd; 4'he: out=8'h8b; 4'hf: out=8'h8a; endcase
            4'hd: case(in[3:0]) 4'h0: out=8'h70; 4'h1: out=8'h3e; 4'h2: out=8'hb5; 4'h3: out=8'h66; 4'h4: out=8'h48; 4'h5: out=8'h03; 4'h6: out=8'hf6; 4'h7: out=8'h0e; 4'h8: out=8'h61; 4'h9: out=8'h35; 4'ha: out=8'h57; 4'hb: out=8'hb9; 4'hc: out=8'h86; 4'hd: out=8'hc1; 4'he: out=8'h1d; 4'hf: out=8'h9e; endcase
            4'he: case(in[3:0]) 4'h0: out=8'he1; 4'h1: out=8'hf8; 4'h2: out=8'h98; 4'h3: out=8'h11; 4'h4: out=8'h69; 4'h5: out=8'hd9; 4'h6: out=8'h8e; 4'h7: out=8'h94; 4'h8: out=8'h9b; 4'h9: out=8'h1e; 4'ha: out=8'h87; 4'hb: out=8'he9; 4'hc: out=8'hce; 4'hd: out=8'h55; 4'he: out=8'h28; 4'hf: out=8'hdf; endcase
            4'hf: case(in[3:0]) 4'h0: out=8'h8c; 4'h1: out=8'ha1; 4'h2: out=8'h89; 4'h3: out=8'h0d; 4'h4: out=8'hbf; 4'h5: out=8'he6; 4'h6: out=8'h42; 4'h7: out=8'h68; 4'h8: out=8'h41; 4'h9: out=8'h99; 4'ha: out=8'h2d; 4'hb: out=8'h0f; 4'hc: out=8'hb0; 4'hd: out=8'h54; 4'he: out=8'hbb; 4'hf: out=8'h16; endcase
        endcase
    end
endmodule

module inv_sbox(input [7:0] in, output reg [7:0] out);
    always @(*) begin
        case (in[7:4])
            4'h0: case(in[3:0]) 4'h0: out=8'h52; 4'h1: out=8'h09; 4'h2: out=8'h6a; 4'h3: out=8'hd5; 4'h4: out=8'h30; 4'h5: out=8'h36; 4'h6: out=8'ha5; 4'h7: out=8'h38; 4'h8: out=8'hbf; 4'h9: out=8'h40; 4'ha: out=8'ha3; 4'hb: out=8'h9e; 4'hc: out=8'h81; 4'hd: out=8'hf3; 4'he: out=8'hd7; 4'hf: out=8'hfb; endcase
            4'h1: case(in[3:0]) 4'h0: out=8'h7c; 4'h1: out=8'he3; 4'h2: out=8'h39; 4'h3: out=8'h82; 4'h4: out=8'h9b; 4'h5: out=8'h2f; 4'h6: out=8'hff; 4'h7: out=8'h87; 4'h8: out=8'h34; 4'h9: out=8'h8e; 4'ha: out=8'h43; 4'hb: out=8'h44; 4'hc: out=8'hc4; 4'hd: out=8'hde; 4'he: out=8'he9; 4'hf: out=8'hcb; endcase
            4'h2: case(in[3:0]) 4'h0: out=8'h54; 4'h1: out=8'h7b; 4'h2: out=8'h94; 4'h3: out=8'h32; 4'h4: out=8'ha6; 4'h5: out=8'hc2; 4'h6: out=8'h23; 4'h7: out=8'h3d; 4'h8: out=8'hee; 4'h9: out=8'h4c; 4'ha: out=8'h95; 4'hb: out=8'h0b; 4'hc: out=8'h42; 4'hd: out=8'hfa; 4'he: out=8'hc3; 4'hf: out=8'h4e; endcase
            4'h3: case(in[3:0]) 4'h0: out=8'h08; 4'h1: out=8'h2e; 4'h2: out=8'ha1; 4'h3: out=8'h66; 4'h4: out=8'h28; 4'h5: out=8'hd9; 4'h6: out=8'h24; 4'h7: out=8'hb2; 4'h8: out=8'h76; 4'h9: out=8'h5b; 4'ha: out=8'ha2; 4'hb: out=8'h49; 4'hc: out=8'h6d; 4'hd: out=8'h8b; 4'he: out=8'hd1; 4'hf: out=8'h25; endcase
            4'h4: case(in[3:0]) 4'h0: out=8'h72; 4'h1: out=8'hf8; 4'h2: out=8'hf6; 4'h3: out=8'h64; 4'h4: out=8'h86; 4'h5: out=8'h68; 4'h6: out=8'h98; 4'h7: out=8'h16; 4'h8: out=8'hd4; 4'h9: out=8'ha4; 4'ha: out=8'h5c; 4'hb: out=8'hcc; 4'hc: out=8'h5d; 4'hd: out=8'h65; 4'he: out=8'hb6; 4'hf: out=8'h92; endcase
            4'h5: case(in[3:0]) 4'h0: out=8'h6c; 4'h1: out=8'h70; 4'h2: out=8'h48; 4'h3: out=8'h50; 4'h4: out=8'hfd; 4'h5: out=8'hed; 4'h6: out=8'hb9; 4'h7: out=8'hda; 4'h8: out=8'h5e; 4'h9: out=8'h15; 4'ha: out=8'h46; 4'hb: out=8'h57; 4'hc: out=8'ha7; 4'hd: out=8'h8d; 4'he: out=8'h9d; 4'hf: out=8'h84; endcase
            4'h6: case(in[3:0]) 4'h0: out=8'h90; 4'h1: out=8'hd8; 4'h2: out=8'hab; 4'h3: out=8'h00; 4'h4: out=8'h8c; 4'h5: out=8'hbc; 4'h6: out=8'hd3; 4'h7: out=8'h0a; 4'h8: out=8'hf7; 4'h9: out=8'he4; 4'ha: out=8'h58; 4'hb: out=8'h05; 4'hc: out=8'hb8; 4'hd: out=8'hb3; 4'he: out=8'h45; 4'hf: out=8'h06; endcase
            4'h7: case(in[3:0]) 4'h0: out=8'hd0; 4'h1: out=8'h2c; 4'h2: out=8'h1e; 4'h3: out=8'h8f; 4'h4: out=8'hca; 4'h5: out=8'h3f; 4'h6: out=8'h0f; 4'h7: out=8'h02; 4'h8: out=8'hc1; 4'h9: out=8'haf; 4'ha: out=8'hbd; 4'hb: out=8'h03; 4'hc: out=8'h01; 4'hd: out=8'h13; 4'he: out=8'h8a; 4'hf: out=8'h6b; endcase
            4'h8: case(in[3:0]) 4'h0: out=8'h3a; 4'h1: out=8'h91; 4'h2: out=8'h11; 4'h3: out=8'h41; 4'h4: out=8'h4f; 4'h5: out=8'h67; 4'h6: out=8'hdc; 4'h7: out=8'hea; 4'h8: out=8'h97; 4'h9: out=8'hf2; 4'ha: out=8'hcf; 4'hb: out=8'hce; 4'hc: out=8'hf0; 4'hd: out=8'hb4; 4'he: out=8'he6; 4'hf: out=8'h73; endcase
            4'h9: case(in[3:0]) 4'h0: out=8'h96; 4'h1: out=8'hac; 4'h2: out=8'h74; 4'h3: out=8'h22; 4'h4: out=8'he7; 4'h5: out=8'had; 4'h6: out=8'h35; 4'h7: out=8'h85; 4'h8: out=8'he2; 4'h9: out=8'hf9; 4'ha: out=8'h37; 4'hb: out=8'he8; 4'hc: out=8'h1c; 4'hd: out=8'h75; 4'he: out=8'hdf; 4'hf: out=8'h6e; endcase
            4'ha: case(in[3:0]) 4'h0: out=8'h47; 4'h1: out=8'hf1; 4'h2: out=8'h1a; 4'h3: out=8'h71; 4'h4: out=8'h1d; 4'h5: out=8'h29; 4'h6: out=8'hc5; 4'h7: out=8'h89; 4'h8: out=8'h6f; 4'h9: out=8'hb7; 4'ha: out=8'h62; 4'hb: out=8'h0e; 4'hc: out=8'haa; 4'hd: out=8'h18; 4'he: out=8'hbe; 4'hf: out=8'h1b; endcase
            4'hb: case(in[3:0]) 4'h0: out=8'hfc; 4'h1: out=8'h56; 4'h2: out=8'h3e; 4'h3: out=8'h4b; 4'h4: out=8'hc6; 4'h5: out=8'hd2; 4'h6: out=8'h79; 4'h7: out=8'h20; 4'h8: out=8'h9a; 4'h9: out=8'hdb; 4'ha: out=8'hc0; 4'hb: out=8'hfe; 4'hc: out=8'h78; 4'hd: out=8'hcd; 4'he: out=8'h5a; 4'hf: out=8'hf4; endcase
            4'hc: case(in[3:0]) 4'h0: out=8'h1f; 4'h1: out=8'hdd; 4'h2: out=8'ha8; 4'h3: out=8'h33; 4'h4: out=8'h88; 4'h5: out=8'h07; 4'h6: out=8'hc7; 4'h7: out=8'h31; 4'h8: out=8'hb1; 4'h9: out=8'h12; 4'ha: out=8'h10; 4'hb: out=8'h59; 4'hc: out=8'h27; 4'hd: out=8'h80; 4'he: out=8'hec; 4'hf: out=8'h5f; endcase
            4'hd: case(in[3:0]) 4'h0: out=8'h60; 4'h1: out=8'h51; 4'h2: out=8'h7f; 4'h3: out=8'ha9; 4'h4: out=8'h19; 4'h5: out=8'hb5; 4'h6: out=8'h4a; 4'h7: out=8'h0d; 4'h8: out=8'h2d; 4'h9: out=8'he5; 4'ha: out=8'h7a; 4'hb: out=8'h9f; 4'hc: out=8'h93; 4'hd: out=8'hc9; 4'he: out=8'h9c; 4'hf: out=8'hef; endcase
            4'he: case(in[3:0]) 4'h0: out=8'ha0; 4'h1: out=8'he0; 4'h2: out=8'h3b; 4'h3: out=8'h4d; 4'h4: out=8'hae; 4'h5: out=8'h2a; 4'h6: out=8'hf5; 4'h7: out=8'hb0; 4'h8: out=8'hc8; 4'h9: out=8'heb; 4'ha: out=8'hbb; 4'hb: out=8'h3c; 4'hc: out=8'h83; 4'hd: out=8'h53; 4'he: out=8'h99; 4'hf: out=8'h61; endcase
            4'hf: case(in[3:0]) 4'h0: out=8'h17; 4'h1: out=8'h2b; 4'h2: out=8'h04; 4'h3: out=8'h7e; 4'h4: out=8'hba; 4'h5: out=8'h77; 4'h6: out=8'hd6; 4'h7: out=8'h26; 4'h8: out=8'he1; 4'h9: out=8'h69; 4'ha: out=8'h14; 4'hb: out=8'h63; 4'hc: out=8'h55; 4'hd: out=8'h21; 4'he: out=8'h0c; 4'hf: out=8'h7d; endcase
        endcase
    end
endmodule

// ============================================================================
// AES SHIFTROWS & MIXCOLUMNS
// ============================================================================
module aes_shiftrows_128(input [127:0] in, output [127:0] out);
    assign out[127:120] = in[127:120]; assign out[119:112] = in[87:80];
    assign out[111:104] = in[47:40];   assign out[103:96]  = in[7:0];
    assign out[95:88]   = in[95:88];   assign out[87:80]   = in[55:48];
    assign out[79:72]   = in[15:8];    assign out[71:64]   = in[103:96];
    assign out[63:56]   = in[63:56];   assign out[55:48]   = in[23:16];
    assign out[47:40]   = in[111:104]; assign out[39:32]   = in[71:64];
    assign out[31:24]   = in[31:24];   assign out[23:16]   = in[119:112];
    assign out[15:8]    = in[79:72];   assign out[7:0]     = in[39:32];
endmodule

module aes_inv_shiftrows_128(input [127:0] in, output [127:0] out);
    assign out[127:120] = in[127:120]; assign out[119:112] = in[23:16];
    assign out[111:104] = in[47:40];   assign out[103:96]  = in[71:64];
    assign out[95:88]   = in[95:88];   assign out[87:80]   = in[119:112];
    assign out[79:72]   = in[15:8];    assign out[71:64]   = in[39:32];
    assign out[63:56]   = in[63:56];   assign out[55:48]   = in[87:80];
    assign out[47:40]   = in[111:104]; assign out[39:32]   = in[7:0];
    assign out[31:24]   = in[31:24];   assign out[23:16]   = in[55:48];
    assign out[15:8]    = in[79:72];   assign out[7:0]     = in[103:96];
endmodule

module aes_mixcolumns_128(input [127:0] in, output [127:0] out);
    function [7:0] xtime(input [7:0] a); xtime = {a[6:0], 1'b0} ^ (8'h1b & {8{a[7]}}); endfunction
    genvar c;
    generate
        for (c=0; c<4; c=c+1) begin: G_MC
            wire [7:0] s0 = in[8*(15 - (c*4 + 0)) +: 8];
            wire [7:0] s1 = in[8*(15 - (c*4 + 1)) +: 8];
            wire [7:0] s2 = in[8*(15 - (c*4 + 2)) +: 8];
            wire [7:0] s3 = in[8*(15 - (c*4 + 3)) +: 8];
            assign out[8*(15 - (c*4 + 0)) +: 8] = xtime(s0) ^ (xtime(s1) ^ s1) ^ s2 ^ s3;
            assign out[8*(15 - (c*4 + 1)) +: 8] = s0 ^ xtime(s1) ^ (xtime(s2) ^ s2) ^ s3;
            assign out[8*(15 - (c*4 + 2)) +: 8] = s0 ^ s1 ^ xtime(s2) ^ (xtime(s3) ^ s3);
            assign out[8*(15 - (c*4 + 3)) +: 8] = (xtime(s0) ^ s0) ^ s1 ^ s2 ^ xtime(s3);
        end
    endgenerate
endmodule

module aes_inv_mixcolumns_128(input [127:0] in, output [127:0] out);
    function [7:0] xtime(input [7:0] a); xtime = {a[6:0], 1'b0} ^ (8'h1b & {8{a[7]}}); endfunction
    function [7:0] mul2(input [7:0] a);  mul2 = xtime(a); endfunction
    function [7:0] mul4(input [7:0] a);  mul4 = mul2(mul2(a)); endfunction
    function [7:0] mul8(input [7:0] a);  mul8 = mul2(mul4(a)); endfunction
    function [7:0] mul9(input [7:0] a);  mul9 = mul8(a) ^ a; endfunction
    function [7:0] mul11(input [7:0] a); mul11 = mul8(a) ^ mul2(a) ^ a; endfunction
    function [7:0] mul13(input [7:0] a); mul13 = mul8(a) ^ mul4(a) ^ a; endfunction
    function [7:0] mul14(input [7:0] a); mul14 = mul8(a) ^ mul4(a) ^ mul2(a); endfunction
    genvar c;
    generate
        for (c=0; c<4; c=c+1) begin: G_IMC
            wire [7:0] s0 = in[8*(15 - (c*4 + 0)) +: 8];
            wire [7:0] s1 = in[8*(15 - (c*4 + 1)) +: 8];
            wire [7:0] s2 = in[8*(15 - (c*4 + 2)) +: 8];
            wire [7:0] s3 = in[8*(15 - (c*4 + 3)) +: 8];
            assign out[8*(15 - (c*4 + 0)) +: 8] = mul14(s0) ^ mul11(s1) ^ mul13(s2) ^ mul9(s3);
            assign out[8*(15 - (c*4 + 1)) +: 8] = mul9(s0)  ^ mul14(s1) ^ mul11(s2) ^ mul13(s3);
            assign out[8*(15 - (c*4 + 2)) +: 8] = mul13(s0) ^ mul9(s1)  ^ mul14(s2) ^ mul11(s3);
            assign out[8*(15 - (c*4 + 3)) +: 8] = mul11(s0) ^ mul13(s1) ^ mul9(s2)  ^ mul14(s3);
        end
    endgenerate
endmodule

// ============================================================================
// UART RECEIVER & TRANSMITTER (50 MHz, 115200 Baud)
// ============================================================================
module uart_rx #(parameter CLK_FREQ=50000000, parameter BAUD_RATE=115200)(
    input            clk,
    input            rst_n,
    input            rx,
    output reg [7:0] data_out,
    output reg       valid,
    input            ready
);
    localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;
    localparam S_IDLE=0, S_START=1, S_DATA=2, S_STOP=3;

    reg [1:0]  state = S_IDLE;
    reg [15:0] clk_cnt = 0;
    reg [2:0]  bit_idx = 0;
    reg [7:0]  rx_shifter = 0;
    reg        rx_sync1 = 1, rx_sync2 = 1;

    always @(posedge clk) begin
        rx_sync1 <= rx;
        rx_sync2 <= rx_sync1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            clk_cnt <= 0;
            bit_idx <= 0;
            data_out <= 0;
            valid <= 0;
        end else begin
            if (valid && ready) valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    clk_cnt <= 0;
                    bit_idx <= 0;
                    if (!rx_sync2) state <= S_START;
                end
                S_START: begin
                    if (clk_cnt == (CLKS_PER_BIT / 2)) begin
                        if (!rx_sync2) begin
                            clk_cnt <= 0;
                            state <= S_DATA;
                        end else state <= S_IDLE;
                    end else clk_cnt <= clk_cnt + 1;
                end
                S_DATA: begin
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= 0;
                        rx_shifter[bit_idx] <= rx_sync2;
                        if (bit_idx == 7) state <= S_STOP;
                        else bit_idx <= bit_idx + 1;
                    end else clk_cnt <= clk_cnt + 1;
                end
                S_STOP: begin
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= 0;
                        data_out <= rx_shifter;
                        valid <= 1'b1;
                        state <= S_IDLE;
                    end else clk_cnt <= clk_cnt + 1;
                end
            endcase
        end
    end
endmodule

module uart_tx #(parameter CLK_FREQ=50000000, parameter BAUD_RATE=115200)(
    input        clk,
    input        rst_n,
    input        tx_start,
    input  [7:0] data_in,
    output reg   tx,
    output reg   busy
);
    localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;
    localparam S_IDLE=0, S_START=1, S_DATA=2, S_STOP=3;

    reg [1:0]  state = S_IDLE;
    reg [15:0] clk_cnt = 0;
    reg [2:0]  bit_idx = 0;
    reg [7:0]  tx_data_reg = 0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            tx <= 1'b1;
            busy <= 1'b0;
            clk_cnt <= 0;
            bit_idx <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    tx <= 1'b1;
                    clk_cnt <= 0;
                    bit_idx <= 0;
                    if (tx_start) begin
                        busy <= 1'b1;
                        tx_data_reg <= data_in;
                        state <= S_START;
                    end else busy <= 1'b0;
                end
                S_START: begin
                    tx <= 1'b0;
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= 0;
                        state <= S_DATA;
                    end else clk_cnt <= clk_cnt + 1;
                end
                S_DATA: begin
                    tx <= tx_data_reg[bit_idx];
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= 0;
                        if (bit_idx == 7) state <= S_STOP;
                        else bit_idx <= bit_idx + 1;
                    end else clk_cnt <= clk_cnt + 1;
                end
                S_STOP: begin
                    tx <= 1'b1;
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= 0;
                        state <= S_IDLE;
                    end else clk_cnt <= clk_cnt + 1;
                end
            endcase
        end
    end
endmodule