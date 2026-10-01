"""
===============================================================================
NIST FIPS-197 AES-128 Cryptographic Co-Processor Host Interface
Target Platform: AMD-Xilinx Artix-7 FPGA (XC7A35T) | Protocol: 115200 Baud UART
===============================================================================
"""

import tkinter as tk
from tkinter import ttk, filedialog, messagebox
import serial
import serial.tools.list_ports
import threading
import time
import os
import secrets
import subprocess

# ============================================================================
# SCIENTIFIC / INSTRUMENTATION COLOR PALETTE (Light High-Contrast Theme)
# ============================================================================
BG_MAIN       = "#F1F5F9"  # Slate 100
PANEL_BG      = "#FFFFFF"  # Clean White
TEXT_PRIMARY  = "#0F172A"  # Slate 900
TEXT_MUTED    = "#475569"  # Slate 600
ACCENT_BLUE   = "#1D4ED8"  # IEEE Steel Blue
ACCENT_GREEN  = "#047857"  # Laboratory Emerald
ACCENT_RED    = "#B91C1C"  # Calibration Red
ACCENT_AMBER  = "#B45309"  # Warning Amber
TERMINAL_BG   = "#0F172A"  # Monospace Dark Terminal
TERMINAL_FG   = "#E2E8F0"  # Monospace White

FONT_TITLE    = ("Segoe UI", 10, "bold")
FONT_REGULAR  = ("Segoe UI", 9)
FONT_BOLD     = ("Segoe UI", 9, "bold")
FONT_MONO     = ("Consolas", 10)
FONT_LOG      = ("Consolas", 9)

NIST_KEY_HEX  = "000102030405060708090A0B0C0D0E0F"
NIST_PT_HEX   = "00112233445566778899AABBCCDDEEFF"
NIST_EXP_CT   = "69C4E0D86A7B0430D8CDB78070B4C55A"


class ScientificHSMApp:
    def __init__(self, root):
        self.root = root
        self.root.title("NIST FIPS-197 AES-128 FPGA Hardware Co-Processor Interface")
        self.root.geometry("1020x780")
        self.root.minsize(960, 720)
        self.root.configure(bg=BG_MAIN)

        self.ser = None
        self.is_connected = False
        self.total_processed_blocks = 0
        self.selected_file_path = None

        self.setup_styles()
        self.build_ui()
        self.refresh_ports()

    def setup_styles(self):
        self.style = ttk.Style()
        self.style.theme_use("clam")

        self.style.configure("TNotebook", background=BG_MAIN, borderwidth=0)
        self.style.configure("TNotebook.Tab", background="#E2E8F0", foreground=TEXT_MUTED,
                             font=FONT_BOLD, padding=[16, 6], borderwidth=1, relief="flat")
        self.style.map("TNotebook.Tab",
                       background=[("selected", PANEL_BG)],
                       foreground=[("selected", ACCENT_BLUE)])

        self.style.configure("TProgressbar", thickness=6, troughcolor="#E2E8F0",
                             background=ACCENT_BLUE, borderwidth=0)

    def build_ui(self):
        # 1. Institutional Header
        hdr_frame = tk.Frame(self.root, bg=PANEL_BG, bd=1, relief="solid", highlightthickness=0)
        hdr_frame.pack(fill="x", padx=16, pady=(12, 6))

        hdr_inner = tk.Frame(hdr_frame, bg=PANEL_BG, padx=14, pady=10)
        hdr_inner.pack(fill="x")

        title_box = tk.Frame(hdr_inner, bg=PANEL_BG)
        title_box.pack(side="left")

        tk.Label(title_box, text="NIST FIPS-197 AES-128 Cryptographic Co-Processor Interface",
                 font=("Segoe UI", 12, "bold"), fg=TEXT_PRIMARY, bg=PANEL_BG).pack(anchor="w")
        tk.Label(title_box, text="Hardware Security Module Evaluation Suite | Target: Artix-7 FPGA (50.00 MHz)",
                 font=("Segoe UI", 8), fg=TEXT_MUTED, bg=PANEL_BG).pack(anchor="w", pady=(2, 0))

        conn_box = tk.Frame(hdr_inner, bg=PANEL_BG)
        conn_box.pack(side="right")

        tk.Label(conn_box, text="Port:", font=FONT_BOLD, fg=TEXT_MUTED, bg=PANEL_BG).pack(side="left", padx=4)
        self.cb_ports = ttk.Combobox(conn_box, width=12, state="readonly", font=FONT_MONO)
        self.cb_ports.pack(side="left", padx=4)

        btn_refresh = tk.Button(conn_box, text="Refresh", font=FONT_REGULAR, bg=BG_MAIN, fg=TEXT_PRIMARY,
                                bd=1, relief="solid", padx=8, pady=2, cursor="hand2", command=self.refresh_ports)
        btn_refresh.pack(side="left", padx=4)

        self.btn_connect = tk.Button(conn_box, text="Connect Device", font=FONT_BOLD, bg=ACCENT_BLUE, fg="#FFFFFF",
                                     bd=0, padx=14, pady=4, cursor="hand2", command=self.toggle_connection)
        self.btn_connect.pack(side="left", padx=8)

        self.lbl_status_badge = tk.Label(conn_box, text="OFFLINE", font=("Segoe UI", 8, "bold"),
                                         fg="#FFFFFF", bg=ACCENT_RED, padx=8, pady=2)
        self.lbl_status_badge.pack(side="left", padx=4)

        # 2. Telemetry Cards
        telemetry_frame = tk.Frame(self.root, bg=BG_MAIN)
        telemetry_frame.pack(fill="x", padx=16, pady=4)

        self.card_status  = self.create_telemetry_card(telemetry_frame, "CO-PROCESSOR STATE", "DISCONNECTED", ACCENT_RED, 0)
        self.card_engine  = self.create_telemetry_card(telemetry_frame, "CORE SPECIFICATION", "10-Round FIPS-197", TEXT_PRIMARY, 1)
        self.card_blocks  = self.create_telemetry_card(telemetry_frame, "BLOCKS PROCESSED", "0 Blocks (0 Bytes)", ACCENT_BLUE, 2)
        self.card_rate    = self.create_telemetry_card(telemetry_frame, "EFFECTIVE BANDWIDTH", "0.00 KB/s", ACCENT_GREEN, 3)

        # 3. Key Management
        key_panel = tk.Frame(self.root, bg=PANEL_BG, bd=1, relief="solid", highlightthickness=0)
        key_panel.pack(fill="x", padx=16, pady=6)

        k_inner = tk.Frame(key_panel, bg=PANEL_BG, padx=14, pady=8)
        k_inner.pack(fill="x")

        tk.Label(k_inner, text="Cipher Key (128-Bit Hex):", font=FONT_BOLD,
                 fg=TEXT_PRIMARY, bg=PANEL_BG).pack(side="left", padx=(0, 8))

        self.entry_key = tk.Entry(k_inner, font=FONT_MONO, bg="#F8FAFC", fg=TEXT_PRIMARY,
                                  bd=1, relief="solid", width=36)
        self.entry_key.insert(0, NIST_KEY_HEX)
        self.entry_key.pack(side="left", ipady=3, padx=4)

        btn_nist_key = tk.Button(k_inner, text="NIST Vector Key", font=FONT_REGULAR, bg=BG_MAIN, fg=TEXT_PRIMARY,
                                 bd=1, relief="solid", padx=8, pady=2, cursor="hand2", command=self.load_nist_key)
        btn_nist_key.pack(side="left", padx=4)

        btn_rand_key = tk.Button(k_inner, text="Generate Random", font=FONT_REGULAR, bg=BG_MAIN, fg=TEXT_PRIMARY,
                                 bd=1, relief="solid", padx=8, pady=2, cursor="hand2", command=self.generate_random_key)
        btn_rand_key.pack(side="left", padx=4)

        btn_burn = tk.Button(k_inner, text="Program Key to FPGA", font=FONT_BOLD, bg=ACCENT_AMBER, fg="#FFFFFF",
                             bd=0, padx=12, pady=3, cursor="hand2", command=self.burn_key_to_fpga)
        btn_burn.pack(side="right", padx=4)

        # 4. Tabs
        notebook = ttk.Notebook(self.root)
        notebook.pack(fill="both", expand=True, padx=16, pady=4)

        tab_vector = tk.Frame(notebook, bg=PANEL_BG, bd=1, relief="solid")
        tab_file   = tk.Frame(notebook, bg=PANEL_BG, bd=1, relief="solid")

        notebook.add(tab_vector, text=" Vector Cryptography & Evaluation ")
        notebook.add(tab_file,   text=" Binary Payload & File Vault ")

        self.build_vector_tab(tab_vector)
        self.build_file_tab(tab_file)

        # 5. Log Terminal
        log_panel = tk.Frame(self.root, bg=PANEL_BG, bd=1, relief="solid", height=130)
        log_panel.pack(fill="x", side="bottom", padx=16, pady=(4, 12))

        log_hdr = tk.Frame(log_panel, bg=PANEL_BG, padx=10, pady=4)
        log_hdr.pack(fill="x")

        tk.Label(log_hdr, text="Serial Bus Frame Analyzer & Execution Log", font=FONT_BOLD,
                 fg=TEXT_MUTED, bg=PANEL_BG).pack(side="left")

        btn_clear_log = tk.Button(log_hdr, text="Clear Console", font=("Segoe UI", 8), bg=BG_MAIN, fg=TEXT_MUTED,
                                  bd=1, relief="solid", padx=6, pady=1, cursor="hand2", command=self.clear_log)
        btn_clear_log.pack(side="right")

        self.txt_log = tk.Text(log_panel, height=5, font=FONT_LOG, bg=TERMINAL_BG, fg=TERMINAL_FG,
                               bd=0, relief="flat", wrap="word", insertbackground="#FFFFFF")
        self.txt_log.pack(fill="both", expand=True, padx=8, pady=(0, 6))

        self.txt_log.tag_config("info", foreground="#60A5FA")
        self.txt_log.tag_config("success", foreground="#34D399")
        self.txt_log.tag_config("warn", foreground="#FBBF24")
        self.txt_log.tag_config("error", foreground="#F87171")
        self.txt_log.tag_config("tx", foreground="#C084FC")

        self.log("Laboratory Suite Initialized. Ready to connect to FPGA Hardware Co-Processor.", "info")

    def create_telemetry_card(self, parent, title, initial_val, color, col_idx):
        card = tk.Frame(parent, bg=PANEL_BG, bd=1, relief="solid", padx=12, pady=8)
        card.pack(side="left", fill="both", expand=True, padx=4 if col_idx != 0 else 0)

        lbl_t = tk.Label(card, text=title, font=("Segoe UI", 7, "bold"), fg=TEXT_MUTED, bg=PANEL_BG)
        lbl_t.pack(anchor="w")

        lbl_v = tk.Label(card, text=initial_val, font=("Segoe UI", 10, "bold"), fg=color, bg=PANEL_BG)
        lbl_v.pack(anchor="w", pady=(2, 0))
        return lbl_v

    def build_vector_tab(self, parent):
        pane = tk.Frame(parent, bg=PANEL_BG, padx=16, pady=12)
        pane.pack(fill="both", expand=True)

        cols = tk.Frame(pane, bg=PANEL_BG)
        cols.pack(fill="both", expand=True)

        left = tk.Frame(cols, bg=PANEL_BG)
        left.pack(side="left", fill="both", expand=True, padx=(0, 8))

        lbl_p = tk.Frame(left, bg=PANEL_BG)
        lbl_p.pack(fill="x", pady=(0, 4))
        tk.Label(lbl_p, text="Input Plaintext (ASCII / UTF-8):", font=FONT_BOLD,
                 fg=TEXT_PRIMARY, bg=PANEL_BG).pack(side="left")

        self.txt_plain = tk.Text(left, height=8, font=FONT_MONO, bg="#F8FAFC", fg=TEXT_PRIMARY,
                                 bd=1, relief="solid", padx=8, pady=6)
        self.txt_plain.insert("1.0", "Hello from RISC-V Hardware Security Module!")
        self.txt_plain.pack(fill="both", expand=True)

        right = tk.Frame(cols, bg=PANEL_BG)
        right.pack(side="right", fill="both", expand=True, padx=(8, 0))

        lbl_c = tk.Frame(right, bg=PANEL_BG)
        lbl_c.pack(fill="x", pady=(0, 4))
        tk.Label(lbl_c, text="Output Ciphertext (Hexadecimal Bytes):", font=FONT_BOLD,
                 fg=ACCENT_BLUE, bg=PANEL_BG).pack(side="left")

        self.txt_cipher = tk.Text(right, height=8, font=FONT_MONO, bg="#F8FAFC", fg=ACCENT_BLUE,
                                  bd=1, relief="solid", padx=8, pady=6)
        self.txt_cipher.pack(fill="both", expand=True)

        btn_bar = tk.Frame(pane, bg=PANEL_BG)
        btn_bar.pack(fill="x", pady=(10, 0))

        btn_enc = tk.Button(btn_bar, text="Execute Encryption (FPGA)", font=FONT_BOLD,
                            bg=ACCENT_BLUE, fg="#FFFFFF", bd=0, padx=16, pady=6,
                            cursor="hand2", command=self.encrypt_text)
        btn_enc.pack(side="left", padx=(0, 8))

        btn_dec = tk.Button(btn_bar, text="Execute Decryption (FPGA)", font=FONT_BOLD,
                            bg=ACCENT_GREEN, fg="#FFFFFF", bd=0, padx=16, pady=6,
                            cursor="hand2", command=self.decrypt_text)
        btn_dec.pack(side="left", padx=8)

        btn_nist = tk.Button(btn_bar, text="Run NIST Golden Test Vector", font=FONT_REGULAR,
                             bg=BG_MAIN, fg=TEXT_PRIMARY, bd=1, relief="solid", padx=12, pady=5,
                             cursor="hand2", command=self.run_nist_validation)
        btn_nist.pack(side="left", padx=12)

        btn_copy = tk.Button(btn_bar, text="Copy Ciphertext", font=FONT_REGULAR,
                             bg=BG_MAIN, fg=TEXT_PRIMARY, bd=1, relief="solid", padx=10, pady=5,
                             cursor="hand2", command=self.copy_cipher_to_clipboard)
        btn_copy.pack(side="right")

    def build_file_tab(self, parent):
        pane = tk.Frame(parent, bg=PANEL_BG, padx=20, pady=16)
        pane.pack(fill="both", expand=True)

        tk.Label(pane, text="Select Target File (PDF, Images, Documents, Binary) for Hardware Encryption:",
                 font=FONT_BOLD, fg=TEXT_PRIMARY, bg=PANEL_BG).pack(anchor="w")

        f_select = tk.Frame(pane, bg=PANEL_BG)
        f_select.pack(fill="x", pady=(8, 14))

        self.lbl_file_path = tk.Label(f_select, text="No file selected...", font=FONT_MONO,
                                      fg=TEXT_MUTED, bg="#F8FAFC", bd=1, relief="solid", anchor="w", padx=10, pady=6)
        self.lbl_file_path.pack(side="left", fill="x", expand=True, padx=(0, 8))

        btn_browse = tk.Button(f_select, text="Browse File...", font=FONT_REGULAR, bg=BG_MAIN, fg=TEXT_PRIMARY,
                               bd=1, relief="solid", padx=14, pady=5, cursor="hand2", command=self.select_file)
        btn_browse.pack(side="right")

        act_bar = tk.Frame(pane, bg=PANEL_BG)
        act_bar.pack(fill="x", pady=8)

        btn_enc_file = tk.Button(act_bar, text="🔒 Encrypt File (Creates .enc)", font=FONT_BOLD,
                                 bg=ACCENT_BLUE, fg="#FFFFFF", bd=0, padx=18, pady=8,
                                 cursor="hand2", command=lambda: self.process_file(mode='enc'))
        btn_enc_file.pack(side="left", padx=(0, 10))

        btn_dec_file = tk.Button(act_bar, text="🔓 Decrypt .enc File (Restores Original)", font=FONT_BOLD,
                                 bg=ACCENT_GREEN, fg="#FFFFFF", bd=0, padx=18, pady=8,
                                 cursor="hand2", command=lambda: self.process_file(mode='dec'))
        btn_dec_file.pack(side="left", padx=10)

        prog_box = tk.Frame(pane, bg=PANEL_BG)
        prog_box.pack(fill="x", pady=(16, 0))

        self.lbl_progress_status = tk.Label(prog_box, text="Status: Ready", font=FONT_BOLD,
                                            fg=TEXT_MUTED, bg=PANEL_BG)
        self.lbl_progress_status.pack(anchor="w", pady=(0, 4))

        self.progress_bar = ttk.Progressbar(prog_box, orient="horizontal", mode="determinate")
        self.progress_bar.pack(fill="x", ipady=2)

    def read_exact(self, count, timeout=1.5):
        buf = bytearray()
        t0 = time.time()
        while len(buf) < count:
            needed = count - len(buf)
            chunk = self.ser.read(needed)
            if chunk:
                buf.extend(chunk)
            elif (time.time() - t0) > timeout:
                break
        return bytes(buf)

    def refresh_ports(self):
        ports = [p.device for p in serial.tools.list_ports.comports()]
        self.cb_ports['values'] = ports
        if ports:
            self.cb_ports.current(0)
            self.log(f"Enumerated COM ports: {', '.join(ports)}", "info")

    def toggle_connection(self):
        if not self.is_connected:
            port = self.cb_ports.get()
            if not port:
                messagebox.showerror("Configuration Error", "Please specify a valid COM port.")
                return
            try:
                self.ser = serial.Serial(port, 115200, timeout=0.5, write_timeout=0.5)
                self.ser.dtr = False
                self.ser.rts = False
                time.sleep(0.05)
                self.ser.reset_input_buffer()
                self.ser.reset_output_buffer()

                self.log(f"Transmitting Diagnostic Ping (0x04) to {port}...", "tx")
                self.ser.write(b'\x04')
                resp = self.read_exact(1, timeout=1.0)

                if resp == b'\x55':
                    self.is_connected = True
                    self.btn_connect.config(text="Disconnect", bg=ACCENT_RED)
                    self.lbl_status_badge.config(text="ONLINE", bg=ACCENT_GREEN)
                    self.card_status.config(text="ACTIVE (READY)", fg=ACCENT_GREEN)
                    self.log(f"Device Verified: FPGA responded with Status Acknowledge (0x55) on {port}", "success")
                else:
                    self.ser.close()
                    self.log(f"Handshake Fault: Expected 0x55, received {resp.hex() if resp else 'NULL'}", "error")
                    messagebox.showwarning("Handshake Fault", "Device did not return 0x55 ACK. Verify bitstream programming.")
            except Exception as e:
                self.log(f"Bus Exception: {str(e)}", "error")
                messagebox.showerror("Serial Port Error", str(e))
        else:
            if self.ser:
                self.ser.close()
            self.is_connected = False
            self.btn_connect.config(text="Connect Device", bg=ACCENT_BLUE)
            self.lbl_status_badge.config(text="OFFLINE", bg=ACCENT_RED)
            self.card_status.config(text="DISCONNECTED", fg=ACCENT_RED)
            self.log("Serial communications port closed.", "info")

    def load_nist_key(self):
        self.entry_key.delete(0, "end")
        self.entry_key.insert(0, NIST_KEY_HEX)
        self.log(f"Loaded NIST SP 800-38A Reference Key: {NIST_KEY_HEX}", "info")

    def generate_random_key(self):
        rand_hex = secrets.token_hex(16).upper()
        self.entry_key.delete(0, "end")
        self.entry_key.insert(0, rand_hex)
        self.log(f"Generated Cryptographically Secure 128-bit Key: {rand_hex}", "info")

    def burn_key_to_fpga(self):
        if not self.is_connected:
            messagebox.showerror("Connection Error", "Establish connection with FPGA hardware first.")
            return
        hex_key = self.entry_key.get().strip().replace(" ", "")
        try:
            key_bytes = bytes.fromhex(hex_key)
            if len(key_bytes) != 16:
                raise ValueError("Key vector must be exactly 16 bytes (32 hexadecimal characters).")
            self.ser.reset_input_buffer()
            self.log(f"Programming 128-bit Key into FPGA Register Schedule: {hex_key}", "tx")
            self.ser.write(b'\x01\x10' + key_bytes)
            ack = self.read_exact(1, timeout=1.0)
            if ack == b'\xAA':
                self.log("FPGA Acknowledged Key Register Write (0xAA received)", "success")
                messagebox.showinfo("Program Success", "Cipher key successfully stored into FPGA silicon registers.")
            else:
                self.log(f"Key Write Failure: FPGA returned {ack.hex() if ack else 'NULL'}", "error")
                messagebox.showerror("Write Error", "FPGA failed to acknowledge key program command.")
        except Exception as e:
            messagebox.showerror("Format Error", str(e))

    def encrypt_text(self):
        if not self.is_connected:
            messagebox.showerror("Connection Error", "Establish connection with FPGA hardware first.")
            return
        raw_text = self.txt_plain.get("1.0", "end-1c").encode('utf-8')
        if not raw_text:
            return

        pad_len = 16 - (len(raw_text) % 16)
        padded_text = raw_text + bytes([pad_len] * pad_len)
        total_blocks = len(padded_text) // 16

        cipher_hex = ""
        self.ser.reset_input_buffer()
        t0 = time.time()

        for i in range(total_blocks):
            block = padded_text[i*16:(i+1)*16]
            self.ser.write(b'\x02\x10' + block)
            resp = self.read_exact(17, timeout=1.5)
            if len(resp) == 17 and resp[0:1] == b'\xAA':
                cipher_hex += resp[1:].hex().upper()
                self.total_processed_blocks += 1
            else:
                self.log(f"Encryption Packet Fault at block index {i+1}.", "error")
                messagebox.showerror("Bus Error", f"Encryption packet {i+1} timed out.")
                return

        elapsed = time.time() - t0
        rate_kb = (len(padded_text) / 1024) / elapsed if elapsed > 0 else 0
        self.card_blocks.config(text=f"{self.total_processed_blocks} Blocks ({self.total_processed_blocks*16} B)")
        self.card_rate.config(text=f"{rate_kb:.2f} KB/s")
        self.txt_cipher.delete("1.0", "end")
        self.txt_cipher.insert("1.0", cipher_hex)
        self.log(f"Encryption Complete: {total_blocks} block(s) [{len(cipher_hex)//2} bytes] processed in {elapsed*1000:.2f} ms ({rate_kb:.2f} KB/s).", "success")

    def decrypt_text(self):
        if not self.is_connected:
            messagebox.showerror("Connection Error", "Establish connection with FPGA hardware first.")
            return
        hex_str = self.txt_cipher.get("1.0", "end-1c").strip().replace(" ", "").replace("\n", "")
        if not hex_str:
            messagebox.showerror("Data Error", "No ciphertext vector present in output pane.")
            return

        try:
            cipher_bytes = bytes.fromhex(hex_str)
            if len(cipher_bytes) % 16 != 0:
                raise ValueError(f"Ciphertext length ({len(cipher_bytes)} B) is not aligned to 16-byte boundary.")

            plain_bytes = b""
            total_blocks = len(cipher_bytes) // 16
            self.ser.reset_input_buffer()
            t0 = time.time()

            for i in range(total_blocks):
                block = cipher_bytes[i*16:(i+1)*16]
                self.ser.write(b'\x03\x10' + block)
                resp = self.read_exact(17, timeout=1.5)
                if len(resp) == 17 and resp[0:1] == b'\xAA':
                    plain_bytes += resp[1:]
                    self.total_processed_blocks += 1
                else:
                    self.log(f"Decryption Packet Fault at block index {i+1}.", "error")
                    messagebox.showerror("Bus Error", f"Decryption packet {i+1} timed out.")
                    return

            elapsed = time.time() - t0
            rate_kb = (len(cipher_bytes) / 1024) / elapsed if elapsed > 0 else 0
            pad_len = plain_bytes[-1]
            if 1 <= pad_len <= 16 and plain_bytes[-pad_len:] == bytes([pad_len] * pad_len):
                unpadded = plain_bytes[:-pad_len]
            else:
                unpadded = plain_bytes

            decrypted_str = unpadded.decode('utf-8', errors='replace')
            self.txt_plain.delete("1.0", "end")
            self.txt_plain.insert("1.0", decrypted_str)
            self.card_blocks.config(text=f"{self.total_processed_blocks} Blocks ({self.total_processed_blocks*16} B)")
            self.card_rate.config(text=f"{rate_kb:.2f} KB/s")
            self.log(f"Decryption Complete: {total_blocks} block(s) recovered in {elapsed*1000:.2f} ms ({rate_kb:.2f} KB/s).", "success")
        except Exception as e:
            self.log(f"Decryption Failure: {str(e)}", "error")
            messagebox.showerror("Decryption Fault", str(e))

    def run_nist_validation(self):
        if not self.is_connected:
            messagebox.showerror("Connection Error", "Connect to FPGA first.")
            return

        self.log("--- Commencing NIST FIPS-197 Mathematical Validation Test ---", "info")
        self.entry_key.delete(0, "end")
        self.entry_key.insert(0, NIST_KEY_HEX)
        self.burn_key_to_fpga()

        pt_bytes = bytes.fromhex(NIST_PT_HEX)
        self.ser.reset_input_buffer()
        self.ser.write(b'\x02\x10' + pt_bytes)
        resp = self.read_exact(17, timeout=1.5)

        if len(resp) == 17 and resp[0:1] == b'\xAA':
            hardware_ct = resp[1:].hex().upper()
            self.txt_cipher.delete("1.0", "end")
            self.txt_cipher.insert("1.0", hardware_ct)

            if hardware_ct == NIST_EXP_CT:
                self.log(f"✅ NIST TEST PASSED: Hardware output ({hardware_ct}) matches Golden Reference ({NIST_EXP_CT}) 100% bit-for-bit.", "success")
                messagebox.showinfo("NIST Compliance Verified", f"Test Vector Passed!\n\nFPGA Hardware Ciphertext:\n{hardware_ct}\n\nNIST Reference Expected:\n{NIST_EXP_CT}")
            else:
                self.log(f"❌ NIST TEST FAILED: Output {hardware_ct} != Expected {NIST_EXP_CT}", "error")
                messagebox.showerror("Verification Failed", f"Output mismatch:\nFPGA: {hardware_ct}\nExpected: {NIST_EXP_CT}")
        else:
            self.log("NIST evaluation packet transmission failed.", "error")

    def copy_cipher_to_clipboard(self):
        hex_str = self.txt_cipher.get("1.0", "end-1c").strip()
        if hex_str:
            self.root.clipboard_clear()
            self.root.clipboard_append(hex_str)
            self.log("Ciphertext vector copied to system clipboard.", "info")

    def select_file(self):
        f = filedialog.askopenfilename()
        if f:
            self.selected_file_path = f
            sz_kb = os.path.getsize(f) / 1024
            self.lbl_file_path.config(text=f"{self.selected_file_path} ({sz_kb:.2f} KB)", fg=TEXT_PRIMARY)
            self.log(f"Selected file: {self.selected_file_path} ({sz_kb:.2f} KB)", "info")

    def process_file(self, mode):
        if not self.is_connected:
            messagebox.showerror("Connection Error", "Establish connection with FPGA hardware first.")
            return
        if not self.selected_file_path or not os.path.exists(self.selected_file_path):
            messagebox.showerror("Data Error", "Please click 'Browse File...' and select a valid file first.")
            return

        threading.Thread(target=self._file_worker, args=(mode,), daemon=True).start()

    def _file_worker(self, mode):
        cmd = b'\x02' if mode == 'enc' else b'\x03'

        try:
            with open(self.selected_file_path, 'rb') as f:
                data = f.read()

            if mode == 'enc':
                pad_len = 16 - (len(data) % 16)
                data += bytes([pad_len] * pad_len)

            total_blocks = len(data) // 16
            out_data = bytearray()

            self.log(f"Streaming {total_blocks} block(s) [{len(data)} bytes] to FPGA...", "tx")
            self.lbl_progress_status.config(text=f"Streaming: 0 / {total_blocks} blocks", fg=ACCENT_BLUE)
            self.progress_bar['value'] = 0

            t0 = time.time()
            self.ser.reset_input_buffer()

            for i in range(total_blocks):
                block = data[i*16:(i+1)*16]
                self.ser.write(cmd + b'\x10' + block)
                resp = self.read_exact(17, timeout=1.5)

                if len(resp) == 17 and resp[0:1] == b'\xAA':
                    out_data.extend(resp[1:])
                    self.total_processed_blocks += 1
                else:
                    self.log(f"❌ Packet fault at block {i+1}/{total_blocks}", "error")
                    self.lbl_progress_status.config(text="Hardware Transfer Fault", fg=ACCENT_RED)
                    messagebox.showerror("Transfer Error", f"FPGA timed out at block {i+1} of {total_blocks}.")
                    return

                if i % 25 == 0 or i == total_blocks - 1:
                    elapsed_now = time.time() - t0
                    cur_speed = (len(out_data) / 1024) / elapsed_now if elapsed_now > 0 else 0
                    pct = ((i + 1) / total_blocks) * 100
                    self.progress_bar['value'] = pct
                    self.lbl_progress_status.config(text=f"Processing: {i+1} of {total_blocks} blocks ({pct:.1f}%) | {cur_speed:.2f} KB/s")
                    self.card_blocks.config(text=f"{self.total_processed_blocks} Blocks ({self.total_processed_blocks*16} B)")
                    self.card_rate.config(text=f"{cur_speed:.2f} KB/s")

            elapsed = time.time() - t0
            speed_kb = (len(data) / 1024) / elapsed if elapsed > 0 else 0

            if mode == 'dec':
                pad_len = out_data[-1]
                if 1 <= pad_len <= 16 and out_data[-pad_len:] == bytes([pad_len] * pad_len):
                    final_bytes = bytes(out_data[:-pad_len])
                else:
                    final_bytes = bytes(out_data)
            else:
                final_bytes = bytes(out_data)

            # Generate Safe Output Path that ALWAYS succeeds on Windows/OneDrive
            orig_name = os.path.basename(self.selected_file_path)
            if mode == 'enc':
                out_filename = orig_name + ".enc"
            else:
                out_filename = "restored_" + (orig_name[:-4] if orig_name.endswith(".enc") else orig_name)

            # Try candidate directories in order
            candidate_dirs = [
                os.path.dirname(os.path.abspath(self.selected_file_path)),
                os.path.join(os.path.expanduser("~"), "Downloads"),
                os.path.join(os.path.expanduser("~"), "Desktop"),
                os.getcwd()
            ]

            saved_path = None
            for d in candidate_dirs:
                if d:
                    try:
                        os.makedirs(d, exist_ok=True)
                        target = os.path.join(d, out_filename)
                        with open(target, 'wb') as f:
                            f.write(final_bytes)
                        saved_path = target
                        break
                    except Exception:
                        continue

            if not saved_path:
                saved_path = os.path.abspath(out_filename)
                with open(saved_path, 'wb') as f:
                    f.write(final_bytes)

            self.card_blocks.config(text=f"{self.total_processed_blocks} Blocks ({self.total_processed_blocks*16} B)")
            self.card_rate.config(text=f"{speed_kb:.2f} KB/s")
            self.lbl_progress_status.config(text=f"✅ File Saved: {os.path.basename(saved_path)} ({speed_kb:.2f} KB/s)", fg=ACCENT_GREEN)
            self.log(f"🎉 Saved to: {saved_path} [{len(final_bytes)} bytes in {elapsed:.2f}s]", "success")

            # Show Success Dialog & Open folder immediately
            messagebox.showinfo("Operation Complete",
                                f"File successfully {'Encrypted' if mode=='enc' else 'Decrypted'} via FPGA!\n\nSaved to:\n{saved_path}")
            folder = os.path.dirname(saved_path)
            if os.name == 'nt':
                os.startfile(folder)
            elif os.name == 'posix':
                subprocess.Popen(['xdg-open', folder])

        except Exception as e:
            self.log(f"File System Error: {str(e)}", "error")
            messagebox.showerror("File Error", f"Failed to save file: {str(e)}")

    def log(self, msg, level="info"):
        ts = time.strftime("[%H:%M:%S]")
        self.txt_log.insert("end", f"{ts} {msg}\n", level)
        self.txt_log.see("end")

    def clear_log(self):
        self.txt_log.delete("1.0", "end")


if __name__ == "__main__":
    root = tk.Tk()
    app = ScientificHSMApp(root)
    root.mainloop()