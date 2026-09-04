#!/bin/sh
# Launch RBDOOM-3-BFG.
# The runtime fullscreen-toggle deadlock on native Wayland (NVIDIA Vulkan)
# is fixed locally in neo/sys/DeviceManager_VK.cpp: BeginFrame() now
# recreates the swapchain when vkAcquireNextImageKHR returns
# VK_ERROR_OUT_OF_DATE_KHR instead of deadlocking on the unsignaled
# acquire semaphore.
# If you ever hit windowing trouble again, uncomment the next line to
# run through XWayland as a fallback:
# export SDL_VIDEODRIVER=x11
cd "$(dirname "$0")"
exec ./RBDoom3BFG "$@"
