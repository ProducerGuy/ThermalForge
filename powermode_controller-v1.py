#!/usr/bin/env python3
# DEPRECATED (0.2.0): superseded by ThermalForge's built-in Overheat Protection
# (PowerModeController — 100 ms decisions, 2 s mode sync, GUI thresholds, verified
# read-back). Kept only as a historical reference; the app no longer needs it.
#
import subprocess
import json
import time
from datetime import datetime

INTERVAL = 2
ENABLED = True
HIGH_TEMP = 88.0
LOW_TEMP = 70.0
MODE_HIGH = 2
MODE_REDUCED = 1

def set_powermode(mode):
    try:
        subprocess.run(
            ["sudo", "pmset", "-c", "powermode", str(mode)],
            check=True,
            capture_output=True,
            text=True
        )
        print(f"Power mode set to {mode}")

    except subprocess.CalledProcessError as e:
        print("pmset failed:")
        print(e.stderr)

def get_thermalforge_status():
    try:
        result = subprocess.run(
            ["thermalforge", "status"],
            capture_output=True,
            text=True,
            check=True
        )

        return json.loads(result.stdout)

    except Exception as e:
        print("thermalforge error:", e)
        return None

def get_max_temperature(data):
    if not data or "temperatures" not in data:
        return None

    return max(float(t) for t in data["temperatures"].values())

def main():

    mode = MODE_REDUCED

    print("PowerMode controller started")
    print("Regulation enabled:", ENABLED)

    while True:

        data = get_thermalforge_status()
        temp = get_max_temperature(data)

        timestamp = datetime.now().strftime("%H:%M:%S")

        if temp is not None:

            print(
                f"{timestamp}  max temperature: {temp:.1f} °C  mode={mode}"
            )

            if ENABLED:

                # Too hot -> reduce power
                if temp >= HIGH_TEMP and mode != MODE_REDUCED:
                    mode = MODE_REDUCED
                    print(f"temperature high -> mode {mode}")
                    set_powermode(mode)

                # Cool enough -> high power
                elif temp <= LOW_TEMP and mode != MODE_HIGH:
                    mode = MODE_HIGH
                    print(f"temperature low -> mode {mode}")
                    set_powermode(mode)

        else:
            print(f"{timestamp}  no temperature data")

        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
