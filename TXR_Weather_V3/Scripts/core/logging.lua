-- TXR Weather Mod v3.0
-- core/logging.lua
-- Centralized logging with file output and console display

local Logging = {}

-- ============== CONFIGURATION ==============
local LOG_LEVELS = {
    DEBUG = 1,
    INFO = 2,
    WARN = 3,
    ERROR = 4
}

local LEVEL_NAMES = {
    [1] = "DEBUG",
    [2] = "INFO",
    [3] = "WARN",
    [4] = "ERROR"
}

-- ============== STATE ==============
local logFile = nil
local logPath = nil
local minLevel = LOG_LEVELS.DEBUG
local logToConsole = true       -- honored from config
local isInitialized = false
local MOD_VERSION = "3.0.0"  -- overwritten from config.version in Init (Config.Version.String)

-- Flush throttling: INFO/DEBUG flushes are batched; WARN/ERROR flush at
-- once so crash diagnostics survive.
local FLUSH_INTERVAL = 0.5  -- seconds
local lastFlush = 0

-- Tuning-feedback side channel: lines with these module tags (the Alt+D
-- exposure feedback and the Alt+Z/X/C/V skylight nudges among them) are
-- also appended to the persistent Logs/tuning_feedback.log, so users can
-- send just the datapoints. It accumulates across sessions with a session
-- marker, is created on the first feedback press, and every line is
-- flushed (presses are rare and must survive a crash).
local FEEDBACK_TAGS = { ExposureTune = true, SkylightTune = true, RainSpot = true, StarTune = true }
local FEEDBACK_FILENAME = "tuning_feedback.log"
local feedbackFile = nil
local feedbackPath = nil
local feedbackSessionMarked = false

-- ============== INTERNAL HELPERS ==============

local function getTimestamp()
    -- Returns HH:MM:SS format
    local time = os.date("*t")
    return string.format("%02d:%02d:%02d", time.hour, time.min, time.sec)
end

local function getDateTimeString()
    -- Returns full date/time for session markers
    return os.date("%Y-%m-%d %H:%M:%S")
end

local function getLogFileName()
    -- Generate log filename with date
    local date = os.date("%Y%m%d_%H%M%S")
    return string.format("TXR_Weather_V3_%s.log", date)
end

-- Logs live in Mods/<mod>/Logs/. The debug.getinfo source path mixes
-- separators (package.path contributes "/", the module dot becomes "\"),
-- so the match accepts either and anchors on the core/ folder, the same
-- derivation persistence.lua uses for the mod root. The directory is
-- created once per session: os.execute spawns a shell, and a per-call
-- spawn used to fire again on the first feedback key press with the game
-- full screen.
local logsDirCached = nil

local function ensureLogDirectory()
    if logsDirCached then return logsDirCached end
    local source = (debug.getinfo(1, "S").source or ""):gsub("@", "")
    local scriptsDir = source:match("(.+)[/\\]core[/\\]")
    local modRoot = scriptsDir and scriptsDir:match("(.+)[/\\]")
    local logsDir = modRoot and (modRoot .. "/Logs/") or "./../Logs/"
    os.execute('mkdir "' .. logsDir:gsub("/", "\\") .. '" 2>nul')
    logsDirCached = logsDir
    return logsDir
end

local function writeToFile(message, forceFlush)
    if not logFile then return end

    local success, err = pcall(function()
        logFile:write(message, "\n")  -- varargs avoids a concatenation allocation
        local now = os.clock()
        if forceFlush or (now - lastFlush) >= FLUSH_INTERVAL then
            lastFlush = now
            logFile:flush()
        end
    end)

    if not success then
        -- Can't log the error to file, just continue
        print("[LOGGING ERROR] Failed to write to log file: " .. tostring(err))
    end
end

local function writeToConsole(message)
    -- Print to UE4SS console (skipped when disabled in config)
    if logToConsole then
        print(message)
    end
end

--- Append one line to the persistent tuning-feedback file (lazy-opened; a
--- session marker precedes the first line of each session)
local function writeFeedback(line)
    if not feedbackFile then
        local ok = pcall(function()
            local logsDir = ensureLogDirectory()
            feedbackPath = logsDir .. FEEDBACK_FILENAME
            feedbackFile = io.open(feedbackPath, "a")
        end)
        if not ok or not feedbackFile then return end
    end
    pcall(function()
        if not feedbackSessionMarked then
            feedbackSessionMarked = true
            feedbackFile:write(string.format(
                "---- Session %s (mod v%s) ----\n", getDateTimeString(), MOD_VERSION))
        end
        feedbackFile:write(line, "\n")
        feedbackFile:flush()
    end)
end

-- ============== PUBLIC API ==============

--- Initialize the logging system
--- @param config table Optional configuration {minLevel, logToFile, logToConsole}
--- @return boolean success
function Logging.Init(config)
    if isInitialized then
        Logging.Warn("Logging", "Already initialized, skipping")
        return true
    end
    
    config = config or {}
    
    -- Set minimum log level
    if config.minLevel then
        if type(config.minLevel) == "string" then
            minLevel = LOG_LEVELS[config.minLevel:upper()] or LOG_LEVELS.DEBUG
        else
            minLevel = config.minLevel
        end
    end

    -- Honor console logging flag (default on)
    logToConsole = (config.logToConsole ~= false)

    -- Stamp the real mod version into the session header.
    if config.version then MOD_VERSION = tostring(config.version) end

    -- Initialize file logging
    if config.logToFile ~= false then
        local logsDir = ensureLogDirectory()
        logPath = logsDir .. getLogFileName()
        
        local err
        logFile, err = io.open(logPath, "w")
        
        if not logFile then
            print("[LOGGING ERROR] Failed to open log file: " .. tostring(err))
            print("[LOGGING ERROR] Path attempted: " .. logPath)
            -- Continue without file logging
        end
    end
    
    isInitialized = true
    
    -- Write session header
    local header = string.format(
        "================================================================================\n" ..
        "TXR Weather Mod v%s: Log Session Started\n" ..
        "Date/Time: %s\n" ..
        "Log Level: %s\n" ..
        "================================================================================",
        MOD_VERSION,
        getDateTimeString(),
        LEVEL_NAMES[minLevel]
    )
    
    if logFile then
        writeToFile(header, true)
    end
    writeToConsole(header)
    
    return true
end

--- Core logging function
--- @param level number Log level (use LOG_LEVELS constants)
--- @param module string Module name for context
--- @param message string Log message
--- @param data table|nil Optional key-value data to append
function Logging.Log(level, module, message, data)
    if not isInitialized then
        -- Auto-initialize with defaults if not done
        Logging.Init({})
    end
    
    if level < minLevel then
        return  -- Skip logs below minimum level
    end
    
    local levelName = LEVEL_NAMES[level] or "???"
    local timestamp = getTimestamp()
    
    -- Build the log line
    local line = string.format("[%s] [%s] %s: %s",
        timestamp,
        levelName,
        module or "???",
        message or ""
    )
    
    -- Append key-value data if provided
    if data and type(data) == "table" then
        local parts = {}
        for k, v in pairs(data) do
            table.insert(parts, string.format("%s=%s", tostring(k), tostring(v)))
        end
        if #parts > 0 then
            line = line .. " (" .. table.concat(parts, " ") .. ")"
        end
    end
    
    -- WARN/ERROR flush immediately so they survive a crash; lower levels batch.
    if logFile then
        writeToFile(line, level >= LOG_LEVELS.WARN)
    end
    writeToConsole(line)

    -- Tuning-feedback side channel (see FEEDBACK_TAGS)
    if module and FEEDBACK_TAGS[module] then
        writeFeedback(line)
    end
end

--- Convenience functions for each log level
function Logging.Debug(module, message, data)
    Logging.Log(LOG_LEVELS.DEBUG, module, message, data)
end

function Logging.Info(module, message, data)
    Logging.Log(LOG_LEVELS.INFO, module, message, data)
end

function Logging.Warn(module, message, data)
    Logging.Log(LOG_LEVELS.WARN, module, message, data)
end

function Logging.Error(module, message, data)
    Logging.Log(LOG_LEVELS.ERROR, module, message, data)
end

--- True when DEBUG lines would be written (release builds run at INFO), so
--- a module can skip work whose only output is Log.Debug.
function Logging.IsDebugEnabled()
    return minLevel <= LOG_LEVELS.DEBUG
end

-- Export log levels for external use
Logging.LEVELS = LOG_LEVELS

return Logging
