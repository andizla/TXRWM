-- TXR Weather Mod v3.0
-- data/gap_slabs.lua
-- THE AUTHORED LEAK-FIX SITE LIST for the map-wide campaign: pure
-- data, one paste-ready row per line. The slab editor's saved rows
-- (Logs/slab_rows.txt) drop in verbatim. Loaded by systems/gap_walls;
-- Config.GapWalls.Slabs appends on top of this list (user/experiment
-- extension hook, ships empty).
--
-- Geometry: world-space cm, yaw/pitch deg, sx/sy/sz in metres (the
-- engine cube is 1 m). Plain rows = invisible shadow-only blockers;
-- solid = true keeps collision and renders (ramps, cloned ground).
return {
    { sec = "ginza-seam", cx = 223518, cy = -756434, cz = 300, yaw = -41.9, sx = 107.0, sy = 0.8, sz = 14.0 },
    { sec = "ginza-ramp", cx = 223348, cy = -757895, cz = 400, yaw = -41.9, sx = 120.0, sy = 0.8, sz = 18.0 },
    -- 2026-08-24 pass (authored in the first GT-queue session)
    { sec = "site-1", cx = -10891, cy = -922171, cz = 1764, yaw = 102.9, sx = 910.0, sy = 0.8, sz = 30.0 },
    { sec = "site-2", cx = -13005, cy = -881669, cz = 1209, yaw = 66.2, sx = 190.0, sy = 0.8, sz = 14.0 },
    { sec = "site-3", cx = -6682, cy = -868757, cz = 754, yaw = 53.7, sx = 165.0, sy = 0.8, sz = 45.0 },
    { sec = "site-4", cx = 4063, cy = -860670, cz = 1218, yaw = 24.5, sx = 275.0, sy = 0.8, sz = 26.0 },
    { sec = "site-5", cx = 22417, cy = -846929, cz = 455, yaw = 51.7, sx = 210.0, sy = 0.8, sz = 33.0 },
}
