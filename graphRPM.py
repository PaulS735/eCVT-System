import matplotlib.pyplot as plt
import re

# Read the data file
with open('datalog.txt', 'r') as f:
    lines = f.readlines()

# Parse the data
timestamps = []
rpms = []
torques = []
actpositions = []
MAX_RPM = 2000
MAX_ACT = 4095

for line in lines:
    # Skip initialization messages
    if "First magnet detected - initializing" in line:
        continue

    # Skip preset change messages
    if "Preset:" in line:
        continue

    # Match lines with timestamp, RPM, torque, and actuator position
    match = re.search(
        r'\[(\d+\.\d+)\s+[\d.]+\]\s*[01],\d+,(\d+\.\d+),(\d+\.\d+),(\d+)',
        line
    )
    if match:
        timestamp = float(match.group(1))
        rpm = float(match.group(2))
        torque = float(match.group(3))
        actpos = int(match.group(4))

        if rpm <= MAX_RPM and actpos <= MAX_ACT:
            timestamps.append(timestamp)
            rpms.append(rpm)
            torques.append(torque)
            actpositions.append(actpos)

# Create the plot with three y-axes
fig, ax1 = plt.subplots(figsize=(14, 7))

# Plot RPM on left y-axis
color_rpm = 'tab:blue'
ax1.set_xlabel('Time (seconds)', fontsize=12)
ax1.set_ylabel('RPM', color=color_rpm, fontsize=12)
ax1.plot(timestamps, rpms, color=color_rpm, linewidth=2, marker='o', markersize=4, label='RPM')
ax1.tick_params(axis='y', labelcolor=color_rpm)
ax1.grid(True, alpha=0.3)

# Create second y-axis for torque
ax2 = ax1.twinx()
color_torque = 'tab:red'
ax2.set_ylabel('Torque (lb-ft)', color=color_torque, fontsize=12)
ax2.plot(timestamps, torques, color=color_torque, linewidth=2, marker='s', markersize=4, label='Torque')
ax2.tick_params(axis='y', labelcolor=color_torque)

# Create third y-axis for actuator position (offset to the right)
ax3 = ax1.twinx()
ax3.spines['right'].set_position(('outward', 60))
color_act = 'tab:green'
ax3.set_ylabel('Actuator Position (ADC)', color=color_act, fontsize=12)
ax3.plot(timestamps, actpositions, color=color_act, linewidth=2, marker='^', markersize=3, label='Actuator Pos')
ax3.tick_params(axis='y', labelcolor=color_act)

# Add title and legends
plt.title('Motor RPM, Torque, and Actuator Position over Time', fontsize=14)
ax1.legend(loc='upper left')
ax2.legend(loc='upper right')
ax3.legend(loc='center right')

fig.tight_layout()
plt.show()
