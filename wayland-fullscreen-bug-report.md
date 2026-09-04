# Deadlock when toggling fullscreen at runtime on Wayland (Vulkan/NVRHI)

## Summary

Toggling `r_fullscreen` at runtime (e.g. from the video settings menu) permanently
deadlocks the game on native Wayland. Both exclusive (`r_fullscreen 1`) and
borderless (`r_fullscreen -2`) transitions are affected. Starting the game already
in fullscreen works; only the live toggle hangs. Running through XWayland
(`SDL_VIDEODRIVER=x11`) avoids it.

## Environment

- master @ 95306db, Linux release build (`cmake-linux-release.sh`, GCC 16.1.1)
- CachyOS (Arch), KDE Plasma on Wayland
- NVIDIA proprietary driver 610.43.02, Vulkan loader 1.4.350
- SDL2 API via sdl2-compat 2.32.70 on SDL3 3.4.10 (Arch has replaced classic SDL2
  with sdl2-compat, so this is what every up-to-date Arch/CachyOS user runs)

## Reproduction

```
./RBDoom3BFG +set r_fullscreen 0 +wait 120 +set r_fullscreen 1 +wait 240 +quit
```

Hangs 5/5 times on native Wayland. Same command with `SDL_VIDEODRIVER=x11` exits
cleanly 5/5 times.

## Root cause

After `VKimp_SetScreenParms()` switches the window mode, the Wayland compositor
invalidates the swapchain. On the next frame, `DeviceManager_VK::BeginFrame()`'s
`vkAcquireNextImageKHR` returns `VK_ERROR_OUT_OF_DATE_KHR`. Instrumented trace:

```
[trace] BeginFrame: acquire result=0 image=1        <- last good frame
[trace] Present:    presentKHR result=0
[trace] BeginFrame: acquire result=-1000001004      <- VK_ERROR_OUT_OF_DATE_KHR
[trace] Present:    presentKHR result=-1000001004
[trace] BeginFrame: acquire result=-1000001004      <- second failed acquire
[trace] Present:    waitEventQuery (sync3)...       <- deadlock, never returns
```

The only guard on the acquire result is an `assert`, which is compiled out in
release builds. The engine then:

1. proceeds with the failed acquire — per spec a failed `vkAcquireNextImageKHR`
   leaves the acquire semaphore **unsignaled**;
2. `queueWaitForSemaphore( m_PresentSemaphore )` makes the frame's command-list
   submission wait on that never-signaled semaphore, permanently wedging the
   graphics queue;
3. the next frame's `Present()` blocks forever in
   `waitEventQuery( m_FrameWaitQuery )` → `nvrhi::vulkan::Queue::waitCommandList`
   inside the driver, because the event query sits behind the wedged submission.

Stack at hang (main thread):

```
poll ()                                   <- libnvidia-glcore
nvrhi::vulkan::Queue::waitCommandList()
DeviceManager_VK::Present()
idRenderBackend::GL_BlockingSwapBuffers()
idRenderSystemLocal::SwapCommandBuffers()
idCommonLocal::Frame()
```

The existing size-based recreate path (`DeviceManager::UpdateWindowSize` →
`ResizeSwapChain`) does not save the situation because the compositor can
invalidate the swapchain before the SDL resize event is seen — and for
transitions at identical resolution there is no size change at all. X11 gets
away with it because the driver reports `VK_SUBOPTIMAL_KHR` there, which still
signals the semaphore.

## Fix

Handle `VK_ERROR_OUT_OF_DATE_KHR` in `BeginFrame()` by recreating the swapchain
and re-acquiring before any work is queued on the unsignaled semaphore (patch
attached, `wayland-fullscreen-fix.patch`). The present-semaphore pool is created
once in `CreateDeviceAndSwapChain()` and survives `ResizeSwapChain()`, so no
semaphore management changes are needed. `Present()` needs no change: per spec a
failed `vkQueuePresentKHR` still executes its semaphore wait.

Verified after the fix: the reproduction sequence plus a full
windowed → exclusive → windowed → borderless → windowed cycle completes cleanly
on native Wayland (5/5 runs), with the recovery firing exactly once per
transition.
