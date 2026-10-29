# LEMO - A Unified Platform for Bimanual Data Collection, Training, and Inference

[English](README.md) | [简体中文](README_zh.md)

LEMO integrates bimanual teleoperation, camera acquisition, data recording, and policy inference connectivity into a ROS 2 Humble workspace. It brings together data collection, training, and inference workflows for embodied AI development.

In this document, **LEMO platform** refers to the RK3588 device running teleoperation, data collection, and the policy client. **Compute platform** refers to the GPU server running the model inference service.

## Repository Layout

```text
~/lemo/
├── lemo-server/            # Inference server deployed on the compute platform
├── README.md              # English documentation
├── README_zh.md            # Chinese documentation
├── ethernet_setup.sh      # Ethernet connection setup utility
└── lemo_1.x.x.x            # LEMO runtime package deployed on the LEMO platform
```

The examples below assume that `lemo_1.x.x.x` is placed in the home directory (`~/`) on the LEMO platform.

## Features

- **Bimanual teleoperation**: Convert leader inputs into left/right arm and gripper targets, with support for single-arm and dual-arm operation.
- **Hardware configuration**: Select hardware profiles, save machine-specific settings, and override them at launch time.
- **Camera acquisition**: Capture three camera streams using a dedicated node, with hardware triggering and configurable frame rate, rotation, and exposure.
- **Data collection and management**: Record MCAP data and use the web dashboard to browse, replay, and download episodes. Conversion to LeRobot requires an additional conversion tool and its dependencies.
- **Web dashboard**: Monitor joints, grippers, cameras, and runtime status; control teleoperation and recording; and manage local collection tasks and logs.
- **Policy inference integration**: Connect to a compatible external inference service over WebSocket, with pause, homing, and human takeover controls. Models run on the compute platform rather than the LEMO platform.

## System Architecture

```text
Leader → g4_spi → teleop_bridge → /motion_target/* → arm_bridge → SDK → CAN → Motors
                                       ↑
                              policy_client (optional)

camera_publisher → Camera images
Joint feedback / Camera images / Runtime status → Dashboard / Recording / Policy observations
```

The complete workspace contains the following main components:

| Component | Purpose |
| --- | --- |
| `g4_spi` | SPI-to-CAN bridge and leader data acquisition |
| `camera_publisher` | Dedicated three-camera acquisition and hardware triggering |
| `teleop_bridge` (ROS package name: `lemo`) | Teleoperation mapping, run-mode management, and the unified launch entry point |
| `a1z_arm_bridge_sdk` | Left/right arm and gripper control, feedback, and optional trajectory smoothing |
| `lemo_dashboard` | Web monitoring, recording controls, and data management |
| `policy_client` | Client for an external policy inference service |
| `data_collection` | Prebuilt recording component used as a runtime overlay; excluded from source builds |
| `profiles/` | Gripper, leader, and machine configuration templates |
| `scripts/` | Deployment, environment setup, and hardware profile management utilities |

## Requirements

### LEMO Platform

- Ubuntu 22.04 ARM64 with ROS 2 Humble installed and its official package repositories configured.
- SPI, CAN, camera, and GPIO interfaces compatible with the supplied hardware.
- A complete runtime package with matching arm SDK resources, hardware profiles, and system/Python runtime dependencies. Recording requires the prebuilt `data_collection` component.
- Compatible Pinocchio runtime libraries when using a gravity-compensation-enabled arm bridge. The development version was validated with Pinocchio 3.4.0; NumPy must also be compatible with the system OpenCV installation.

The deployment steps below use a precompiled runtime package and do not require a source build. Git, CMake, colcon, and other build dependencies are needed only when building from source. For a source build, missing Pinocchio may result in an arm bridge without gravity compensation; a precompiled binary linked against Pinocchio still requires its matching runtime libraries.

### Compute Platform

- Linux x86_64 with a supported NVIDIA GPU and a working NVIDIA driver. GPU memory requirements depend on the model and runtime configuration.
- System Python 3, network access to download dependencies and model-associated resources, and sudo privileges to install system dependencies.
- Sufficient disk space for Python environments, download caches, and model files.
- Network connectivity to the LEMO platform. ROS 2 and ARM64 runtime packages are not required on the compute platform for the WebSocket inference service described here.

`server_setup.sh` installs build tools and the selected backend's Python environment. You do not need to install Conda or uv manually. Trained weights and matching model resources must be provided separately.

## Deployment and Configuration

### 1. Deploy the Workspace

Extract the runtime package first:

```bash
cd ~/
# Assume lemo_1.x.x.x.tar.gz is in the home directory.
tar -zxvf lemo_1.x.x.x.tar.gz
# Replace the package name with the actual version.
```

Configure the environment:

```bash
cd ~/lemo_1.x.x.x/
./run.sh --check
source install/setup.bash
sudo ./deploy.sh
```

Compatible system and Python runtime dependencies must already be installed. `deploy.sh` checks the runtime package, installs system services, configures GPIO/SPI permissions and the shell environment, and sets up log rotation. It does not download source code or compile the workspace.

### 2. Configure the Hardware

Edit `/etc/lemo/machine.yaml` as needed, primarily to configure camera settings and the policy client on the LEMO platform. Other settings can remain unchanged for the supplied hardware configuration.

```yaml
robot_sn: YOUR_ROBOT_SN
ros_domain_id: 26
gripper_profile: g1z
leader_profile: dvt
camera:
  hz: 15
  wrist_rotation_deg: 180
  exposure_us: 20000
policy:
  server_url: ws://192.168.88.1:8765
  task: The_first_task
  embodiment: galaxea_a1z
  send_raw_jpeg: false
  smoothing: bcubic
  smooth_vmax: 3.5
  smooth_amax: 50
  smooth_jerk: 400
```

- `robot_sn`: Unique device identifier.
- `ros_domain_id`: ROS communication domain; keep the default for this deployment.
- `gripper_profile`: Gripper version; keep the default for the supplied hardware.
- `leader_profile`: Leader arm version; keep the default for the supplied hardware.
- `camera`: Camera settings.
- `policy`: Policy inference settings.

> Assign each device a unique, stable serial number for identification, data traceability, and maintenance. The system uses centralized discovery, so normal operation does not require changing the Domain ID. The main settings to edit here are `camera` and `policy`.

### 3. Pre-launch Checks

- Verify that the hardware configuration, gripper calibration, and gravity compensation settings match the physical device.
- Ensure that no other teleoperation instance or legacy service is using the same SPI/CAN devices.
- Check that all three cameras and both arms provide feedback, and that the recording directory is writable and has sufficient free space.

## Teleoperation and Data Collection

```bash
source ~/lemo_1.x.x.x/install/setup.bash
# Run the source command above in each new terminal.
ros2 launch lemo lemo.launch.py # Launch the data collection system.
```

By default, this starts dual-arm control, G4SPI, cameras, the recording component, and the dashboard at a control rate of 200 Hz. Starting the recording component does not immediately start recording an episode.

Open `http://<LEMO_PLATFORM_IP>:8000` from another device on the same LAN, or `http://localhost:8000` from a browser on the LEMO platform itself.

1. Check hardware status and camera previews.
2. Press the button below the joystick on the right-hand controller to enable teleoperation, or use the corresponding dashboard control.
3. Press the button below the joystick on the left-hand controller to start/stop recording, or use the dashboard recording controls.
4. Browse, replay, or download saved episodes on the data management page.

**Recording can start only while teleoperation is enabled. Stop recording before ending teleoperation.**

In the sequence below, **right-controller button** and **left-controller button** refer to the buttons below the joysticks on the respective handheld controllers, not the left/right directions of a joystick.

A typical data collection sequence is:

```text
Right-controller button [Enable teleoperation] → Left-controller button [Start recording] → Teleoperate and record actions/images → Left-controller button [Stop and save recording] → Right-controller button [End teleoperation]
```

For consecutive episodes, leave teleoperation enabled after stopping a recording. Press the button below the left controller's joystick again to start the next episode, and repeat as needed.

When a local task is set as the current task, subsequent recorded episodes are automatically associated with it.

Examples with launch arguments:

```bash
# Start only the left arm, without the recording component.
ros2 launch lemo lemo.launch.py arm:=left start_recording:=false

# Start without cameras.
ros2 launch lemo lemo.launch.py start_camera:=false
```

List all launch arguments:

```bash
ros2 launch lemo lemo.launch.py --show-args
```

| Argument | Purpose |
| --- | --- |
| `arm` | `left`, `right`, or `both` |
| `ctrl_hz` | Control rate; defaults to 200 Hz |
| `gripper` / `leader` | Hardware profiles; read from the machine configuration by default |
| `start_g4spi` / `start_camera` | Whether to start the acquisition bridge / cameras |
| `start_recording` / `start_dashboard` | Whether to start the recording component / dashboard |
| `camera_hz` / `camera_rotation_deg` / `camera_exposure_us` | Camera frame rate, rotation angle, and exposure time |
| `arm_smoothing` | Trajectory smoothing for teleoperation and other targets; defaults to `legacy` |
| `arm_smoothing_policy` | Smoothing specifically for inference/replay; inherits `arm_smoothing` when empty |
| `start_policy` | Whether to start the policy client; disabled by default |
| `data_collection_install` | Path to the prebuilt recording component |
| `log_dir` | Log directory |

Keep `g4spi_poll_hz` at its default of 2000 Hz. Lowering the G4SPI polling rate may cause feedback to accumulate or drop out.

## Web Dashboard and Data Management

The dashboard can start with the unified launch entry point or run separately:

```bash
ros2 run lemo_dashboard lemo-dashboard
```

It provides live joint and gripper feedback, camera previews, read-only leader monitoring, recording controls, episode management, and log viewing. Enable leader-only monitoring only after teleoperation has ended and the system has returned to HOME. In this mode, teleoperation, recording, and takeover buttons are blocked.

The default recording directory is:

```text
~/GalaxeaDataset/<YYYYMMDD>/<NAME>_RAW/
```

Each episode directory contains MCAP files and optional metadata. To change the dataset directory scanned by the dashboard:

```bash
DASHBOARD_DATASET_ROOT=/path/to/dataset ros2 run lemo_dashboard lemo-dashboard
```

This variable changes only where the dashboard looks for data. Configure the recording destination separately in the recording component. Before using external storage, confirm that it is mounted and writable.

The dashboard listens on `0.0.0.0:8000` by default and should be used on a trusted network. Set `DASHBOARD_TOKEN` to require an access token; requests must include an `X-Dashboard-Token` header or a `token` query parameter. When running separately, use `--port`, `--no-camera`, or `--no-episodes` to adjust the port and resource usage. For example:

```bash
ros2 run lemo_dashboard lemo-dashboard --port 9000
# Access the dashboard on port 9000 in this example.
```

Without ROS, OpenCV, or rosbag2, the dashboard falls back to local preview mode. Demo values do not represent live hardware feedback, and recording and MCAP replay are unavailable.

Cloud upload requires separate device identity and service credentials. These are not required for local data collection.

## Inference Deployment

Inference uses two endpoints. The **server** in `lemo-server/` runs on the compute platform, loads the model, and generates actions. The **policy client** in `lemo_1.x.x.x/` runs on the LEMO platform, uploads camera and joint observations through `policy_client`, and receives and executes actions. Start the server first, then configure and start the policy client, and finally start inference from the dashboard.

### 1. Server: Deploy the Inference Service

Follow this order: place code and models → install the environment → configure the service → start and verify. Environment installation is independent of model configuration.

#### 1.1 Place Code and Models

The examples use `~/workspace` as the compute platform's deployment directory. Put code in `lemo-server/` and model resources alongside it in `lemo-models/`. This separates code updates from model resources:

```text
~/workspace/
├── lemo-server/
│   ├── server_setup.sh                  # Install and check the environment only
│   ├── deploy/
│   │   ├── start_serve.sh                # Read configuration and start the service
│   │   ├── serve.env                     # Default configuration
│   │   └── serve.env.local.example       # Local configuration template
│   ├── scripts/
│   └── src/
└── lemo-models/
    ├── g05/my_model/                     # G0.5 example
    │   ├── checkpoints/step_35000.pt
    │   ├── action_tokenizer.pt
    │   ├── dataset_stats.json            # Matching dataset statistics
    │   └── ...                          # Training configuration and related files
    ├── qwen3_5_2b_base_processor/         # Complete G0.5 processor directory
    └── lerobot/my_model/                 # LeRobot example
        └── checkpoints/025000/pretrained_model/
            ├── config.json
            ├── model.safetensors
            ├── policy_preprocessor.json
            ├── policy_postprocessor.json
            └── ...                      # Associated normalization parameters
```

Prepare only the files required by your chosen backend. `my_model`, `step_35000`, and `025000` are examples; replace them with the actual names. G0.5 weights, action tokenizer, and processor must be compatible with one another. Here, the G0.5 processor is a directory of model preprocessing and tokenization configuration/assets, not a hardware processor. Copy the complete directory, including its configuration and tokenizer files. Keep the matching training configuration and `dataset_stats.json` with the model. LeRobot processor files contain preprocessing, postprocessing, and normalization settings; retain their associated parameter files as well. For LeRobot, copy the complete `pretrained_model/` directory. If the checkpoint has no embedded processor, prepare dataset statistics as described in `lemo-server/deploy/README_LEROBOT.md`.

#### 1.2 Install the Runtime Environment

Open the code directory prepared above. Installation requires Linux x86_64, system Python 3, a working NVIDIA driver, network access, and sudo privileges.

```bash
cd ~/workspace/lemo-server
nvidia-smi
```

Select the backend that matches your model and run only one of the following commands:

```bash
# G0.5
bash server_setup.sh --backend g05

# Or LeRobot
bash server_setup.sh --backend lerobot
```

The script installs build dependencies, creates a Python 3.10 environment, installs backend dependencies, and checks CUDA and basic imports. You do not need to install Conda or uv manually or supply model paths. The G0.5 environment is `.venv/`; the LeRobot environment is `.venv-lerobot/`.

The initial installation downloads large PyTorch and CUDA dependencies. Wait for the script to finish: only the `Environment ready` message confirms successful installation and validation. If installation fails or is interrupted, resolve the cause and rerun the same command; downloaded files are reused from the cache. `--check` checks an existing environment and does not install missing dependencies.

The script does not download your trained weights, change service configuration, or start inference. To verify an existing environment, run `bash server_setup.sh --backend g05 --check` (use `lerobot` for LeRobot). Run `bash server_setup.sh --help` for other options.

#### 1.3 Configure the Model and Service

For initial configuration, run the following on the compute platform:

```bash
cd ~/workspace/lemo-server
# Copy the template only if a local configuration does not already exist.
[ -f deploy/serve.env.local ] || cp deploy/serve.env.local.example deploy/serve.env.local
# Edit the server configuration.
nano deploy/serve.env.local
```

Use the configuration for your chosen backend below. Names correspond to the model directory layout above. Do not commit the local configuration file to the repository.

G0.5:

```bash
MODEL_TYPE=g05
G05_CHECKPOINT=$HOME/workspace/lemo-models/g05/my_model/checkpoints/step_35000.pt
G05_TOKENIZER=$HOME/workspace/lemo-models/g05/my_model/action_tokenizer.pt
G05_PROCESSOR=$HOME/workspace/lemo-models/qwen3_5_2b_base_processor
SERVE_PORT=8765
ACTION_STEPS=32
EMBODIMENT=galaxea_a1z
DEVICE=cuda
```

LeRobot:

```bash
MODEL_TYPE=lerobot
LEROBOT_POLICY_PATH=$HOME/workspace/lemo-models/lerobot/my_model/checkpoints/025000/pretrained_model
LEROBOT_DEFAULT_TASK="pick up the red cube"
SERVE_PORT=8765
ACTION_STEPS=32
DEVICE=cuda
```

The task description must match the training data. For a LeRobot checkpoint without an embedded processor, also set `LEROBOT_STATS_PATH=/path/to/stats.json`. The default joint and image mapping is supplied with the program. Set `LEROBOT_MAPPING` when using custom feature names.

You do not need to specify a Python interpreter: the launcher defaults to `.venv/bin/python` or `.venv-lerobot/bin/python` within the program directory. If an older local configuration sets `EFMNODE_PYTHON` or `LEROBOT_PYTHON`, remove the old override or update it to the corresponding new environment path.

#### 1.4 Wired Connection Between the Compute and LEMO Platforms (Optional)

**Skip this section if the two devices can already communicate over an existing network.** If they cannot ping each other after connecting an Ethernet cable, use the following setup procedure. The script assigns these addresses:

| Device | IP address |
| --- | --- |
| Server | `192.168.88.1` |
| Policy client | `192.168.88.2` |

Both endpoints must run Linux with NetworkManager and have system Python 3, `nmcli`, `ip`, `ping`, and sudo privileges. Connect the cable first; either an onboard Ethernet port or a USB Ethernet adapter can be used. Run the commands locally or through a separate Wi-Fi SSH connection, rather than through the Ethernet interface being configured.

**1.4.1 On the Compute Platform**

`ethernet_setup.sh` is in the `lemo/` repository root, alongside `README.md`. Copy it to the target device; it does not require a fixed installation path.

```bash
# Open the directory containing ethernet_setup.sh.
cd /path/to/script-directory
chmod +x ethernet_setup.sh
bash ./ethernet_setup.sh --role server
```

**1.4.2 On the LEMO Platform**

Copy the same script to the LEMO platform. You do not need to install the server environment there. Run it from its directory:

```bash
# Open the directory containing ethernet_setup.sh.
cd /path/to/script-directory
chmod +x ethernet_setup.sh
bash ./ethernet_setup.sh --role lemo
```

When configuring the first device, the other endpoint may not yet be ready. In that case, the script reports that the peer is unreachable and exits with code 2. The local configuration has been saved. Configure the second device, then verify connectivity as described below.

**1.4.3 Verify Connectivity**

On each device, open the directory containing `ethernet_setup.sh` and run the appropriate command below to check connectivity without modifying configuration:

```bash
# Compute platform
bash ./ethernet_setup.sh --role server --check

# LEMO platform
bash ./ethernet_setup.sh --role lemo --check
```

Once both endpoints report that wired communication has passed verification, proceed to start the service. With the addresses assigned in this section, the compute platform uses `192.168.88.1`, so set `server_url` to `ws://192.168.88.1:8765`.

**Handling Setup Messages**

| Message or symptom | Action |
| --- | --- |
| Multiple candidate interfaces remain after excluding SSH and Internet interfaces | Add `--interface INTERFACE_NAME` using a name listed by the script; select the port connected to the other device |
| No physical link detected | Run `--diagnose` to inspect interfaces. Distinguish a disabled interface, `NO-CARRIER`, and an unrecognized adapter; then check the cable, adapter, and peer's power. Do not select a Wi-Fi interface |
| Subnet conflict | Add the same alternative private subnet on both endpoints, such as `--subnet 192.168.89.0/24`; change the service address to `192.168.89.1` accordingly |
| Preview changes before applying them | Add `--dry-run` to preview the interface and addresses without changing the network |
| Interface shows `disconnected` or is obtaining an IP address | This does not necessarily mean the cable is faulty. A direct connection usually has no DHCP server; use the script to configure static addresses |
| Communication still fails after configuring both endpoints | Check the cable and subnet settings. Try another cable, port, or USB adapter, then rerun setup. A physical link does not guarantee bidirectional packet transmission |
| Port or adapter has changed | Rerun setup. The script updates the dedicated connection for the current interface; specify an interface explicitly if multiple candidates remain |
| Wired communication works but inference cannot connect | Check whether the server has started, its listening address and port, and the firewall |

The script stops and provides an explanation if the subnet conflicts, or if the selected interface carries the current SSH connection or the route actually used for Internet access. If the interface only has a backup default route from an old configuration while SSH and Internet access use other interfaces, the script allows a dedicated direct connection and preserves the original profile. Do not disable Wi-Fi or clear other network configuration just to bypass a message.

#### 1.5 Start and Verify

> The first launch may need to fetch configuration or resources from Hugging Face. If the platform cannot access the default endpoint and startup fails for that reason, you can configure a mirror accessible from your network:

```bash
export HF_ENDPOINT=https://hf-mirror.com
```

Start the inference server in the same terminal:

```bash
cd ~/workspace/lemo-server
bash deploy/start_serve.sh
```

When the server is ready, the terminal should display a message such as:

```text
INFO | >> Policy server listening on 0.0.0.0:8765
```

The launcher checks model paths, Python, and port availability before loading the model. Once model loading and warmup have succeeded and the service is listening on `0.0.0.0:8765`, keep it running and set `policy.server_url` on the LEMO platform to `ws://<COMPUTE_PLATFORM_IP>:8765`.

The first load may require additional resources associated with the model. A listening server means only that the server is ready; you must still verify policy client connectivity and hardware execution. Restart the service after changing weights or tasks. Install the corresponding environment before switching backends.

### 2. Policy Client: Configure the LEMO Platform

Complete deployment and hardware configuration on the LEMO platform first, and confirm that cameras and joint feedback work. Add or update the top-level `policy:` section in `/etc/lemo/machine.yaml`, alongside the hardware settings. Replace the address and task with the actual values:

```yaml
policy:
  server_url: "ws://<COMPUTE_PLATFORM_IP>:8765"
  task: "pick up the red cube"
  embodiment: galaxea_a1z
  send_raw_jpeg: false
  smoothing: bcubic
  smooth_vmax: 3.5
  smooth_amax: 50
  smooth_jerk: 400
```

- `server_url`: WebSocket address of the compute platform, such as `ws://<COMPUTE_PLATFORM_IP>:8765`. The LEMO platform uploads observations and receives model-generated actions through this connection.
- `task`: Task description sent to the model, such as `pick up the red cube`. It must match the task description used for training.
- `embodiment`: Robot configuration identifier, such as `galaxea_a1z`. It selects the appropriate observation, action, and model adaptation settings on the server and must agree with the server configuration.
- `send_raw_jpeg`: Image transmission mode. `true` sends JPEG bytes directly for decoding on the compute platform; `false` decodes and resizes images on the LEMO platform before sending arrays. Select the mode supported by the server protocol.
- `smoothing`: Trajectory smoothing for inference and replay. `bcubic` uses cubic spline interpolation over recent target points to make sparse action targets more continuous, with some added latency. Teleoperation uses its separate `arm_smoothing` setting.
- `smooth_vmax`: Joint velocity limit for the smoothed trajectory, in rad/s. The example value of 3.5 is approximately 201°/s.
- `smooth_amax`: Joint acceleration limit for the smoothed trajectory, in rad/s². It limits how quickly velocity changes.
- `smooth_jerk`: Joint jerk limit for the smoothed trajectory, in rad/s³. It limits how quickly acceleration changes and affects the smoothness of starts, stops, and direction changes.

After saving the configuration and starting the inference service, run the following on the LEMO platform:

```bash
ros2 launch lemo lemo.launch.py start_policy:=true
```

To temporarily override the URL at launch time:

```bash
ros2 launch lemo lemo.launch.py start_policy:=true policy_server_url:=ws://<COMPUTE_PLATFORM_ETHERNET_IP>:8765
```

The launcher reads the `policy:` settings automatically, so you do not need to repeat them each time. Restart the launch process after changing the configuration. Explicit command-line arguments take precedence over the file and can be used for debugging.

The smoothing values above are examples and must be validated for the actual hardware and model. Before the first hardware run, verify joint and gripper units and the model's normalization conventions. By default, gripper values are passed as percentages.

**Confirm the Connection and Start Inference**

Check that the LEMO platform logs show a connection to the configured WebSocket address, then open `http://<LEMO_PLATFORM_IP>:8000`. Click **Inference** (「推理」) in the dashboard to start sending policy actions. Starting the client alone does not immediately execute inference actions. Pause, homing, stop, and human takeover are available through the corresponding controls.

When troubleshooting inference, enable **Automatically record inference** (「自动录推理」) in the dashboard; it is off by default. The resulting recordings include raw actions, control targets, and feedback. If the inference connection drops, the client clears its queue, stops sending actions, and retries the connection.

Inspect `/policy_client/status` for connection status, action queue information, and clamping status.

## Run Modes and Episode Labels

`teleop_bridge` manages standby, teleoperation, inference, human takeover, pause, homing, and replay modes, and publishes the current state on `/run_mode/state`. Standby after startup or homing does not automatically enable inference. If the mode manager becomes unavailable, the policy client stops sending actions.

After a recording is saved, `run_mode_timeline.json` may be generated in the episode directory. It records the control source, time spent in each mode, and transitions, making it possible to distinguish teleoperation, policy execution, and human takeover data.

## Log Management

The unified launch defaults to writing runtime logs to `/dev/shm/ros_log`. A background process periodically archives inactive logs to `~/.ros/log`. Logs still in memory and not yet archived are lost on power failure. The dashboard may not show logs for the current session until the session has ended and the logs have been archived.

To write logs directly to disk:

```bash
ros2 launch lemo lemo.launch.py log_dir:=~/.ros/log
```

## Checking and Stopping the System

```bash
ros2 node list
```

Normal operation should include the teleoperation bridge, left/right arm bridges, and G4SPI nodes, along with enabled camera, recording, and dashboard nodes. Duplicate node names may indicate duplicate launches or leftover processes.

For normal shutdown, run the stop script included in the runtime package. Replace `1.x.x.x` with the installed package version:

```bash
sudo ~/lemo_1.x.x.x/scripts/lemo_setup.sh stop
```

This stops the arm bridges first and waits for motor disable commands to be sent before stopping the communication bridge and other nodes. Pressing Ctrl+C directly in the unified launch may stop the communication bridge first, preventing disable commands from reaching the motors. Use the ordered shutdown procedure above for normal shutdown.

For hardware faults or emergencies, follow the device's emergency-stop procedure. If gravity compensation causes sagging, drift, or abnormal posture, disable it and stop using it until the model and calibration have been checked.

---

## Troubleshooting

**Inference Startup**

| Symptom | Checks |
| --- | --- |
| Server reports `[FATAL]` at startup | Check the model files, Python path, and service configuration indicated by the error |
| Port already in use | Identify the process reported by the startup check; stop the old service or change the port, and update the client address on the LEMO platform accordingly |
| Policy client cannot connect | Check the compute platform's IP, network connectivity, port, firewall, and VPN routes |
| Connected but no actions execute | Confirm that inference is enabled in the dashboard, that both endpoints use the same `embodiment`, and inspect the client status and logs |
| LeRobot dependency or data-format issues | See `lemo-server/deploy/README_LEROBOT.md` |

**Permission Error When Starting the Policy Client**

```text
PermissionError: [Errno 13] Permission denied: '/dev/shm/ros_log/2026-10-21-16-02-16-383730-lubancat-9832'
```

The user cannot write to the log directory. Run the following to set a writable log location and adjust directory permissions:

```bash
mkdir -p "$HOME/.ros/log"
export ROS_LOG_DIR="$HOME/.ros/log"
sudo chown "$(id -u):$(id -g)" /dev/shm/ros_log
chmod u+rwx /dev/shm/ros_log
```
