import csv
import json
import time
from datetime import datetime, timedelta

from coppeliasim_zmqremoteapi_client import RemoteAPIClient
import paho.mqtt.client as mqtt
import win32com.client

# =====================================================================
# CONFIG
# =====================================================================
TOTAL_HOURS = 72
N_JOINTS = 6
POLL_INTERVAL = 0.2  # วินาที (ต้องถี่กว่า 1 ชั่วโมงเสมือน = 5 วินาที มาก ๆ)

# เวลาเริ่มต้น (Timestamp รายชั่วโมง นับจากนี้ไป +1 ชม. ต่อแถว)
START_TIME = datetime.now().replace(minute=0, second=0, microsecond=0)
CSV_FILE = f"ur10_pdm_72h_{START_TIME:%Y%m%d_%H%M}.csv"

MQTT_TOPIC = "factory/robot/ur10/health"

STATE_CODE = {"Normal": 0, "Warning": 1, "Breakdown": 2}

# PLC register map (ค่า x10 เก็บทศนิยม 1 ตำแหน่ง)
#   D200-D205 : Torque  J1-J6
#   D206-D211 : Temp    J1-J6
#   D212-D217 : Current J1-J6
#   D218-D223 : Angle   J1-J6
#   D230      : Heartbeat
#   D231      : Machine state (0=Normal, 1=Warning, 2=Breakdown)
#   D232      : Hour index (0-71)
REG_TORQUE, REG_TEMP, REG_CURRENT, REG_ANGLE = 200, 206, 212, 218
REG_HEARTBEAT, REG_STATE, REG_HOUR = 230, 231, 232

# =====================================================================
# CSV header
# =====================================================================
HEADER = (
    ["Timestamp", "Hour", "Sim_Time", "Machine_State"]
    + [f"J{i}_Angle" for i in range(1, N_JOINTS + 1)]
    + [f"J{i}_Temp" for i in range(1, N_JOINTS + 1)]
    + [f"J{i}_Current" for i in range(1, N_JOINTS + 1)]
    + [f"J{i}_Torque" for i in range(1, N_JOINTS + 1)]
)

with open(CSV_FILE, mode="w", newline="", encoding="utf-8") as f:
    csv.writer(f).writerow(HEADER)
print(f"[System] Dataset file: {CSV_FILE}")

# =====================================================================
# 1. Connect to Mitsubishi FX5U (GX Simulator3 via MX Component)
# =====================================================================
plc = win32com.client.Dispatch("ActUtlType.ActUtlType")
plc.ActLogicalStationNumber = 1
if plc.Open() != 0:
    raise Exception("Critical: Cannot link to PLC Simulator. Check MX Component.")
print("[System] Linked to FX5U successfully.")

# =====================================================================
# 2. Connect to CoppeliaSim
# =====================================================================
client = RemoteAPIClient()
sim = client.require("sim")
print("[System] Linked to CoppeliaSim successfully.")

# =====================================================================
# 3. Connect to MQTT Broker
# =====================================================================
mqtt_client = mqtt.Client()
try:
    mqtt_client.connect("localhost", 1883, 60)
    mqtt_client.loop_start()
    print("[System] Connected to MQTT Broker.")
except Exception as e:
    print(f"[Warning] MQTT offline: {e}")


# =====================================================================
# Helpers
# =====================================================================
def plc_write(register: str, value: float, scale: float = 10.0):
    """เขียนค่าลง PLC (คูณ scale และจำกัดช่วง int16)"""
    v = int(round(value * scale))
    v = max(-32768, min(32767, v))
    plc.SetDevice(register, v)


def read_pdm():
    """อ่าน String signal จาก Lua แล้วแตกเป็น dict
    Format: SimTime, Hour, State, Angle x6, Temp x6, Current x6, Torque x6 (27 ฟิลด์)
    """
    raw = sim.getStringSignal("UR10_PdM_Data")
    if not raw:
        return None
    if isinstance(raw, bytes):
        raw = raw.decode()
    p = raw.split(",")
    if len(p) != 3 + 4 * N_JOINTS:
        return None
    nums = [float(x) for x in p[3:]]
    n = N_JOINTS
    return {
        "sim_time": float(p[0]),
        "hour": int(p[1]),
        "state": p[2],
        "angle": nums[0:n],
        "temp": nums[n:2 * n],
        "current": nums[2 * n:3 * n],
        "torque": nums[3 * n:4 * n],
    }


def append_csv(d):
    ts = (START_TIME + timedelta(hours=d["hour"])).strftime("%Y-%m-%d %H:%M:%S")
    row = (
        [ts, d["hour"], d["sim_time"], d["state"]]
        + d["angle"] + d["temp"] + d["current"] + d["torque"]
    )
    with open(CSV_FILE, mode="a", newline="", encoding="utf-8") as f:
        csv.writer(f).writerow(row)
    return ts


def update_plc(d, heartbeat):
    for i in range(N_JOINTS):
        plc_write(f"D{REG_TORQUE + i}", d["torque"][i])
        plc_write(f"D{REG_TEMP + i}", d["temp"][i])
        plc_write(f"D{REG_CURRENT + i}", d["current"][i])
        plc_write(f"D{REG_ANGLE + i}", d["angle"][i])
    plc.SetDevice(f"D{REG_HEARTBEAT}", heartbeat)
    plc.SetDevice(f"D{REG_STATE}", STATE_CODE.get(d["state"], 0))
    plc.SetDevice(f"D{REG_HOUR}", d["hour"])


def publish_mqtt(d, ts):
    payload = {
        "Timestamp": ts,
        "Hour": d["hour"],
        "SimTime": round(d["sim_time"], 1),
        "Status": d["state"],
        "Joints": {
            f"J{i + 1}": {
                "Angle": round(d["angle"][i], 2),
                "Temp": round(d["temp"][i], 1),
                "Current": round(d["current"][i], 2),
                "Torque": round(d["torque"][i], 1),
            }
            for i in range(N_JOINTS)
        },
    }
    mqtt_client.publish(MQTT_TOPIC, json.dumps(payload))


# =====================================================================
# Main loop
# =====================================================================
heartbeat = 0
last_hour = -1  # ชั่วโมงล่าสุดที่บันทึกลง CSV แล้ว

try:
    while True:
        sim_state = sim.getSimulationState()

        # จบงาน: เคยบันทึกข้อมูลแล้ว และ Simulation หยุด (Lua สั่งหยุดเมื่อครบ 72 ชม.)
        if sim_state == sim.simulation_stopped:
            if last_hour >= 0:
                print(f"[System] Simulation finished. Logged up to hour {last_hour}.")
                break
            print("[Idle] Waiting for CoppeliaSim simulation to start...")
            time.sleep(1.0)
            continue

        # Check system enable bit (M10) from PLC
        ret, sys_running = plc.GetDevice("M10")

        if sys_running == 1:
            d = read_pdm()
            if d is not None:
                heartbeat = (heartbeat + 1) % 1000
                update_plc(d, heartbeat)

                # บันทึก CSV + ส่ง MQTT เฉพาะตอนขึ้นชั่วโมงใหม่ (รายชั่วโมง)
                if d["hour"] != last_hour and d["hour"] < TOTAL_HOURS:
                    last_hour = d["hour"]
                    ts = append_csv(d)
                    publish_mqtt(d, ts)
                    print(
                        f"[Log] {ts} | Hour {d['hour']:2d}/{TOTAL_HOURS} |"
                        f" {d['state']:<9} | J3: {d['angle'][2]:6.1f}deg"
                        f" {d['temp'][2]:5.1f}C {d['current'][2]:5.2f}A"
                    )
        else:
            print("[Idle] Waiting for M10 = ON from HMI/PLC...")

        time.sleep(POLL_INTERVAL)

except KeyboardInterrupt:
    print("[System] Interrupted by user.")

finally:
    try:
        mqtt_client.loop_stop()
    except Exception:
        pass
    plc.Close()
    print("[System] Clean shutdown.")