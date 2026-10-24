--!nonstrict
--[[
    ASTD Macro v1.0.0
    มาโครบันทึก/เล่นซ้ำอินพุตเมาส์และคีย์บอร์ด สำหรับ Real Executor
    ใช้เฉพาะ API ที่ประกาศใน real_executor_apis.d.luau
    ไม่เรียกฟังก์ชันภายในเกม ไม่ใช้ hook / fireclickdetector / anti-cheat bypass
]]

-- ============================================================================
-- 00) ป้องกันการรันซ้ำ
-- ============================================================================

local GENV = _G
if type(getgenv) == "function" then
    local ok, env = pcall(getgenv)
    if ok and type(env) == "table" then
        GENV = env
    end
end

local oldInstance = GENV.__ASTD_MACRO
if type(oldInstance) == "table" and type(oldInstance.destroy) == "function" then
    pcall(oldInstance.destroy)
end

-- ============================================================================
-- 01) ค่าคงที่ บริการ และธีม
-- ============================================================================

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer

local APP_NAME = "ASTD Macro"
local APP_VERSION = "1.0.0"
local GUI_NAME = "ASTD_Macro_Menu"

local ROOT_DIR = "ASTD_Macro"
local PROFILE_DIR = ROOT_DIR .. "/profiles"
local EXPORT_DIR = ROOT_DIR .. "/exports"
local LOG_DIR = ROOT_DIR .. "/logs"
local SETTINGS_PATH = ROOT_DIR .. "/settings.json"
local INDEX_PATH = ROOT_DIR .. "/index.json"
local LOG_PATH = LOG_DIR .. "/session.log"

local MAX_EVENTS = 30000
local MAX_LOG_ENTRIES = 250
local MAX_LOG_LABELS = 140
local PROFILE_FORMAT = "astd-macro-profile"

local FONT = Enum.Font.Gotham
local FONT_TITLE = Enum.Font.GothamMedium

local Theme = {
    bg = Color3.fromRGB(15, 17, 23),
    panel = Color3.fromRGB(24, 28, 37),
    panel2 = Color3.fromRGB(32, 37, 49),
    panel3 = Color3.fromRGB(43, 50, 65),
    dark = Color3.fromRGB(12, 14, 19),
    stroke = Color3.fromRGB(54, 63, 80),
    text = Color3.fromRGB(232, 236, 244),
    muted = Color3.fromRGB(154, 164, 181),
    accent = Color3.fromRGB(88, 140, 255),
    accentDark = Color3.fromRGB(54, 94, 190),
    success = Color3.fromRGB(47, 191, 113),
    successDark = Color3.fromRGB(30, 130, 76),
    warning = Color3.fromRGB(245, 165, 36),
    danger = Color3.fromRGB(229, 72, 77),
    dangerDark = Color3.fromRGB(158, 42, 47),
    white = Color3.fromRGB(255, 255, 255),
}

local STATUS_COLORS = {
    ready = Theme.success,
    recording = Theme.danger,
    playing = Theme.accent,
    paused = Theme.warning,
    error = Theme.danger,
    warn = Theme.warning,
}

local LOG_COLORS = {
    info = Theme.text,
    success = Theme.success,
    warn = Theme.warning,
    error = Theme.danger,
}

-- ============================================================================
-- 02) ตัวช่วยทั่วไป
-- ============================================================================

local function clock()
    return os.clock()
end

local function getViewport()
    local camera = workspace.CurrentCamera
    if camera then
        return camera.ViewportSize
    end
    return Vector2.new(1280, 720)
end

local function clampSafe(value, minValue, maxValue)
    if maxValue < minValue then
        return minValue
    end
    return math.clamp(value, minValue, maxValue)
end

local function formatNumber(value)
    value = tonumber(value) or 0
    if math.abs(value - math.floor(value)) < 0.0001 then
        return tostring(math.floor(value))
    end
    local text = string.format("%.3f", value)
    text = text:gsub("0+$", ""):gsub("%.$", "")
    return text
end

local function formatDuration(seconds)
    seconds = math.max(0, math.floor((tonumber(seconds) or 0) + 0.5))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs = seconds % 60
    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, secs)
    end
    return string.format("%d:%02d", minutes, secs)
end

local function trimText(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function charLength(text)
    local ok, length = pcall(function()
        return utf8.len(text)
    end)
    if ok and type(length) == "number" then
        return length
    end
    return #text
end

local function normalizeProfileName(text)
    local name = trimText(text)
    name = name:gsub("%c", "")
    name = trimText(name)
    if name == "" then
        return nil, "กรุณากรอกชื่อโปรไฟล์"
    end
    local length = charLength(name)
    if length > 40 then
        return nil, "ชื่อยาวเกิน 40 ตัวอักษร"
    end
    return name
end

local function boolOr(value, fallback)
    if type(value) == "boolean" then
        return value
    end
    return fallback
end

local function numberOr(value, fallback)
    value = tonumber(value)
    if value == nil or value ~= value then
        return fallback
    end
    return value
end

local function getMousePosition()
    local ok, position = pcall(function()
        return UserInputService:GetMouseLocation()
    end)
    if ok and typeof(position) == "Vector2" then
        return position
    end
    return nil
end

local function isGameActive()
    if type(isrbxactive) ~= "function" then
        return true
    end
    local ok, active = pcall(isrbxactive)
    if ok then
        return active ~= false
    end
    return true
end

-- ============================================================================
-- 03) ไฟล์และ JSON (sandbox ของ Real)
-- ============================================================================

local FileTools = {
    ready = type(writefile) == "function" and type(readfile) == "function",
}

local function writeTextFile(path, content)
    if type(writefile) ~= "function" then
        return false, "writefile ไม่พร้อมใช้งาน"
    end
    local ok, err = pcall(writefile, path, tostring(content))
    if ok then
        return true
    end
    return false, tostring(err)
end

local function readTextFile(path)
    if type(readfile) ~= "function" then
        return nil, "readfile ไม่พร้อมใช้งาน"
    end
    local ok, content = pcall(readfile, path)
    if ok and type(content) == "string" then
        return content
    end
    return nil, tostring(content)
end

local function fileExists(path)
    if type(isfile) ~= "function" then
        return false
    end
    local ok, exists = pcall(isfile, path)
    return ok and exists == true
end

local function folderExists(path)
    if type(isfolder) ~= "function" then
        return false
    end
    local ok, exists = pcall(isfolder, path)
    return ok and exists == true
end

local function deleteFile(path)
    if type(delfile) ~= "function" then
        return false, "delfile ไม่พร้อมใช้งาน"
    end
    local ok, err = pcall(delfile, path)
    if ok then
        return true
    end
    return false, tostring(err)
end

local function ensureWorkspaceFolders()
    if type(makefolder) ~= "function" then
        return false, "makefolder ไม่พร้อมใช้งาน"
    end
    local folders = { ROOT_DIR, PROFILE_DIR, EXPORT_DIR, LOG_DIR }
    for _, path in ipairs(folders) do
        if not folderExists(path) then
            local ok, err = pcall(makefolder, path)
            if not ok then
                return false, tostring(err)
            end
        end
    end
    return true
end

local function encodeJson(value)
    local ok, text = pcall(function()
        return HttpService:JSONEncode(value)
    end)
    if ok and type(text) == "string" then
        return text
    end
    return nil, tostring(text)
end

local function decodeJson(text)
    local ok, value = pcall(function()
        return HttpService:JSONDecode(text)
    end)
    if ok and type(value) == "table" then
        return value
    end
    return nil, tostring(value)
end

local function writeJsonFile(path, value)
    local text, encodeError = encodeJson(value)
    if not text then
        return false, "แปลง JSON ไม่สำเร็จ: " .. tostring(encodeError)
    end
    return writeTextFile(path, text)
end

local function readJsonFile(path)
    if not fileExists(path) then
        return nil, "ไม่พบไฟล์"
    end
    local text, readError = readTextFile(path)
    if not text then
        return nil, tostring(readError)
    end
    local value, decodeError = decodeJson(text)
    if not value then
        return nil, "JSON เสียหาย: " .. tostring(decodeError)
    end
    return value
end

-- ============================================================================
-- 04) แผนที่ปุ่ม Windows Virtual-Key
-- ============================================================================

local VK_BY_NAME = {
    A = 0x41, B = 0x42, C = 0x43, D = 0x44, E = 0x45, F = 0x46, G = 0x47,
    H = 0x48, I = 0x49, J = 0x4A, K = 0x4B, L = 0x4C, M = 0x4D, N = 0x4E,
    O = 0x4F, P = 0x50, Q = 0x51, R = 0x52, S = 0x53, T = 0x54, U = 0x55,
    V = 0x56, W = 0x57, X = 0x58, Y = 0x59, Z = 0x5A,

    Zero = 0x30, One = 0x31, Two = 0x32, Three = 0x33, Four = 0x34,
    Five = 0x35, Six = 0x36, Seven = 0x37, Eight = 0x38, Nine = 0x39,

    KeypadZero = 0x60, KeypadOne = 0x61, KeypadTwo = 0x62, KeypadThree = 0x63,
    KeypadFour = 0x64, KeypadFive = 0x65, KeypadSix = 0x66, KeypadSeven = 0x67,
    KeypadEight = 0x68, KeypadNine = 0x69, KeypadPeriod = 0x6E,
    KeypadDivide = 0x6F, KeypadMultiply = 0x6A, KeypadMinus = 0x6D,
    KeypadPlus = 0x6B, KeypadEnter = 0x0D,

    F1 = 0x70, F2 = 0x71, F3 = 0x72, F4 = 0x73, F5 = 0x74, F6 = 0x75,
    F7 = 0x76, F8 = 0x77, F9 = 0x78, F10 = 0x79, F11 = 0x7A, F12 = 0x7B,

    Backspace = 0x08, Tab = 0x09, Return = 0x0D, Escape = 0x1B,
    Space = 0x20, Pause = 0x13, CapsLock = 0x14, NumLock = 0x90,
    ScrollLock = 0x91, Print = 0x2C, Menu = 0x5D,

    PageUp = 0x21, PageDown = 0x22, End = 0x23, Home = 0x24,
    Left = 0x25, Up = 0x26, Right = 0x27, Down = 0x28,
    Insert = 0x2D, Delete = 0x2E,

    LeftShift = 0xA0, RightShift = 0xA1,
    LeftControl = 0xA2, RightControl = 0xA3,
    LeftAlt = 0xA4, RightAlt = 0xA5,
    LeftMeta = 0x5B, RightMeta = 0x5C,

    Semicolon = 0xBA, Equals = 0xBB, Comma = 0xBC, Minus = 0xBD,
    Period = 0xBE, Slash = 0xBF, Backquote = 0xC0,
    LeftBracket = 0xDB, Backslash = 0xDC, RightBracket = 0xDD, Quote = 0xDE,
}

local EVENT_LABELS = {
    mouseMove = "เลื่อนเมาส์",
    mouseDown = "กดเมาส์",
    mouseUp = "ปล่อยเมาส์",
    keyDown = "กดปุ่ม",
    keyUp = "ปล่อยปุ่ม",
    wheel = "เลื่อนล้อ",
}

local function eventLabel(event)
    local base = EVENT_LABELS[event.type] or tostring(event.type)
    if event.type == "mouseDown" or event.type == "mouseUp" then
        return base .. (event.button == "Right" and "ขวา" or "ซ้าย")
    end
    if event.type == "keyDown" or event.type == "keyUp" then
        return base .. " " .. tostring(event.key or "?")
    end
    return base
end

local function validateEvents(raw, strict)
    if type(raw) ~= "table" then
        return nil, "ข้อมูลเหตุการณ์ไม่ใช่ตาราง"
    end

    local result = {}
    local skipped = 0

    for index, event in ipairs(raw) do
        local valid = type(event) == "table"
        local normalized = nil

        if valid and type(event.t) == "number" and event.t == event.t and event.t >= 0 then
            local t = math.clamp(event.t, 0, 172800)
            local eventType = event.type

            if eventType == "mouseMove" or eventType == "mouseDown" or eventType == "mouseUp" then
                if type(event.x) == "number" and type(event.y) == "number" then
                    normalized = {
                        t = t,
                        type = eventType,
                        x = math.clamp(event.x, -20000, 20000),
                        y = math.clamp(event.y, -20000, 20000),
                    }
                    if eventType == "mouseDown" or eventType == "mouseUp" then
                        if event.button == "Left" or event.button == "Right" then
                            normalized.button = event.button
                        else
                            normalized = nil
                        end
                    end
                end
            elseif eventType == "keyDown" or eventType == "keyUp" then
                local keyName = type(event.key) == "string" and event.key or nil
                local vk = numberOr(event.vk, nil)
                if not vk or vk < 1 or vk > 255 then
                    vk = keyName and VK_BY_NAME[keyName] or nil
                end
                if keyName and vk then
                    normalized = {
                        t = t,
                        type = eventType,
                        key = keyName,
                        vk = math.floor(vk),
                    }
                end
            elseif eventType == "wheel" then
                if type(event.z) == "number" then
                    normalized = {
                        t = t,
                        type = "wheel",
                        z = math.clamp(event.z, -120, 120),
                    }
                end
            end
        end

        if normalized then
            if #result >= MAX_EVENTS then
                if strict then
                    return nil, "จำนวนเหตุการณ์เกิน " .. tostring(MAX_EVENTS)
                end
                skipped += 1
            else
                normalized._order = index
                table.insert(result, normalized)
            end
        else
            skipped += 1
            if strict then
                return nil, "เหตุการณ์ลำดับที่ " .. tostring(index) .. " ไม่ถูกต้อง"
            end
        end
    end

    table.sort(result, function(a, b)
        if a.t == b.t then
            return a._order < b._order
        end
        return a.t < b.t
    end)
    for _, event in ipairs(result) do
        event._order = nil
    end

    return result, skipped
end

-- ============================================================================
-- 05) สถานะหลัก
-- ============================================================================

local State: any = {
    mode = "idle",
    statusText = "พร้อมใช้งาน",
    statusKind = "ready",
    playbackIndex = 0,
    loop = 0,
    finished = false,
    blocked = false,
    paused = false,
    dirty = false,
    autoHidden = false,
    menuVisible = true,
    token = 0,
    events = {},
    recordStart = 0,
    lastMoveSample = 0,
    lastRecordedMove = nil,
    recordingMouse = {},
    recordingKeys = {},
    heldKeys = {},
    heldMouse = {},
    dragging = false,
    dragStart = nil,
    dragOrigin = nil,
}

local App = {
    apiStatus = {
        input = false,
        files = false,
        clipboard = false,
        gui = "none",
    },
    executorName = "Unknown",
    executorVersion = "",
    warnedKeys = {},
}

local UI: any = {
    refs = {},
    nav = {},
    pages = {},
    transport = { record = {}, play = {}, pause = {}, stop = {} },
    progressFills = {},
    progressTexts = {},
    stepLabels = {},
    loopLabels = {},
}

-- ============================================================================
-- 06) Logger
-- ============================================================================

local Log = {
    entries = {},
    uiLabels = {},
    uiScroll = nil,
    uiOrder = 0,
    onEntry = nil,
    fileReady = false,
    fileCreated = false,
    fileWarned = false,
}

local function scrollLogToBottom()
    if not Log.uiScroll then
        return
    end
    task.defer(function()
        if not Log.uiScroll then
            return
        end
        pcall(function()
            Log.uiScroll.CanvasPosition = Vector2.new(0, math.max(0, Log.uiScroll.AbsoluteCanvasSize.Y))
        end)
    end)
end

local function appendLogLabel(entry)
    if not Log.uiScroll then
        return
    end

    Log.uiOrder += 1
    local label = Instance.new("TextLabel")
    label.Name = "LogLine"
    label.BackgroundTransparency = 1
    label.Size = UDim2.new(1, -8, 0, 0)
    label.AutomaticSize = Enum.AutomaticSize.Y
    label.Font = FONT
    label.Text = entry.line
    label.TextSize = 12
    label.TextColor3 = entry.color
    label.TextWrapped = true
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Top
    label.LineHeight = 1.1
    label.LayoutOrder = Log.uiOrder
    label.Parent = Log.uiScroll

    table.insert(Log.uiLabels, label)
    while #Log.uiLabels > MAX_LOG_LABELS do
        local old = table.remove(Log.uiLabels, 1)
        if old then
            old:Destroy()
        end
    end
    scrollLogToBottom()
end

function Log.renderAll()
    if not Log.uiScroll then
        return
    end
    for _, child in ipairs(Log.uiScroll:GetChildren()) do
        if child:IsA("GuiObject") then
            child:Destroy()
        end
    end
    Log.uiLabels = {}
    Log.uiOrder = 0
    for _, entry in ipairs(Log.entries) do
        appendLogLabel(entry)
    end
end

function Log.attachUI(scrollFrame)
    Log.uiScroll = scrollFrame
    Log.renderAll()
end

function Log.add(level, message)
    level = level or "info"
    local entry = {
        level = level,
        message = tostring(message),
        time = os.time(),
    }
    entry.line = string.format("[%s] %s", os.date("%H:%M:%S", entry.time), entry.message)
    entry.color = LOG_COLORS[level] or Theme.text

    table.insert(Log.entries, entry)
    while #Log.entries > MAX_LOG_ENTRIES do
        table.remove(Log.entries, 1)
    end

    print(string.format("[%s][%s] %s", APP_NAME, level, entry.message))

    if Log.fileReady then
        local line = entry.line .. "\n"
        local ok
        if Log.fileCreated then
            ok = pcall(appendfile, LOG_PATH, line)
        else
            ok = pcall(writefile, LOG_PATH, line)
            if ok then
                Log.fileCreated = true
            end
        end
        if not ok and not Log.fileWarned then
            Log.fileWarned = true
            Log.fileReady = false
            print("[" .. APP_NAME .. "] ไม่สามารถเขียนไฟล์ log ได้")
        end
    end

    if Log.onEntry then
        local ok, err = pcall(Log.onEntry, entry)
        if not ok then
            print("[" .. APP_NAME .. "] Log UI error: " .. tostring(err))
        end
    end
end

function Log.initFile()
    if type(writefile) ~= "function" or type(appendfile) ~= "function" then
        return
    end

    if fileExists(LOG_PATH) and type(readfile) == "function" and type(writefile) == "function" then
        local content = readTextFile(LOG_PATH)
        if content and #content > 400000 then
            local tail = content:sub(-200000)
            local newline = tail:find("\n", 1, true)
            if newline then
                tail = tail:sub(newline + 1)
            end
            writeTextFile(LOG_PATH, "-- log rotated " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n" .. tail)
        end
    end

    Log.fileCreated = fileExists(LOG_PATH)
    Log.fileReady = true
end

function Log.clear()
    Log.entries = {}
    if Log.uiScroll then
        for _, child in ipairs(Log.uiScroll:GetChildren()) do
            if child:IsA("GuiObject") then
                child:Destroy()
            end
        end
    end
    Log.uiLabels = {}
    Log.uiOrder = 0
end

function Log.copyToClipboard()
    local lines = {}
    for _, entry in ipairs(Log.entries) do
        table.insert(lines, entry.line)
    end
    local text = table.concat(lines, "\n")
    if type(setclipboard) ~= "function" then
        Log.add("warn", "คัดลอกไม่ได้: setclipboard ไม่พร้อมใช้งาน")
        return
    end
    local ok, err = pcall(setclipboard, text)
    if ok then
        Log.add("success", "คัดลอกบันทึกสถานะแล้ว")
    else
        Log.add("error", "คัดลอกบันทึกสถานะไม่สำเร็จ: " .. tostring(err))
    end
end

-- ============================================================================
-- 07) การตั้งค่า
-- ============================================================================

local DEFAULT_SETTINGS = {
    version = 1,
    loops = 1,
    infinite = false,
    loopDelay = 2,
    speed = 1,
    guardFocus = true,
    autosave = true,
    autoHide = true,
    offsetX = 0,
    offsetY = 0,
    afkEnabled = false,
    afkInterval = 5,
}

local Settings = {}
for key, value in pairs(DEFAULT_SETTINGS) do
    Settings[key] = value
end

local function loadSettings()
    local data, err = readJsonFile(SETTINGS_PATH)
    if not data then
        if err ~= "ไม่พบไฟล์" then
            Log.add("warn", "อ่านการตั้งค่าไม่ได้: " .. tostring(err))
        end
        return
    end

    Settings.loops = math.floor(math.clamp(numberOr(data.loops, Settings.loops), 1, 9999))
    Settings.infinite = boolOr(data.infinite, Settings.infinite)
    Settings.loopDelay = math.clamp(numberOr(data.loopDelay, Settings.loopDelay), 0, 600)
    Settings.speed = math.clamp(numberOr(data.speed, Settings.speed), 0.25, 4)
    Settings.guardFocus = boolOr(data.guardFocus, Settings.guardFocus)
    Settings.autosave = boolOr(data.autosave, Settings.autosave)
    Settings.autoHide = boolOr(data.autoHide, Settings.autoHide)
    Settings.offsetX = math.floor(math.clamp(numberOr(data.offsetX, Settings.offsetX), -1000, 1000))
    Settings.offsetY = math.floor(math.clamp(numberOr(data.offsetY, Settings.offsetY), -1000, 1000))
    Settings.afkEnabled = boolOr(data.afkEnabled, Settings.afkEnabled)
    Settings.afkInterval = math.floor(math.clamp(numberOr(data.afkInterval, Settings.afkInterval), 1, 15))
end

local function saveSettings()
    local data = {
        version = 1,
        loops = Settings.loops,
        infinite = Settings.infinite,
        loopDelay = Settings.loopDelay,
        speed = Settings.speed,
        guardFocus = Settings.guardFocus,
        autosave = Settings.autosave,
        autoHide = Settings.autoHide,
        offsetX = Settings.offsetX,
        offsetY = Settings.offsetY,
        afkEnabled = Settings.afkEnabled,
        afkInterval = Settings.afkInterval,
    }
    local ok, err = writeJsonFile(SETTINGS_PATH, data)
    if not ok then
        if not Settings._warnedWrite then
            Settings._warnedWrite = true
            Log.add("warn", "บันทึกการตั้งค่าไม่ได้: " .. tostring(err))
        end
        return false
    end
    Settings._warnedWrite = false
    return true
end

-- ============================================================================
-- 08) โปรไฟล์
-- ============================================================================

local Profiles = {
    list = {},
    events = {},
    selectedId = nil,
    _indexWarned = false,
}

local function profilePath(id)
    return PROFILE_DIR .. "/" .. tostring(id) .. ".json"
end

local function findProfileMeta(id)
    if not id then
        return nil
    end
    for _, item in ipairs(Profiles.list) do
        if item.id == id then
            return item
        end
    end
    return nil
end

local function selectedProfileMeta()
    return findProfileMeta(Profiles.selectedId)
end

local function nameExists(name, exceptId)
    local lowered = string.lower(name)
    for _, item in ipairs(Profiles.list) do
        if item.id ~= exceptId and string.lower(item.name) == lowered then
            return true
        end
    end
    return false
end

local function uniqueProfileName(base, exceptId)
    base = trimText(base)
    if base == "" then
        base = "โปรไฟล์"
    end
    if not nameExists(base, exceptId) then
        return base
    end
    for index = 2, 99 do
        local candidate = base .. " " .. tostring(index)
        if not nameExists(candidate, exceptId) then
            return candidate
        end
    end
    return base .. " " .. tostring(os.time())
end

local profileCounter = 0
local function newProfileId()
    while true do
        profileCounter += 1
        local id = string.format("p_%d_%03d", os.time(), profileCounter % 1000)
        local exists = findProfileMeta(id) ~= nil
        if not exists and FileTools.ready then
            exists = fileExists(profilePath(id))
        end
        if not exists then
            return id
        end
    end
end

local function buildIndexData()
    local items = {}
    for _, item in ipairs(Profiles.list) do
        table.insert(items, {
            id = item.id,
            name = item.name,
            created = item.created,
            modified = item.modified,
            duration = item.duration,
            count = item.count,
        })
    end
    return {
        version = 1,
        selected = Profiles.selectedId,
        items = items,
    }
end

local function saveIndex()
    local ok, err = writeJsonFile(INDEX_PATH, buildIndexData())
    if not ok and not Profiles._indexWarned then
        Profiles._indexWarned = true
        Log.add("warn", "บันทึก index โปรไฟล์ไม่ได้: " .. tostring(err))
    elseif ok then
        Profiles._indexWarned = false
    end
    return ok
end

local function profileData(meta, events)
    return {
        format = PROFILE_FORMAT,
        version = 1,
        id = meta.id,
        name = meta.name,
        created = meta.created,
        modified = meta.modified,
        duration = meta.duration,
        events = events,
    }
end

local function saveProfileToDisk(meta, events)
    meta.count = #events
    meta.duration = #events > 0 and events[#events].t or 0
    meta.modified = os.time()
    return writeJsonFile(profilePath(meta.id), profileData(meta, events))
end

local function readProfileFromDisk(id)
    local data, err = readJsonFile(profilePath(id))
    if not data then
        return nil, err
    end
    local events, skipped = validateEvents(data.events or {}, false)
    if not events then
        return nil, "รูปแบบเหตุการณ์เสียหาย"
    end
    if skipped and skipped > 0 then
        Log.add("warn", "โหลดโปรไฟล์โดยข้ามเหตุการณ์เสีย " .. tostring(skipped) .. " รายการ")
    end
    return {
        id = id,
        name = type(data.name) == "string" and trimText(data.name) or "โปรไฟล์",
        created = numberOr(data.created, os.time()),
        modified = numberOr(data.modified, os.time()),
        duration = numberOr(data.duration, #events > 0 and events[#events].t or 0),
        count = #events,
        events = events,
    }
end

local function addProfileMeta(meta)
    table.insert(Profiles.list, 1, meta)
end

local function scanProfileFiles()
    if type(listfiles) ~= "function" then
        return
    end
    local ok, entries = pcall(listfiles, PROFILE_DIR)
    if not ok or type(entries) ~= "table" then
        return
    end

    local found = {}
    for _, path in ipairs(entries) do
        local base = tostring(path):match("([^/\\]+)$") or tostring(path)
        if string.sub(string.lower(base), -5) == ".json" then
            local id = string.sub(base, 1, #base - 5)
            local profile = readProfileFromDisk(id)
            if profile then
                table.insert(found, {
                    id = id,
                    name = uniqueProfileName(profile.name),
                    created = profile.created,
                    modified = profile.modified,
                    duration = profile.duration,
                    count = profile.count,
                })
            end
        end
    end

    table.sort(found, function(a, b)
        return (a.modified or 0) > (b.modified or 0)
    end)
    Profiles.list = found
end

local function loadProfiles()
    local data, err = readJsonFile(INDEX_PATH)
    if data and type(data.items) == "table" then
        local loaded = {}
        for _, item in ipairs(data.items) do
            if type(item) == "table" and type(item.id) == "string" and type(item.name) == "string" then
                local id = item.id
                local exists = true
                if FileTools.ready then
                    exists = fileExists(profilePath(id))
                end
                if exists then
                    table.insert(loaded, {
                        id = id,
                        name = trimText(item.name),
                        created = numberOr(item.created, os.time()),
                        modified = numberOr(item.modified, os.time()),
                        duration = math.max(0, numberOr(item.duration, 0)),
                        count = math.max(0, math.floor(numberOr(item.count, 0))),
                    })
                end
            end
        end
        Profiles.list = loaded
        if type(data.selected) == "string" and findProfileMeta(data.selected) then
            Profiles.selectedId = data.selected
        end
    else
        if err ~= "ไม่พบไฟล์" then
            Log.add("warn", "อ่าน index ไม่ได้: " .. tostring(err))
        end
        scanProfileFiles()
    end

    if #Profiles.list == 0 then
        local meta = {
            id = newProfileId(),
            name = uniqueProfileName("โปรไฟล์ 1"),
            created = os.time(),
            modified = os.time(),
            duration = 0,
            count = 0,
        }
        addProfileMeta(meta)
        Profiles.selectedId = meta.id
        Profiles.events = {}
        saveProfileToDisk(meta, {})
        saveIndex()
        Log.add("info", "สร้างโปรไฟล์เริ่มต้น: " .. meta.name)
    end
end

-- ============================================================================
-- 09) ตัวช่วยสร้าง UI
-- ============================================================================

local function newInstance(className, props)
    local instance = Instance.new(className)
    if props then
        for key, value in pairs(props) do
            if key ~= "Parent" then
                instance[key] = value
            end
        end
        if props.Parent then
            instance.Parent = props.Parent
        end
    end
    return instance
end

local function nextLayoutOrder(parent)
    local current = parent:GetAttribute("_layoutOrder")
    if type(current) ~= "number" then
        current = 0
    end
    current += 1
    parent:SetAttribute("_layoutOrder", current)
    return current
end

local function addCorner(instance, radius)
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, radius or 8)
    corner.Parent = instance
    return corner
end

local function addStroke(instance, color, thickness)
    local existing = instance:FindFirstChildOfClass("UIStroke")
    if existing then
        existing.Color = color or Theme.stroke
        existing.Thickness = thickness or 1
        return existing
    end
    local stroke = Instance.new("UIStroke")
    stroke.Color = color or Theme.stroke
    stroke.Thickness = thickness or 1
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.Parent = instance
    return stroke
end

local function applyPadding(instance, top, bottom, left, right)
    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, top or 0)
    padding.PaddingBottom = UDim.new(0, bottom or 0)
    padding.PaddingLeft = UDim.new(0, left or 0)
    padding.PaddingRight = UDim.new(0, right or 0)
    padding.Parent = instance
    return padding
end

local function makeLabel(parent, text, textSize, color, size, xAlign)
    local label = newInstance("TextLabel", {
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = size or UDim2.new(1, 0, 0, 20),
        Font = FONT,
        Text = tostring(text or ""),
        TextSize = textSize or 14,
        TextColor3 = color or Theme.text,
        TextXAlignment = xAlign or Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        TextTruncate = Enum.TextTruncate.AtEnd,
        RichText = false,
        LineHeight = 1.05,
        Parent = parent,
    })
    label.LayoutOrder = nextLayoutOrder(parent)
    return label
end

local function makeWrappedLabel(parent, text, textSize, color, height)
    local label = newInstance("TextLabel", {
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, height or 36),
        Font = FONT,
        Text = tostring(text or ""),
        TextSize = textSize or 12,
        TextColor3 = color or Theme.muted,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        TextWrapped = true,
        RichText = false,
        LineHeight = 1.1,
        Parent = parent,
    })
    label.LayoutOrder = nextLayoutOrder(parent)
    return label
end

local function makeButton(parent, text, size, background, onClick, options)
    options = options or {}
    local baseColor = background or Theme.panel3
    local button = newInstance("TextButton", {
        Size = size or UDim2.new(0, 120, 0, 34),
        BackgroundColor3 = baseColor,
        BackgroundTransparency = options.transparent and 0.75 or 0,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Font = FONT,
        Text = tostring(text or ""),
        TextSize = options.textSize or 13,
        TextColor3 = options.textColor or Theme.text,
        TextXAlignment = Enum.TextXAlignment.Center,
        TextYAlignment = Enum.TextYAlignment.Center,
        ClipsDescendants = true,
        Parent = parent,
    })
    button.LayoutOrder = nextLayoutOrder(parent)
    button:SetAttribute("enabled", true)
    button:SetAttribute("baseTransparency", options.transparent and 0.75 or 0)

    addCorner(button, 8)
    if options.stroke or options.transparent then
        local stroke = addStroke(button, options.stroke or Theme.stroke, 1)
        stroke.Transparency = 0.15
    end

    button.MouseEnter:Connect(function()
        if button:GetAttribute("enabled") == false then
            return
        end
        button.BackgroundColor3 = baseColor:Lerp(Theme.white, 0.08)
    end)
    button.MouseLeave:Connect(function()
        button.BackgroundColor3 = baseColor
    end)
    button.MouseButton1Click:Connect(function()
        if button:GetAttribute("enabled") == false then
            return
        end
        local ok, err = pcall(onClick)
        if not ok then
            Log.add("error", "คำสั่ง UI ผิดพลาด: " .. tostring(err))
        end
    end)
    return button
end

local function setButtonEnabled(button, enabled)
    if not button then
        return
    end
    button:SetAttribute("enabled", enabled == true)
    button.Active = enabled == true
    button.AutoButtonColor = false
    local baseTransparency = button:GetAttribute("baseTransparency")
    if type(baseTransparency) ~= "number" then
        baseTransparency = 0
    end
    button.BackgroundTransparency = enabled and baseTransparency or 0.62
    button.TextTransparency = enabled and 0 or 0.45
end

local function setButtonText(button, text)
    if button then
        button.Text = tostring(text or "")
    end
end

local function makeCard(parent, title)
    local card = newInstance("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = Theme.panel,
        BackgroundTransparency = 0,
        BorderSizePixel = 0,
        Parent = parent,
    })
    card.LayoutOrder = nextLayoutOrder(parent)
    addCorner(card, 10)
    addStroke(card, Theme.stroke, 1)
    applyPadding(card, 14, 14, 14, 14)

    local list = Instance.new("UIListLayout")
    list.Padding = UDim.new(0, 10)
    list.SortOrder = Enum.SortOrder.LayoutOrder
    list.Parent = card

    local head = newInstance("Frame", {
        Size = UDim2.new(1, 0, 0, 20),
        BackgroundTransparency = 1,
        Parent = card,
    })
    head.LayoutOrder = nextLayoutOrder(card)

    local bar = newInstance("Frame", {
        Size = UDim2.fromOffset(3, 14),
        Position = UDim2.new(0, 0, 0.5, -7),
        BackgroundColor3 = Theme.accent,
        BorderSizePixel = 0,
        Parent = head,
    })
    addCorner(bar, 2)

    local titleLabel = newInstance("TextLabel", {
        Size = UDim2.new(1, -12, 1, 0),
        Position = UDim2.new(0, 12, 0, 0),
        BackgroundTransparency = 1,
        Font = FONT_TITLE,
        Text = tostring(title or ""),
        TextSize = 14,
        TextColor3 = Theme.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = head,
    })

    local content = newInstance("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Parent = card,
    })
    content.LayoutOrder = nextLayoutOrder(card)
    local contentList = Instance.new("UIListLayout")
    contentList.Padding = UDim.new(0, 8)
    contentList.SortOrder = Enum.SortOrder.LayoutOrder
    contentList.Parent = content

    return card, content
end

local function addRow(parent, height)
    local row = newInstance("Frame", {
        Size = UDim2.new(1, 0, 0, height or 34),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Parent = parent,
    })
    row.LayoutOrder = nextLayoutOrder(parent)
    return row
end

local function makeNumberRow(parent, labelText, initialValue, options, onChange)
    options = options or {}
    local minimum = options.min or 0
    local maximum = options.max or 100
    local integer = options.integer == true
    local value = numberOr(initialValue, minimum)

    local row = addRow(parent, 36)
    makeLabel(row, labelText, 13, Theme.text, UDim2.new(1, -120, 1, 0))

    local box = newInstance("TextBox", {
        Size = UDim2.fromOffset(100, 30),
        Position = UDim2.new(1, -100, 0.5, -15),
        BackgroundColor3 = Theme.dark,
        BorderSizePixel = 0,
        Font = FONT,
        Text = formatNumber(value),
        TextSize = 13,
        TextColor3 = Theme.text,
        TextXAlignment = Enum.TextXAlignment.Center,
        TextYAlignment = Enum.TextYAlignment.Center,
        ClearTextOnFocus = false,
        TextEditable = true,
        Parent = row,
    })
    addCorner(box, 6)
    local boxStroke = addStroke(box, Theme.stroke, 1)

    local function applyValue(raw, fire)
        local parsed = tonumber(trimText(raw))
        if not parsed or parsed ~= parsed then
            box.Text = formatNumber(value)
            return
        end
        parsed = math.clamp(parsed, minimum, maximum)
        if integer then
            parsed = math.floor(parsed + 0.5)
        end
        local changed = math.abs(parsed - value) > 0.0001
        value = parsed
        box.Text = formatNumber(value)
        if changed and fire then
            local ok, err = pcall(onChange, value)
            if not ok then
                Log.add("error", "ตั้งค่าไม่สำเร็จ: " .. tostring(err))
            end
        end
    end

    box.Focused:Connect(function()
        boxStroke.Color = Theme.accent
    end)
    box.FocusLost:Connect(function()
        boxStroke.Color = Theme.stroke
        applyValue(box.Text, true)
    end)

    return {
        box = box,
        get = function()
            return value
        end,
        set = function(newValue)
            value = math.clamp(numberOr(newValue, minimum), minimum, maximum)
            if integer then
                value = math.floor(value + 0.5)
            end
            box.Text = formatNumber(value)
        end,
        apply = function()
            applyValue(box.Text, true)
        end,
    }
end

local function makeToggleRow(parent, labelText, initialValue, hintText, onChange)
    local value = initialValue == true
    local rowHeight = hintText and 58 or 40
    local row = addRow(parent, rowHeight)

    makeLabel(row, labelText, 13, Theme.text, UDim2.new(1, -140, 0, hintText and 24 or 40))

    local stateLabel = makeLabel(row, "", 11, Theme.muted, UDim2.fromOffset(44, 40), Enum.TextXAlignment.Right)
    stateLabel.Position = UDim2.new(1, -130, 0, 0)

    local switch = newInstance("TextButton", {
        Size = UDim2.fromOffset(50, 26),
        Position = UDim2.new(1, -50, 0, hintText and 7 or 7),
        BackgroundColor3 = Theme.panel3,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Text = "",
        Parent = row,
    })
    addCorner(switch, 13)
    addStroke(switch, Theme.stroke, 1)

    local knob = newInstance("Frame", {
        Size = UDim2.fromOffset(18, 18),
        Position = UDim2.new(0, 4, 0.5, -9),
        BackgroundColor3 = Theme.white,
        BorderSizePixel = 0,
        Parent = switch,
    })
    addCorner(knob, 9)

    if hintText then
        local hint = makeLabel(row, hintText, 11, Theme.muted, UDim2.new(1, -70, 0, 16))
        hint.Position = UDim2.new(0, 0, 0, 28)
        hint.TextWrapped = true
        hint.TextYAlignment = Enum.TextYAlignment.Top
    end

    local function render()
        switch.BackgroundColor3 = value and Theme.accent or Theme.panel3
        knob.Position = value and UDim2.new(1, -22, 0.5, -9) or UDim2.new(0, 4, 0.5, -9)
        stateLabel.Text = value and "เปิด" or "ปิด"
        stateLabel.TextColor3 = value and Theme.success or Theme.muted
    end

    local function setValue(newValue, fire)
        newValue = newValue == true
        local changed = newValue ~= value
        value = newValue
        render()
        if changed and fire then
            local ok, err = pcall(onChange, value)
            if not ok then
                Log.add("error", "ตั้งค่าไม่สำเร็จ: " .. tostring(err))
            end
        end
    end

    switch.MouseButton1Click:Connect(function()
        setValue(not value, true)
    end)

    render()
    return {
        switch = switch,
        get = function()
            return value
        end,
        set = function(newValue, fire)
            setValue(newValue, fire)
        end,
    }
end

local function makeProgressBar(parent)
    local bar = newInstance("Frame", {
        Size = UDim2.new(1, 0, 0, 8),
        BackgroundColor3 = Theme.dark,
        BorderSizePixel = 0,
        Parent = parent,
    })
    bar.LayoutOrder = nextLayoutOrder(parent)
    addCorner(bar, 4)

    local fill = newInstance("Frame", {
        Size = UDim2.new(0, 0, 1, 0),
        BackgroundColor3 = Theme.accent,
        BorderSizePixel = 0,
        Parent = bar,
    })
    addCorner(fill, 4)
    return bar, fill
end

local function makeInfoRow(parent, labelText, valueText, valueColor)
    local row = addRow(parent, 30)
    makeLabel(row, labelText, 12, Theme.muted, UDim2.new(0.5, 0, 1, 0))
    local valueLabel = makeLabel(row, valueText, 12, valueColor or Theme.text, UDim2.new(0.5, 0, 1, 0), Enum.TextXAlignment.Right)
    valueLabel.Position = UDim2.new(0.5, 0, 0, 0)
    return valueLabel
end

-- ============================================================================
-- 10) สถานะและหน้าต่าง Modal
-- ============================================================================

local function setStatus(text, kind)
    State.statusText = tostring(text or "")
    State.statusKind = kind or "ready"
    local color = STATUS_COLORS[State.statusKind] or Theme.muted

    if UI.statusText then
        UI.statusText.Text = State.statusText
        UI.statusText.TextColor3 = color
    end
    if UI.statusDot then
        UI.statusDot.BackgroundColor3 = color
    end
    if UI.statusStroke then
        UI.statusStroke.Color = color
    end
    if UI.refs.statusPageStatus then
        UI.refs.statusPageStatus.Text = State.statusText
        UI.refs.statusPageStatus.TextColor3 = color
    end
    if type(App.updateDockStatus) == "function" then
        pcall(App.updateDockStatus)
    end
end

local function closeModal()
    if UI.modal then
        UI.modal:Destroy()
        UI.modal = nil
    end
end

local function openModal(title, subtitle, width, height)
    if not UI.main then
        return nil
    end
    closeModal()

    local overlay = newInstance("TextButton", {
        Name = "ModalOverlay",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Theme.dark,
        BackgroundTransparency = 0.42,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Text = "",
        ZIndex = 200,
        Parent = UI.main,
    })
    UI.modal = overlay
    overlay.MouseButton1Click:Connect(function()
        closeModal()
    end)

    local card = newInstance("Frame", {
        Name = "ModalCard",
        Size = UDim2.fromOffset(width or 440, height or 220),
        Position = UDim2.new(0.5, 0, 0.5, 0),
        AnchorPoint = Vector2.new(0.5, 0.5),
        BackgroundColor3 = Theme.panel,
        BorderSizePixel = 0,
        Active = true,
        ZIndex = 201,
        Parent = overlay,
    })
    addCorner(card, 12)
    addStroke(card, Theme.stroke, 1)

    local titleLabel = newInstance("TextLabel", {
        Size = UDim2.new(1, -36, 0, 24),
        Position = UDim2.fromOffset(18, 14),
        BackgroundTransparency = 1,
        Font = FONT_TITLE,
        Text = tostring(title or ""),
        TextSize = 16,
        TextColor3 = Theme.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        Parent = card,
    })

    if subtitle and subtitle ~= "" then
        newInstance("TextLabel", {
            Size = UDim2.new(1, -36, 0, 30),
            Position = UDim2.fromOffset(18, 38),
            BackgroundTransparency = 1,
            Font = FONT,
            Text = tostring(subtitle),
            TextSize = 12,
            TextColor3 = Theme.muted,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Top,
            TextWrapped = true,
            LineHeight = 1.1,
            Parent = card,
        })
    end

    local content = newInstance("Frame", {
        Size = UDim2.new(1, -36, 1, -130),
        Position = UDim2.fromOffset(18, 70),
        BackgroundTransparency = 1,
        Parent = card,
    })

    local actions = newInstance("Frame", {
        Size = UDim2.new(1, -36, 0, 36),
        Position = UDim2.new(0, 18, 1, -52),
        BackgroundTransparency = 1,
        Parent = card,
    })
    local actionList = Instance.new("UIListLayout")
    actionList.FillDirection = Enum.FillDirection.Horizontal
    actionList.HorizontalAlignment = Enum.HorizontalAlignment.Right
    actionList.VerticalAlignment = Enum.VerticalAlignment.Center
    actionList.Padding = UDim.new(0, 8)
    actionList.SortOrder = Enum.SortOrder.LayoutOrder
    actionList.Parent = actions

    local modal = {
        overlay = overlay,
        card = card,
        content = content,
        actions = actions,
    }

    function modal.addAction(text, color, callback, options)
        options = options or {}
        return makeButton(actions, text, UDim2.fromOffset(options.width or 112, 34), color, callback, {
            textSize = 12,
            stroke = options.stroke,
            transparent = options.transparent,
        })
    end

    return modal
end

local function showPrompt(title, subtitle, defaultText, confirmText, onConfirm)
    local modal = openModal(title, subtitle, 440, 220)
    if not modal then
        return
    end

    local box = newInstance("TextBox", {
        Size = UDim2.new(1, 0, 0, 34),
        BackgroundColor3 = Theme.dark,
        BorderSizePixel = 0,
        Font = FONT,
        Text = tostring(defaultText or ""),
        PlaceholderText = "ชื่อโปรไฟล์",
        PlaceholderColor3 = Theme.muted,
        TextSize = 13,
        TextColor3 = Theme.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        ClearTextOnFocus = false,
        Parent = modal.content,
    })
    applyPadding(box, 0, 0, 10, 10)
    addCorner(box, 6)
    addStroke(box, Theme.stroke, 1)

    local errorLabel = newInstance("TextLabel", {
        Size = UDim2.new(1, 0, 0, 18),
        Position = UDim2.fromOffset(0, 42),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = "",
        TextSize = 11,
        TextColor3 = Theme.danger,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        Parent = modal.content,
    })

    modal.addAction("ยกเลิก", Theme.panel3, closeModal)
    modal.addAction(confirmText or "ยืนยัน", Theme.accent, function()
        local name, err = normalizeProfileName(box.Text)
        if not name then
            errorLabel.Text = err
            return
        end
        closeModal()
        local ok, callbackError = pcall(onConfirm, name)
        if not ok then
            Log.add("error", "ดำเนินการไม่สำเร็จ: " .. tostring(callbackError))
        end
    end)

    task.defer(function()
        pcall(function()
            box:CaptureFocus()
            box.CursorPosition = -1
        end)
    end)
end

local function showConfirm(title, message, confirmText, onConfirm, isDanger)
    local modal = openModal(title, nil, 460, 210)
    if not modal then
        return
    end

    local messageLabel = newInstance("TextLabel", {
        Size = UDim2.new(1, 0, 0, 80),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = tostring(message or ""),
        TextSize = 13,
        TextColor3 = Theme.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        TextWrapped = true,
        LineHeight = 1.15,
        Parent = modal.content,
    })

    modal.addAction("ยกเลิก", Theme.panel3, closeModal)
    modal.addAction(confirmText or "ยืนยัน", isDanger and Theme.danger or Theme.accent, function()
        closeModal()
        local ok, err = pcall(onConfirm)
        if not ok then
            Log.add("error", "ดำเนินการไม่สำเร็จ: " .. tostring(err))
        end
    end)
end

local function showExportDialog(jsonText, subtitle)
    local modal = openModal("ส่งออกโปรไฟล์", subtitle, 560, 480)
    if not modal then
        return
    end

    local box = newInstance("TextBox", {
        Size = UDim2.new(1, 0, 0, 300),
        BackgroundColor3 = Theme.dark,
        BorderSizePixel = 0,
        Font = FONT,
        Text = jsonText,
        TextSize = 11,
        TextColor3 = Theme.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        TextWrapped = true,
        MultiLine = true,
        ClearTextOnFocus = false,
        Parent = modal.content,
    })
    applyPadding(box, 8, 8, 10, 10)
    addCorner(box, 6)
    addStroke(box, Theme.stroke, 1)

    local note = newInstance("TextLabel", {
        Size = UDim2.new(1, 0, 0, 20),
        Position = UDim2.fromOffset(0, 312),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = subtitle or "",
        TextSize = 11,
        TextColor3 = Theme.muted,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        TextWrapped = true,
        Parent = modal.content,
    })

    modal.addAction("คัดลอกอีกครั้ง", Theme.panel3, function()
        if type(setclipboard) ~= "function" then
            note.Text = "API คลิปบอร์ดไม่พร้อมใช้งาน"
            note.TextColor3 = Theme.danger
            return
        end
        local ok, err = pcall(setclipboard, jsonText)
        if ok then
            note.Text = "คัดลอก JSON ไปยังคลิปบอร์ดแล้ว"
            note.TextColor3 = Theme.success
        else
            note.Text = "คัดลอกไม่สำเร็จ: " .. tostring(err)
            note.TextColor3 = Theme.danger
        end
    end)
    modal.addAction("ปิด", Theme.accent, closeModal)
end

local function showImportDialog()
    local modal = openModal("นำเข้าโปรไฟล์", "วางข้อความ JSON ที่คัดลอกมา แล้วกดนำเข้า", 560, 480)
    if not modal then
        return
    end

    local box = newInstance("TextBox", {
        Size = UDim2.new(1, 0, 0, 300),
        BackgroundColor3 = Theme.dark,
        BorderSizePixel = 0,
        Font = FONT,
        Text = "",
        PlaceholderText = "วาง JSON ที่นี่ (Ctrl+V)",
        PlaceholderColor3 = Theme.muted,
        TextSize = 11,
        TextColor3 = Theme.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        TextWrapped = true,
        MultiLine = true,
        ClearTextOnFocus = false,
        Parent = modal.content,
    })
    applyPadding(box, 8, 8, 10, 10)
    addCorner(box, 6)
    addStroke(box, Theme.stroke, 1)

    local errorLabel = newInstance("TextLabel", {
        Size = UDim2.new(1, 0, 0, 20),
        Position = UDim2.fromOffset(0, 312),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = "",
        TextSize = 11,
        TextColor3 = Theme.danger,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        TextWrapped = true,
        Parent = modal.content,
    })

    modal.addAction("ยกเลิก", Theme.panel3, closeModal)
    modal.addAction("นำเข้า", Theme.accent, function()
        local ok, err = App.importProfileText(box.Text)
        if ok then
            closeModal()
        else
            errorLabel.Text = tostring(err or "นำเข้าไม่สำเร็จ")
        end
    end)

    task.defer(function()
        pcall(function()
            box:CaptureFocus()
        end)
    end)
end

-- ============================================================================
-- 11) สร้าง GUI
-- ============================================================================

local function setMenuVisible(visible)
    visible = visible == true
    if not UI.main then
        return
    end
    if not visible then
        closeModal()
    end
    UI.main.Visible = visible
    if UI.dock then
        UI.dock.Visible = not visible
    end
    State.menuVisible = visible
    if visible and State.autoHidden then
        State.autoHidden = false
    end
end

local function toggleMenu()
    setMenuVisible(not State.menuVisible)
end

local function switchPage(key)
    for pageKey, page in pairs(UI.pages) do
        page.frame.Visible = pageKey == key
    end
    for navKey, nav in pairs(UI.nav) do
        local active = navKey == key
        nav.button.BackgroundColor3 = active and Theme.panel2 or Theme.panel
        nav.button.TextColor3 = active and Theme.accent or Theme.muted
        nav.bar.Visible = active
    end
    UI.activePage = key
end

local function resolveGuiParent()
    if type(gethui) == "function" then
        local ok, hiddenUi = pcall(gethui)
        if ok and typeof(hiddenUi) == "Instance" then
            local old = hiddenUi:FindFirstChild(GUI_NAME)
            if old then
                pcall(function()
                    old:Destroy()
                end)
            end
            return hiddenUi, "gethui"
        end
    end

    local okCore, coreGui = pcall(function()
        return game:GetService("CoreGui")
    end)
    if okCore and coreGui then
        local old = coreGui:FindFirstChild(GUI_NAME)
        if old then
            pcall(function()
                old:Destroy()
            end)
        end
        return coreGui, "CoreGui"
    end

    if LocalPlayer then
        local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
        if not playerGui then
            playerGui = LocalPlayer:WaitForChild("PlayerGui", 5)
        end
        if playerGui then
            local old = playerGui:FindFirstChild(GUI_NAME)
            if old then
                pcall(function()
                    old:Destroy()
                end)
            end
            return playerGui, "PlayerGui"
        end
    end

    return nil, "none"
end

local function buildUI()
    local parent, guiMode = resolveGuiParent()
    if not parent then
        return false, "ไม่พบที่สำหรับสร้าง GUI"
    end
    App.apiStatus.gui = guiMode

    local screenGui = newInstance("ScreenGui", {
        Name = GUI_NAME,
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        DisplayOrder = 999999,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        Parent = parent,
    })
    UI.screenGui = screenGui

    local viewport = getViewport()
    local mainWidth = 840
    local mainHeight = 600
    local initialX = math.max(8, math.floor((viewport.X - mainWidth) / 2))
    local initialY = math.max(8, math.floor((viewport.Y - mainHeight) / 2))

    local main = newInstance("Frame", {
        Name = "Main",
        Size = UDim2.fromOffset(mainWidth, mainHeight),
        Position = UDim2.fromOffset(initialX, initialY),
        BackgroundColor3 = Theme.bg,
        BorderSizePixel = 0,
        ClipsDescendants = true,
        Parent = screenGui,
    })
    UI.main = main
    addCorner(main, 12)
    addStroke(main, Theme.stroke, 1)

    -- Header ---------------------------------------------------------------
    local header = newInstance("Frame", {
        Name = "Header",
        Size = UDim2.new(1, 0, 0, 62),
        BackgroundColor3 = Theme.panel,
        BorderSizePixel = 0,
        Parent = main,
    })

    local headerLine = newInstance("Frame", {
        Size = UDim2.new(1, 0, 0, 1),
        Position = UDim2.new(0, 0, 1, -1),
        BackgroundColor3 = Theme.stroke,
        BorderSizePixel = 0,
        Parent = header,
    })

    local titleArea = newInstance("Frame", {
        Name = "DragArea",
        Size = UDim2.new(0, 470, 1, 0),
        BackgroundTransparency = 1,
        Active = true,
        Parent = header,
    })

    newInstance("TextLabel", {
        Size = UDim2.new(1, -20, 0, 24),
        Position = UDim2.fromOffset(20, 8),
        BackgroundTransparency = 1,
        Font = FONT_TITLE,
        Text = "ASTD Macro",
        TextSize = 19,
        TextColor3 = Theme.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        Parent = titleArea,
    })

    newInstance("TextLabel", {
        Size = UDim2.new(1, -20, 0, 18),
        Position = UDim2.fromOffset(20, 33),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = "บันทึกและเล่นซ้ำอินพุต • Real Executor",
        TextSize = 11,
        TextColor3 = Theme.muted,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        Parent = titleArea,
    })

    local statusPill = newInstance("Frame", {
        Size = UDim2.fromOffset(170, 26),
        Position = UDim2.new(1, -360, 0, 18),
        BackgroundColor3 = Theme.panel2,
        BorderSizePixel = 0,
        Parent = header,
    })
    addCorner(statusPill, 13)
    UI.statusStroke = addStroke(statusPill, Theme.success, 1)
    UI.statusStroke.Transparency = 0.25

    UI.statusDot = newInstance("Frame", {
        Size = UDim2.fromOffset(8, 8),
        Position = UDim2.new(0, 11, 0.5, -4),
        BackgroundColor3 = Theme.success,
        BorderSizePixel = 0,
        Parent = statusPill,
    })
    addCorner(UI.statusDot, 4)

    UI.statusText = newInstance("TextLabel", {
        Size = UDim2.new(1, -30, 1, 0),
        Position = UDim2.fromOffset(25, 0),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = "พร้อมใช้งาน",
        TextSize = 11,
        TextColor3 = Theme.success,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = statusPill,
    })

    local minimizeButton = makeButton(header, "—", UDim2.fromOffset(34, 36), Theme.panel3, function()
        setMenuVisible(false)
    end, { textSize = 17 })
    minimizeButton.Position = UDim2.new(1, -180, 0, 13)

    local emergencyButton = makeButton(header, "■  หยุดฉุกเฉิน", UDim2.fromOffset(122, 36), Theme.danger, function()
        App.emergencyStop()
    end, { textSize = 12 })
    emergencyButton.Position = UDim2.new(1, -138, 0, 13)
    UI.emergencyButton = emergencyButton

    titleArea.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
            return
        end
        if UI.modal then
            return
        end
        State.dragging = true
        State.dragStart = input.Position
        State.dragOrigin = main.Position
    end)

    -- Sidebar --------------------------------------------------------------
    local sidebar = newInstance("Frame", {
        Name = "Sidebar",
        Size = UDim2.new(0, 184, 1, -90),
        Position = UDim2.new(0, 0, 0, 62),
        BackgroundColor3 = Theme.panel,
        BorderSizePixel = 0,
        Parent = main,
    })

    newInstance("Frame", {
        Size = UDim2.new(0, 1, 1, 0),
        Position = UDim2.new(1, -1, 0, 0),
        BackgroundColor3 = Theme.stroke,
        BorderSizePixel = 0,
        Parent = sidebar,
    })

    newInstance("TextLabel", {
        Size = UDim2.new(1, -24, 0, 16),
        Position = UDim2.fromOffset(14, 16),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = "เมนู",
        TextSize = 10,
        TextColor3 = Theme.muted,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        Parent = sidebar,
    })

    local navItems = {
        { key = "macro", label = "มาโคร" },
        { key = "profiles", label = "โปรไฟล์" },
        { key = "playback", label = "การเล่นซ้ำ" },
        { key = "settings", label = "ตั้งค่า" },
        { key = "logs", label = "บันทึกสถานะ" },
    }

    for index, item in ipairs(navItems) do
        local button = newInstance("TextButton", {
            Size = UDim2.new(1, -24, 0, 42),
            Position = UDim2.fromOffset(12, 42 + (index - 1) * 48),
            BackgroundColor3 = Theme.panel,
            BorderSizePixel = 0,
            AutoButtonColor = false,
            Font = FONT,
            Text = item.label,
            TextSize = 13,
            TextColor3 = Theme.muted,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Center,
            Parent = sidebar,
        })
        applyPadding(button, 0, 0, 16, 8)
        addCorner(button, 8)

        local bar = newInstance("Frame", {
            Size = UDim2.fromOffset(3, 18),
            Position = UDim2.new(0, 0, 0.5, -9),
            BackgroundColor3 = Theme.accent,
            BorderSizePixel = 0,
            Visible = false,
            Parent = button,
        })
        addCorner(bar, 2)

        button.MouseEnter:Connect(function()
            if UI.activePage ~= item.key then
                button.BackgroundColor3 = Theme.panel2
                button.TextColor3 = Theme.text
            end
        end)
        button.MouseLeave:Connect(function()
            if UI.activePage ~= item.key then
                button.BackgroundColor3 = Theme.panel
                button.TextColor3 = Theme.muted
            end
        end)
        button.MouseButton1Click:Connect(function()
            switchPage(item.key)
        end)

        UI.nav[item.key] = {
            button = button,
            bar = bar,
        }
    end

    local sidebarHint = newInstance("TextLabel", {
        Size = UDim2.new(1, -24, 0, 42),
        Position = UDim2.new(0, 12, 1, -54),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = "F7  ซ่อน / แสดงเมนู\nF8  หยุดฉุกเฉิน",
        TextSize = 10,
        TextColor3 = Theme.muted,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        TextWrapped = true,
        LineHeight = 1.2,
        Parent = sidebar,
    })

    -- Footer ---------------------------------------------------------------
    local footer = newInstance("Frame", {
        Name = "Footer",
        Size = UDim2.new(1, 0, 0, 28),
        Position = UDim2.new(0, 0, 1, -28),
        BackgroundColor3 = Theme.panel,
        BorderSizePixel = 0,
        Parent = main,
    })

    newInstance("Frame", {
        Size = UDim2.new(1, 0, 0, 1),
        BackgroundColor3 = Theme.stroke,
        BorderSizePixel = 0,
        Parent = footer,
    })

    UI.footerProfile = newInstance("TextLabel", {
        Size = UDim2.new(1, -260, 1, 0),
        Position = UDim2.fromOffset(14, 0),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = "โปรไฟล์: —",
        TextSize = 10,
        TextColor3 = Theme.muted,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = footer,
    })

    newInstance("TextLabel", {
        Size = UDim2.fromOffset(230, 28),
        Position = UDim2.new(1, -244, 0, 0),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = string.format("%s v%s • เก็บข้อมูลใน %s/", APP_NAME, APP_VERSION, ROOT_DIR),
        TextSize = 10,
        TextColor3 = Theme.muted,
        TextXAlignment = Enum.TextXAlignment.Right,
        TextYAlignment = Enum.TextYAlignment.Center,
        Parent = footer,
    })

    -- Page host ------------------------------------------------------------
    local pageHost = newInstance("Frame", {
        Name = "PageHost",
        Size = UDim2.new(1, -184, 1, -90),
        Position = UDim2.new(0, 184, 0, 62),
        BackgroundTransparency = 1,
        Parent = main,
    })
    applyPadding(pageHost, 10, 4, 16, 10)

    local function makePage(key, title, subtitle)
        local page = newInstance("ScrollingFrame", {
            Name = "Page_" .. key,
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            CanvasSize = UDim2.new(0, 0, 0, 0),
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
            ScrollingDirection = Enum.ScrollingDirection.Y,
            ScrollBarThickness = 4,
            ScrollBarImageColor3 = Theme.stroke,
            ClipsDescendants = true,
            Visible = false,
            Parent = pageHost,
        })
        applyPadding(page, 0, 14, 0, 6)

        local layout = Instance.new("UIListLayout")
        layout.Padding = UDim.new(0, 10)
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.Parent = page

        local titleLabel = makeLabel(page, title, 20, Theme.text, UDim2.new(1, 0, 0, 26))
        local subtitleLabel = makeLabel(page, subtitle, 12, Theme.muted, UDim2.new(1, 0, 0, 18))

        UI.pages[key] = {
            frame = page,
            title = titleLabel,
            subtitle = subtitleLabel,
        }
        return page
    end

    local function makeButtonRow(parent, height)
        local row = addRow(parent, height or 36)
        local layout = Instance.new("UIListLayout")
        layout.FillDirection = Enum.FillDirection.Horizontal
        layout.Padding = UDim.new(0, 8)
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.Parent = row
        return row
    end

    -- หน้า มาโคร ----------------------------------------------------------
    local macroPage = makePage("macro", "มาโคร", "เลือกโปรไฟล์ เริ่มบันทึก และควบคุมการเล่นซ้ำ")
    do
        local _, body = makeCard(macroPage, "โปรไฟล์ที่เลือก")
        UI.refs.macroProfileName = makeLabel(body, "ยังไม่มีโปรไฟล์", 17, Theme.text, UDim2.new(1, 0, 0, 24))
        UI.refs.macroProfileMeta = makeLabel(body, "0 เหตุการณ์ • 0:00", 11, Theme.muted, UDim2.new(1, 0, 0, 16))

        local row = makeButtonRow(body, 36)
        makeButton(row, "จัดการโปรไฟล์", UDim2.new(0.5, -4, 1, 0), Theme.panel3, function()
            switchPage("profiles")
        end, { textSize = 12 })
        UI.refs.saveNowButton = makeButton(row, "บันทึกตอนนี้", UDim2.new(0.5, -4, 1, 0), Theme.successDark, function()
            App.saveCurrentProfile()
        end, { textSize = 12 })
    end

    do
        local _, body = makeCard(macroPage, "บันทึกอินพุต")
        makeWrappedLabel(body, "กดเริ่มบันทึก แล้วรอ 3 วินาที ระบบจะบันทึกเมาส์และคีย์บอร์ดจนกว่าจะกดหยุด ปุ่ม F7/F8 จะไม่ถูกบันทึก", 12, Theme.muted, 38)

        local row = makeButtonRow(body, 38)
        local recordButton = makeButton(row, "●  เริ่มบันทึก", UDim2.new(0.56, -4, 1, 0), Theme.danger, function()
            App.requestStartRecording()
        end, { textSize = 13 })
        UI.refs.recordButton = recordButton
        table.insert(UI.transport.record, recordButton)

        makeButton(row, "ซ่อนเมนู (F7)", UDim2.new(0.44, -4, 1, 0), Theme.panel3, function()
            setMenuVisible(false)
        end, { textSize = 11 })

        UI.refs.recordInfo = makeLabel(body, "เวลา 0:00 • 0 เหตุการณ์", 11, Theme.muted, UDim2.new(1, 0, 0, 16))
        makeWrappedLabel(body, "แนะนำ: ซ่อนเมนูระหว่างบันทึก เพื่อให้พื้นที่เล่นเกมไม่ถูกบัง", 10, Theme.muted, 18)
    end

    do
        local _, body = makeCard(macroPage, "เล่นซ้ำ")
        UI.refs.playbackSummary = makeLabel(body, "1 รอบ • พัก 2 วิ • ความเร็ว 1x", 12, Theme.text, UDim2.new(1, 0, 0, 18))

        local row = makeButtonRow(body, 38)
        local playButton = makeButton(row, "▶  เริ่มเล่น", UDim2.new(1 / 3, -6, 1, 0), Theme.accent, function()
            App.playOrResume()
        end, { textSize = 12 })
        table.insert(UI.transport.play, playButton)

        local pauseButton = makeButton(row, "⏸  พัก", UDim2.new(1 / 3, -6, 1, 0), Theme.panel3, function()
            App.togglePause()
        end, { textSize = 12 })
        table.insert(UI.transport.pause, pauseButton)

        local stopButton = makeButton(row, "⏹  หยุด", UDim2.new(1 / 3, -6, 1, 0), Theme.dangerDark, function()
            App.stopPlayback()
        end, { textSize = 12 })
        table.insert(UI.transport.stop, stopButton)

        UI.refs.macroPlayInfo = makeLabel(body, "ยังไม่มีข้อมูล — เริ่มบันทึกก่อน", 11, Theme.muted, UDim2.new(1, 0, 0, 16))
    end

    do
        local _, body = makeCard(macroPage, "ระบบกัน AFK (แยกจาก Macro)")
        UI.refs.afkToggle = makeToggleRow(body, "เปิดระบบกัน AFK", false, nil, function(value)
            App.setAfkEnabled(value)
        end)

        UI.refs.afkInterval = makeNumberRow(body, "ขยับทุก (นาที)", Settings.afkInterval, {
            min = 1,
            max = 15,
            integer = true,
        }, function(value)
            Settings.afkInterval = value
            saveSettings()
            App.updateAfkUI()
        end)

        UI.refs.afkStatus = makeLabel(body, "ปิดอยู่", 12, Theme.muted, UDim2.new(1, 0, 0, 18))
        UI.refs.afkStopButton = makeButton(body, "หยุดระบบ AFK", UDim2.new(1, 0, 0, 34), Theme.panel3, function()
            App.setAfkEnabled(false)
        end, { textSize = 12 })

        makeWrappedLabel(body, "ระบบจะขยับเมาส์เล็กน้อยเมื่อหน้าต่างเกม active และ Macro ไม่ได้ทำงาน ไม่รับประกันว่าจะไม่ถูก kick — ยังไม่ได้ทดสอบในเกมจริง", 10, Theme.muted, 48)
    end

    -- หน้า โปรไฟล์ ---------------------------------------------------------
    local profilesPage = makePage("profiles", "โปรไฟล์", "สร้าง เลือก เปลี่ยนชื่อ นำเข้า และส่งออก Macro")
    do
        local _, body = makeCard(profilesPage, "รายการโปรไฟล์")
        local listScroll = newInstance("ScrollingFrame", {
            Size = UDim2.new(1, 0, 0, 230),
            BackgroundColor3 = Theme.dark,
            BorderSizePixel = 0,
            CanvasSize = UDim2.new(0, 0, 0, 0),
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
            ScrollingDirection = Enum.ScrollingDirection.Y,
            ScrollBarThickness = 4,
            ScrollBarImageColor3 = Theme.stroke,
            ClipsDescendants = true,
            Parent = body,
        })
        listScroll.LayoutOrder = nextLayoutOrder(body)
        applyPadding(listScroll, 6, 6, 6, 6)
        addCorner(listScroll, 8)
        addStroke(listScroll, Theme.stroke, 1)
        local listLayout = Instance.new("UIListLayout")
        listLayout.Padding = UDim.new(0, 6)
        listLayout.SortOrder = Enum.SortOrder.LayoutOrder
        listLayout.Parent = listScroll
        UI.refs.profileList = listScroll

        local row = makeButtonRow(body, 36)
        makeButton(row, "สร้างใหม่", UDim2.new(0.5, -4, 1, 0), Theme.accent, function()
            App.promptCreateProfile()
        end, { textSize = 12 })
        makeButton(row, "นำเข้า JSON", UDim2.new(0.5, -4, 1, 0), Theme.panel3, function()
            App.promptImportProfile()
        end, { textSize = 12 })
    end

    do
        local _, body = makeCard(profilesPage, "จัดการโปรไฟล์ที่เลือก")
        UI.refs.selectedProfileName = makeLabel(body, "ยังไม่มีโปรไฟล์", 15, Theme.text, UDim2.new(1, 0, 0, 22))

        local row = makeButtonRow(body, 36)
        UI.refs.profileSaveButton = makeButton(row, "บันทึกตอนนี้", UDim2.new(1 / 3, -6, 1, 0), Theme.successDark, function()
            App.saveCurrentProfile()
        end, { textSize = 11 })
        makeButton(row, "เปลี่ยนชื่อ", UDim2.new(1 / 3, -6, 1, 0), Theme.panel3, function()
            App.promptRenameProfile()
        end, { textSize = 11 })
        makeButton(row, "ส่งออก", UDim2.new(1 / 3, -6, 1, 0), Theme.panel3, function()
            App.exportCurrentProfile()
        end, { textSize = 11 })

        UI.refs.profileDeleteButton = makeButton(body, "ลบโปรไฟล์นี้", UDim2.new(1, 0, 0, 34), Theme.dangerDark, function()
            App.promptDeleteProfile()
        end, { textSize = 12 })

        makeWrappedLabel(body, "ไฟล์โปรไฟล์ถูกเก็บใน workspace ของ Real และบันทึกอัตโนมัติเมื่อหยุดบันทึก (ถ้าเปิดไว้)", 10, Theme.muted, 30)
    end

    -- หน้า การเล่นซ้ำ ------------------------------------------------------
    local playbackPage = makePage("playback", "การเล่นซ้ำ", "ตั้งจำนวนรอบ จังหวะพัก และควบคุมการเล่น")
    do
        local _, body = makeCard(playbackPage, "รูปแบบการเล่น")
        UI.refs.loopsInput = makeNumberRow(body, "จำนวนรอบ", Settings.loops, {
            min = 1,
            max = 9999,
            integer = true,
        }, function(value)
            Settings.loops = value
            saveSettings()
            App.refreshTransport()
        end)

        UI.refs.infiniteToggle = makeToggleRow(body, "วนซ้ำไม่จำกัด", Settings.infinite, "เมื่อเปิด จะเล่นซ้ำจนกว่าจะกดหยุด", function(value)
            Settings.infinite = value
            saveSettings()
            App.refreshTransport()
        end)

        UI.refs.delayInput = makeNumberRow(body, "พักระหว่างรอบ (วินาที)", Settings.loopDelay, {
            min = 0,
            max = 600,
        }, function(value)
            Settings.loopDelay = value
            saveSettings()
            App.refreshTransport()
        end)

        UI.refs.speedInput = makeNumberRow(body, "ความเร็วเล่นซ้ำ (เท่า)", Settings.speed, {
            min = 0.25,
            max = 4,
        }, function(value)
            Settings.speed = value
            saveSettings()
            App.refreshTransport()
        end)
    end

    do
        local _, body = makeCard(playbackPage, "ควบคุมการเล่น")
        local stepLabel = makeLabel(body, "ยังไม่เริ่ม", 13, Theme.text, UDim2.new(1, 0, 0, 20))
        local loopLabel = makeLabel(body, "รอบ 0/1", 11, Theme.muted, UDim2.new(1, 0, 0, 16))
        table.insert(UI.stepLabels, stepLabel)
        table.insert(UI.loopLabels, loopLabel)

        local _, fill = makeProgressBar(body)
        table.insert(UI.progressFills, fill)
        local progressText = makeLabel(body, "0 / 0", 11, Theme.muted, UDim2.new(1, 0, 0, 16), Enum.TextXAlignment.Right)
        table.insert(UI.progressTexts, progressText)

        local row = makeButtonRow(body, 38)
        local playButton = makeButton(row, "▶  เริ่มเล่น", UDim2.new(1 / 3, -6, 1, 0), Theme.accent, function()
            App.playOrResume()
        end, { textSize = 12 })
        table.insert(UI.transport.play, playButton)

        local pauseButton = makeButton(row, "⏸  พัก", UDim2.new(1 / 3, -6, 1, 0), Theme.panel3, function()
            App.togglePause()
        end, { textSize = 12 })
        table.insert(UI.transport.pause, pauseButton)

        local stopButton = makeButton(row, "⏹  หยุด", UDim2.new(1 / 3, -6, 1, 0), Theme.dangerDark, function()
            App.stopPlayback()
        end, { textSize = 12 })
        table.insert(UI.transport.stop, stopButton)

        makeWrappedLabel(body, "ระหว่างเล่นจริง ต้องให้หน้าต่าง Roblox เป็นหน้าต่างที่ active หากเปิดการป้องกันไว้ ระบบจะพักอัตโนมัติเมื่อสลับหน้าต่าง", 10, Theme.muted, 34)
    end

    do
        local _, body = makeCard(playbackPage, "ข้อมูลโปรไฟล์")
        UI.refs.playbackProfileName = makeInfoRow(body, "ชื่อโปรไฟล์", "—")
        UI.refs.playbackEventCount = makeInfoRow(body, "จำนวนเหตุการณ์", "0")
        UI.refs.playbackDuration = makeInfoRow(body, "ความยาว", "0:00")
    end

    -- หน้า ตั้งค่า --------------------------------------------------------
    local settingsPage = makePage("settings", "ตั้งค่า", "พฤติกรรมของ Macro การปรับพิกัด และข้อมูลระบบ")
    do
        local _, body = makeCard(settingsPage, "การทำงาน")
        UI.refs.guardFocusToggle = makeToggleRow(body, "พักเมื่อเกมไม่ active", Settings.guardFocus, "ถ้าปิด การเล่นจะดำเนินต่อ แต่ Real อาจไม่ส่งอินพุต", function(value)
            Settings.guardFocus = value
            saveSettings()
        end)

        UI.refs.autosaveToggle = makeToggleRow(body, "บันทึกโปรไฟล์อัตโนมัติ", Settings.autosave, "บันทึกไฟล์เมื่อกดหยุดบันทึก", function(value)
            Settings.autosave = value
            saveSettings()
        end)

        UI.refs.autoHideToggle = makeToggleRow(body, "ซ่อนเมนูเมื่อเริ่มเล่น", Settings.autoHide, "ลดการชนกับปุ่มบนหน้าจอระหว่างเล่น", function(value)
            Settings.autoHide = value
            saveSettings()
        end)
    end

    do
        local _, body = makeCard(settingsPage, "ปรับเทียบพิกัด")
        UI.refs.offsetXInput = makeNumberRow(body, "ชดเชยแกน X (พิกเซล)", Settings.offsetX, {
            min = -1000,
            max = 1000,
            integer = true,
        }, function(value)
            Settings.offsetX = value
            saveSettings()
        end)
        UI.refs.offsetYInput = makeNumberRow(body, "ชดเชยแกน Y (พิกเซล)", Settings.offsetY, {
            min = -1000,
            max = 1000,
            integer = true,
        }, function(value)
            Settings.offsetY = value
            saveSettings()
        end)
        makeWrappedLabel(body, "ใช้เมื่อเล่นซ้ำแล้วตำแหน่งคลิกเยื้องจากเดิม ค่าเริ่มต้น 0 ทั้งสองแกน", 10, Theme.muted, 28)
    end

    do
        local _, body = makeCard(settingsPage, "ข้อมูลระบบ")
        UI.refs.infoExecutor = makeInfoRow(body, "Executor", "—")
        UI.refs.infoInput = makeInfoRow(body, "API อินพุต", "—")
        UI.refs.infoFiles = makeInfoRow(body, "API ไฟล์", "—")
        UI.refs.infoClipboard = makeInfoRow(body, "คลิปบอร์ด", "—")
        UI.refs.infoGui = makeInfoRow(body, "ตำแหน่ง GUI", "—")
        UI.refs.infoPath = makeInfoRow(body, "ที่เก็บข้อมูล", ROOT_DIR .. "/")
        makeWrappedLabel(body, "ข้อมูลทั้งหมดถูกเก็บใน workspace ของ executor ไม่มีคีย์หรือข้อมูลส่วนตัวถูกส่งออก", 10, Theme.muted, 28)
    end

    do
        local _, body = makeCard(settingsPage, "จัดการสคริปต์")
        local row = makeButtonRow(body, 36)
        makeButton(row, "รีเซ็ตการตั้งค่า", UDim2.new(0.5, -4, 1, 0), Theme.panel3, function()
            App.promptResetSettings()
        end, { textSize = 11 })
        makeButton(row, "ปิดสคริปต์", UDim2.new(0.5, -4, 1, 0), Theme.dangerDark, function()
            App.promptCloseScript()
        end, { textSize = 11 })
        makeWrappedLabel(body, "การปิดสคริปต์จะหยุดงานที่กำลังทำและปล่อยปุ่มที่ค้างอยู่ก่อนลบ GUI", 10, Theme.muted, 18)
    end

    -- หน้า บันทึกสถานะ -----------------------------------------------------
    local logsPage = makePage("logs", "บันทึกสถานะ", "ประวัติการทำงานและข้อผิดพลาดล่าสุด")
    do
        local _, body = makeCard(logsPage, "สถานะปัจจุบัน")
        UI.refs.statusPageStatus = makeInfoRow(body, "สถานะ", "พร้อมใช้งาน", Theme.success)
        UI.refs.statusPageProfile = makeInfoRow(body, "โปรไฟล์", "—")
        UI.refs.statusPageStep = makeInfoRow(body, "ขั้นตอน", "ยังไม่เริ่ม")
        UI.refs.statusPageAfk = makeInfoRow(body, "ระบบกัน AFK", "ปิดอยู่")
    end

    do
        local _, body = makeCard(logsPage, "Log ล่าสุด")
        local row = makeButtonRow(body, 34)
        makeButton(row, "คัดลอก Log", UDim2.new(0.5, -4, 1, 0), Theme.panel3, function()
            Log.copyToClipboard()
        end, { textSize = 11 })
        makeButton(row, "ล้าง Log", UDim2.new(0.5, -4, 1, 0), Theme.dangerDark, function()
            App.promptClearLog()
        end, { textSize = 11 })

        local scroll = newInstance("ScrollingFrame", {
            Size = UDim2.new(1, 0, 0, 310),
            BackgroundColor3 = Theme.dark,
            BorderSizePixel = 0,
            CanvasSize = UDim2.new(0, 0, 0, 0),
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
            ScrollingDirection = Enum.ScrollingDirection.Y,
            ScrollBarThickness = 4,
            ScrollBarImageColor3 = Theme.stroke,
            ClipsDescendants = true,
            Parent = body,
        })
        scroll.LayoutOrder = nextLayoutOrder(body)
        applyPadding(scroll, 6, 6, 6, 6)
        addCorner(scroll, 8)
        addStroke(scroll, Theme.stroke, 1)
        local logLayout = Instance.new("UIListLayout")
        logLayout.Padding = UDim.new(0, 4)
        logLayout.SortOrder = Enum.SortOrder.LayoutOrder
        logLayout.Parent = scroll

        UI.refs.logScroll = scroll
        Log.attachUI(scroll)
        Log.onEntry = appendLogLabel

        makeLabel(body, "ไฟล์: " .. LOG_PATH, 10, Theme.muted, UDim2.new(1, 0, 0, 16))
    end

    -- Dock สำหรับตอนซ่อนเมนู ------------------------------------------------
    local dock = newInstance("Frame", {
        Name = "Dock",
        Size = UDim2.fromOffset(360, 48),
        Position = UDim2.new(0.5, 0, 0, 10),
        AnchorPoint = Vector2.new(0.5, 0),
        BackgroundColor3 = Theme.panel,
        BorderSizePixel = 0,
        Visible = false,
        Parent = screenGui,
    })
    addCorner(dock, 10)
    addStroke(dock, Theme.stroke, 1)
    UI.dock = dock

    local dockStop = makeButton(dock, "■", UDim2.fromOffset(36, 34), Theme.danger, function()
        App.emergencyStop()
    end, { textSize = 15 })
    dockStop.Position = UDim2.fromOffset(7, 7)

    newInstance("TextLabel", {
        Size = UDim2.fromOffset(200, 14),
        Position = UDim2.fromOffset(52, 5),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = APP_NAME,
        TextSize = 9,
        TextColor3 = Theme.muted,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        Parent = dock,
    })

    UI.dockStatus = newInstance("TextLabel", {
        Size = UDim2.fromOffset(210, 20),
        Position = UDim2.fromOffset(52, 20),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = "พร้อมใช้งาน",
        TextSize = 12,
        TextColor3 = Theme.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = dock,
    })

    local dockMenuButton = makeButton(dock, "เมนู", UDim2.fromOffset(66, 32), Theme.panel3, function()
        setMenuVisible(true)
    end, { textSize = 12 })
    dockMenuButton.Position = UDim2.new(1, -74, 0, 8)

    switchPage("macro")
    return true
end

-- ============================================================================
-- 12) รีเฟรช UI
-- ============================================================================

local AfkGuard = {
    lastNudge = nil,
    lastCheck = 0,
    lastResult = "",
}

local function updateProgress(index, total, loop, loopsDisplay)
    index = math.clamp(math.floor(numberOr(index, 0)), 0, math.max(0, total))
    total = math.max(0, math.floor(numberOr(total, 0)))
    loop = math.max(0, math.floor(numberOr(loop, 0)))
    loopsDisplay = loopsDisplay or (Settings.infinite and "∞" or formatNumber(Settings.loops))

    local percent = total > 0 and (index / total) or 0
    for _, fill in ipairs(UI.progressFills) do
        fill.Size = UDim2.new(percent, 0, 1, 0)
    end
    for _, label in ipairs(UI.progressTexts) do
        label.Text = string.format("%d / %d", index, total)
    end

    local stepText
    if State.finished then
        stepText = "เล่นจบแล้ว"
    elseif index <= 0 then
        stepText = "ยังไม่เริ่ม"
    else
        local event = Profiles.events[index]
        local label = event and eventLabel(event) or "—"
        stepText = string.format("ขั้นตอน %d/%d • %s", index, total, label)
    end

    for _, label in ipairs(UI.stepLabels) do
        label.Text = stepText
    end
    for _, label in ipairs(UI.loopLabels) do
        label.Text = string.format("รอบ %d/%s", loop, loopsDisplay)
    end

    if UI.refs.macroPlayInfo then
        if State.finished then
            UI.refs.macroPlayInfo.Text = string.format("เล่นจบแล้ว • %d/%d", index, total)
        elseif index > 0 then
            UI.refs.macroPlayInfo.Text = string.format("รอบ %d/%s • ขั้นตอน %d/%d", loop, loopsDisplay, index, total)
        elseif total > 0 then
            UI.refs.macroPlayInfo.Text = string.format("พร้อมเล่น • %d เหตุการณ์", total)
        else
            UI.refs.macroPlayInfo.Text = "ยังไม่มีข้อมูล — เริ่มบันทึกก่อน"
        end
    end

    if UI.refs.statusPageStep then
        UI.refs.statusPageStep.Text = stepText
        UI.refs.statusPageStep.TextColor3 = State.finished and Theme.success or Theme.text
    end
    if type(App.updateDockStatus) == "function" then
        pcall(App.updateDockStatus)
    end
end

function App.updateDockStatus()
    if not UI.dockStatus then
        return
    end
    local extras = {}
    if Settings.afkEnabled then
        table.insert(extras, "AFK เปิด")
    end
    local text = State.statusText
    if #extras > 0 then
        text = text .. " • " .. table.concat(extras, " • ")
    end
    UI.dockStatus.Text = text
end

function App.updateAfkUI()
    local enabled = Settings.afkEnabled
    if UI.refs.afkToggle then
        UI.refs.afkToggle.set(enabled, false)
    end

    local text = "ปิดอยู่"
    local color = Theme.muted
    if enabled then
        if not App.apiStatus.input then
            text = "เปิด • API อินพุตไม่พร้อม"
            color = Theme.danger
        elseif State.mode ~= "idle" then
            text = "เปิด • รอ Macro ว่าง"
            color = Theme.warning
        elseif AfkGuard.lastNudge then
            text = "เปิด • ขยับล่าสุด " .. os.date("%H:%M:%S", AfkGuard.lastNudge)
            color = Theme.success
        else
            text = "เปิด • รอรอบถัดไป"
            color = Theme.success
        end
    end

    if UI.refs.afkStatus then
        UI.refs.afkStatus.Text = text
        UI.refs.afkStatus.TextColor3 = color
    end
    if UI.refs.afkStopButton then
        setButtonEnabled(UI.refs.afkStopButton, enabled)
    end
    if UI.refs.statusPageAfk then
        UI.refs.statusPageAfk.Text = text
        UI.refs.statusPageAfk.TextColor3 = color
    end
    if type(App.updateDockStatus) == "function" then
        pcall(App.updateDockStatus)
    end
end

function App.refreshProfileSummary()
    local meta = selectedProfileMeta()
    local name = meta and meta.name or "ยังไม่มีโปรไฟล์"
    local count = meta and meta.count or 0
    local duration = meta and meta.duration or 0
    local metaText = string.format("%d เหตุการณ์ • %s", count, formatDuration(duration))

    if UI.refs.macroProfileName then
        UI.refs.macroProfileName.Text = name
    end
    if UI.refs.macroProfileMeta then
        UI.refs.macroProfileMeta.Text = metaText
    end
    if UI.refs.selectedProfileName then
        UI.refs.selectedProfileName.Text = name
    end
    if UI.refs.playbackProfileName then
        UI.refs.playbackProfileName.Text = name
    end
    if UI.refs.playbackEventCount then
        UI.refs.playbackEventCount.Text = tostring(count)
    end
    if UI.refs.playbackDuration then
        UI.refs.playbackDuration.Text = formatDuration(duration)
    end
    if UI.refs.statusPageProfile then
        UI.refs.statusPageProfile.Text = name
    end
    if UI.footerProfile then
        UI.footerProfile.Text = "โปรไฟล์: " .. name .. (State.dirty and " • ยังไม่บันทึก" or "")
    end
end

function App.refreshTransport()
    local mode = State.mode
    local total = #Profiles.events
    local loopsDisplay = Settings.infinite and "∞" or formatNumber(Settings.loops)

    local recordEnabled = mode ~= "playing" and mode ~= "paused"
    local recordText = "●  เริ่มบันทึก"
    if mode == "recording" then
        recordText = "■  หยุดบันทึก"
    elseif mode == "countdown" then
        recordText = "ยกเลิก"
    end
    for _, button in ipairs(UI.transport.record) do
        setButtonText(button, recordText)
        setButtonEnabled(button, recordEnabled)
    end

    local playText = "▶  เริ่มเล่น"
    if mode == "paused" then
        playText = "▶  เล่นต่อ"
    end
    local playEnabled = mode ~= "playing" and mode ~= "recording" and mode ~= "countdown"
    for _, button in ipairs(UI.transport.play) do
        setButtonText(button, playText)
        setButtonEnabled(button, playEnabled)
    end

    local pauseText = mode == "paused" and "▶  เล่นต่อ" or "⏸  พัก"
    for _, button in ipairs(UI.transport.pause) do
        setButtonText(button, pauseText)
        setButtonEnabled(button, mode == "playing" or mode == "paused")
    end
    for _, button in ipairs(UI.transport.stop) do
        setButtonEnabled(button, mode == "playing" or mode == "paused")
    end

    if UI.refs.playbackSummary then
        local loopText = Settings.infinite and "วนไม่จำกัด" or (formatNumber(Settings.loops) .. " รอบ")
        UI.refs.playbackSummary.Text = string.format("%s • พัก %s วิ • ความเร็ว %sx", loopText, formatNumber(Settings.loopDelay), formatNumber(Settings.speed))
    end

    local meta = selectedProfileMeta()
    local canSave = meta ~= nil and mode == "idle" and total > 0
    if UI.refs.saveNowButton then
        setButtonEnabled(UI.refs.saveNowButton, canSave)
    end
    if UI.refs.profileSaveButton then
        setButtonEnabled(UI.refs.profileSaveButton, canSave)
    end
    if UI.refs.profileDeleteButton then
        setButtonEnabled(UI.refs.profileDeleteButton, meta ~= nil and mode == "idle")
    end

    updateProgress(State.playbackIndex, total, State.loop, loopsDisplay)
end

function App.refreshProfiles()
    local scroll = UI.refs.profileList
    if not scroll then
        return
    end
    for _, child in ipairs(scroll:GetChildren()) do
        if child:IsA("GuiObject") then
            child:Destroy()
        end
    end

    if #Profiles.list == 0 then
        local empty = makeWrappedLabel(scroll, "ยังไม่มีโปรไฟล์ กดสร้างใหม่ หรือเริ่มบันทึกเพื่อสร้างโปรไฟล์อัตโนมัติ", 11, Theme.muted, 40)
        empty.TextXAlignment = Enum.TextXAlignment.Center
        empty.TextYAlignment = Enum.TextYAlignment.Center
        empty.Size = UDim2.new(1, -8, 0, 48)
        return
    end

    for _, item in ipairs(Profiles.list) do
        local selected = item.id == Profiles.selectedId
        local row = makeButton(scroll, "", UDim2.new(1, -4, 0, 54), selected and Theme.panel2 or Theme.panel, function()
            App.selectProfile(item.id)
        end, { textSize = 12 })
        if selected then
            addStroke(row, Theme.accent, 1)
        end

        local nameLabel = makeLabel(row, item.name, 13, selected and Theme.accent or Theme.text, UDim2.new(1, -86, 0, 20))
        nameLabel.Position = UDim2.fromOffset(10, 6)

        local metaLabel = makeLabel(row, string.format("%d เหตุการณ์ • %s", item.count or 0, formatDuration(item.duration or 0)), 10, Theme.muted, UDim2.new(1, -86, 0, 16))
        metaLabel.Position = UDim2.fromOffset(10, 27)

        local stateLabel = makeLabel(row, selected and "ใช้งาน" or "เลือก", 10, selected and Theme.accent or Theme.muted, UDim2.fromOffset(64, 54), Enum.TextXAlignment.Right)
        stateLabel.Position = UDim2.new(1, -72, 0, 0)
    end

    App.refreshProfileSummary()
    App.refreshTransport()
end

function App.refreshSettingsUI()
    if UI.refs.loopsInput then
        UI.refs.loopsInput.set(Settings.loops)
    end
    if UI.refs.delayInput then
        UI.refs.delayInput.set(Settings.loopDelay)
    end
    if UI.refs.speedInput then
        UI.refs.speedInput.set(Settings.speed)
    end
    if UI.refs.offsetXInput then
        UI.refs.offsetXInput.set(Settings.offsetX)
    end
    if UI.refs.offsetYInput then
        UI.refs.offsetYInput.set(Settings.offsetY)
    end
    if UI.refs.afkInterval then
        UI.refs.afkInterval.set(Settings.afkInterval)
    end
    if UI.refs.guardFocusToggle then
        UI.refs.guardFocusToggle.set(Settings.guardFocus, false)
    end
    if UI.refs.autosaveToggle then
        UI.refs.autosaveToggle.set(Settings.autosave, false)
    end
    if UI.refs.autoHideToggle then
        UI.refs.autoHideToggle.set(Settings.autoHide, false)
    end
    if UI.refs.infiniteToggle then
        UI.refs.infiniteToggle.set(Settings.infinite, false)
    end

    if UI.refs.infoExecutor then
        local versionText = App.executorVersion ~= "" and (" " .. App.executorVersion) or ""
        UI.refs.infoExecutor.Text = App.executorName .. versionText
    end
    if UI.refs.infoInput then
        UI.refs.infoInput.Text = App.apiStatus.input and "พร้อม" or "ไม่ครบ"
        UI.refs.infoInput.TextColor3 = App.apiStatus.input and Theme.success or Theme.danger
    end
    if UI.refs.infoFiles then
        UI.refs.infoFiles.Text = App.apiStatus.files and "พร้อม" or "จำกัด"
        UI.refs.infoFiles.TextColor3 = App.apiStatus.files and Theme.success or Theme.warning
    end
    if UI.refs.infoClipboard then
        UI.refs.infoClipboard.Text = App.apiStatus.clipboard and "พร้อม" or "ไม่มี"
        UI.refs.infoClipboard.TextColor3 = App.apiStatus.clipboard and Theme.success or Theme.warning
    end
    if UI.refs.infoGui then
        UI.refs.infoGui.Text = App.apiStatus.gui
    end

    App.updateAfkUI()
end

-- ============================================================================
-- 13) ตัวช่วยบันทึกและปล่อยอินพุต
-- ============================================================================

local function releaseHeld()
    for vk in pairs(State.heldKeys) do
        pcall(keyrelease, vk)
    end
    State.heldKeys = {}

    if State.heldMouse.Left then
        pcall(mouse1release)
    end
    if State.heldMouse.Right then
        pcall(mouse2release)
    end
    State.heldMouse = {}
end

local function pointInGui(position)
    if not position then
        return false
    end
    local frames = { UI.main, UI.dock }
    for _, frame in ipairs(frames) do
        if frame and frame.Visible then
            local origin = frame.AbsolutePosition
            local size = frame.AbsoluteSize
            if position.X >= origin.X - 2 and position.X <= origin.X + size.X + 2
                and position.Y >= origin.Y - 2 and position.Y <= origin.Y + size.Y + 2 then
                return true
            end
        end
    end
    return false
end

local function roundedPosition(position)
    return math.floor(position.X + 0.5), math.floor(position.Y + 0.5)
end

local function closeRecordingInputs(events, endTime)
    if type(events) ~= "table" then
        return
    end

    local position = getMousePosition()
    local x, y = 0, 0
    if position then
        x, y = roundedPosition(position)
    end

    local appended = false
    for button in pairs(State.recordingMouse) do
        table.insert(events, {
            t = endTime,
            type = "mouseUp",
            button = button,
            x = x,
            y = y,
        })
        appended = true
    end
    for keyName, held in pairs(State.recordingKeys) do
        table.insert(events, {
            t = endTime,
            type = "keyUp",
            key = keyName,
            vk = held and held.vk or VK_BY_NAME[keyName],
        })
        appended = true
    end

    if appended then
        table.sort(events, function(a, b)
            return a.t < b.t
        end)
    end

    State.recordingMouse = {}
    State.recordingKeys = {}
end

local function warnUnsupportedKey(keyName)
    if App.warnedKeys[keyName] then
        return
    end
    App.warnedKeys[keyName] = true
    Log.add("warn", "ไม่รองรับปุ่ม " .. tostring(keyName) .. " — ปุ่มนี้จะไม่ถูกบันทึก")
end

local function updateRecordInfo()
    if not UI.refs.recordInfo then
        return
    end
    if State.mode == "recording" then
        local elapsed = clock() - State.recordStart
        UI.refs.recordInfo.Text = string.format("เวลา %s • %d เหตุการณ์", formatDuration(elapsed), #State.events)
    elseif State.mode == "countdown" then
        UI.refs.recordInfo.Text = "กำลังเตรียมบันทึก..."
    else
        local meta = selectedProfileMeta()
        local count = meta and meta.count or 0
        local duration = meta and meta.duration or 0
        UI.refs.recordInfo.Text = string.format("%d เหตุการณ์ • %s", count, formatDuration(duration))
    end
end

local function updateMetaFromEvents(meta, events)
    if not meta then
        return
    end
    meta.count = #events
    meta.duration = #events > 0 and events[#events].t or 0
    meta.modified = os.time()
end

local function ensureProfileForRecording()
    local meta = selectedProfileMeta()
    if meta then
        return meta
    end

    meta = {
        id = newProfileId(),
        name = uniqueProfileName("โปรไฟล์ 1"),
        created = os.time(),
        modified = os.time(),
        duration = 0,
        count = 0,
    }
    addProfileMeta(meta)
    Profiles.selectedId = meta.id
    Profiles.events = {}
    saveProfileToDisk(meta, {})
    saveIndex()
    App.refreshProfiles()
    Log.add("info", "สร้างโปรไฟล์อัตโนมัติ: " .. meta.name)
    return meta
end

local function addRecordedEvent(event)
    if State.mode ~= "recording" then
        return
    end
    if #State.events >= MAX_EVENTS then
        Log.add("warn", string.format("ถึงขีดจำกัด %d เหตุการณ์ — หยุดบันทึกอัตโนมัติ", MAX_EVENTS))
        App.stopRecording()
        return
    end
    event.t = math.max(0, clock() - State.recordStart)
    table.insert(State.events, event)
end

local function startRecordingNow()
    State.token += 1
    local token = State.token
    State.mode = "countdown"
    State.events = {}
    State.recordStart = 0
    State.lastMoveSample = 0
    State.lastRecordedMove = nil
    State.recordingMouse = {}
    State.recordingKeys = {}
    State.playbackIndex = 0
    State.loop = 0
    State.finished = false
    State.paused = false
    setStatus("เตรียมบันทึก 3...", "warn")
    App.refreshTransport()
    updateRecordInfo()

    local meta = selectedProfileMeta()
    Log.add("info", "เตรียมบันทึกโปรไฟล์: " .. (meta and meta.name or "ไม่มีชื่อ"))

    task.spawn(function()
        for index = 3, 1, -1 do
            if token ~= State.token or State.mode ~= "countdown" then
                return
            end
            setStatus("เริ่มบันทึกใน " .. tostring(index) .. " วินาที", "warn")
            task.wait(1)
        end
        if token ~= State.token or State.mode ~= "countdown" then
            return
        end

        State.mode = "recording"
        State.recordStart = clock()
        State.lastMoveSample = 0
        State.lastRecordedMove = nil
        setStatus("กำลังบันทึก", "recording")
        App.refreshTransport()
        Log.add("info", "เริ่มบันทึกอินพุตแล้ว")

        local position = getMousePosition()
        if position and not pointInGui(position) then
            local x, y = roundedPosition(position)
            State.lastRecordedMove = position
            addRecordedEvent({ type = "mouseMove", x = x, y = y })
        end
        updateRecordInfo()
    end)
end

function App.requestStartRecording()
    if State.mode == "playing" or State.mode == "paused" then
        Log.add("warn", "หยุดการเล่นก่อนเริ่มบันทึก")
        return
    end
    if State.mode == "recording" or State.mode == "countdown" then
        App.stopRecording()
        return
    end

    ensureProfileForRecording()
    local meta = selectedProfileMeta()
    if meta and #Profiles.events > 0 then
        showConfirm(
            "บันทึกทับโปรไฟล์?",
            string.format("การบันทึกใหม่จะแทนที่ %d เหตุการณ์ในโปรไฟล์ \"%s\"", #Profiles.events, meta.name),
            "บันทึกทับ",
            function()
                startRecordingNow()
            end,
            true
        )
        return
    end
    startRecordingNow()
end

function App.saveCurrentProfile(silent)
    local meta = selectedProfileMeta()
    if not meta then
        Log.add("warn", "ยังไม่ได้เลือกโปรไฟล์")
        return false
    end
    if State.mode ~= "idle" then
        Log.add("warn", "หยุดงานที่กำลังทำก่อนบันทึกโปรไฟล์")
        return false
    end
    if #Profiles.events == 0 then
        Log.add("warn", "ยังไม่มีเหตุการณ์ให้บันทึก")
        return false
    end

    local ok, err = saveProfileToDisk(meta, Profiles.events)
    if not ok then
        Log.add("error", "บันทึกไฟล์โปรไฟล์ไม่สำเร็จ: " .. tostring(err))
        return false
    end
    State.dirty = false
    saveIndex()
    if not silent then
        Log.add("success", string.format("บันทึกโปรไฟล์ \"%s\" แล้ว (%d เหตุการณ์)", meta.name, #Profiles.events))
    end
    App.refreshProfiles()
    App.refreshProfileSummary()
    return true
end

function App.stopRecording()
    if State.mode == "countdown" then
        State.token += 1
        State.mode = "idle"
        State.events = {}
        State.playbackIndex = 0
        State.loop = 0
        setStatus("ยกเลิกการบันทึก", "warn")
        Log.add("info", "ยกเลิกการบันทึก")
        App.refreshTransport()
        updateRecordInfo()
        return
    end

    if State.mode ~= "recording" then
        return
    end

    local events = State.events
    local endTime = math.max(0, clock() - State.recordStart)
    closeRecordingInputs(events, endTime)
    State.token += 1
    State.mode = "idle"
    State.events = {}
    State.playbackIndex = 0
    State.loop = 0
    State.finished = false

    if #events == 0 then
        setStatus("ไม่ได้บันทึกเหตุการณ์", "warn")
        Log.add("warn", "หยุดบันทึกแต่ไม่มีเหตุการณ์ใดถูกบันทึก")
        App.refreshTransport()
        updateRecordInfo()
        return
    end

    local meta = selectedProfileMeta()
    Profiles.events = events
    updateMetaFromEvents(meta, events)

    local saved = false
    if Settings.autosave then
        saved = App.saveCurrentProfile(true)
    else
        Log.add("info", "ยังไม่เขียนไฟล์ (ปิดบันทึกอัตโนมัติ) — กดบันทึกตอนนี้เมื่อพร้อม")
    end
    State.dirty = not saved

    if saved then
        setStatus("บันทึกเสร็จสิ้น", "ready")
        Log.add("success", string.format("บันทึกเสร็จ: %d เหตุการณ์ • %s", #events, formatDuration(events[#events].t)))
    else
        setStatus("บันทึกไว้ในหน่วยความจำ", "warn")
        Log.add("warn", string.format("เก็บ %d เหตุการณ์ไว้ในหน่วยความจำ ยังไม่ได้เขียนไฟล์", #events))
    end

    App.refreshProfiles()
    updateRecordInfo()
end

function App.emergencyStop()
    local previousMode = State.mode
    local hadAfk = Settings.afkEnabled
    State.token += 1
    State.dragging = false
    closeModal()

    local recordedEvents = State.events
    if previousMode == "recording" then
        closeRecordingInputs(recordedEvents, math.max(0, clock() - State.recordStart))
    end

    State.mode = "idle"
    State.paused = false
    State.blocked = false
    State.events = {}
    State.recordingMouse = {}
    State.recordingKeys = {}
    State.playbackIndex = 0
    State.loop = 0
    State.finished = false
    releaseHeld()

    if previousMode == "recording" and #recordedEvents > 0 then
        Profiles.events = recordedEvents
        local meta = selectedProfileMeta()
        updateMetaFromEvents(meta, recordedEvents)
        State.dirty = true
        if Settings.autosave then
            App.saveCurrentProfile(true)
        end
    end

    if hadAfk then
        Settings.afkEnabled = false
        saveSettings()
    end

    if State.autoHidden then
        State.autoHidden = false
        setMenuVisible(true)
    end

    local hadWork = previousMode ~= "idle" or hadAfk
    setStatus(hadWork and "หยุดฉุกเฉินแล้ว" or "พร้อมใช้งาน", hadWork and "warn" or "ready")
    Log.add("warn", "หยุดฉุกเฉิน: หยุด Macro และปิดระบบกัน AFK")
    App.refreshProfiles()
    App.updateAfkUI()
    updateRecordInfo()
end

-- ============================================================================
-- 14) รับอินพุตเพื่อบันทึก และลากหน้าต่าง
-- ============================================================================

local Running = true
local Connections = {}

local function connectTracked(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(Connections, connection)
    return connection
end

local function connectInputHandlers()
    connectTracked(UserInputService.InputBegan, function(input)
        if input.KeyCode == Enum.KeyCode.F8 then
            App.emergencyStop()
            return
        end
        if input.KeyCode == Enum.KeyCode.F7 then
            toggleMenu()
            return
        end

        if State.mode ~= "recording" then
            return
        end
        local focusedTextBox = UserInputService:GetFocusedTextBox()

        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.MouseButton2 then
            local button = input.UserInputType == Enum.UserInputType.MouseButton1 and "Left" or "Right"
            local position = getMousePosition()
            if not position or pointInGui(position) then
                return
            end
            if not State.recordingMouse[button] then
                State.recordingMouse[button] = true
                local x, y = roundedPosition(position)
                addRecordedEvent({ type = "mouseDown", button = button, x = x, y = y })
            end
        elseif input.UserInputType == Enum.UserInputType.Keyboard then
            if focusedTextBox then
                return
            end
            local keyCode = input.KeyCode
            if keyCode and keyCode ~= Enum.KeyCode.Unknown then
                local keyName = keyCode.Name
                local vk = VK_BY_NAME[keyName]
                if vk then
                    if not State.recordingKeys[keyName] then
                        State.recordingKeys[keyName] = { vk = vk }
                        addRecordedEvent({ type = "keyDown", key = keyName, vk = vk })
                    end
                else
                    warnUnsupportedKey(keyName)
                end
            end
        end
        updateRecordInfo()
    end)

    connectTracked(UserInputService.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            State.dragging = false
        end

        if State.mode ~= "recording" then
            return
        end
        local focusedTextBox = UserInputService:GetFocusedTextBox()

        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.MouseButton2 then
            local button = input.UserInputType == Enum.UserInputType.MouseButton1 and "Left" or "Right"
            if State.recordingMouse[button] then
                State.recordingMouse[button] = nil
                local position = getMousePosition()
                if position then
                    local x, y = roundedPosition(position)
                    addRecordedEvent({ type = "mouseUp", button = button, x = x, y = y })
                end
            end
        elseif input.UserInputType == Enum.UserInputType.Keyboard then
            if focusedTextBox then
                return
            end
            local keyCode = input.KeyCode
            if keyCode and keyCode ~= Enum.KeyCode.Unknown then
                local keyName = keyCode.Name
                local held = State.recordingKeys[keyName]
                if held then
                    State.recordingKeys[keyName] = nil
                    addRecordedEvent({ type = "keyUp", key = keyName, vk = held.vk or VK_BY_NAME[keyName] })
                end
            end
        end
        updateRecordInfo()
    end)

    connectTracked(UserInputService.InputChanged, function(input)
        if State.dragging and input.UserInputType == Enum.UserInputType.MouseMovement and UI.main then
            if not State.dragStart or not State.dragOrigin then
                return
            end
            local delta = input.Position - State.dragStart
            local viewport = getViewport()
            local size = UI.main.AbsoluteSize
            local newX = State.dragOrigin.X.Offset + delta.X
            local newY = State.dragOrigin.Y.Offset + delta.Y
            newX = clampSafe(newX, 120 - size.X, viewport.X - 120)
            newY = clampSafe(newY, 0, math.max(0, viewport.Y - 60))
            UI.main.Position = UDim2.fromOffset(math.floor(newX), math.floor(newY))
        end

        if State.mode == "recording" and input.UserInputType == Enum.UserInputType.MouseWheel then
            if UserInputService:GetFocusedTextBox() then
                return
            end
            local position = getMousePosition()
            if position and pointInGui(position) then
                return
            end
            local amount = input.Position.Z
            if amount and amount ~= 0 then
                addRecordedEvent({ type = "wheel", z = amount })
            end
        end
    end)

    local lastInfoUpdate = 0
    connectTracked(RunService.Heartbeat, function()
        if State.mode ~= "recording" then
            if State.mode == "countdown" then
                local now = clock()
                if now - lastInfoUpdate >= 0.2 then
                    lastInfoUpdate = now
                    updateRecordInfo()
                end
            end
            return
        end

        local now = clock()
        if now - State.lastMoveSample >= 0.033 then
            State.lastMoveSample = now
            local position = getMousePosition()
            if position then
                local mouseHeld = next(State.recordingMouse) ~= nil
                if mouseHeld or not pointInGui(position) then
                    local last = State.lastRecordedMove
                    if not last or (position - last).Magnitude >= 2 then
                        local x, y = roundedPosition(position)
                        State.lastRecordedMove = position
                        addRecordedEvent({ type = "mouseMove", x = x, y = y })
                    end
                end
            end
        end
        if now - lastInfoUpdate >= 0.2 then
            lastInfoUpdate = now
            updateRecordInfo()
        end
    end)
end

-- ============================================================================
-- 15) เล่นซ้ำ
-- ============================================================================

local function waitUntilClear(token)
    local wasBlocked = false
    while true do
        if token ~= State.token then
            return false
        end

        local blocked = State.mode == "paused"
            or (Settings.guardFocus and not isGameActive())

        if blocked then
            if not wasBlocked then
                wasBlocked = true
                State.blocked = true
                releaseHeld()
                if State.mode == "paused" then
                    setStatus("พักอยู่", "paused")
                    Log.add("info", "พักการเล่นที่ขั้นตอน " .. tostring(State.playbackIndex))
                else
                    setStatus("พัก: เกมไม่ active", "paused")
                    Log.add("info", "พักการเล่น: หน้าต่างเกมไม่ active")
                end
            end
            task.wait(0.1)
        else
            if wasBlocked then
                State.blocked = false
                setStatus("กำลังเล่น", "playing")
                Log.add("info", "เล่นต่อ")
                App.refreshTransport()
            end
            return true
        end
    end
end

local function waitTimeline(token, timeline, target)
    while true do
        if token ~= State.token then
            return false
        end

        local now = clock()
        local blocked = State.mode == "paused"
            or (Settings.guardFocus and not isGameActive())

        if blocked then
            local pauseStart = now
            if not waitUntilClear(token) then
                return false
            end
            local pausedFor = clock() - pauseStart
            timeline.shift += pausedFor
            target = clock() + math.max(0, target - pauseStart)
        elseif now < target then
            task.wait(math.min(target - now, 0.03))
        else
            return true
        end
    end
end

local function applyEvent(event, index, total)
    local ok, err = pcall(function()
        if event.type == "mouseMove" then
            local x = math.floor(numberOr(event.x, 0) + Settings.offsetX + 0.5)
            local y = math.floor(numberOr(event.y, 0) + Settings.offsetY + 0.5)
            mousemoveabs(math.max(0, x), math.max(0, y))
        elseif event.type == "mouseDown" then
            local x = math.floor(numberOr(event.x, 0) + Settings.offsetX + 0.5)
            local y = math.floor(numberOr(event.y, 0) + Settings.offsetY + 0.5)
            mousemoveabs(math.max(0, x), math.max(0, y))
            if event.button == "Right" then
                if not State.heldMouse.Right then
                    mouse2press()
                    State.heldMouse.Right = true
                end
            else
                if not State.heldMouse.Left then
                    mouse1press()
                    State.heldMouse.Left = true
                end
            end
        elseif event.type == "mouseUp" then
            local x = math.floor(numberOr(event.x, 0) + Settings.offsetX + 0.5)
            local y = math.floor(numberOr(event.y, 0) + Settings.offsetY + 0.5)
            mousemoveabs(math.max(0, x), math.max(0, y))
            if event.button == "Right" then
                if State.heldMouse.Right then
                    mouse2release()
                    State.heldMouse.Right = nil
                end
            else
                if State.heldMouse.Left then
                    mouse1release()
                    State.heldMouse.Left = nil
                end
            end
        elseif event.type == "keyDown" then
            local vk = numberOr(event.vk, VK_BY_NAME[event.key])
            if not vk then
                error("ไม่พบรหัสปุ่ม " .. tostring(event.key))
            end
            if not State.heldKeys[vk] then
                keypress(vk)
                State.heldKeys[vk] = true
            end
        elseif event.type == "keyUp" then
            local vk = numberOr(event.vk, VK_BY_NAME[event.key])
            if not vk then
                error("ไม่พบรหัสปุ่ม " .. tostring(event.key))
            end
            if State.heldKeys[vk] then
                keyrelease(vk)
                State.heldKeys[vk] = nil
            end
        elseif event.type == "wheel" then
            mousescroll(numberOr(event.z, 0))
        else
            error("ชนิดเหตุการณ์ไม่รองรับ: " .. tostring(event.type))
        end
    end)

    if not ok then
        return false, tostring(err)
    end
    return true
end

local function failPlayback(token, index, total, event, err)
    if token ~= State.token then
        return
    end
    State.token += 1
    State.mode = "idle"
    State.paused = false
    State.blocked = false
    State.finished = false
    releaseHeld()
    setStatus("เกิดข้อผิดพลาด", "error")
    Log.add("error", string.format(
        "ขั้นตอน %d/%d (%s) ล้มเหลว: %s",
        index,
        total,
        eventLabel(event),
        tostring(err)
    ))
    if State.autoHidden then
        State.autoHidden = false
        setMenuVisible(true)
    end
    updateProgress(index, total, State.loop, Settings.infinite and "∞" or formatNumber(Settings.loops))
    App.refreshTransport()
end

local function runPlayback(token, events, loops, loopsDisplay, speed)
    local total = #events
    local loop = 1
    local lastProgressUpdate = 0

    while true do
        if token ~= State.token then
            return
        end

        State.loop = loop
        local timeline = { base = clock(), shift = 0 }

        for index = 1, total do
            if token ~= State.token then
                return
            end

            local event = events[index]
            local target = timeline.base + (event.t / speed) + timeline.shift
            if not waitTimeline(token, timeline, target) then
                return
            end
            if token ~= State.token then
                return
            end

            State.playbackIndex = index
            local ok, err = applyEvent(event, index, total)
            if not ok then
                failPlayback(token, index, total, event, err)
                return
            end

            local now = clock()
            if index == total or now - lastProgressUpdate >= 0.08 then
                lastProgressUpdate = now
                updateProgress(index, total, loop, loopsDisplay)
            end
        end

        releaseHeld()
        if loops ~= math.huge and loop >= loops then
            break
        end
        if token ~= State.token then
            return
        end

        local delayTimeline = { base = clock(), shift = 0 }
        if not waitTimeline(token, delayTimeline, delayTimeline.base + Settings.loopDelay) then
            return
        end
        loop += 1
    end

    if token ~= State.token then
        return
    end

    State.mode = "idle"
    State.paused = false
    State.blocked = false
    State.finished = true
    State.playbackIndex = total
    State.loop = loop
    setStatus("เล่นจบแล้ว", "ready")
    Log.add("success", string.format(
        "เล่นจบ: %s • %d เหตุการณ์ • %s",
        loops == math.huge and "ไม่จำกัด" or (tostring(loop) .. " รอบ"),
        total,
        formatDuration(events[total].t)
    ))
    updateProgress(total, total, loop, loopsDisplay)
    if State.autoHidden then
        State.autoHidden = false
        setMenuVisible(true)
    end
    App.refreshTransport()
end

function App.startPlayback()
    if State.mode == "recording" or State.mode == "countdown" then
        Log.add("warn", "หยุดบันทึกก่อนเริ่มเล่น")
        return
    end
    if State.mode == "playing" then
        return
    end
    if State.mode == "paused" then
        App.togglePause()
        return
    end

    local events = Profiles.events
    if #events == 0 then
        setStatus("ไม่มีข้อมูลให้เล่น", "warn")
        Log.add("warn", "ยังไม่มีเหตุการณ์ในโปรไฟล์นี้ — เริ่มบันทึกก่อน")
        return
    end
    if not App.apiStatus.input then
        setStatus("API อินพุตไม่พร้อม", "error")
        Log.add("error", "ไม่สามารถเล่นได้: API อินพุตของ executor ไม่ครบ")
        return
    end

    State.token += 1
    local token = State.token
    State.mode = "playing"
    State.paused = false
    State.blocked = false
    State.finished = false
    State.playbackIndex = 0
    State.loop = 1
    State.autoHidden = false

    local loops = Settings.infinite and math.huge or math.max(1, math.floor(Settings.loops))
    local loopsDisplay = Settings.infinite and "∞" or tostring(loops)
    local speed = math.max(0.1, Settings.speed)

    if Settings.autoHide and State.menuVisible then
        setMenuVisible(false)
        State.autoHidden = true
    end

    setStatus("กำลังเล่น", "playing")
    Log.add("info", string.format(
        "เริ่มเล่น: %d เหตุการณ์ • %s • ความเร็ว %sx",
        #events,
        Settings.infinite and "วนไม่จำกัด" or (tostring(loops) .. " รอบ"),
        formatNumber(speed)
    ))
    updateProgress(0, #events, 1, loopsDisplay)
    App.refreshTransport()

    task.spawn(function()
        local ok, err = pcall(runPlayback, token, events, loops, loopsDisplay, speed)
        if not ok and token == State.token then
            State.token += 1
            State.mode = "idle"
            State.paused = false
            State.blocked = false
            releaseHeld()
            setStatus("เกิดข้อผิดพลาด", "error")
            Log.add("error", "การเล่นหยุดผิดปกติ: " .. tostring(err))
            App.refreshTransport()
        end
    end)
end

function App.togglePause()
    if State.mode == "playing" then
        State.mode = "paused"
        State.paused = true
        releaseHeld()
        setStatus("พักอยู่", "paused")
        Log.add("info", "พักการเล่นที่ขั้นตอน " .. tostring(State.playbackIndex))
        App.refreshTransport()
    elseif State.mode == "paused" then
        State.mode = "playing"
        State.paused = false
        setStatus("กำลังเล่น", "playing")
        Log.add("info", "เล่นต่อจากขั้นตอน " .. tostring(State.playbackIndex))
        App.refreshTransport()
    end
end

function App.playOrResume()
    if State.mode == "paused" then
        App.togglePause()
    else
        App.startPlayback()
    end
end

function App.stopPlayback()
    if State.mode ~= "playing" and State.mode ~= "paused" then
        return
    end

    local stoppedAt = State.playbackIndex
    local total = #Profiles.events
    State.token += 1
    State.mode = "idle"
    State.paused = false
    State.blocked = false
    State.playbackIndex = 0
    State.loop = 0
    State.finished = false
    releaseHeld()

    if State.autoHidden then
        State.autoHidden = false
        setMenuVisible(true)
    end

    setStatus("หยุดการเล่นแล้ว", "warn")
    Log.add("info", string.format("หยุดการเล่นที่ขั้นตอน %d/%d", stoppedAt, total))
    App.refreshTransport()
end

-- ============================================================================
-- 16) จัดการโปรไฟล์
-- ============================================================================

function App.selectProfile(id, silent, force)
    if State.mode ~= "idle" then
        Log.add("warn", "หยุดงานที่กำลังทำก่อนเปลี่ยนโปรไฟล์")
        return false
    end
    if id == Profiles.selectedId and not force then
        return true
    end
    if State.dirty and not force then
        showConfirm(
            "ยังไม่ได้บันทึกโปรไฟล์?",
            "เหตุการณ์ล่าสุดยังไม่ได้เขียนลงไฟล์ หากเปลี่ยนโปรไฟล์ตอนนี้ข้อมูลในหน่วยความจำจะหาย",
            "เปลี่ยนโปรไฟล์",
            function()
                State.dirty = false
                App.selectProfile(id, silent, true)
            end,
            true
        )
        return false
    end
    local meta = findProfileMeta(id)
    if not meta then
        Log.add("warn", "ไม่พบโปรไฟล์ที่เลือก")
        return false
    end

    local data, err = readProfileFromDisk(id)
    if data then
        Profiles.events = data.events or {}
        meta.name = data.name or meta.name
        meta.duration = data.duration or 0
        meta.count = data.count or #Profiles.events
        meta.modified = data.modified or meta.modified
        meta.created = data.created or meta.created
    else
        Profiles.events = {}
        Log.add("warn", "อ่านโปรไฟล์ไม่สำเร็จ: " .. tostring(err))
    end

    Profiles.selectedId = id
    State.playbackIndex = 0
    State.loop = 0
    State.finished = false
    State.dirty = false
    saveIndex()
    App.refreshProfiles()
    updateRecordInfo()
    if not silent then
        Log.add("info", "เลือกโปรไฟล์: " .. meta.name)
    end
    return true
end

function App.promptCreateProfile(force)
    if State.mode ~= "idle" then
        Log.add("warn", "หยุดงานที่กำลังทำก่อนสร้างโปรไฟล์")
        return
    end
    if State.dirty and not force then
        showConfirm(
            "ยังไม่ได้บันทึกโปรไฟล์?",
            "เหตุการณ์ล่าสุดยังไม่ได้เขียนลงไฟล์ การสร้างโปรไฟล์ใหม่จะทำให้ข้อมูลในหน่วยความจำหาย",
            "ดำเนินการต่อ",
            function()
                App.promptCreateProfile(true)
            end,
            true
        )
        return
    end

    showPrompt(
        "สร้างโปรไฟล์ใหม่",
        "ตั้งชื่อโปรไฟล์ (สูงสุด 40 ตัวอักษร)",
        "โปรไฟล์ " .. tostring(#Profiles.list + 1),
        "สร้าง",
        function(name)
            name = uniqueProfileName(name)
            local meta = {
                id = newProfileId(),
                name = name,
                created = os.time(),
                modified = os.time(),
                duration = 0,
                count = 0,
            }
            addProfileMeta(meta)
            Profiles.selectedId = meta.id
            Profiles.events = {}
            State.playbackIndex = 0
            State.loop = 0
            State.finished = false
            State.dirty = false
            local ok, err = saveProfileToDisk(meta, {})
            if not ok then
                State.dirty = true
                Log.add("warn", "สร้างโปรไฟล์ในหน่วยความจำ แต่เขียนไฟล์ไม่ได้: " .. tostring(err))
            else
                State.dirty = false
            end
            saveIndex()
            App.refreshProfiles()
            App.refreshProfileSummary()
            Log.add("success", "สร้างโปรไฟล์: " .. name)
        end
    )
end

function App.promptRenameProfile()
    if State.mode ~= "idle" then
        Log.add("warn", "หยุดงานที่กำลังทำก่อนเปลี่ยนชื่อ")
        return
    end
    local meta = selectedProfileMeta()
    if not meta then
        Log.add("warn", "ยังไม่ได้เลือกโปรไฟล์")
        return
    end

    showPrompt(
        "เปลี่ยนชื่อโปรไฟล์",
        "ตั้งชื่อใหม่ (สูงสุด 40 ตัวอักษร)",
        meta.name,
        "บันทึกชื่อ",
        function(name)
            name = uniqueProfileName(name, meta.id)
            meta.name = name
            local ok, err = saveProfileToDisk(meta, Profiles.events)
            if not ok then
                State.dirty = true
                Log.add("warn", "เปลี่ยนชื่อในหน่วยความจำ แต่เขียนไฟล์ไม่ได้: " .. tostring(err))
            else
                State.dirty = false
            end
            saveIndex()
            App.refreshProfiles()
            App.refreshProfileSummary()
            Log.add("success", "เปลี่ยนชื่อโปรไฟล์เป็น: " .. name)
        end
    )
end

function App.promptDeleteProfile()
    if State.mode ~= "idle" then
        Log.add("warn", "หยุดงานที่กำลังทำก่อนลบโปรไฟล์")
        return
    end
    local meta = selectedProfileMeta()
    if not meta then
        Log.add("warn", "ยังไม่ได้เลือกโปรไฟล์")
        return
    end

    showConfirm(
        "ลบโปรไฟล์?",
        string.format("ลบโปรไฟล์ \"%s\" พร้อมเหตุการณ์ %d รายการ? การลบย้อนกลับไม่ได้", meta.name, #Profiles.events),
        "ลบโปรไฟล์",
        function()
            if FileTools.ready and fileExists(profilePath(meta.id)) then
                local ok, err = deleteFile(profilePath(meta.id))
                if not ok then
                    Log.add("error", "ลบไฟล์โปรไฟล์ไม่สำเร็จ: " .. tostring(err))
                    return
                end
            end

            local removedId = meta.id
            for index, item in ipairs(Profiles.list) do
                if item.id == removedId then
                    table.remove(Profiles.list, index)
                    break
                end
            end

            if Profiles.selectedId == removedId then
                Profiles.events = {}
                Profiles.selectedId = Profiles.list[1] and Profiles.list[1].id or nil
                if Profiles.selectedId then
                    local nextMeta = selectedProfileMeta()
                    if nextMeta then
                        local data = readProfileFromDisk(nextMeta.id)
                        Profiles.events = data and data.events or {}
                        if data then
                            nextMeta.count = data.count
                            nextMeta.duration = data.duration
                        end
                    end
                end
                State.playbackIndex = 0
                State.loop = 0
                State.finished = false
                State.dirty = false
            end
            saveIndex()
            App.refreshProfiles()
            updateRecordInfo()
            Log.add("success", "ลบโปรไฟล์: " .. meta.name)
        end,
        true
    )
end

function App.exportCurrentProfile()
    if State.mode ~= "idle" then
        Log.add("warn", "หยุดงานที่กำลังทำก่อนส่งออก")
        return
    end
    local meta = selectedProfileMeta()
    if not meta then
        Log.add("warn", "ยังไม่ได้เลือกโปรไฟล์")
        return
    end
    if #Profiles.events == 0 then
        Log.add("warn", "โปรไฟล์นี้ยังไม่มีเหตุการณ์ให้ส่งออก")
        return
    end

    local json, err = encodeJson(profileData(meta, Profiles.events))
    if not json then
        Log.add("error", "สร้าง JSON สำหรับส่งออกไม่สำเร็จ: " .. tostring(err))
        return
    end

    local clipboardOk = false
    if type(setclipboard) == "function" then
        local ok = pcall(setclipboard, json)
        clipboardOk = ok
    end

    local fileOk = false
    local fileErr = nil
    if FileTools.ready then
        fileOk, fileErr = writeTextFile(EXPORT_DIR .. "/" .. meta.id .. ".json", json)
    end

    local parts = {}
    table.insert(parts, clipboardOk and "คัดลอกไปยังคลิปบอร์ดแล้ว" or "คัดลอกคลิปบอร์ดไม่ได้")
    if fileOk then
        table.insert(parts, "บันทึกไฟล์ " .. EXPORT_DIR .. "/" .. meta.id .. ".json แล้ว")
    elseif fileErr then
        table.insert(parts, "เขียนไฟล์ส่งออกไม่ได้: " .. tostring(fileErr))
    end
    local subtitle = table.concat(parts, " • ")

    Log.add("info", "ส่งออกโปรไฟล์: " .. meta.name .. " — " .. subtitle)
    showExportDialog(json, subtitle)
end

function App.importProfileText(text)
    if State.mode ~= "idle" then
        return false, "หยุดงานที่กำลังทำก่อนนำเข้า"
    end
    text = trimText(text)
    if text == "" then
        return false, "ยังไม่มีข้อความ JSON"
    end

    local data, decodeError = decodeJson(text)
    if not data then
        return false, "JSON ไม่ถูกต้อง: " .. tostring(decodeError)
    end

    local rawEvents = nil
    local rawName = nil
    if type(data.events) == "table" then
        rawEvents = data.events
        rawName = data.name
    elseif #data > 0 then
        rawEvents = data
        rawName = "นำเข้า"
    end
    if not rawEvents then
        return false, "ไม่พบเหตุการณ์ใน JSON"
    end

    local events, err = validateEvents(rawEvents, true)
    if not events then
        return false, tostring(err)
    end
    if #events == 0 then
        return false, "ไม่มีเหตุการณ์ที่ใช้งานได้"
    end

    local name = "นำเข้า"
    if type(rawName) == "string" then
        local normalized = normalizeProfileName(rawName)
        if normalized then
            name = normalized
        end
    end
    name = uniqueProfileName(name)

    local meta = {
        id = newProfileId(),
        name = name,
        created = os.time(),
        modified = os.time(),
        duration = events[#events].t,
        count = #events,
    }
    addProfileMeta(meta)
    Profiles.selectedId = meta.id
    Profiles.events = events
    State.playbackIndex = 0
    State.loop = 0
    State.finished = false
    State.dirty = false
    local saved, saveError = saveProfileToDisk(meta, events)
    if not saved then
        State.dirty = true
        Log.add("warn", "นำเข้าในหน่วยความจำ แต่เขียนไฟล์ไม่ได้: " .. tostring(saveError))
    else
        State.dirty = false
    end
    saveIndex()
    App.refreshProfiles()
    updateRecordInfo()
    Log.add("success", string.format("นำเข้าโปรไฟล์: %s (%d เหตุการณ์)", name, #events))
    return true
end

function App.promptImportProfile(force)
    if State.mode ~= "idle" then
        Log.add("warn", "หยุดงานที่กำลังทำก่อนนำเข้า")
        return
    end
    if State.dirty and not force then
        showConfirm(
            "ยังไม่ได้บันทึกโปรไฟล์?",
            "เหตุการณ์ล่าสุดยังไม่ได้เขียนลงไฟล์ การนำเข้าโปรไฟล์ใหม่จะทำให้ข้อมูลในหน่วยความจำหาย",
            "ดำเนินการต่อ",
            function()
                App.promptImportProfile(true)
            end,
            true
        )
        return
    end
    showImportDialog()
end

-- ============================================================================
-- 17) ระบบกัน AFK (แยกจาก Macro)
-- ============================================================================

function App.setAfkEnabled(value)
    value = value == true
    if Settings.afkEnabled == value then
        App.updateAfkUI()
        return
    end
    Settings.afkEnabled = value
    saveSettings()
    if value then
        AfkGuard.lastCheck = clock()
        AfkGuard.startedAt = os.time()
        AfkGuard.lastNudge = nil
        AfkGuard.lastResult = ""
        if not App.apiStatus.input then
            Log.add("warn", "เปิดระบบกัน AFK แต่ API อินพุตไม่พร้อม — ระบบจะขยับเมาส์ไม่ได้")
        else
            Log.add("info", string.format("เปิดระบบกัน AFK (ขยับทุก %d นาที) — ไม่รับประกันว่าจะไม่ถูก kick", Settings.afkInterval))
        end
    else
        Log.add("info", "ปิดระบบกัน AFK")
    end
    App.updateAfkUI()
end

function AfkGuard.nudge(reason)
    if not Settings.afkEnabled then
        return false
    end
    if not App.apiStatus.input then
        AfkGuard.lastResult = "ข้าม: API ไม่พร้อม"
        App.updateAfkUI()
        return false
    end
    if State.mode ~= "idle" then
        AfkGuard.lastResult = "ข้าม: Macro กำลังทำงาน"
        App.updateAfkUI()
        return false
    end
    if not isGameActive() then
        AfkGuard.lastResult = "ข้าม: เกมไม่ active"
        App.updateAfkUI()
        return false
    end

    local position = getMousePosition()
    local deltaX = 1
    if position then
        local viewport = getViewport()
        if position.X >= viewport.X - 20 then
            deltaX = -1
        end
    end

    local firstOk = pcall(mousemoverel, deltaX, 0)
    local secondOk = pcall(mousemoverel, -deltaX, 0)
    if firstOk and secondOk then
        AfkGuard.lastNudge = os.time()
        AfkGuard.lastResult = "สำเร็จ"
        Log.add("info", "กัน AFK: ขยับเมาส์เล็กน้อย (" .. tostring(reason) .. ")")
        App.updateAfkUI()
        return true
    end

    AfkGuard.lastResult = "ล้มเหลว"
    Log.add("warn", "กัน AFK ไม่สำเร็จ: mousemoverel ใช้งานไม่ได้")
    App.updateAfkUI()
    return false
end

-- ============================================================================
-- 18) คำสั่งอื่น ๆ และการปิดสคริปต์
-- ============================================================================

function App.promptResetSettings()
    showConfirm(
        "รีเซ็ตการตั้งค่า?",
        "ค่าจำนวนรอบ ช่วงพัก ความเร็ว พิกัด และระบบกัน AFK จะกลับเป็นค่าเริ่มต้น (โปรไฟล์ไม่ถูกลบ)",
        "รีเซ็ต",
        function()
            for key, value in pairs(DEFAULT_SETTINGS) do
                Settings[key] = value
            end
            Settings._warnedWrite = false
            saveSettings()
            App.refreshSettingsUI()
            App.refreshTransport()
            App.updateAfkUI()
            setStatus("รีเซ็ตการตั้งค่าแล้ว", "ready")
            Log.add("info", "รีเซ็ตการตั้งค่าเป็นค่าเริ่มต้น")
        end,
        true
    )
end

function App.promptClearLog()
    showConfirm(
        "ล้างบันทึกสถานะ?",
        "รายการ log ในหน่วยความจำและบนหน้าจอจะถูกล้าง (ไฟล์ log เดิมยังอยู่)",
        "ล้าง Log",
        function()
            Log.clear()
            Log.add("info", "ล้างบันทึกสถานะแล้ว")
        end,
        true
    )
end

function App.promptCloseScript()
    local message = "งานที่กำลังทำจะถูกหยุด ปุ่มที่ค้างจะถูกปล่อย และ GUI จะถูกปิด"
    if State.dirty then
        message = message .. " • มีเหตุการณ์ที่ยังไม่ถูกบันทึกและจะหายไป"
    end
    showConfirm(
        "ปิดสคริปต์?",
        message,
        "ปิดสคริปต์",
        function()
            App.destroy()
        end,
        true
    )
end

local RuntimeHandle = { version = APP_VERSION }

function App.destroy()
    if State.destroyed then
        return
    end
    State.destroyed = true
    Running = false
    State.token += 1
    State.mode = "idle"
    closeModal()
    releaseHeld()

    for _, connection in ipairs(Connections) do
        pcall(function()
            connection:Disconnect()
        end)
    end
    Connections = {}

    saveSettings()
    saveIndex()

    Log.onEntry = nil
    Log.uiScroll = nil
    Log.uiLabels = {}

    if UI.screenGui then
        UI.screenGui:Destroy()
    end
    if GENV.__ASTD_MACRO == RuntimeHandle then
        GENV.__ASTD_MACRO = nil
    end
    print("[" .. APP_NAME .. "] ปิดสคริปต์แล้ว")
end

App.publicHandle = RuntimeHandle
RuntimeHandle.destroy = App.destroy
RuntimeHandle.stop = function()
    App.emergencyStop()
end

-- ============================================================================
-- 19) เริ่มต้นสคริปต์
-- ============================================================================

local missingInput = {}
local inputApiChecks = {
    { name = "mousemoveabs", value = mousemoveabs },
    { name = "mousemoverel", value = mousemoverel },
    { name = "mouse1press", value = mouse1press },
    { name = "mouse1release", value = mouse1release },
    { name = "mouse2press", value = mouse2press },
    { name = "mouse2release", value = mouse2release },
    { name = "mousescroll", value = mousescroll },
    { name = "keypress", value = keypress },
    { name = "keyrelease", value = keyrelease },
}
for _, api in ipairs(inputApiChecks) do
    if type(api.value) ~= "function" then
        table.insert(missingInput, api.name)
    end
end
App.apiStatus.input = #missingInput == 0

App.apiStatus.clipboard = type(setclipboard) == "function"

if type(identifyexecutor) == "function" then
    local ok, name, version = pcall(identifyexecutor)
    if ok then
        App.executorName = tostring(name or "Unknown")
        App.executorVersion = tostring(version or "")
    end
end

local foldersOk, foldersError = ensureWorkspaceFolders()
App.apiStatus.files = FileTools.ready and foldersOk

if App.apiStatus.files then
    Log.initFile()
else
    Log.add("warn", "ที่เก็บไฟล์ไม่พร้อมใช้งาน: " .. tostring(foldersError or "writefile/readfile ไม่ครบ"))
end

loadSettings()
if Settings.afkEnabled then
    AfkGuard.startedAt = os.time()
end
loadProfiles()

if not Profiles.selectedId and #Profiles.list > 0 then
    Profiles.selectedId = Profiles.list[1].id
end
if Profiles.selectedId then
    local data, readError = readProfileFromDisk(Profiles.selectedId)
    if data then
        Profiles.events = data.events or {}
        local meta = selectedProfileMeta()
        if meta then
            meta.name = data.name or meta.name
            meta.count = data.count or #Profiles.events
            meta.duration = data.duration or 0
            meta.created = data.created or meta.created
            meta.modified = data.modified or meta.modified
        end
    else
        Profiles.events = {}
        Log.add("warn", "อ่านโปรไฟล์เริ่มต้นไม่สำเร็จ: " .. tostring(readError))
    end
end

local uiCallOk, uiOk, uiError = pcall(buildUI)
if not uiCallOk then
    uiError = uiOk
    uiOk = false
end
if not uiOk then
    Log.add("error", "สร้าง GUI ไม่สำเร็จ: " .. tostring(uiError))
    print("[" .. APP_NAME .. "] สร้าง GUI ไม่สำเร็จ: " .. tostring(uiError))
    if UI.screenGui then
        pcall(function()
            UI.screenGui:Destroy()
        end)
    end
    return
end

connectInputHandlers()

if LocalPlayer then
    connectTracked(LocalPlayer.Idled, function()
        if Settings.afkEnabled and State.mode == "idle" then
            AfkGuard.nudge("เกมรายงาน Idled")
        else
            Log.add("info", "เกมรายงานว่าผู้เล่นไม่ได้ใช้งาน (Idled)")
        end
    end)
end

task.spawn(function()
    while Running do
        task.wait(1)
        if not Running then
            break
        end
        if Settings.afkEnabled and State.mode == "idle" and App.apiStatus.input then
            local now = os.time()
            local interval = math.max(1, math.floor(Settings.afkInterval)) * 60
            local last = AfkGuard.lastNudge or AfkGuard.startedAt or now
            if now - last >= interval then
                AfkGuard.nudge("ครบรอบ")
            end
        end
    end
end)

App.refreshProfiles()
App.refreshSettingsUI()
App.refreshTransport()
updateRecordInfo()

if App.apiStatus.input then
    setStatus("พร้อมใช้งาน", "ready")
else
    setStatus("API อินพุตไม่พร้อม", "error")
end

Log.add("info", string.format(
    "%s v%s เริ่มทำงาน • executor %s %s • GUI %s",
    APP_NAME,
    APP_VERSION,
    App.executorName,
    App.executorVersion,
    App.apiStatus.gui
))
Log.add("info", string.format(
    "API: input %s • files %s • clipboard %s • profiles %d",
    App.apiStatus.input and "พร้อม" or "ไม่ครบ",
    App.apiStatus.files and "พร้อม" or "จำกัด",
    App.apiStatus.clipboard and "พร้อม" or "ไม่มี",
    #Profiles.list
))
if App.apiStatus.files then
    Log.add("info", "ที่เก็บข้อมูล: " .. tostring(ROOT_DIR) .. "/ (workspace ของ executor)")
end
if #missingInput > 0 then
    Log.add("error", "API อินพุตที่ขาด: " .. table.concat(missingInput, ", "))
end

RuntimeHandle.open = function()
    setMenuVisible(true)
end
RuntimeHandle.toggle = function()
    toggleMenu()
end
RuntimeHandle.status = function()
    return State.mode, State.statusText
end

GENV.__ASTD_MACRO = RuntimeHandle

print(string.format("[%s] โหลดสำเร็จ — กด F7 ซ่อน/แสดงเมนู, F8 หยุดฉุกเฉิน", APP_NAME))
