## Hint

Please change branch to [Bunker-DVI-Dataset-reg-1](https://github.com/MapsHD/benchmark-genz-lio-to-HDMapping/tree/Bunker-DVI-Dataset-reg-1) for quick experiment.

## Example Dataset:

Download the dataset from [Bunker DVI Dataset](https://charleshamesse.github.io/bunker-dvi-dataset/)

# benchmark-genz-lio-to-HDMapping

Runs the [GenZ-LIO](https://github.com/cocel-postech/genz-lio) LiDAR-inertial
odometry on a ROS 1 bag file and converts the output to an
[HDMapping](https://github.com/MapsHD/HDMapping) session.

GenZ-LIO (D. Lee et al., "Generalizable LiDAR-Inertial Odometry Beyond
Confined–Open Boundaries") is an iterated error-state Kalman filter with
scale-aware adaptive voxelization and GenZ's hybrid point-to-plane /
point-to-point metric, built to stay robust across confined spaces, open
environments and the transitions between them. The benchmark runs its ROS 1
(Noetic) wrapper.

## Prerequisites

- Docker
- A ROS 1 bag with a LiDAR topic and a `sensor_msgs/Imu` topic (ROS 2 bags are
  automatically converted to ROS 1 format). The LiDAR topic is a
  `livox_ros_driver/CustomMsg` (or `livox_ros_driver2/CustomMsg`) for
  `lidar_type: livox` and a `sensor_msgs/PointCloud2` for all other LiDAR types.

## Step 1 — Clone with submodules

```bash
git clone https://github.com/MapsHD/benchmark-genz-lio-to-HDMapping.git --recursive
cd benchmark-genz-lio-to-HDMapping
```

## Step 2 — Build the Docker image

```bash
docker build -t genz-lio_noetic .
```

This installs:
- Ubuntu 20.04 + ROS 1 Noetic, PCL, yaml-cpp (GenZ-LIO fetches Eigen 3.4 while building, as in its own ROS 1 CI)
- Livox-SDK and livox_ros_driver (Livox CustomMsg support), built in its own
  workspace before GenZ-LIO, as in GenZ-LIO's ROS 1 instructions
- catkin workspace with `genz_lio` and `genz_lio_to_hdmapping`

## Step 3 — Run the pipeline

```bash
chmod +x docker_session_run-ros1-genz-lio.sh
./docker_session_run-ros1-genz-lio.sh /path/to/input.bag /path/to/output/dir
```

Or with no arguments to use a GUI file selector (requires `zenity`).

| Variable | Default | Meaning |
|----------|---------|---------|
| `CONFIG_FILE` | `default/velodyne.yaml` | GenZ-LIO parameter file: a file on the host, or a path relative to GenZ-LIO's [config/](https://github.com/cocel-postech/genz-lio/tree/master/ros/config) folder |
| `USE_RVIZ` | `1` | RViz live view |
| `PLAY_RATE` | `1.0` | rosbag play rate (lower it if GenZ-LIO cannot keep up) |

GenZ-LIO ships sensor templates in `default/` (`avia.yaml`, `mid360.yaml`,
`ouster.yaml`, `velodyne.yaml`, ...) and the configurations of its paper's
experiments in `experiments/`. The templates have zero LiDAR-IMU extrinsics as
placeholders; set your sensor's calibration in a copy and pass it:

```bash
CONFIG_FILE=/path/to/my_sensor.yaml \
  ./docker_session_run-ros1-genz-lio.sh /path/to/input.bag /path/to/output/dir
```

For the Bunker DVI dataset (Livox Mid-360) the image also ships `bunker.yaml`,
see [overlay/config/bunker.yaml](overlay/config/bunker.yaml): GenZ-LIO's
`default/mid360.yaml` with the Mid-360's LiDAR-IMU extrinsic and the full
(dense) scan published.

Before anything starts, the script checks that both topics of the parameter
file are in the bag with a type GenZ-LIO reads for that LiDAR type.

**What happens:**

The script opens a Docker container with a tmux session containing five panes on
window 0 and a `control` window (window 1, the attach target):

| Pane | Role |
|------|------|
| 0 | `roscore` |
| 1 | `roslaunch genz_lio genz_lio_bench.launch` — GenZ-LIO's `odometry.launch` (+ RViz live view) |
| 2 | `rosbag record /Odometry /cloud_registered /clock` |
| 3 | `rosbag play --clock` — plays your input bag |
| 4 | diagnostics — shows active topics and publishing rates |

When playback finishes, the control window stops the recorder, kills all nodes
and RViz, and exits tmux. A second Docker run then converts the recorded bag
into the HDMapping session format.

## Step 4 — Open in HDMapping

Output files appear in `<output_dir>/output_hdmapping-genz-lio/`:

```
lio_initial_poses.reg
poses.reg
scan_lio_0.laz
...
session.json
trajectory_lio_0.csv
...
```

Open `session.json` with the
[multi_view_tls_registration_step_2](https://github.com/MapsHD/HDMapping)
application.

## Notes on GenZ-LIO

GenZ-LIO publishes:

| Topic | Type | Meaning |
|-------|------|---------|
| `/Odometry` | `nav_msgs/Odometry` | the 6-DoF IMU (body) pose in the `odom` frame, one per scan |
| `/cloud_registered` | `sensor_msgs/PointCloud2` | the scan in the `odom` frame, one per scan (voxelized or dense, `publish/dense_publish_en`) |
| `/path` | `nav_msgs/Path` | the trajectory so far, for display |

The converter records `/Odometry` + `/cloud_registered`. GenZ-LIO publishes
the scan only while someone subscribes to it, which the recorder does.

**Timestamps:** the benchmark does not change GenZ-LIO's clock (no
`use_sim_time`). GenZ-LIO stamps every output with the scan end time taken from
the input messages, so the result is in bag time; `/clock` is recorded as a
reference and the converter translates the result into bag time only if it is
not (it reports which case applied).

## Contact

januszbedkowski@gmail.com
