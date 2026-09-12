-- NV-EGPU-Buddy: NVIDIA eGPU scanout corruption guards for gamescope's DRM backend.
-- Primary (non-laggy): disable explicit sync + in-fence on the NVIDIA output (gamescope #1964 corruption).
-- Optional (laggy, opt-in): force syncobj wait on commit.
local function env_enabled(name)
    local v = os.getenv(name)
    if v == nil or v == "" then return false end
    v = string.lower(v)
    return v ~= "0" and v ~= "false" and v ~= "no" and v ~= "off"
end
if env_enabled("NV_EGPU_GAMESCOPE_DISABLE_EXPLICIT_SYNC") then
    gamescope.convars.drm_debug_disable_explicit_sync.value = true
    gamescope.convars.drm_debug_disable_in_fence_fd.value = true
    debug("[nv-egpu-buddy] DRM explicit sync + in-fence disabled for the NVIDIA eGPU output")
end
if env_enabled("NV_EGPU_GAMESCOPE_DRM_SYNC_GUARDS") then
    gamescope.convars.drm_debug_syncobj_force_wait_on_commit.value = true
    gamescope.convars.drm_debug_disable_in_fence_fd.value = true
    debug("[nv-egpu-buddy] DRM syncobj wait-on-commit guard enabled (serialized, laggy)")
end
