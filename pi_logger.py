#!/usr/bin/env python3
"""Pi-side serial logger for eCVT Teensy telemetry.

Reads USB Serial from Teensy at 115200 baud, prepends timestamps,
writes to a log file, and prints to stdout.
"""

import serial
import time
import sys
import os

SERIAL_PORT = '/dev/ttyACM0'
BAUD_RATE = 9600
RECONNECT_DELAY = 5  # seconds between reconnect attempts

def main():
    # Output filename from CLI arg or default
    outfile = sys.argv[1] if len(sys.argv) > 1 else 'datalog.txt'

    start_time = time.time()
    print(f"Logging to {outfile} from {SERIAL_PORT} at {BAUD_RATE} baud")
    print("Press Ctrl+C to stop.\n")

    while True:
        ser = None
        fh = None
        try:
            ser = serial.Serial(SERIAL_PORT, BAUD_RATE, timeout=1)
            fh = open(outfile, 'a')
            print(f"Connected to {SERIAL_PORT}")

            while True:
                raw = ser.readline()
                if not raw:
                    continue

                line = raw.decode('utf-8', errors='replace').strip()
                if not line:
                    continue

                now = time.time()
                elapsed = now - start_time
                stamped = f"[{now:.6f} {elapsed:.2f}] {line}"

                fh.write(stamped + '\n')
                fh.flush()
                print(stamped)

        except serial.SerialException as e:
            print(f"Serial error: {e}")
            print(f"Reconnecting in {RECONNECT_DELAY}s...")
            time.sleep(RECONNECT_DELAY)

        except KeyboardInterrupt:
            print("\nStopping logger.")
            break

        finally:
            if ser and ser.is_open:
                ser.close()
            if fh and not fh.closed:
                fh.close()

if __name__ == '__main__':
    main()
