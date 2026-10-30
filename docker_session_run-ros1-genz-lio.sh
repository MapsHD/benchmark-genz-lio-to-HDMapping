#!/bin/bash
# Run GenZ-LIO on a rosbag (ROS 1 .bag or ROS 2 bag directory), record output
# topics, then convert the recorded bag to an HDMapping session.
#
# GenZ-LIO publishes the body (IMU) pose on /Odometry and the scan in the odom
# frame on /cloud_registered (only while someone subscribes, which the
# recorder does), both stamped with the scan end time taken from the input
# messages. We record both, plus /clock as a bag time reference: GenZ-LIO's
# own clock is left untouched and the converter translates the result into
# bag time if needed.

IMAGE_NAME='genz-lio_noetic'
TMUX_SESSION='ros1_genz_lio'

DATASET_CONTAINER_PATH='/ros_ws/dataset/input.bag'
CONVERTED_BAG_CONTAINER='/tmp/dataset_ros1.bag'
BAG_OUTPUT_CONTAINER='/ros_ws/recordings'
CONFIG_MOUNT_CONTAINER='/ros_ws/config/genz_lio.yaml'
CONFIG_DIR_CONTAINER='/ros_ws/src/genz-lio/ros/config'

RECORDED_BAG_NAME="recorded-genz-lio.bag"
HDMAPPING_OUT_NAME="output_hdmapping"

# Recorded topics (used by the converter).
ODOM_TOPIC="${ODOM_TOPIC:-/Odometry}"
CLOUD_TOPIC="${CLOUD_TOPIC:-/cloud_registered}"

# GenZ-LIO parameter file (LiDAR/IMU topics, LiDAR type, extrinsics, noise):
# a file on the host, or a path relative to GenZ-LIO's config/ folder (its
# default/ and experiments/ files, and the benchmark's bunker.yaml).
# Default: GenZ-LIO's own launch default, default/velodyne.yaml.
CONFIG_FILE="${CONFIG_FILE:-default/velodyne.yaml}"

# RViz on by default — the live view of how GenZ-LIO tracks the dataset.
USE_RVIZ="${USE_RVIZ:-1}"

# Force Mesa software rendering by default so RViz renders even when the host
# GPU driver is not exposed to the container (the libGL "nvidia-drm" / amdgpu case).
LIBGL_SW="${LIBGL_SW:-1}"
if [[ "$LIBGL_SW" == "1" ]]; then LIBGL_ENV="1"; else LIBGL_ENV=""; fi

usage() {
  echo "Usage:"
  echo "  $0 <input.bag-or-ros2bag-dir> <output_dir>"
  echo
  echo "If no arguments are provided, a GUI file selector will be used."
  echo
  echo "Environment variables:"
  echo "  CONFIG_FILE  - GenZ-LIO parameter file: a host *.yaml, or a path relative to"
  echo "                 GenZ-LIO's config/ folder  (default: default/velodyne.yaml;"
  echo "                 bunker.yaml for the Bunker DVI dataset)"
  echo "  ODOM_TOPIC   - GenZ-LIO odometry output topic   (default: /Odometry)"
  echo "  CLOUD_TOPIC  - GenZ-LIO odom-frame scan topic   (default: /cloud_registered)"
  echo "  USE_RVIZ     - 1/0, launch RViz live view       (default: 1)"
  echo "  PLAY_RATE    - rosbag play rate                 (default: 1.0)"
  exit 1
}

echo "=== GenZ-LIO rosbag pipeline ==="

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
fi

if [[ $# -eq 2 ]]; then
  DATASET_HOST_PATH="$1"
  BAG_OUTPUT_HOST="$2"
elif [[ $# -eq 0 ]]; then
  command -v zenity >/dev/null || {
    echo "Error: zenity is not available"
    exit 1
  }
  DATASET_HOST_PATH=$(zenity --file-selection --title="Select BAG file (or ROS 2 bag directory)")
  BAG_OUTPUT_HOST=$(zenity --file-selection --directory --title="Select output directory")
else
  usage
fi

if [[ -z "$DATASET_HOST_PATH" || -z "$BAG_OUTPUT_HOST" ]]; then
  echo "Error: no file or directory selected"
  exit 1
fi

if [[ ! -e "$DATASET_HOST_PATH" ]]; then
  echo "Error: input does not exist: $DATASET_HOST_PATH"
  exit 1
fi

# Parameter file: a host file is mounted into the container; a relative path
# that is not a host file is one shipped in GenZ-LIO's config/ folder (checked
# inside the container).
CONFIG_MOUNT=()
if [[ -f "$CONFIG_FILE" ]]; then
  CONFIG_FILE=$(realpath "$CONFIG_FILE")
  CONFIG_MOUNT=(-v "$CONFIG_FILE":"$CONFIG_MOUNT_CONTAINER":ro)
  CONFIG_CONTAINER="$CONFIG_MOUNT_CONTAINER"
  CONFIG_DESC="$CONFIG_FILE (host)"
elif [[ "$CONFIG_FILE" != /* ]]; then
  CONFIG_CONTAINER="$CONFIG_DIR_CONTAINER/$CONFIG_FILE"
  CONFIG_DESC="$CONFIG_FILE (GenZ-LIO config/)"
else
  echo "Error: CONFIG_FILE does not exist: $CONFIG_FILE"
  exit 1
fi

mkdir -p "$BAG_OUTPUT_HOST"

DATASET_HOST_PATH=$(realpath "$DATASET_HOST_PATH")
BAG_OUTPUT_HOST=$(realpath "$BAG_OUTPUT_HOST")

# RViz on/off resolved to a roslaunch boolean
RVIZ_ARG=false; [[ "$USE_RVIZ" == "1" ]] && RVIZ_ARG=true

echo "Input           : $DATASET_HOST_PATH"
echo "Output dir      : $BAG_OUTPUT_HOST"
echo "Parameter file  : $CONFIG_DESC"
echo "Odom topic      : $ODOM_TOPIC"
echo "Cloud topic     : $CLOUD_TOPIC"

if [[ -d "$DATASET_HOST_PATH" ]]; then
  INPUT_IS_DIR=1
else
  INPUT_IS_DIR=0
fi

xhost +local:docker >/dev/null

# ── Phase 1: run GenZ-LIO + record output topics ─────────────────────────────
docker run -it --rm \
  --network host \
  -e DISPLAY=$DISPLAY \
  -e ROS_HOME=/tmp/.ros \
  -e LIBGL_ALWAYS_SOFTWARE="$LIBGL_ENV" \
  -e RVIZ_ARG="$RVIZ_ARG" \
  -e CONFIG_CONTAINER="$CONFIG_CONTAINER" \
  -e ODOM_TOPIC="$ODOM_TOPIC" \
  -e CLOUD_TOPIC="$CLOUD_TOPIC" \
  -e INPUT_IS_DIR="$INPUT_IS_DIR" \
  -e PLAY_RATE="${PLAY_RATE:-1.0}" \
  -u 1000:1000 \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v "$DATASET_HOST_PATH":"$DATASET_CONTAINER_PATH":ro \
  -v "$BAG_OUTPUT_HOST":"$BAG_OUTPUT_CONTAINER" \
  "${CONFIG_MOUNT[@]}" \
  "$IMAGE_NAME" \
  /bin/bash -c '

    source /opt/ros/noetic/setup.bash
    source /ros_ws/devel/setup.bash

    # ── If input is a ROS 2 bag directory, convert to a ROS 1 bag ──────────
    if [[ "$INPUT_IS_DIR" == "1" ]]; then
      echo "[convert] Converting ROS 2 bag to ROS 1 bag format..."
      rm -f '"$CONVERTED_BAG_CONTAINER"'
      rosbags-convert '"$DATASET_CONTAINER_PATH"' --dst '"$CONVERTED_BAG_CONTAINER"' || {
        echo "[convert] ERROR: rosbags-convert failed"; exit 1; }
      ROS1_BAG="'"$CONVERTED_BAG_CONTAINER"'"
    else
      ROS1_BAG="'"$DATASET_CONTAINER_PATH"'"
    fi

    export ROS1_BAG
    echo "[convert] ROS 1 bag ready at: $ROS1_BAG"
    ls -la $ROS1_BAG

    # ── Preflight: the LiDAR and IMU topics of the parameter file must be in ─
    # the bag with a type GenZ-LIO reads, otherwise it processes nothing and
    # the run records no output.
    if ! python3 /ros_ws/scripts/genz_lio_preflight.py "$CONFIG_CONTAINER" "$ROS1_BAG"; then
      echo "[preflight] input check failed, nothing is run"
      exit 42
    fi

    tmux new-session -d -s '"$TMUX_SESSION"'

    # ---------- PANE 0: roscore ----------
    tmux send-keys -t '"$TMUX_SESSION"' '\''
source /opt/ros/noetic/setup.bash
source /ros_ws/devel/setup.bash
echo "[roscore] starting..."
roscore
'\'' C-m

    # ---------- PANE 1: GenZ-LIO (+ RViz) ----------
    tmux split-window -v -t '"$TMUX_SESSION"'
    tmux send-keys -t '"$TMUX_SESSION"' '\''sleep 4
source /opt/ros/noetic/setup.bash
source /ros_ws/devel/setup.bash
echo "[genz_lio] launching genz_lio_bench.launch (config=$CONFIG_CONTAINER, rviz=$RVIZ_ARG) ..."
roslaunch genz_lio genz_lio_bench.launch config:=$CONFIG_CONTAINER rviz:=$RVIZ_ARG
'\'' C-m

    # ---------- PANE 2: rosbag record ----------
    tmux split-window -v -t '"$TMUX_SESSION"'
    tmux send-keys -t '"$TMUX_SESSION"' '\''sleep 6
source /opt/ros/noetic/setup.bash
source /ros_ws/devel/setup.bash
rm -f '"$BAG_OUTPUT_CONTAINER/$RECORDED_BAG_NAME"'
echo "[record] start"
rosbag record $ODOM_TOPIC $CLOUD_TOPIC /clock -O '"$BAG_OUTPUT_CONTAINER/$RECORDED_BAG_NAME"'
echo "[record] exit"
'\'' C-m

    # ---------- PANE 3: rosbag play ----------
    tmux split-window -v -t '"$TMUX_SESSION"'
    tmux send-keys -t '"$TMUX_SESSION"' '\''sleep 10
source /opt/ros/noetic/setup.bash
source /ros_ws/devel/setup.bash
echo "[play] start"
rosbag play --clock --rate ${PLAY_RATE:-1.0} $ROS1_BAG; tmux wait-for -S BAG_DONE;
echo "[play] done"
'\'' C-m

    # ---------- PANE 4: diagnostics ----------
    tmux split-window -h -t '"$TMUX_SESSION"'
    tmux send-keys -t '"$TMUX_SESSION"' '\''sleep 14
source /opt/ros/noetic/setup.bash
source /ros_ws/devel/setup.bash
echo "=== ROS 1 DIAGNOSTICS ==="
echo ""
echo "--- Active topics ---"
rostopic list
echo ""
echo "--- Checking GenZ-LIO output: $ODOM_TOPIC ---"
timeout 5 rostopic hz $ODOM_TOPIC 2>&1 &
echo ""
echo "--- Checking GenZ-LIO output: $CLOUD_TOPIC ---"
timeout 5 rostopic hz $CLOUD_TOPIC 2>&1 &
wait
echo ""
echo "[diag] done — you can type ROS 1 commands here, e.g.:"
echo "  rostopic echo $ODOM_TOPIC"
'\'' C-m

    # ---------- Control window (window 1) ----------
    # This is the window the user attaches to; the 5 noisy panes are on window 0.
    # It waits for the play pane to signal end of playback, then tears the whole
    # session down.
    tmux new-window -t '"$TMUX_SESSION"' -n control '\''
source /opt/ros/noetic/setup.bash
source /ros_ws/devel/setup.bash
echo "[control] waiting for bag playback to finish..."
tmux wait-for BAG_DONE
echo "[control] bag playback finished — shutting down"

# Give GenZ-LIO a moment to process remaining queued scans
sleep 3

# Graceful stop: Ctrl+C to each pane
# Pane layout: 0=roscore, 1=genz_lio+rviz, 2=recorder, 3=play, 4=diag
echo "[control] sending Ctrl+C to all panes..."
tmux send-keys -t '"$TMUX_SESSION"':0.2 C-c
sleep 1
tmux send-keys -t '"$TMUX_SESSION"':0.1 C-c
sleep 1
tmux send-keys -t '"$TMUX_SESSION"':0.0 C-c
sleep 3

# Force-kill by process name
echo "[control] force-killing remaining processes..."
pkill -9 genz_lio_node    2>/dev/null || true
pkill -9 rviz             2>/dev/null || true
pkill -9 rosmaster        2>/dev/null || true
pkill -9 rosout           2>/dev/null || true
sleep 1

echo "[control] terminating tmux"
tmux kill-server
'\''

    tmux attach -t '"$TMUX_SESSION"'
  '

# The preflight check failed: nothing was recorded, and converting would pick
# up a stale recording from an earlier run.
if [[ $? -eq 42 ]]; then
  echo "=== ABORTED: input check failed, no conversion ==="
  exit 1
fi

# ── Phase 2: convert recorded bag to HDMapping session ────────────────────────
echo "=== Converting recorded bag to HDMapping session ==="

docker run -it --rm \
  --network host \
  -e ROS_HOME=/tmp/.ros \
  -u 1000:1000 \
  -v "$BAG_OUTPUT_HOST":"$BAG_OUTPUT_CONTAINER" \
  "$IMAGE_NAME" \
  /bin/bash -c "
    set -e
    source /opt/ros/noetic/setup.bash
    source /ros_ws/devel/setup.bash
    rosrun genz_lio_to_hdmapping listener \
      \"$BAG_OUTPUT_CONTAINER/$RECORDED_BAG_NAME\" \
      \"$BAG_OUTPUT_CONTAINER/$HDMAPPING_OUT_NAME-genz-lio\" \
      \"$ODOM_TOPIC\" \
      \"$CLOUD_TOPIC\"
  "

echo "=== DONE ==="
