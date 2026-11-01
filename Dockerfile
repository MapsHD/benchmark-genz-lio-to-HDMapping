FROM ubuntu:20.04

SHELL ["/bin/bash", "-c"]
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# ── Base tools ────────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    gnupg2 \
    lsb-release \
    software-properties-common \
    build-essential \
    cmake \
    git \
    apt-transport-https \
    ca-certificates \
    wget \
    libeigen3-dev \
    libpcl-dev \
    libyaml-cpp-dev \
    libboost-dev \
    libapr1-dev \
    libaprutil1-dev \
    nlohmann-json3-dev \
    tmux \
    python3-pip \
    python3-yaml \
    && rm -rf /var/lib/apt/lists/*

# ── ROS 1 Noetic ─────────────────────────────────────────────────────────────
# Packages follow GenZ-LIO's ros/README.md (ROS 1 support).
RUN curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
    | gpg --dearmor -o /usr/share/keyrings/ros-archive-keyring.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] \
    http://packages.ros.org/ros/ubuntu $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/ros.list && \
    apt-get update && apt-get install -y --no-install-recommends \
    ros-noetic-desktop-full \
    ros-noetic-tf \
    ros-noetic-tf2-ros \
    ros-noetic-pcl-conversions \
    ros-noetic-pcl-ros \
    ros-noetic-visualization-msgs \
    ros-noetic-rosbag \
    python3-rosdep \
    python3-catkin-tools \
    && rm -rf /var/lib/apt/lists/*

# ── rosbags (used to convert ROS 2 bags to ROS 1, if needed) ─────────────────
RUN pip3 install --no-cache-dir "rosbags==0.9.22"

# ── Livox-SDK ────────────────────────────────────────────────────────────────
# Needed by livox_ros_driver (src/livox_ros_driver), which provides the
# livox_ros_driver/CustomMsg GenZ-LIO reads (lidar_type: livox); without it the
# driver's CMake would try to download the SDK during the build.
RUN git clone https://github.com/Livox-SDK/Livox-SDK.git /tmp/Livox-SDK && \
    cd /tmp/Livox-SDK/build && \
    cmake .. && \
    make -j$(nproc) && \
    make install && \
    rm -rf /tmp/Livox-SDK

# ── livox_ros_driver in its own workspace ────────────────────────────────────
# As in GenZ-LIO's ros/README.md: the driver is built and sourced before
# GenZ-LIO. GenZ-LIO's package.xml does not depend on it, so in a shared
# workspace catkin may configure GenZ-LIO first and miss the driver.
WORKDIR /livox_ws
COPY ./src/livox_ros_driver ./src/livox_ros_driver
RUN source /opt/ros/noetic/setup.bash && \
    catkin_make -DCMAKE_BUILD_TYPE=Release -j4

# ── Build catkin workspace (GenZ-LIO + converter) ────────────────────────────
WORKDIR /ros_ws

# catkin finds GenZ-LIO's ROS package in src/genz-lio/ros; it builds the core
# from ../cpp/genz_lio (Ubuntu 20.04's Eigen is 3.3, so the core's CMake
# fetches Eigen 3.4 at configure time, as in the author's ROS 1 CI).
COPY ./src/genz-lio              ./src/genz-lio
COPY ./src/genz-lio-to-hdmapping ./src/genz-lio-to-hdmapping

# Benchmark parameter files added to GenZ-LIO's config/ folder (next to its
# default/ and experiments/ ones); the benchmark launch file and RViz view next
# to GenZ-LIO's own; preflight check used by the run script.
COPY ./overlay/config/  ./src/genz-lio/ros/config/
COPY ./overlay/launch/  ./src/genz-lio/ros/launch/
COPY ./overlay/rviz/    ./src/genz-lio/ros/rviz/
COPY ./overlay/scripts/ /ros_ws/scripts/

# The CMake log must report "Livox CustomMsg support enabled". The final guard
# fails the image build loudly if an executable is missing. /ros_ws/devel/setup.bash
# chains /livox_ws, so sourcing it alone gives the driver's messages as well.
RUN set -o pipefail && \
    source /livox_ws/devel/setup.bash && \
    catkin_make -DCMAKE_BUILD_TYPE=Release -j4 2>&1 | tee /tmp/catkin_make.log && \
    grep -q "Livox CustomMsg support enabled" /tmp/catkin_make.log && \
    test -f /ros_ws/devel/lib/genz_lio/genz_lio_node && \
    test -f /ros_ws/devel/lib/genz_lio_to_hdmapping/listener && \
    echo "[build] genz_lio_node (with Livox CustomMsg) and converter present"

# ── Non-root user ─────────────────────────────────────────────────────────────
ARG UID=1000
ARG GID=1000
RUN groupadd -g $GID ros && \
    useradd -m -u $UID -g $GID -s /bin/bash ros && \
    chown -R $UID:$GID /ros_ws

RUN echo "source /opt/ros/noetic/setup.bash"   >> /root/.bashrc && \
    echo "source /ros_ws/devel/setup.bash"     >> /root/.bashrc && \
    echo "source /opt/ros/noetic/setup.bash"   >> /home/ros/.bashrc && \
    echo "source /ros_ws/devel/setup.bash"     >> /home/ros/.bashrc

CMD ["bash"]
