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
local logToConsole = true       -- honored from config (was previously ignored)
local isInitialized = false
local sessionStartTime = nil
local MOD_VERSION = "3.0.0"  -- overwritten from config.version in Init (Config.Version.String)

-- Flush throttling: avoid a synchronous disk flush on every log line.
-- INFO/DEBUG flushes are batched; WARN/ERROR flush immediately so crash
-- diagnostics are never lost.
local FLUSH_INTERVAL = 0.5  -- seconds
local lastFlush = 0

-- Tuning-feedback side channel: lines with these module tags (the Alt+D /
-- Alt+Shift+D exposure feedback and the Alt+Z/X/C/V skylight nudges) are ALSO
-- appended to one persistent Logs/tuning_feedback.log, so users can send just
-- the relevant datapoints instead of digging through full session logs. The
-- file accumulates across sessions with a session marker, is only created on
-- the first feedback press, and every line is flushed (presses are rare and
-- must survive a crash).
local FEEDBACK_TAGS = { ExposureTune = true, SkylightTune = true }
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

local function ensureLogDirectory()
    -- Try to create Logs directory if it doesn't exist
    -- UE4SS mods typically run from Mods/ModName/Scripts/
    -- We'll put logs in Mods/ModName/Logs/
    local baseDir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
    local logsDir = baseDir .. "../Logs/"
    
    -- Attempt to create directory (may fail silently if exists)
    os.execute('mkdir "' .. logsDir .. '" 2>nul')
    
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

    -- Stamp the real mod version into the session header (was hardcoded "3.0.0").
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
    
    sessionStartTime = os.time()
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

--- Shutdown the logging system
function Logging.Shutdown()
    if not isInitialized then return end
    
    local footer = string.format(
        "================================================================================\n" ..
        "Log Session Ended: %s\n" ..
        "Session Duration: %d seconds\n" ..
        "================================================================================",
        getDateTimeString(),
        os.time() - sessionStartTime
    )
    
    if logFile then
        writeToFile(footer, true)
        logFile:close()
        logFile = nil
    end
    if feedbackFile then
        pcall(function() feedbackFile:close() end)
        feedbackFile = nil
    end
    writeToConsole(footer)

    isInitialized = false
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
    
    -- Output to both file and console
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

--- Set minimum log level at runtime
--- @param level string|number "DEBUG", "INFO", "WARN", "ERROR" or numeric
function Logging.SetLevel(level)
    if type(level) == "string" then
        minLevel = LOG_LEVELS[level:upper()] or LOG_LEVELS.DEBUG
    else
        minLevel = level
    end
    Logging.Info("Logging", "Log level changed", {level = LEVEL_NAMES[minLevel]})
end

--- Get current log file path
--- @return string|nil
function Logging.GetLogPath()
    return logPath
end

--- Check if logging is initialized
--- @return boolean
function Logging.IsInitialized()
    return isInitialized
end

-- Export log levels for external use
Logging.LEVELS = LOG_LEVELS

return Logging
