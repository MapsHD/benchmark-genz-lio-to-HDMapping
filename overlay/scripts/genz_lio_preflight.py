#!/usr/bin/env python3
"""Preflight check for the GenZ-LIO benchmark run.

GenZ-LIO subscribes to the LiDAR and IMU topics named in its parameter file
(common/lidar_topic, common/imu_topic). If either is missing from the bag, or
the LiDAR topic has a type GenZ-LIO does not read, it processes nothing and the
run records no output, so the check stops the run first (exit code 42, the run
script then skips the conversion).

LiDAR message type by preprocess/lidar_type:
  livox        livox_ros_driver/CustomMsg; livox_ros_driver2/CustomMsg has the
               same definition (same md5), so ROS 1 delivers it as well
  anything else (livox_pcl, velodyne, ouster, hesai, ...)   sensor_msgs/PointCloud2

Usage: genz_lio_preflight.py <parameter_file.yaml> <input.bag>
"""

import sys

import rosbag
import yaml

LIVOX_TYPES = ("livox_ros_driver/CustomMsg", "livox_ros_driver2/CustomMsg")


def main():
    config_path, bag_path = sys.argv[1], sys.argv[2]
    try:
        with open(config_path) as f:
            config = yaml.safe_load(f)
        lidar_topic = config["common"]["lidar_topic"]
        imu_topic = config["common"]["imu_topic"]
        lidar_type = str(config["preprocess"]["lidar_type"])
    except (OSError, KeyError, TypeError, yaml.YAMLError) as e:
        print(f"[preflight] ERROR: cannot read topics and lidar_type from parameter file {config_path}: {e}")
        sys.exit(42)
    lidar_types = LIVOX_TYPES if lidar_type == "livox" else ("sensor_msgs/PointCloud2",)
    print(f"[preflight] parameter file: {config_path}")
    print(f"[preflight] LiDAR topic: {lidar_topic} (lidar_type {lidar_type})  IMU topic: {imu_topic}")

    bag = rosbag.Bag(bag_path)
    topics = bag.get_type_and_topic_info().topics
    bag.close()

    ok = True
    for name, accepted in ((lidar_topic, lidar_types), (imu_topic, ("sensor_msgs/Imu",))):
        info = topics.get(name)
        if info is None or info.msg_type not in accepted:
            found = info.msg_type if info else "not in the bag"
            print(f"[preflight] ERROR: {name} must be {' or '.join(accepted)} ({found}).")
            ok = False
        else:
            print(f"[preflight] {name}: {info.message_count} msgs ({info.msg_type})")
    if not ok:
        for msg_type in lidar_types + ("sensor_msgs/Imu",):
            names = [t for t, i in topics.items() if i.msg_type == msg_type]
            print(f"[preflight] {msg_type} topics in this bag: {', '.join(names) or '(none)'}")
        print("[preflight] Choose the parameter file of your sensor (CONFIG_FILE) or set "
              "common/lidar_topic, common/imu_topic and preprocess/lidar_type in it.")
        sys.exit(42)


if __name__ == "__main__":
    main()
