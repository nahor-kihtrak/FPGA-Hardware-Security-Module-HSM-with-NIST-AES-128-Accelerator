## Clock signal (50 MHz)
set_property -dict { PACKAGE_PIN N11    IOSTANDARD LVCMOS33 } [get_ports { clk }];
create_clock -add -name sys_clk_pin -period 20.00 -waveform {0 10} [get_ports { clk }];

## USB UART (C4 = TXD to PC, D4 = RXD from PC)
set_property -dict { PACKAGE_PIN C4 IOSTANDARD LVCMOS33 } [get_ports { usb_uart_txd }]; # TX to PC
set_property -dict { PACKAGE_PIN D4 IOSTANDARD LVCMOS33 } [get_ports { usb_uart_rxd }]; # RX from PC

## Push Buttons (pb[0] = Top Reset button)
set_property -dict { PACKAGE_PIN K13 IOSTANDARD LVCMOS33 PULLDOWN true } [get_ports { pb[0] }];
set_property -dict { PACKAGE_PIN L14 IOSTANDARD LVCMOS33 PULLDOWN true } [get_ports { pb[1] }];
set_property -dict { PACKAGE_PIN M12 IOSTANDARD LVCMOS33 PULLDOWN true } [get_ports { pb[2] }];
set_property -dict { PACKAGE_PIN L13 IOSTANDARD LVCMOS33 PULLDOWN true } [get_ports { pb[3] }];
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 PULLDOWN true } [get_ports { pb[4] }];

## 16 Slide Switches
set_property -dict { PACKAGE_PIN L5  IOSTANDARD LVCMOS33 } [get_ports { sw[0] }];
set_property -dict { PACKAGE_PIN L4  IOSTANDARD LVCMOS33 } [get_ports { sw[1] }];
set_property -dict { PACKAGE_PIN M4  IOSTANDARD LVCMOS33 } [get_ports { sw[2] }];
set_property -dict { PACKAGE_PIN M2  IOSTANDARD LVCMOS33 } [get_ports { sw[3] }];
set_property -dict { PACKAGE_PIN M1  IOSTANDARD LVCMOS33 } [get_ports { sw[4] }];
set_property -dict { PACKAGE_PIN N3  IOSTANDARD LVCMOS33 } [get_ports { sw[5] }];
set_property -dict { PACKAGE_PIN N2  IOSTANDARD LVCMOS33 } [get_ports { sw[6] }];
set_property -dict { PACKAGE_PIN N1  IOSTANDARD LVCMOS33 } [get_ports { sw[7] }];
set_property -dict { PACKAGE_PIN P1  IOSTANDARD LVCMOS33 } [get_ports { sw[8] }];
set_property -dict { PACKAGE_PIN P4  IOSTANDARD LVCMOS33 } [get_ports { sw[9] }];
set_property -dict { PACKAGE_PIN T8  IOSTANDARD LVCMOS33 } [get_ports { sw[10] }];
set_property -dict { PACKAGE_PIN R8  IOSTANDARD LVCMOS33 } [get_ports { sw[11] }];
set_property -dict { PACKAGE_PIN N6  IOSTANDARD LVCMOS33 } [get_ports { sw[12] }];
set_property -dict { PACKAGE_PIN T7  IOSTANDARD LVCMOS33 } [get_ports { sw[13] }];
set_property -dict { PACKAGE_PIN P8  IOSTANDARD LVCMOS33 } [get_ports { sw[14] }];
set_property -dict { PACKAGE_PIN M6  IOSTANDARD LVCMOS33 } [get_ports { sw[15] }];

## 16 LEDs
set_property -dict { PACKAGE_PIN J3  IOSTANDARD LVCMOS33 } [get_ports { led[0] }];
set_property -dict { PACKAGE_PIN H3  IOSTANDARD LVCMOS33 } [get_ports { led[1] }];
set_property -dict { PACKAGE_PIN J1  IOSTANDARD LVCMOS33 } [get_ports { led[2] }];
set_property -dict { PACKAGE_PIN K1  IOSTANDARD LVCMOS33 } [get_ports { led[3] }];
set_property -dict { PACKAGE_PIN L3  IOSTANDARD LVCMOS33 } [get_ports { led[4] }];
set_property -dict { PACKAGE_PIN L2  IOSTANDARD LVCMOS33 } [get_ports { led[5] }];
set_property -dict { PACKAGE_PIN K3  IOSTANDARD LVCMOS33 } [get_ports { led[6] }];
set_property -dict { PACKAGE_PIN K2  IOSTANDARD LVCMOS33 } [get_ports { led[7] }];
set_property -dict { PACKAGE_PIN K5  IOSTANDARD LVCMOS33 } [get_ports { led[8] }];
set_property -dict { PACKAGE_PIN P6  IOSTANDARD LVCMOS33 } [get_ports { led[9] }];
set_property -dict { PACKAGE_PIN R7  IOSTANDARD LVCMOS33 } [get_ports { led[10] }];
set_property -dict { PACKAGE_PIN R6  IOSTANDARD LVCMOS33 } [get_ports { led[11] }];
set_property -dict { PACKAGE_PIN T5  IOSTANDARD LVCMOS33 } [get_ports { led[12] }];
set_property -dict { PACKAGE_PIN R5  IOSTANDARD LVCMOS33 } [get_ports { led[13] }];
set_property -dict { PACKAGE_PIN T10 IOSTANDARD LVCMOS33 } [get_ports { led[14] }];
set_property -dict { PACKAGE_PIN T9  IOSTANDARD LVCMOS33 } [get_ports { led[15] }];

## 7-Segment Display
set_property -dict { PACKAGE_PIN F2  IOSTANDARD LVCMOS33 } [get_ports { digit[0] }];
set_property -dict { PACKAGE_PIN E1  IOSTANDARD LVCMOS33 } [get_ports { digit[1] }];
set_property -dict { PACKAGE_PIN G5  IOSTANDARD LVCMOS33 } [get_ports { digit[2] }];
set_property -dict { PACKAGE_PIN G4  IOSTANDARD LVCMOS33 } [get_ports { digit[3] }];

set_property -dict { PACKAGE_PIN G2  IOSTANDARD LVCMOS33 } [get_ports { Seven_Seg[0] }]; # A
set_property -dict { PACKAGE_PIN G1  IOSTANDARD LVCMOS33 } [get_ports { Seven_Seg[1] }]; # B
set_property -dict { PACKAGE_PIN H5  IOSTANDARD LVCMOS33 } [get_ports { Seven_Seg[2] }]; # C
set_property -dict { PACKAGE_PIN H4  IOSTANDARD LVCMOS33 } [get_ports { Seven_Seg[3] }]; # D
set_property -dict { PACKAGE_PIN J5  IOSTANDARD LVCMOS33 } [get_ports { Seven_Seg[4] }]; # E
set_property -dict { PACKAGE_PIN J4  IOSTANDARD LVCMOS33 } [get_ports { Seven_Seg[5] }]; # F
set_property -dict { PACKAGE_PIN H2  IOSTANDARD LVCMOS33 } [get_ports { Seven_Seg[6] }]; # G
set_property -dict { PACKAGE_PIN H1  IOSTANDARD LVCMOS33 } [get_ports { Seven_Seg[7] }]; # DP

## 2x16 LCD Display
set_property -dict { PACKAGE_PIN P3 IOSTANDARD LVCMOS33 } [get_ports { lcd_data[7] }];
set_property -dict { PACKAGE_PIN M5 IOSTANDARD LVCMOS33 } [get_ports { lcd_data[6] }];
set_property -dict { PACKAGE_PIN N4 IOSTANDARD LVCMOS33 } [get_ports { lcd_data[5] }];
set_property -dict { PACKAGE_PIN R2 IOSTANDARD LVCMOS33 } [get_ports { lcd_data[4] }];
set_property -dict { PACKAGE_PIN R1 IOSTANDARD LVCMOS33 } [get_ports { lcd_data[3] }];
set_property -dict { PACKAGE_PIN R3 IOSTANDARD LVCMOS33 } [get_ports { lcd_data[2] }];
set_property -dict { PACKAGE_PIN T2 IOSTANDARD LVCMOS33 } [get_ports { lcd_data[1] }];
set_property -dict { PACKAGE_PIN T4 IOSTANDARD LVCMOS33 } [get_ports { lcd_data[0] }];
set_property -dict { PACKAGE_PIN T3 IOSTANDARD LVCMOS33 } [get_ports { lcd_e }];
set_property -dict { PACKAGE_PIN P5 IOSTANDARD LVCMOS33 } [get_ports { lcd_rs }];

set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]