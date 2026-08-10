-- TXR Weather Mod v3.0
-- systems/audio.lua
-- Phase 10: Weather audio (rain, wind, thunder). WORKING since 3.2.0 via the
-- direct-spawn engine: the UDS sound assets are loaded and played through
-- GameplayStatics:SpawnSound2D (UEHelpers) on the game thread, with volumes
-- scaled from UDW's live Rain / Wind Intensity, and thunder one-shots on a
-- randomized timer while Thunder/Lightning is high. Loops are respawned if a
-- level change (or a non-looping wave) stops them; everything fades out on
-- course unload.
--
-- UDW's own sound system produces NO audio in TXR (verified: enable + volumes +
-- its apply functions all execute and read back correctly, but Sound_Global
-- never plays, even with a direct FadeIn kick). HOWEVER its apply functions are
-- LOAD-BEARING: calling "Static Properties - Sound Effects" / "Instant Sound
-- Update" makes UDW async-load its soft-referenced sound assets into memory,
-- and that is what makes our StaticFindObject/StaticLoadObject on those assets
-- succeed (StaticLoadObject alone fails for them in TXR; removing the native
-- kick in the 3.2.0 cleanup silenced everything). So the native apply stays as
-- the ASSET LOADER, one-shot per course, and the audible path is the spawns.

local Audio = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local State = require("core.state")
local Config = require("config")

-- Lazy-load to avoid circular dependencies
local Actors = nil
local UEH = nil

local MODULE = "Audio"

-- ============== CONFIGURATION ==============
local ENABLE_RAIN_AUDIO = true
local ENABLE_WIND_AUDIO = true
local ENABLE_THUNDER_AUDIO = true

-- Volume scaling
local RAIN_VOLUME_SCALE = 1.0
local WIND_VOLUME_SCALE = 0.8
local THUNDER_VOLUME_SCALE = 1.0
local CLOSE_THUNDER_MIN = 7.0   -- Thunder/Lightning level below which only
                                -- distant rumbles play (Config.Audio.CloseThunderMin)

-- ============== UDW NATIVE SOUND PROPERTIES / FUNCTIONS (v1.5 names) ==============
-- Used only as the asset-loading kick (see header); they make no sound themselves.
local PROP_ENABLE_SOUNDS = "Enable Weather Sound Effects"
local PROP_RAIN_VOLUME = "Rain Volume"
local PROP_WIND_VOLUME = "Wind Volume"
local FN_STATIC = "Static Properties - Sound Effects"
local FN_APPLY_VOLUMES = "Apply Sound Effects Volume Levels"
local FN_INSTANT_UPDATE = "Instant Sound Update"

-- ============== DIRECT-SPAWN SOUND ASSETS ==============
-- MetaSound loops (UDW's own weather loops) + plain-wave thunder one-shots.
local ASSET_RAIN_LOOP = "/Game/UltraDynamicSky/Sound/MetaSounds/UDS_Rain_Loop.UDS_Rain_Loop"
local ASSET_WIND_FALLBACK = "/Game/UltraDynamicSky/Sound/Wind/BrownianNoise_1.BrownianNoise_1"
local ASSET_DISTANT_THUNDER = "/Game/UltraDynamicSky/Sound/Distant_Thunder/DistantThunder_%d.DistantThunder_%d"
local ASSET_CLOSE_THUNDER = "/Game/UltraDynamicSky/Sound/Close_Thunder/CloseThunder_%d.CloseThunder_%d"
local DISTANT_THUNDER_COUNT = 11
local CLOSE_THUNDER_COUNT = 6

local SETTLE_TICKS = 32          -- ~4s at 8 Hz past BeginPlay before applying
local UPDATE_INTERVAL_TICKS = 8  -- ~1s between direct-spawn volume updates
local THUNDER_GAP_MIN = 7.0      -- seconds between thunder one-shots
local THUNDER_GAP_MAX = 20.0
-- Failed asset LOADS per path per course before the asset is declared dead, at
-- roughly one attempt per second. Despite the old name this never counted spawn
-- failures: countSpawnFail is called only when loadSoundGT returns nil (a
-- SpawnSound2D that returns no component does not count, see spawn2DGT).
-- DO NOT LOWER THIS. It was cut to 3 on 2026-07-30 on the reasoning that "a
-- load which fails for a path fails the same way every time", which is exactly
-- backwards here: the failure is TRANSIENT. These assets are soft-referenced,
-- and nothing resolves until UDW's native kick finishes an ASYNC load. Measured
-- the same day with the two-point probe below: at 8 ticks past the kick all four
-- test assets read present=false, at 120 ticks (~15 s) all four read present=true
-- (UDS_Global_WeatherSounds, UDS_Directional_WeatherSounds and UDS_Rain_Loop as
-- MetaSoundSource, BrownianNoise_1 as SoundWave). They ARE in TXR's cook. A
-- budget of 3 gives up at ~5 s, before the load lands, and silences rain audio
-- outright, which is the same failure the 3.2.0 cleanup caused by removing the
-- native kick. 30 covers the measured ~15 s with 2x margin.
local MAX_LOAD_FAILS = 30

-- ============== STATE ==============
local isInitialized = false
local audioEnabled = true
local settleTicks = 0
local appliedThisCourse = false
local applied = false
local updateCounter = 0
local pendingUpdate = false  -- a game-thread sound update is queued

-- Direct-spawn state (only touched on the game thread after the first spawn)
local rainAC = nil
local windAC = nil
local nextThunderAt = 0
local kickTicks = -1   -- ticks since the native load kick; -1 = not kicked yet
local warnedOnce = {}  -- one-time warnings per asset/subsystem
local spawnFails = {}  -- per-asset failed spawn attempts this course
local deadAssets = {}  -- assets given up on this course (see MAX_LOAD_FAILS)
-- 2026-08-04 (field case that night: ONE kick, and the async load never
-- landed; BrownianNoise_1 burned all 30 attempts over 41 s): a stuck load
-- gets the kick re-fired at 10 and 20 fails. The kick is idempotent
-- (three UDW property writes plus UDW's own three apply calls). Set by
-- countSpawnFail, consumed by Tick (which is defined after the kick fn,
-- so it can reference it without the local-ordering trap).
local kickRefireWanted = false
local probeFired = {}  -- per-offset: probe sample landed (or was queued)

-- ============== INTERNAL FUNCTIONS ==============

local function getActors()
    if not Actors then
        local success, mod = pcall(require, "systems.actors")
        if success then Actors = mod end
    end
    return Actors
end

local function warnOnce(key, msg, ctx)
    if warnedOnce[key] then return end
    warnedOnce[key] = true
    Log.Warn(MODULE, msg, ctx)
end

-- ---------- game-thread-only helpers (call only from ExecuteInGameThread) ----------

--- True while a map teardown is in progress. Game-thread jobs are scheduled
--- from the async tick, so the world can start dying between schedule time and
--- run time; every GT entry point must re-check this at RUN time (a spawn or
--- native call against a dying world is an uncatchable access violation).
local function teardownActiveGT()
    local actors = getActors()
    if actors and actors.IsDiscoverySuspended then
        return actors.IsDiscoverySuspended()
    end
    return false
end

local function loadSoundGT(path)
    local obj = nil
    pcall(function() obj = StaticFindObject(path) end)
    if obj and obj.IsValid and obj:IsValid() then return obj end
    local ok, loaded = pcall(function() return StaticLoadObject(nil, nil, path) end)
    if ok and loaded and loaded.IsValid and loaded:IsValid() then return loaded end
    return nil
end

--- WHICH UDS SOUNDS ARE RESOLVABLE, AND WHEN (2026-07-30).
--- TIMING IS THE WHOLE POINT, and the first version of this probe got it wrong.
--- Per this module's header: StaticLoadObject ALONE fails for these assets in
--- TXR, and they only become resolvable after UDW's native apply kicks an ASYNC
--- load. A probe that samples before the kick, or in the same frame as it,
--- therefore reports a false negative on assets that are perfectly present. That
--- is exactly what happened: the first run reported all four absent while sound
--- was audibly playing in game.
--- So sample TWICE, both after the kick, and print the tick offset. The same
--- async-load mechanism is why UDW's Rain Particles component carries
--- RainParticlesAsset=nil for the first ~38 s of a course and then suddenly has
--- /Game/UltraDynamicSky/Particles/Rain assigned: sounds and rain particles are
--- one bug, not two.
local PROBE_PATHS = {
    -- the two MetaSounds UDW itself references (decompiled reference list)
    "/Game/UltraDynamicSky/Sound/MetaSounds/UDS_Global_WeatherSounds.UDS_Global_WeatherSounds",
    "/Game/UltraDynamicSky/Sound/MetaSounds/UDS_Directional_WeatherSounds.UDS_Directional_WeatherSounds",
    -- the loose waves this module spawns directly and reports as "not cooked"
    "/Game/UltraDynamicSky/Sound/MetaSounds/UDS_Rain_Loop.UDS_Rain_Loop",
    "/Game/UltraDynamicSky/Sound/Wind/BrownianNoise_1.BrownianNoise_1",
}
-- Ticks after the native kick at which to sample, 8 Hz: ~1 s and ~15 s. Two
-- samples separate "absent from the cook" from "async load has not landed yet",
-- which a single sample cannot do.
local PROBE_AT_TICKS = { 8, 120 }

local function probeUDSSoundsGT(offsetTicks)
    for _, p in ipairs(PROBE_PATHS) do
        local snd = loadSoundGT(p)
        local cls = "?"
        if snd then
            pcall(function() cls = snd:GetClass():GetFName():ToString() end)
        end
        Log.Info(MODULE, "UDS sound probe", {
            asset = p:match("([^%./]+)%.[^%.]+$") or p,
            present = snd ~= nil,
            class = cls,
            ticks_after_kick = offsetTicks,
        })
    end
end

local function getWorldGT()
    local actors = getActors()
    if not actors then return nil end
    local uds = actors.GetUDS()
    if not uds then return nil end
    local w = nil
    pcall(function() w = uds:GetWorld() end)
    if w and w.IsValid and w:IsValid() then return w end
    return nil
end

local function getGameplayStaticsGT()
    if not UEH then pcall(function() UEH = require("UEHelpers") end) end
    if not UEH then
        warnOnce("UEHelpers", "UEHelpers not available: direct sound spawning disabled")
        return nil
    end
    local gs = nil
    pcall(function() gs = UEH.GetGameplayStatics() end)
    if gs and gs.IsValid and gs:IsValid() then return gs end
    warnOnce("GameplayStatics", "GameplayStatics not available: direct sound spawning disabled")
    return nil
end

--- Count a failed asset LOAD; after MAX_LOAD_FAILS the asset is dead for
--- the rest of the course and no further load/spawn is attempted
local function countSpawnFail(path)
    spawnFails[path] = (spawnFails[path] or 0) + 1
    if spawnFails[path] == 10 or spawnFails[path] == 20 then
        kickRefireWanted = true
    end
    if spawnFails[path] >= MAX_LOAD_FAILS then
        deadAssets[path] = true
        warnOnce("dead_" .. path, "Sound never became playable: giving up for this course",
            {asset = path, attempts = spawnFails[path]})
    end
end

--- Spawn a 2D sound. Returns the audio component or nil (each failure logged).
local function spawn2DGT(path, vol, label)
    if deadAssets[path] then return nil end
    local gs = getGameplayStaticsGT()
    if not gs then return nil end
    local w = getWorldGT()
    if not w then return nil end
    local snd = loadSoundGT(path)
    if not snd then
        warnOnce(path, "Sound asset not found (not cooked into TXR?)", {asset = path})
        countSpawnFail(path)
        return nil
    end
    spawnFails[path] = nil
    local ac = nil
    -- (WorldContext, Sound, Volume, Pitch, StartTime, Concurrency, bPersistAcrossLevelTransition, bAutoDestroy)
    pcall(function() ac = gs:SpawnSound2D(w, snd, vol, 1.0, 0.0, nil, false, true) end)
    if ac and ac.IsValid and ac:IsValid() then
        Log.Debug(MODULE, "Spawned 2D sound", {label = label, vol = vol})
        return ac
    end
    warnOnce("spawn_" .. label, "SpawnSound2D returned no component", {label = label, asset = path})
    return nil
end

local function fadeKillGT(ac)
    if ac and ac.IsValid and ac:IsValid() then
        pcall(function() ac:FadeOut(0.6, 0.0) end)
    end
end

--- Keep one looping/ambient slot alive at the given volume; nil vol kills it.
local function updateLoopGT(ac, path, vol, label)
    if not vol then
        if ac then fadeKillGT(ac) end
        return nil
    end
    local alive = false
    if ac and ac.IsValid and ac:IsValid() then
        pcall(function() alive = ac:IsPlaying() end)
    end
    if alive then
        pcall(function() ac:SetVolumeMultiplier(vol) end)
        return ac
    end
    -- Not spawned yet, invalidated by a level change, or a non-looping wave that
    -- finished: (re)spawn it
    return spawn2DGT(path, vol, label)
end

--- Full direct-spawn update for one snapshot of the weather state (game
--- thread). thunderLevel = the UDW Thunder/Lightning value: 0 = silent,
--- below CLOSE_THUNDER_MIN = distant rumbles only, above = full mix
--- (Rain runs 4 = distant only; Thunderstorm runs 10 = both).
local function updateSoundsGT(rainVol, windVol, thunderLevel)
    if teardownActiveGT() then return end
    rainAC = updateLoopGT(rainAC, ASSET_RAIN_LOOP, rainVol, "rain_loop")
    windAC = updateLoopGT(windAC, ASSET_WIND_FALLBACK, windVol, "wind_loop")

    local thunderOn = (tonumber(thunderLevel) or 0) > 0.5
    if thunderOn and ENABLE_THUNDER_AUDIO then
        local now = os.clock()
        if now >= (nextThunderAt or 0) then
            local distant = (thunderLevel < CLOSE_THUNDER_MIN)
                or (math.random() < 0.7)
            local path, vol
            if distant then
                local i = math.random(1, DISTANT_THUNDER_COUNT)
                path = string.format(ASSET_DISTANT_THUNDER, i, i)
                vol = 0.6 * THUNDER_VOLUME_SCALE
            else
                local i = math.random(1, CLOSE_THUNDER_COUNT)
                path = string.format(ASSET_CLOSE_THUNDER, i, i)
                vol = 0.85 * THUNDER_VOLUME_SCALE
            end
            spawn2DGT(path, vol, distant and "thunder_distant" or "thunder_close")
            nextThunderAt = now + THUNDER_GAP_MIN + math.random() * (THUNDER_GAP_MAX - THUNDER_GAP_MIN)
        end
    else
        nextThunderAt = 0
    end
end

local function killAllSoundsGT()
    -- During a teardown the components die with the world; just drop the
    -- references without touching them
    if not teardownActiveGT() then
        fadeKillGT(rainAC)
        fadeKillGT(windAC)
    end
    rainAC = nil
    windAC = nil
    nextThunderAt = 0
end

--- The asset-loading kick: push enable + volumes to UDW and run its own sound
--- apply functions. Produces no audio itself, but causes UDW to async-load the
--- soft-referenced sound assets our spawns need. Game thread only.
local function nativeLoadKickGT()
    if teardownActiveGT() then return end
    local actors = getActors()
    if not actors then return end
    local udw = actors.GetUDW()
    if not udw then return end

    pcall(function() udw[PROP_ENABLE_SOUNDS] = true end)
    pcall(function() udw[PROP_RAIN_VOLUME] = RAIN_VOLUME_SCALE end)
    pcall(function() udw[PROP_WIND_VOLUME] = WIND_VOLUME_SCALE end)

    for _, fnName in ipairs({FN_STATIC, FN_APPLY_VOLUMES, FN_INSTANT_UPDATE}) do
        local fn = nil
        pcall(function() fn = udw[fnName] end)
        if fn then pcall(function() fn(udw) end) end
    end
    Log.Info(MODULE, "Native sound kick applied (loads the sound assets)")
end

-- ---------- scheduling ----------

--- Queue one guarded game-thread job; drops the request if one is already
--- queued, and always clears the pending flag even if the job errors
--- @return boolean true when the job was queued (or ran inline), false when
--- dropped: one-shot callers (the probes) must re-arm on false
local function scheduleGuarded(fn)
    if pendingUpdate then return false end
    pendingUpdate = true
    local scheduled = false
    if ExecuteInGameThread then
        scheduled = pcall(function()
            ExecuteInGameThread(function()
                pcall(fn)
                pendingUpdate = false
            end)
        end)
    end
    if not scheduled then
        pcall(fn)
        pendingUpdate = false
    end
    return true
end

--- Queue one direct-spawn update
local function scheduleSoundUpdate(rainVol, windVol, thunderLevel)
    scheduleGuarded(function()
        updateSoundsGT(rainVol, windVol, thunderLevel)
    end)
end

-- ============== PUBLIC API ==============

--- Initialize audio module
--- @return boolean success
function Audio.Init()
    if isInitialized then
        Log.Warn(MODULE, "Already initialized")
        return true
    end

    Log.Info(MODULE, "Initializing audio module")

    -- Read config
    if Config.Audio then
        if Config.Audio.EnableRain ~= nil then
            ENABLE_RAIN_AUDIO = Config.Audio.EnableRain
        end
        if Config.Audio.EnableWind ~= nil then
            ENABLE_WIND_AUDIO = Config.Audio.EnableWind
        end
        if Config.Audio.EnableThunder ~= nil then
            ENABLE_THUNDER_AUDIO = Config.Audio.EnableThunder
        end
        if Config.Audio.RainVolume then
            RAIN_VOLUME_SCALE = Config.Audio.RainVolume
        end
        if Config.Audio.WindVolume then
            WIND_VOLUME_SCALE = Config.Audio.WindVolume
        end
        if Config.Audio.ThunderVolume then
            THUNDER_VOLUME_SCALE = Config.Audio.ThunderVolume
        end
        if Config.Audio.CloseThunderMin then
            CLOSE_THUNDER_MIN = Config.Audio.CloseThunderMin
        end
        if Config.Audio.Enabled == false then
            Log.Info(MODULE, "Audio module disabled in config")
            audioEnabled = false
        end
    end

    isInitialized = true
    State.SetModuleStatus("audio", true)

    return true
end

--- Re-arm the per-course apply (called from main.lua on course load; the actual
--- apply happens in Tick once the settle gate clears)
function Audio.Setup()
    settleTicks = 0
    appliedThisCourse = false
    kickTicks = -1
    spawnFails = {}
    deadAssets = {}
    kickRefireWanted = false
    probeFired = {}
    -- Give-up warnings are per-course state: without this clear a give-up
    -- on any later course in the same session would be silent (deadAssets
    -- still engages, just no log line).
    for k in pairs(warnedOnce) do
        if k:sub(1, 5) == "dead_" then warnedOnce[k] = nil end
    end
end

--- Per-tick: after the settle gate, run the direct-spawn volume update every ~1s
function Audio.Tick()
    if not isInitialized then return end

    local actors = getActors()
    if not actors or not actors.IsOnCourse() then
        -- Course unloaded: re-arm and fade out anything still playing
        settleTicks = 0
        appliedThisCourse = false
        kickTicks = -1
        kickRefireWanted = false
        probeFired = {}
        if rainAC or windAC then
            scheduleGuarded(killAllSoundsGT)
        end
        return
    end

    settleTicks = settleTicks + 1
    if settleTicks < SETTLE_TICKS then return end

    if not appliedThisCourse then
        appliedThisCourse = true
        applied = true
        kickTicks = 0
        scheduleGuarded(nativeLoadKickGT)
    end

    -- Sound probes run WELL AFTER the kick, never with it: the kick starts an
    -- async load and the assets are unresolvable until it lands, so a same-frame
    -- probe reports a false negative (which is exactly what the first version of
    -- this probe did). Separate scheduleGuarded calls on separate ticks, because
    -- it drops a request while one is already queued.
    if kickTicks >= 0 then
        kickTicks = kickTicks + 1
        -- >= plus the fired flag, not ==: a GT hitch spanning one async
        -- tick used to eat the exact-match sample permanently (observed
        -- with a 155 ms RainCollision pass one tick before the 8-tick
        -- probe), corrupting the very timing measurement the probe is for.
        for _, at in ipairs(PROBE_AT_TICKS) do
            if kickTicks >= at and not probeFired[at] then
                local off = at
                if scheduleGuarded(function() probeUDSSoundsGT(off) end) then
                    probeFired[at] = true
                end
            end
        end
    end

    -- A stuck async load re-fires the kick (set at 10/20 fails by
    -- countSpawnFail; see the state-block note).
    if kickRefireWanted then
        if scheduleGuarded(nativeLoadKickGT) then
            kickRefireWanted = false
            Log.Info(MODULE, "Native sound kick re-fired (stuck async load)")
        end
    end

    if not audioEnabled then return end

    updateCounter = updateCounter + 1
    if updateCounter < UPDATE_INTERVAL_TICKS then return end
    updateCounter = 0

    -- Live weather state (primitive reads, async-tolerated like the rest of the mod)
    local udw = actors.GetUDW()
    if not udw then return end
    local rain, wind, thunder = 0.0, 0.0, 0.0
    pcall(function() rain = tonumber(udw["Rain"]) or 0.0 end)
    pcall(function() wind = tonumber(udw["Wind Intensity"]) or 0.0 end)
    pcall(function() thunder = tonumber(udw["Thunder/Lightning"]) or 0.0 end)

    -- 0-10 -> 0-1, monolith-style volume curves, config scales on top; nil = kill
    local rain01 = rain / 10.0
    local wind01 = wind / 10.0
    local rainVol = nil
    if ENABLE_RAIN_AUDIO and rain01 > 0.05 then
        rainVol = math.min(1.0, 0.35 + rain01 * 0.6) * RAIN_VOLUME_SCALE
    end
    local windVol = nil
    if ENABLE_WIND_AUDIO and wind01 > 0.05 then
        windVol = math.min(1.0, 0.30 + wind01 * 0.5) * WIND_VOLUME_SCALE
    end

    scheduleSoundUpdate(rainVol, windVol, thunder)
end

--- Toggle all weather audio
--- @return boolean newState
function Audio.Toggle()
    audioEnabled = not audioEnabled
    if not audioEnabled then
        scheduleGuarded(killAllSoundsGT)
    end
    Log.Info(MODULE, "Audio toggled", {enabled = audioEnabled})
    return audioEnabled
end

--- Set rain volume (picked up by the next ~1s update)
--- @param volume number 0.0-1.0
function Audio.SetRainVolume(volume)
    RAIN_VOLUME_SCALE = math.max(0.0, math.min(1.0, volume))
end

--- Set wind volume
--- @param volume number 0.0-1.0
function Audio.SetWindVolume(volume)
    WIND_VOLUME_SCALE = math.max(0.0, math.min(1.0, volume))
end

--- Set thunder volume
--- @param volume number 0.0-1.0
function Audio.SetThunderVolume(volume)
    THUNDER_VOLUME_SCALE = math.max(0.0, math.min(1.0, volume))
end

--- Check if audio is enabled
--- @return boolean
function Audio.IsEnabled()
    return audioEnabled
end

--- Get status for debugging
--- @return table
function Audio.GetStatus()
    return {
        initialized = isInitialized,
        enabled = audioEnabled,
        applied = applied,
        appliedThisCourse = appliedThisCourse,
        rainLoop = rainAC ~= nil,
        windLoop = windAC ~= nil,
        rainEnabled = ENABLE_RAIN_AUDIO,
        windEnabled = ENABLE_WIND_AUDIO,
        thunderEnabled = ENABLE_THUNDER_AUDIO,
        rainVolume = RAIN_VOLUME_SCALE,
        windVolume = WIND_VOLUME_SCALE,
        thunderVolume = THUNDER_VOLUME_SCALE,
    }
end

return Audio
