--!nonstrict
--[[
    ASTD Macro v2.0.1
    มาโครบันทึก/เล่นซ้ำอินพุตเมาส์และคีย์บอร์ด
    รองรับ Windows/Real Executor และ iPhone/Delta Executor ตาม API ที่ตรวจพบจริง
    - ใช้ API อินพุตของ executor ก่อน; ถ้าไม่มีจะลอง Roblox VirtualUser (สถานะทดลอง)
    - ไม่เรียกฟังก์ชันภายในเกม ไม่ใช้ hook / fireclickdetector / remote ต้องห้าม
    - ฟังก์ชันที่ต้องอ่านสถานะเกมจริง (Auto/คืนค่าเซ็ต/จบด่าน) จะเปิดใช้เมื่อมี
      game adapter ที่ผู้ใช้ติดตั้งและยืนยันเองเท่านั้น
    - v2.0.1: ค่าเริ่มต้นไม่บันทึกการขยับเมาส์/กล้อง ปุ่มเดิน หรือล้อเมาส์
      แต่ยังเก็บคลิกวาง/อัปเกรดและปุ่มที่จำเป็น; เลือกบันทึกเต็มรูปแบบได้ใน Settings
    - คลิกที่บันทึกจะพยายามเก็บจุดอ้างอิงในโลกจาก camera raycast เพื่อฉายกลับ
      ตอนเล่นซ้ำ (best effort; ไม่ใช่การรับประกันตำแหน่งจาก ASTD adapter)
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

local APP_NAME = "ASTD Macro"
local APP_VERSION = "2.0.1"
-- ใช้ตรวจว่าโหลดสคริปต์รุ่นล่าสุดจาก raw link จริง (ไม่เปลี่ยนเลขเวอร์ชัน)
local APP_BUILD = "2026-10-28.1"
local GUI_NAME = "ASTD_Macro_Menu"

-- พิมพ์ตั้งแต่ต้นสคริปต์: ถ้าไม่เห็นบรรทัดนี้ = executor ไม่ได้รันโค้ดเลย ไม่ใช่บั๊กของ Macro
print("[" .. APP_NAME .. "] เริ่มโหลดสคริปต์ build " .. APP_BUILD)

-- ตรวจว่ามี GUI ของ Macro อยู่จริงในเกม (PlayerGui หรือ hidden UI container)
-- ใช้แยก "อินสแตนซ์ที่ยังทำงานจริง" ออกจาก "อินสแตนซ์ค้าง" ที่ GUI ถูกเกมลบไปแล้ว
local function macroGuiExists()
    local function hasGui(container)
        if typeof(container) ~= "Instance" then
            return false
        end
        local ok, found = pcall(function()
            for _, child in ipairs(container:GetChildren()) do
                if child.Name == GUI_NAME and child:IsA("ScreenGui") then
                    return true
                end
            end
            return false
        end)
        return ok and found == true
    end

    local okPlayers, players = pcall(function()
        return game:GetService("Players")
    end)
    if okPlayers and players then
        local player = players.LocalPlayer
        if player and hasGui(player:FindFirstChildOfClass("PlayerGui")) then
            return true
        end
    end
    if type(gethui) == "function" then
        local ok, hidden = pcall(gethui)
        if ok and hasGui(hidden) then
            return true
        end
    end
    return false
end

-- ห้ามสร้างอินสแตนซ์ซ้ำ แต่ถ้าอินสแตนซ์เดิมเหลือแต่ handle ที่ไม่มี GUI แล้ว
-- ต้องปิดตัวเก่าแล้วโหลดใหม่ ไม่งั้นผู้ใช้จะเห็น "เงียบสนิท" และไม่มีทางเปิดเมนูได้เลย
local oldInstance = GENV.__ASTD_MACRO
if type(oldInstance) == "table" and oldInstance.alive ~= false then
    local reused = false
    if macroGuiExists() then
        if type(oldInstance.notifyDuplicate) == "function" then
            reused = pcall(oldInstance.notifyDuplicate)
        end
        if not reused and type(oldInstance.open) == "function" then
            reused = pcall(oldInstance.open)
        end
        -- setMenuVisible คืนค่าเงียบ ๆ เมื่อ GUI ถูกทำลาย จึงต้องตรวจซ้ำว่าเมนูกลับมาจริง
        if reused and not macroGuiExists() then
            reused = false
        end
    end
    if reused then
        print("[" .. APP_NAME .. "] พบอินสแตนซ์ที่ทำงานอยู่ — เปิดเมนูเดิมแทนการโหลดซ้ำ")
        return
    end
    if type(oldInstance.destroy) == "function" then
        pcall(oldInstance.destroy)
        print("[" .. APP_NAME .. "] อินสแตนซ์เดิมใช้ต่อไม่ได้ — ปิดแล้วโหลดใหม่")
    else
        print("[" .. APP_NAME .. "] พบอินสแตนซ์ค้างที่ปิดไม่ได้ — ล้างสถานะแล้วโหลดใหม่")
    end
end
GENV.__ASTD_MACRO = nil

print("[" .. APP_NAME .. "] Bootstrap 1/5: เริ่มต้น v" .. APP_VERSION)

-- ============================================================================
-- 01) ค่าคงที่ บริการ และธีม
-- ============================================================================

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer

local ROOT_DIR = "ASTD_Macro"
local PROFILE_DIR = ROOT_DIR .. "/profiles"
local EXPORT_DIR = ROOT_DIR .. "/exports"
local LOG_DIR = ROOT_DIR .. "/logs"
local SETTINGS_PATH = ROOT_DIR .. "/settings.json"
local INDEX_PATH = ROOT_DIR .. "/index.json"
local LOG_PATH = LOG_DIR .. "/session.log"
local RECOVERY_PATH = ROOT_DIR .. "/recovery.json"

local MAX_EVENTS = 30000
local MAX_MACROS = 60
local MAX_LOG_ENTRIES = 250
local MAX_LOG_LABELS = 140
local PROFILE_FORMAT = "astd-macro-profile"
local PROFILE_VERSION = 2
local STEPS_RENDER_LIMIT = 400
local AUTO_TICK_SECONDS = 1
local GAME_WAIT_SECONDS = 60
local GAME_MAX_ATTEMPTS = 3
local RECOVERY_SNAPSHOT_SECONDS = 5

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

-- พยายามเก็บจุดอ้างอิงในโลกจากรังสีของเมาส์/ทัช ณ ตำแหน่งที่คลิก
-- เก็บลายเซ็นของพื้นผิว/โมเดลที่ถูกคลิกด้วย เพื่อใช้ยืนยันตอนเล่นซ้ำ
-- นี่เป็น best effort จาก camera raycast ไม่ใช่ข้อมูล placement cell/unit ID ของ ASTD
local WORLD_MATCH_RADIUS = 4
local WORLD_OCCUPIED_RADIUS = 6
local WORLD_SCAN_RADIUS = 16
local WORLD_SCAN_STEP = 4
local WORLD_PATH_LIMIT = 240

local function limitedText(value, maxLength)
    if type(value) ~= "string" then
        return nil
    end
    value = trimText(value)
    if value == "" then
        return nil
    end
    if charLength(value) > maxLength then
        local ok, truncated = pcall(function()
            local offset = utf8.offset(value, maxLength + 1)
            if offset then
                return value:sub(1, offset - 1)
            end
            return value
        end)
        value = ok and truncated or value:sub(1, maxLength)
    end
    return value
end

local function vector3Table(value)
    if not value then
        return nil
    end
    local ok, x, y, z = pcall(function()
        return value.X, value.Y, value.Z
    end)
    if not ok or type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return nil
    end
    if math.abs(x) > 1000000 or math.abs(y) > 1000000 or math.abs(z) > 1000000 then
        return nil
    end
    return { x = x, y = y, z = z }
end

local function describeWorldHit(hit)
    if not hit or not hit.Position then
        return nil
    end
    local info = {}
    local instance = hit.Instance
    if instance then
        pcall(function()
            info.name = limitedText(instance.Name, 120)
            info.class = limitedText(instance.ClassName, 80)
            info.path = limitedText(instance:GetFullName(), WORLD_PATH_LIMIT)
            if instance:IsA("Terrain") then
                info.isTerrain = true
            end
        end)
        local model = instance
        local depth = 0
        while model and model ~= workspace and depth < 20 do
            local isModel = false
            pcall(function()
                isModel = model:IsA("Model")
            end)
            if isModel then
                pcall(function()
                    info.modelName = limitedText(model.Name, 120)
                    info.modelClass = limitedText(model.ClassName, 80)
                    info.modelPath = limitedText(model:GetFullName(), WORLD_PATH_LIMIT)
                end)
                local pivot = nil
                pcall(function()
                    if type(model.GetPivot) == "function" then
                        pivot = model:GetPivot().Position
                    elseif model.PrimaryPart then
                        pivot = model.PrimaryPart.Position
                    end
                end)
                local pivotTable = vector3Table(pivot)
                if pivotTable then
                    info.modelPivot = pivotTable
                end
                break
            end
            model = model.Parent
            depth += 1
        end
    end
    if not info.name and not info.class and not info.path and not info.modelName then
        return nil
    end
    return info
end

local function makeWorldRaycastParams()
    local params = RaycastParams.new()
    pcall(function()
        params.FilterType = Enum.RaycastFilterType.Exclude
    end)
    local filter = {}
    pcall(function()
        for _, player in ipairs(Players:GetPlayers()) do
            if player.Character then
                table.insert(filter, player.Character)
            end
        end
    end)
    if #filter > 0 then
        pcall(function()
            params.FilterDescendantsInstances = filter
        end)
    end
    params.IgnoreWater = true
    return params
end

local function raycastFromScreen(x, y, space)
    local camera = workspace.CurrentCamera
    if not camera then
        return nil
    end
    local ok, ray = pcall(function()
        if space == "screen" and type(camera.ScreenPointToRay) == "function" then
            return camera:ScreenPointToRay(x, y)
        end
        return camera:ViewportPointToRay(x, y)
    end)
    if not ok or not ray then
        return nil
    end
    local hitOk, hit = pcall(function()
        return workspace:Raycast(ray.Origin, ray.Direction * 20000, makeWorldRaycastParams())
    end)
    if not hitOk then
        return nil
    end
    return hit
end

local function captureWorldAnchor(screenX, screenY, source)
    local camera = workspace.CurrentCamera
    if not camera then
        return nil
    end
    screenX = numberOr(screenX, 0)
    screenY = numberOr(screenY, 0)

    local ray = nil
    if source ~= "touch" and LocalPlayer then
        local mouse = nil
        pcall(function()
            mouse = LocalPlayer:GetMouse()
        end)
        if mouse then
            pcall(function()
                ray = mouse.UnitRay
            end)
        end
    end
    if not ray then
        pcall(function()
            if source == "touch" then
                ray = camera:ViewportPointToRay(screenX, screenY)
            elseif type(camera.ScreenPointToRay) == "function" then
                ray = camera:ScreenPointToRay(screenX, screenY)
            else
                ray = camera:ViewportPointToRay(screenX, screenY)
            end
        end)
    end
    if not ray then
        return nil
    end

    local ok, hit = pcall(function()
        return workspace:Raycast(ray.Origin, ray.Direction * 20000, makeWorldRaycastParams())
    end)
    if not ok or not hit or not hit.Position then
        return nil
    end

    local point = hit.Position
    if math.abs(point.X) > 1000000 or math.abs(point.Y) > 1000000 or math.abs(point.Z) > 1000000 then
        return nil
    end

    local viewportPoint, viewportOn
    local screenPoint, screenOn
    local projected = pcall(function()
        viewportPoint, viewportOn = camera:WorldToViewportPoint(point)
        screenPoint, screenOn = camera:WorldToScreenPoint(point)
    end)
    if not projected then
        return nil
    end

    local target = Vector2.new(screenX, screenY)
    local viewportDistance = math.huge
    local screenDistance = math.huge
    if viewportOn and viewportPoint and viewportPoint.Z > 0 then
        viewportDistance = (Vector2.new(viewportPoint.X, viewportPoint.Y) - target).Magnitude
    end
    if screenOn and screenPoint and screenPoint.Z > 0 then
        screenDistance = (Vector2.new(screenPoint.X, screenPoint.Y) - target).Magnitude
    end
    if viewportDistance == math.huge and screenDistance == math.huge then
        return nil
    end

    return {
        x = point.X,
        y = point.Y,
        z = point.Z,
        space = screenDistance < viewportDistance and "screen" or "viewport",
        hit = describeWorldHit(hit),
    }
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

local function getFocusedTextBox()
    local ok, box = pcall(function()
        return UserInputService:GetFocusedTextBox()
    end)
    if ok then
        return box
    end
    return nil
end

-- ============================================================================
-- 02.1) ตรวจสอบความสามารถของอุปกรณ์และ Executor
-- ============================================================================

local Cap = {
    platform = "Unknown",
    mobile = false,
    touch = false,
    keyboard = false,
    input = "none",
    inputLabel = "ไม่พร้อม",
    inputDetail = "ไม่พบ API อินพุตที่ใช้ได้",
    realMissing = {},
    realReady = false,
    virtualUser = nil,
    virtualReady = false,
    virtualMissing = {},
    virtualInput = nil,
    virtualInputReady = false,
    virtualInputError = nil,
    vim = nil,
    vimReady = false,
    files = false,
    clipboard = false,
    gui = "none",
    afk = false,
    executorName = "Unknown",
    executorVersion = "",
}

local REAL_INPUT_GETTERS = {
    { name = "mousemoveabs", get = function() return mousemoveabs end },
    { name = "mousemoverel", get = function() return mousemoverel end },
    { name = "mouse1press", get = function() return mouse1press end },
    { name = "mouse1release", get = function() return mouse1release end },
    { name = "mouse2press", get = function() return mouse2press end },
    { name = "mouse2release", get = function() return mouse2release end },
    { name = "mousescroll", get = function() return mousescroll end },
    { name = "keypress", get = function() return keypress end },
    { name = "keyrelease", get = function() return keyrelease end },
}

local VIRTUAL_INPUT_METHODS = {
    "CaptureController",
    "MoveMouse",
    "Button1Down",
    "Button1Up",
    "Button2Down",
    "Button2Up",
    "SetKeyDown",
    "SetKeyUp",
    "ClickButton1",
    "ClickButton2",
}

local function instanceMethodExists(instance, methodName)
    if not instance then
        return false
    end
    local ok, value = pcall(function()
        return instance[methodName]
    end)
    return ok and type(value) == "function"
end

local function detectCapabilities()
    local okTouch, touch = pcall(function()
        return UserInputService.TouchEnabled
    end)
    local okKeyboard, keyboard = pcall(function()
        return UserInputService.KeyboardEnabled
    end)
    Cap.touch = okTouch and touch == true
    Cap.keyboard = okKeyboard and keyboard == true

    local viewport = getViewport()
    Cap.mobile = (Cap.touch and not Cap.keyboard) or (viewport.X > 0 and viewport.X < 760)
    if Cap.mobile then
        Cap.platform = Cap.touch and "Mobile / Touch" or "หน้าต่างแคบ"
    else
        Cap.platform = "Windows / PC"
    end

    Cap.realMissing = {}
    for _, item in ipairs(REAL_INPUT_GETTERS) do
        local ok, fn = pcall(item.get)
        if not ok or type(fn) ~= "function" then
            table.insert(Cap.realMissing, item.name)
        end
    end
    Cap.realReady = #Cap.realMissing == 0

    -- อินพุตเสมือนของ Roblox: ส่งเมาส์/คีย์เข้าเกมโดยไม่ย้ายเมาส์จริงของ OS
    -- VirtualInput เป็น API สาธารณะ (UserInputService:CreateVirtualInput)
    Cap.virtualInput = nil
    Cap.virtualInputReady = false
    Cap.virtualInputError = nil
    local createOk, created = pcall(function()
        return UserInputService:CreateVirtualInput()
    end)
    if createOk
        and created
        and instanceMethodExists(created, "SendMousePosition")
        and instanceMethodExists(created, "SendMouseButton")
    then
        Cap.virtualInput = created
        Cap.virtualInputReady = true
    else
        Cap.virtualInputError = createOk and "CreateVirtualInput ไม่คืน VirtualInput" or tostring(created)
    end

    -- VirtualInputManager (internal service ที่ executor เปิดให้)
    -- ใช้เป็นทางสำรองเมื่อ VirtualInput ถูกจำกัดสิทธิ์/คลิกใกล้ topbar ไม่ได้
    Cap.vim = nil
    Cap.vimReady = false
    local vimOk, vim = pcall(function()
        return game:GetService("VirtualInputManager")
    end)
    if vimOk and vim
        and instanceMethodExists(vim, "SendMouseMoveEvent")
        and instanceMethodExists(vim, "SendMouseButtonEvent")
    then
        Cap.vim = vim
        Cap.vimReady = true
    end

    Cap.virtualUser = nil
    Cap.virtualReady = false
    Cap.virtualMissing = {}
    local serviceOk, service = pcall(function()
        return game:GetService("VirtualUser")
    end)
    if serviceOk and service then
        Cap.virtualUser = service
        for _, methodName in ipairs(VIRTUAL_INPUT_METHODS) do
            if not instanceMethodExists(service, methodName) then
                table.insert(Cap.virtualMissing, methodName)
            end
        end
        Cap.virtualReady = #Cap.virtualMissing == 0
    else
        Cap.virtualMissing = { "VirtualUser service" }
    end

    if Cap.virtualInputReady then
        Cap.input = "virtualinput"
        Cap.inputLabel = "VirtualInput (เมาส์จริงไม่ขยับ)"
        Cap.inputDetail = "คลิก/วางผ่าน VirtualInput ของ Roblox — เมาส์จริงไม่ถูกย้าย"
    elseif Cap.vimReady then
        Cap.input = "vim"
        Cap.inputLabel = "VirtualInputManager (เมาส์จริงไม่ขยับ)"
        Cap.inputDetail = "คลิก/วางผ่าน VirtualInputManager — เมาส์จริงไม่ถูกย้าย"
    elseif Cap.realReady then
        Cap.input = "real"
        Cap.inputLabel = "Executor API (Real)"
        Cap.inputDetail = "fallback: mousemoveabs จะขยับเมาส์จริง"
    elseif Cap.virtualReady then
        Cap.input = "virtual"
        Cap.inputLabel = "Roblox VirtualUser (ทดลอง)"
        Cap.inputDetail = "VirtualUser พร้อม แต่ยังไม่ได้ยืนยันกับ Delta/iOS"
    else
        Cap.input = "none"
        Cap.inputLabel = "ไม่พร้อม"
        local missing = {}
        for _, name in ipairs(Cap.realMissing) do
            table.insert(missing, name)
        end
        for _, name in ipairs(Cap.virtualMissing) do
            table.insert(missing, name)
        end
        Cap.inputDetail = "ขาด: " .. table.concat(missing, ", ")
    end

    -- appendfile ใช้เฉพาะ log; การบันทึกโปรไฟล์ต้องใช้ชุดหลักนี้เท่านั้น
    Cap.files = type(readfile) == "function"
        and type(writefile) == "function"
        and type(isfile) == "function"
        and type(makefolder) == "function"
        and type(delfile) == "function"
    Cap.clipboard = type(setclipboard) == "function"
    Cap.afk = Cap.virtualInputReady or Cap.vimReady
        or (Cap.realReady and type(mousemoverel) == "function")

    if type(identifyexecutor) == "function" then
        local ok, name, version = pcall(identifyexecutor)
        if ok then
            Cap.executorName = tostring(name or "Unknown")
            Cap.executorVersion = tostring(version or "")
        end
    end

    return Cap
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

-- ปุ่มที่ทำให้ตัวละครเดิน/กระโดดในเกมแนว Roblox และไม่ใช่การกระทำหลักของ ASTD
-- ใช้เทียบแบบตัวพิมพ์ใหญ่เพื่อรองรับชื่อ KeyCode และข้อมูลเก่าที่อาจต่างกัน
local MOVEMENT_KEY_NAMES = {
    W = true,
    A = true,
    S = true,
    D = true,
    UP = true,
    DOWN = true,
    LEFT = true,
    RIGHT = true,
    SPACE = true,
}

local MOUSE_DRAG_THRESHOLD = 8
-- นิ้วแตะวางยูนิตอาจขยับได้ง่าย จึงใช้เกณฑ์สูงพอที่จะไม่ทิ้งคลิกวางปกติ
local TOUCH_DRAG_THRESHOLD = 24
-- Macro เก่าที่ไม่มี source แยก mouse/touch ไม่ได้ จึงต้องระวังคลิกวางมากเป็นพิเศษ
local LEGACY_LEFT_DRAG_THRESHOLD = 32

local function isMovementKeyName(name)
    if type(name) ~= "string" then
        return false
    end
    return MOVEMENT_KEY_NAMES[name:upper()] == true
end

local function isMovementKeyEvent(event)
    if type(event) ~= "table" then
        return false
    end
    if event.type ~= "keyDown" and event.type ~= "keyUp" then
        return false
    end
    return isMovementKeyName(event.key)
end

local function eventPointDistance(a, b)
    local dx = numberOr(a and a.x, 0) - numberOr(b and b.x, 0)
    local dy = numberOr(a and a.y, 0) - numberOr(b and b.y, 0)
    return math.sqrt(dx * dx + dy * dy)
end

local function sanitizeVectorTable(raw)
    if type(raw) ~= "table" then
        return nil
    end
    local x = numberOr(raw.x, nil)
    local y = numberOr(raw.y, nil)
    local z = numberOr(raw.z, nil)
    if not x or not y or not z then
        return nil
    end
    if math.abs(x) > 1000000 or math.abs(y) > 1000000 or math.abs(z) > 1000000 then
        return nil
    end
    return { x = x, y = y, z = z }
end

local function sanitizeWorldHit(raw)
    if type(raw) ~= "table" then
        return nil
    end
    local hit = {
        name = limitedText(raw.name, 120),
        class = limitedText(raw.class, 80),
        path = limitedText(raw.path, WORLD_PATH_LIMIT),
        modelName = limitedText(raw.modelName, 120),
        modelClass = limitedText(raw.modelClass, 80),
        modelPath = limitedText(raw.modelPath, WORLD_PATH_LIMIT),
        modelPivot = sanitizeVectorTable(raw.modelPivot),
    }
    if raw.isTerrain == true then
        hit.isTerrain = true
    end
    if not hit.name and not hit.class and not hit.path and not hit.modelName and not hit.modelPath then
        return nil
    end
    return hit
end

local function sanitizeWorldAnchor(raw)
    if type(raw) ~= "table" then
        return nil
    end
    local x = numberOr(raw.x, nil)
    local y = numberOr(raw.y, nil)
    local z = numberOr(raw.z, nil)
    if not x or not y or not z then
        return nil
    end
    if math.abs(x) > 1000000 or math.abs(y) > 1000000 or math.abs(z) > 1000000 then
        return nil
    end
    return {
        x = x,
        y = y,
        z = z,
        space = raw.space == "screen" and "screen" or "viewport",
        hit = sanitizeWorldHit(raw.hit),
    }
end

local function sanitizeGuiPath(raw)
    if type(raw) ~= "table" or #raw == 0 then
        return nil
    end
    local path = {}
    for index = 1, math.min(#raw, 24) do
        local part = raw[index]
        if type(part) ~= "table" then
            return nil
        end
        local name = limitedText(part.name, 120)
        local className = limitedText(part.class, 80)
        local childIndex = math.floor(numberOr(part.index, 0))
        if not name or childIndex < 1 or childIndex > 10000 then
            return nil
        end
        table.insert(path, {
            name = name,
            class = className,
            index = childIndex,
        })
    end
    return path
end

local function sanitizeGuiTarget(raw)
    if type(raw) ~= "table" then
        return nil
    end
    local root = nil
    if raw.root == "PlayerGui" or raw.root == "CoreGui" then
        root = raw.root
    end
    local path = sanitizeGuiPath(raw.path)
    local relativeX = numberOr(raw.relativeX, nil)
    local relativeY = numberOr(raw.relativeY, nil)
    if not root or not path or not relativeX or not relativeY then
        return nil
    end
    return {
        root = root,
        path = path,
        relativeX = math.clamp(relativeX, 0, 1),
        relativeY = math.clamp(relativeY, 0, 1),
        isButton = raw.isButton == true,
        className = limitedText(raw.className, 80),
        text = limitedText(raw.text, 120),
        fullName = limitedText(raw.fullName, 300),
    }
end

local function sanitizeSelection(raw)
    if type(raw) ~= "table" then
        return nil
    end
    local worldId = numberOr(raw.worldId, nil)
    if not worldId or worldId ~= math.floor(worldId) or worldId < 1 or worldId > 2147483647 then
        return nil
    end
    local world = sanitizeWorldAnchor(raw.world)
    if not world then
        return nil
    end
    return {
        worldId = worldId,
        world = world,
    }
end

local function sanitizeEventSource(raw)
    if raw == "touch" or raw == "mouse" then
        return raw
    end
    return nil
end

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
                    local source = sanitizeEventSource(event.source)
                    if source then
                        normalized.source = source
                    end
                    local world = sanitizeWorldAnchor(event.world)
                    if world then
                        normalized.world = world
                    end
                    local worldId = numberOr(event.worldId, nil)
                    if worldId and worldId == math.floor(worldId) and worldId >= 1 and worldId <= 2147483647 then
                        normalized.worldId = worldId
                    end
                    local gui = sanitizeGuiTarget(event.gui)
                    if gui then
                        normalized.gui = gui
                    end
                    local selection = sanitizeSelection(event.selection)
                    if selection then
                        normalized.selection = selection
                    elseif type(event.selection) == "table" then
                        -- ข้อมูลผูกยูนิตเสีย: ห้ามเล่นคลิกนี้แบบเดาเป้าหมาย
                        normalized.selectionInvalid = true
                    end
                    if event.guiUnknown == true then
                        normalized.guiUnknown = true
                    end
                    if event.selectionInvalid == true then
                        normalized.selectionInvalid = true
                    end
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
    dragTouchId = nil,
    selectedSteps = {},
    pendingRecording = nil,
    recordingContext = nil,
    playbackScale = { x = 1, y = 1 },
    lastSavedAt = 0,
    recoveryWarned = false,
    recoveryPrompted = false,
    stepMacroId = nil,
    autoHiddenByAuto = false,
    recordingSetSnapshot = nil,
    recordingSetCapturedAt = nil,
    recordingSetHistory = {},
    lastSetSample = 0,
    lastRecoveryWrite = 0,
    recordViewport = nil,
    playbackFailures = 0,
    playbackEvents = nil,
    worldFallbackWarned = false,
    worldProjectionFallbackWarned = false,
    worldThroughWarned = false,
    guiFallbackWarned = false,
    screenClickWarned = false,
    strictGuiWarned = false,
    selectionLimitWarned = false,
    guiCaptureWarned = false,
    upgradeReselectLogged = false,
    nextWorldId = 1,
    worldTargets = {},
    lastWorldTarget = nil,
    lastWorldSelection = nil,
    heldMousePoints = {},
    skippedClicks = {},
    lastSyntheticWorldId = nil,
    recordingStageArmed = false,
    lastStageSample = 0,
    stageWarned = false,
    destroyed = false,
}

local App: any = {
    apiStatus = {
        input = false,
        files = false,
        clipboard = false,
        gui = "none",
    },
    executorName = "Unknown",
    executorVersion = "",
    warnedKeys = {},
    gameAdapter = nil,
    gameAdapterLabel = "ไม่ได้ติดตั้ง",
    gameAdapterReason = "ยังไม่มี adapter ที่ตรวจสอบสถานะเกม/คืนค่าเซ็ตได้",
    startupNotice = nil,
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

local function defaultAutoSettings()
    return {
        start = false,
        restart = false,
        next = false,
        exp = false,
        target = "",
        goal = 5,
    }
end

local DEFAULT_SETTINGS = {
    version = 3,
    loops = 1,
    -- ค่าเริ่มต้น: เล่นวนจนกว่าจะกดหยุด (ยังปรับเป็นจำนวนรอบได้ในหน้า Macro)
    infinite = true,
    loopDelay = 2,
    speed = 1,
    guardFocus = true,
    autosave = true,
    autoHide = true,
    -- ค่าเริ่มต้นปลอดภัย: ไม่บันทึกการขยับเมาส์/กล้อง ปุ่มเดิน หรือล้อเมาส์
    recordMotion = false,
    recordMovementKeys = false,
    worldAnchor = true,
    worldFallback = false,
    worldThrough = false,
    noMouseMove = true,
    scaleCoords = false,
    offsetX = 0,
    offsetY = 0,
    afkEnabled = false,
    afkInterval = 5,
    auto = defaultAutoSettings(),
}

local Settings = {}
for key, value in pairs(DEFAULT_SETTINGS) do
    Settings[key] = value
end
Settings.auto = defaultAutoSettings()

local function loadSettings()
    local data, err = readJsonFile(SETTINGS_PATH)
    if not data then
        if err ~= "ไม่พบไฟล์" then
            Log.add("warn", "อ่านการตั้งค่าไม่ได้: " .. tostring(err))
        end
        return
    end

    local settingsVersion = math.floor(numberOr(data.version, 1))
    Settings.loops = math.floor(math.clamp(numberOr(data.loops, Settings.loops), 1, 9999))
    Settings.infinite = boolOr(data.infinite, Settings.infinite)
    if settingsVersion < 2 and data.infinite == nil then
        -- v2 ใช้ค่าเริ่มต้นวนไม่จำกัดเฉพาะไฟล์เก่าที่ไม่ได้ระบุค่าไว้
        -- ถ้าผู้ใช้ตั้ง infinite=false ไว้แล้ว ห้ามเขียนทับเพราะจะทำให้เล่นซ้ำเกินที่ต้องการ
        Settings.infinite = true
        Log.add("info", "อัปเกรดการตั้งค่าเป็น v2: เปิดวนซ้ำไม่จำกัด (ปรับได้ในหน้า Macro)")
    end
    Settings.loopDelay = math.clamp(numberOr(data.loopDelay, Settings.loopDelay), 0, 600)
    Settings.speed = math.clamp(numberOr(data.speed, Settings.speed), 0.25, 4)
    Settings.guardFocus = boolOr(data.guardFocus, Settings.guardFocus)
    Settings.autosave = boolOr(data.autosave, Settings.autosave)
    Settings.autoHide = boolOr(data.autoHide, Settings.autoHide)
    Settings.recordMotion = boolOr(data.recordMotion, false)
    Settings.recordMovementKeys = boolOr(data.recordMovementKeys, false)
    Settings.worldAnchor = boolOr(data.worldAnchor, true)
    Settings.worldFallback = boolOr(data.worldFallback, false)
    Settings.worldThrough = boolOr(data.worldThrough, false)
    Settings.noMouseMove = boolOr(data.noMouseMove, true)
    Settings.scaleCoords = boolOr(data.scaleCoords, Settings.scaleCoords)
    Settings.offsetX = math.floor(math.clamp(numberOr(data.offsetX, Settings.offsetX), -1000, 1000))
    Settings.offsetY = math.floor(math.clamp(numberOr(data.offsetY, Settings.offsetY), -1000, 1000))
    Settings.afkEnabled = boolOr(data.afkEnabled, Settings.afkEnabled)
    -- v2: AFK Guard ทำงานทุก 5 นาทีคงที่
    Settings.afkInterval = 5
    if settingsVersion < 3 then
        Log.add("info", "อัปเกรดการตั้งค่า v2.0.1: ปิดบันทึกการขยับเมาส์/กล้องและปุ่มเดินเป็นค่าเริ่มต้น")
    end

    local auto = type(data.auto) == "table" and data.auto or {}
    Settings.auto = defaultAutoSettings()
    Settings.auto.start = boolOr(auto.start, false)
    Settings.auto.restart = boolOr(auto.restart, false)
    Settings.auto.next = boolOr(auto.next, false)
    Settings.auto.exp = boolOr(auto.exp, false)
    if type(auto.target) == "string" then
        Settings.auto.target = trimText(auto.target):sub(1, 80)
    end
    local goal = math.floor(numberOr(auto.goal, 6))
    Settings.auto.goal = goal == 4 and 4 or 5
end

local function saveSettings()
    local data = {
        version = 3,
        loops = Settings.loops,
        infinite = Settings.infinite,
        loopDelay = Settings.loopDelay,
        speed = Settings.speed,
        guardFocus = Settings.guardFocus,
        autosave = Settings.autosave,
        autoHide = Settings.autoHide,
        recordMotion = Settings.recordMotion == true,
        recordMovementKeys = Settings.recordMovementKeys == true,
        worldAnchor = Settings.worldAnchor ~= false,
        worldFallback = Settings.worldFallback == true,
        worldThrough = Settings.worldThrough == true,
        noMouseMove = Settings.noMouseMove ~= false,
        scaleCoords = Settings.scaleCoords,
        offsetX = Settings.offsetX,
        offsetY = Settings.offsetY,
        afkEnabled = Settings.afkEnabled,
        afkInterval = 5,
        auto = {
            start = Settings.auto.start == true,
            restart = Settings.auto.restart == true,
            next = Settings.auto.next == true,
            exp = Settings.auto.exp == true,
            target = Settings.auto.target or "",
            goal = Settings.auto.goal == 4 and 4 or 5,
        },
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
    data = nil,
    events = {},
    selectedId = nil,
    selectedMacroId = nil,
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

local macroCounter = 0
local function newMacroId()
    macroCounter += 1
    return string.format("m_%d_%03d", os.time(), macroCounter % 1000)
end

local function normalizeMacroName(text)
    local name = trimText(text)
    name = name:gsub("%c", "")
    name = trimText(name)
    if name == "" then
        return nil, "กรุณากรอกชื่อ Macro"
    end
    if charLength(name) > 40 then
        return nil, "ชื่อ Macro ยาวเกิน 40 ตัวอักษร"
    end
    return name
end

local function findMacro(profile, id)
    if not profile or type(profile.macros) ~= "table" or not id then
        return nil, nil
    end
    for index, macro in ipairs(profile.macros) do
        if type(macro) == "table" and macro.id == id then
            return macro, index
        end
    end
    return nil, nil
end

local function newMacroIdUnique(macros)
    local id = newMacroId()
    local guard = 0
    while findMacro({ macros = macros or {} }, id) and guard < 1000 do
        guard += 1
        id = newMacroId()
    end
    return id
end

local function macroNameExistsIn(macros, name, exceptId)
    local lowered = string.lower(name)
    for _, macro in ipairs(macros or {}) do
        if macro.id ~= exceptId and string.lower(macro.name or "") == lowered then
            return true
        end
    end
    return false
end

local function uniqueMacroNameIn(macros, base, exceptId)
    base = trimText(base)
    if base == "" then
        base = "มาโคร"
    end
    if not macroNameExistsIn(macros, base, exceptId) then
        return base
    end
    for index = 2, 99 do
        local candidate = base .. " " .. tostring(index)
        if not macroNameExistsIn(macros, candidate, exceptId) then
            return candidate
        end
    end
    return base .. " " .. tostring(os.time())
end

local function selectedMacro()
    if not Profiles.data then
        return nil
    end
    local macro = findMacro(Profiles.data, Profiles.selectedMacroId)
    return macro
end

local function mainMacroOf(profile)
    if not profile then
        return nil
    end
    local macro = findMacro(profile, profile.mainMacroId)
    if macro then
        return macro
    end
    return profile.macros and profile.macros[1] or nil
end

local function clampScreenValue(value, fallback)
    value = math.floor(numberOr(value, fallback))
    if value < 320 then
        value = fallback
    end
    return math.clamp(value, 320, 12000)
end

local function sanitizeSet(raw)
    if type(raw) ~= "table" then
        return nil
    end
    local status = raw.status
    if status ~= "detected" and status ~= "input-only" and status ~= "unavailable" then
        status = "unavailable"
    end

    local result = {
        status = status,
        source = trimText(type(raw.source) == "string" and raw.source or "unknown"):sub(1, 80),
        capturedAt = math.floor(numberOr(raw.capturedAt, 0)),
        note = trimText(type(raw.note) == "string" and raw.note or ""):sub(1, 300),
    }

    local inferred = type(raw.inferred) == "table" and raw.inferred or {}
    local keys = {}
    local keyCount = 0
    if type(inferred.keys) == "table" then
        for key, value in pairs(inferred.keys) do
            if keyCount >= 40 then
                break
            end
            if type(key) == "string" and key ~= "" then
                keys[key:sub(1, 30)] = math.floor(clampSafe(numberOr(value, 0), 0, 99999))
                keyCount += 1
            end
        end
    end
    local clicks = {}
    if type(inferred.clicks) == "table" then
        for _, click in ipairs(inferred.clicks) do
            if #clicks >= 40 then
                break
            end
            if type(click) == "table" then
                table.insert(clicks, {
                    x = math.floor(clampSafe(numberOr(click.x, 0), -20000, 20000)),
                    y = math.floor(clampSafe(numberOr(click.y, 0), -20000, 20000)),
                    t = math.clamp(numberOr(click.t, 0), 0, 172800),
                    button = click.button == "Right" and "Right" or "Left",
                })
            end
        end
    end
    result.inferred = {
        keys = keys,
        keyCount = math.floor(clampSafe(numberOr(inferred.keyCount, keyCount), 0, 99999)),
        clickCount = math.floor(clampSafe(numberOr(inferred.clickCount, #clicks), 0, 99999)),
        clicks = clicks,
    }

    if status == "detected" then
        if type(raw.detected) == "table" then
            local okText, text = encodeJson(raw.detected)
            if okText and type(text) == "string" and #text <= 120000 then
                result.detected = raw.detected
            else
                result.status = "unavailable"
                result.note = "ข้อมูลที่ adapter ตรวจจับมีขนาดใหญ่เกินไป จึงไม่บันทึก"
                status = "unavailable"
            end
        else
            result.status = "input-only"
            result.note = "ไม่มีข้อมูล detected จาก adapter"
            status = "input-only"
        end
    end

    if type(raw.history) == "table" and status == "detected" then
        local history = {}
        for _, item in ipairs(raw.history) do
            if #history >= 20 then
                break
            end
            if type(item) == "table" and type(item.data) == "table" then
                local okText, text = encodeJson(item.data)
                if okText and type(text) == "string" and #text <= 60000 then
                    table.insert(history, {
                        t = math.clamp(numberOr(item.t, 0), 0, 172800),
                        capturedAt = math.floor(numberOr(item.capturedAt, 0)),
                        data = item.data,
                    })
                end
            end
        end
        if #history > 0 then
            result.history = history
        end
    end

    return result
end

local function sanitizeScreen(raw)
    if type(raw) ~= "table" then
        return nil
    end
    return {
        w = clampScreenValue(raw.w, 1280),
        h = clampScreenValue(raw.h, 720),
    }
end

local GAME_CONTEXT_TEXT_LIMIT = 96

local function sanitizeGameContext(raw)
    if type(raw) ~= "table" then
        return nil
    end

    local function text(value, limit)
        if type(value) ~= "string" then
            return nil
        end
        local out = value:gsub("%c", " ")
        out = out:gsub("%s+", " ")
        out = trimText(out)
        if out == "" then
            return nil
        end
        return out:sub(1, limit or GAME_CONTEXT_TEXT_LIMIT)
    end

    local context = {
        capturedAt = math.floor(numberOr(raw.capturedAt, os.time())),
        verified = raw.verified == true,
        status = text(raw.status, 24),
        map = text(raw.map, 96),
        mode = text(raw.mode, 40),
        event = text(raw.event, 96),
        difficulty = text(raw.difficulty, 64),
        act = text(raw.act, 24),
        wave = text(raw.wave, 24),
        sources = {},
        notes = {},
    }

    for _, key in ipairs({ "map", "mode", "event", "difficulty", "act", "wave" }) do
        local source = type(raw.sources) == "table" and text(raw.sources[key], 32) or nil
        if source then
            context.sources[key] = source
        end
        local note = type(raw.notes) == "table" and text(raw.notes[key], 160) or nil
        if note then
            context.notes[key] = note
        end
    end

    local hasValue = false
    for _, key in ipairs({ "map", "mode", "event", "difficulty", "act", "wave" }) do
        if context[key] then
            hasValue = true
            break
        end
    end
    if not hasValue then
        return nil
    end
    return context
end

local function sanitizeMacro(raw, fallbackName, opts)
    opts = opts or {}
    if type(raw) ~= "table" then
        if opts.strict then
            return nil, "Macro ไม่ใช่ตารางข้อมูล"
        end
        raw = {}
    end

    local name, nameError = normalizeMacroName(raw.name or fallbackName)
    if not name then
        if opts.strict then
            return nil, nameError
        end
        name = fallbackName or "มาโคร"
    end

    local events, skipped = validateEvents(type(raw.events) == "table" and raw.events or {}, opts.strict == true)
    if not events then
        return nil, "เหตุการณ์ใน Macro \"" .. tostring(name) .. "\" ไม่ถูกต้อง: " .. tostring(skipped)
    end

    local id = type(raw.id) == "string" and raw.id:gsub("[^%w_%-]", ""):sub(1, 80) or nil
    if not id or id == "" then
        id = newMacroId()
    end

    local created = math.floor(numberOr(raw.created, os.time()))
    local modified = math.floor(numberOr(raw.modified, os.time()))
    local macro = {
        id = id,
        name = name,
        created = created,
        modified = modified,
        events = events,
        set = sanitizeSet(raw.set),
        screen = sanitizeScreen(raw.screen),
        context = sanitizeGameContext(raw.context),
    }
    macro.count = #events
    macro.duration = #events > 0 and events[#events].t or 0
    return macro, nil, skipped
end

local function sanitizeProfile(raw, opts)
    opts = opts or {}
    if type(raw) ~= "table" then
        return nil, "ข้อมูลโปรไฟล์ไม่ใช่ตาราง JSON"
    end

    local name = normalizeProfileName(raw.name or "โปรไฟล์")
    if not name then
        name = "โปรไฟล์"
    end

    local rawMacros = nil
    local migrated = false
    if type(raw.macros) == "table" and #raw.macros > 0 then
        rawMacros = raw.macros
    elseif type(raw.events) == "table" then
        rawMacros = { {
            name = "มาโคร 1",
            events = raw.events,
            set = nil,
            created = raw.created,
            modified = raw.modified,
        } }
        migrated = true
    else
        rawMacros = {}
    end

    local macros = {}
    local skippedTotal = 0
    for index, rawMacro in ipairs(rawMacros) do
        if #macros >= MAX_MACROS then
            break
        end
        local macro, err, skipped = sanitizeMacro(rawMacro, "มาโคร " .. tostring(index), opts)
        if macro then
            if findMacro({ macros = macros }, macro.id) then
                macro.id = newMacroIdUnique(macros)
            end
            macro.name = uniqueMacroNameIn(macros, macro.name, macro.id)
            table.insert(macros, macro)
            skippedTotal += numberOr(skipped, 0)
        elseif opts.strict then
            return nil, tostring(err)
        else
            Log.add("warn", "ข้าม Macro ที่เสียหาย: " .. tostring(err))
        end
    end

    if #macros == 0 then
        local fallback = sanitizeMacro({ name = "มาโคร 1", events = {} }, "มาโคร 1", {})
        table.insert(macros, fallback)
        migrated = migrated or raw.version ~= PROFILE_VERSION
    end

    local mainId = raw.mainMacroId
    if not findMacro({ macros = macros }, mainId) then
        mainId = macros[1].id
    end
    local selectedId = raw.selectedMacroId
    if not findMacro({ macros = macros }, selectedId) then
        selectedId = mainId
    end

    local selected = findMacro({ macros = macros }, selectedId) or macros[1]
    local profile = {
        format = PROFILE_FORMAT,
        version = PROFILE_VERSION,
        id = type(raw.id) == "string" and raw.id:gsub("[^%w_%-]", ""):sub(1, 80) or nil,
        name = name,
        created = math.floor(numberOr(raw.created, os.time())),
        modified = math.floor(numberOr(raw.modified, os.time())),
        macros = macros,
        mainMacroId = mainId,
        selectedMacroId = selectedId,
        events = selected.events,
        count = selected.count,
        duration = selected.duration,
        macroCount = #macros,
    }
    if not profile.id or profile.id == "" then
        profile.id = newProfileId()
    end
    return profile, nil, skippedTotal, migrated
end

local function syncProfileEvents(profile)
    if not profile or type(profile.macros) ~= "table" then
        return nil
    end
    local macro = findMacro(profile, profile.selectedMacroId)
    if not macro then
        macro = mainMacroOf(profile)
    end
    if not macro then
        return nil
    end
    macro.count = #macro.events
    macro.duration = #macro.events > 0 and macro.events[#macro.events].t or 0
    profile.selectedMacroId = macro.id
    profile.events = macro.events
    profile.count = macro.count
    profile.duration = macro.duration
    profile.macroCount = #profile.macros
    return macro
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
            macroCount = item.macroCount or 0,
        })
    end
    return {
        version = PROFILE_VERSION,
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
    local data = Profiles.data
    if not data or data.id ~= meta.id then
        data = {
            id = meta.id,
            name = meta.name,
            created = meta.created,
            modified = meta.modified,
            macros = {},
            selectedMacroId = nil,
            mainMacroId = nil,
        }
        local macro = {
            id = newMacroId(),
            name = "มาโคร 1",
            created = os.time(),
            modified = os.time(),
            events = events or {},
            set = nil,
            screen = nil,
        }
        table.insert(data.macros, macro)
        data.selectedMacroId = macro.id
        data.mainMacroId = macro.id
    end

    local macro = findMacro(data, data.selectedMacroId) or mainMacroOf(data)
    if macro and events then
        macro.events = events
    end
    syncProfileEvents(data)

    data.name = meta.name
    data.created = meta.created
    data.modified = meta.modified

    local macros = {}
    for _, item in ipairs(data.macros) do
        if #macros >= MAX_MACROS then
            break
        end
        table.insert(macros, {
            id = item.id,
            name = item.name,
            created = item.created,
            modified = item.modified,
            events = item.events or {},
            set = item.set,
            screen = item.screen,
            context = item.context,
        })
    end

    return {
        format = PROFILE_FORMAT,
        version = PROFILE_VERSION,
        id = data.id,
        name = data.name,
        created = data.created,
        modified = data.modified,
        mainMacroId = data.mainMacroId,
        selectedMacroId = data.selectedMacroId,
        macros = macros,
    }
end

local function saveProfileToDisk(meta, events)
    local data = Profiles.data
    if data and data.id == meta.id then
        local macro = findMacro(data, data.selectedMacroId) or mainMacroOf(data)
        if macro and events then
            macro.events = events
        end
        syncProfileEvents(data)
    end

    meta.count = data and data.count or (#events > 0 and #events or 0)
    meta.duration = data and data.duration or (#events > 0 and events[#events].t or 0)
    meta.macroCount = data and #data.macros or 0
    meta.modified = os.time()

    local payload = profileData(meta, events)
    local ok, err = writeJsonFile(profilePath(meta.id), payload)
    if ok then
        Profiles.list = Profiles.list
        meta.modified = payload.modified
        Profiles.lastSavedAt = os.time()
    end
    return ok, err
end

local function backupProfileFile(meta)
    if not meta or not FileTools.ready then
        return false, "ไฟล์ไม่พร้อม"
    end
    local path = profilePath(meta.id)
    local text, err = readTextFile(path)
    if not text then
        return false, tostring(err)
    end
    return writeTextFile(path .. ".bak", text)
end

local profileDataForMigration

local function readProfileFromDisk(id, opts)
    opts = opts or {}
    local path = profilePath(id)
    local text, readError = readTextFile(path)
    if not text then
        return nil, tostring(readError)
    end
    local raw, decodeError = decodeJson(text)
    if not raw then
        return nil, "JSON เสียหาย: " .. tostring(decodeError)
    end

    local profile, err, skipped, migrated = sanitizeProfile(raw, { strict = opts.strict == true })
    if not profile then
        return nil, tostring(err)
    end
    profile.id = id

    if skipped and skipped > 0 and not opts.quiet then
        Log.add("warn", string.format("โหลดโปรไฟล์ \"%s\" โดยข้ามเหตุการณ์เสีย %d รายการ", profile.name, skipped))
    end

    if migrated and opts.migrate and FileTools.ready then
        local okBackup, backupError = writeTextFile(path .. ".bak", text)
        if not okBackup then
            Log.add("warn", "สำรองโปรไฟล์ v1 ไม่สำเร็จ: " .. tostring(backupError))
        end
        local meta = {
            id = id,
            name = profile.name,
            created = profile.created,
            modified = os.time(),
            duration = profile.duration,
            count = profile.count,
            macroCount = profile.macroCount,
        }
        local okSave, saveError = writeJsonFile(path, profileDataForMigration(profile, meta))
        if okSave then
            Log.add("info", string.format("อัปเกรดโปรไฟล์ \"%s\" เป็นรูปแบบ v2 (สำรองเป็น .bak)", profile.name))
        else
            Log.add("warn", "อัปเกรดไฟล์โปรไฟล์เป็น v2 ไม่สำเร็จ: " .. tostring(saveError))
        end
    end

    return profile
end

profileDataForMigration = function(profile, meta)
    return {
        format = PROFILE_FORMAT,
        version = PROFILE_VERSION,
        id = meta.id,
        name = profile.name,
        created = profile.created,
        modified = profile.modified,
        mainMacroId = profile.mainMacroId,
        selectedMacroId = profile.selectedMacroId,
        macros = profile.macros,
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
            local profile = readProfileFromDisk(id, { quiet = true })
            if profile then
                table.insert(found, {
                    id = id,
                    name = uniqueProfileName(profile.name),
                    created = profile.created,
                    modified = profile.modified,
                    duration = profile.duration,
                    count = profile.count,
                    macroCount = profile.macroCount,
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
                        macroCount = math.max(0, math.floor(numberOr(item.macroCount, 0))),
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
            macroCount = 1,
        }
        local macro = {
            id = newMacroId(),
            name = "มาโคร 1",
            created = os.time(),
            modified = os.time(),
            events = {},
            set = nil,
            screen = nil,
        }
        Profiles.data = {
            format = PROFILE_FORMAT,
            version = PROFILE_VERSION,
            id = meta.id,
            name = meta.name,
            created = meta.created,
            modified = meta.modified,
            macros = { macro },
            mainMacroId = macro.id,
            selectedMacroId = macro.id,
            events = macro.events,
            count = 0,
            duration = 0,
            macroCount = 1,
        }
        Profiles.events = macro.events
        Profiles.selectedMacroId = macro.id
        addProfileMeta(meta)
        Profiles.selectedId = meta.id
        saveProfileToDisk(meta, {})
        saveIndex()
        Log.add("info", "สร้างโปรไฟล์เริ่มต้น: " .. meta.name)
    end
end

-- ============================================================================
-- 08.1) อินพุตแบบ Abstraction (Real API / VirtualUser)
-- ============================================================================

local Input = {
    backend = "none",
    ready = false,
    virtualUser = nil,
    virtualInput = nil,
    vim = nil,
    switchWarned = false,
    captured = false,
    captureWarned = false,
    point = Vector2.new(0, 0),
    lastError = nil,
}

local function virtualCameraCFrame()
    local camera = workspace.CurrentCamera
    if camera then
        return camera.CFrame
    end
    return CFrame.new()
end

local function virtualCall(methodName, ...)
    local service = Input.virtualUser
    if not service then
        return false, "VirtualUser ไม่พร้อมใช้งาน"
    end
    if not Input.captured then
        Input.captured = true
        local okCapture, captureError = pcall(function()
            service:CaptureController()
        end)
        if not okCapture and not Input.captureWarned then
            Input.captureWarned = true
            Log.add("warn", "VirtualUser: CaptureController ล้มเหลว: " .. tostring(captureError))
        end
    end
    local args = { ... }
    local ok, result = pcall(function()
        return service[methodName](service, table.unpack(args))
    end)
    if not ok then
        Input.lastError = tostring(result)
        return false, tostring(result)
    end
    return true, result
end

local function inputLayerCollector()
    -- ตัวอย่างที่ใช้จริงในเกมส่วนใหญ่ส่ง game เป็น layerCollector
    -- (PlayerGui อาจทำให้คลิกโลกไม่ถึงเกม)
    return game
end

local function createVirtualInputObject()
    local ok, object = pcall(function()
        return UserInputService:CreateVirtualInput()
    end)
    if ok and object
        and instanceMethodExists(object, "SendMousePosition")
        and instanceMethodExists(object, "SendMouseButton")
    then
        return object
    end
    return nil, ok and "CreateVirtualInput ไม่คืน VirtualInput" or tostring(object)
end

local function applyInputLabels()
    if Input.backend == "virtualinput" then
        Cap.inputLabel = "VirtualInput (เมาส์จริงไม่ขยับ)"
        Cap.inputDetail = "คลิก/วางผ่าน VirtualInput ของ Roblox — เมาส์จริงไม่ถูกย้าย"
    elseif Input.backend == "vim" then
        Cap.inputLabel = "VirtualInputManager (เมาส์จริงไม่ขยับ)"
        Cap.inputDetail = "คลิก/วางผ่าน VirtualInputManager — เมาส์จริงไม่ถูกย้าย"
    elseif Input.backend == "real" then
        Cap.inputLabel = "Executor API (Real)"
        Cap.inputDetail = "fallback: mousemoveabs จะขยับเมาส์จริง"
    elseif Input.backend == "virtual" then
        Cap.inputLabel = "Roblox VirtualUser (ทดลอง)"
        Cap.inputDetail = "VirtualUser อาจขยับเมาส์จริง"
    else
        Cap.inputLabel = "ไม่พร้อม"
        Cap.inputDetail = "ไม่พบ API อินพุตที่ใช้ได้"
    end
    Cap.input = Input.backend
end

local function demoteToVim(reason)
    if not Cap.vim then
        return false
    end
    Input.virtualInput = nil
    Input.vim = Cap.vim
    Input.backend = "vim"
    applyInputLabels()
    Cap.afk = true
    if not Input.switchWarned then
        Input.switchWarned = true
        Log.add("warn", "VirtualInput ใช้กับตำแหน่งนี้ไม่ได้ (" .. tostring(reason) .. ") — เปลี่ยนไปใช้ VirtualInputManager")
    end
    return true
end

function Input.init()
    -- ต้องรีเซ็ต backend เดิมก่อนทุกครั้ง ไม่งั้นการปิด noMouseMove ระหว่างใช้งาน
    -- จะค้าง backend เป็น virtualinput ที่ object ถูก nil ไปแล้ว
    Input.backend = "none"
    Input.ready = false
    Input.virtualInput = nil
    Input.vim = nil
    Input.virtualUser = Cap.virtualUser
    Input.lastError = nil
    Input.switchWarned = false
    Input.captured = false

    -- ค่าเริ่มต้น: ใช้อินพุตเสมือนเพื่อไม่ให้เมาส์จริงขยับ
    local preferVirtual = Settings.noMouseMove ~= false
    if preferVirtual then
        local object = Cap.virtualInput
        if not object then
            local created, createError = createVirtualInputObject()
            if created then
                object = created
                Cap.virtualInput = created
                Cap.virtualInputReady = true
            else
                Cap.virtualInputError = createError
            end
        end
        if object then
            Input.virtualInput = object
            Input.backend = "virtualinput"
        elseif Cap.vim then
            Input.vim = Cap.vim
            Input.backend = "vim"
        end
    end
    if Input.backend == "none" then
        if Cap.realReady then
            Input.backend = "real"
        elseif Cap.vim then
            -- ไม่มี API เมาส์ของ executor แต่ VIM ยังใช้ได้: ดีกว่าไปใช้ VirtualUser
            Input.vim = Cap.vim
            Input.backend = "vim"
        elseif Cap.virtualReady then
            Input.backend = "virtual"
        end
    end

    Input.ready = Input.backend ~= "none"
    applyInputLabels()
    Cap.afk = Input.backend == "virtualinput"
        or Input.backend == "vim"
        or (Input.backend == "real" and type(mousemoverel) == "function")
    return Input.ready
end

function Input.available()
    return Input.ready and Input.backend ~= "none"
end

function Input.isVirtual()
    return Input.backend == "virtualinput" or Input.backend == "vim"
end

function Input.describe()
    if Input.backend == "virtualinput" then
        return "VirtualInput (เมาส์จริงไม่ขยับ)"
    elseif Input.backend == "vim" then
        return "VirtualInputManager (เมาส์จริงไม่ขยับ)"
    elseif Input.backend == "real" then
        return "Executor API (Real)"
    elseif Input.backend == "virtual" then
        return "VirtualUser (ทดลอง)"
    end
    return "ไม่พร้อม"
end

function Input.move(x, y)
    x = math.max(0, math.floor(numberOr(x, 0) + 0.5))
    y = math.max(0, math.floor(numberOr(y, 0) + 0.5))
    Input.point = Vector2.new(x, y)

    if Input.backend == "virtualinput" then
        local object = Input.virtualInput
        if not object then
            if not demoteToVim("VirtualInput หายไป") then
                return false, "VirtualInput ไม่พร้อมใช้งาน"
            end
        else
            local ok, err = pcall(function()
                object:SendMousePosition(Input.point)
            end)
            if ok then
                return true
            end
            if not demoteToVim(err) then
                Input.lastError = tostring(err)
                return false, tostring(err)
            end
        end
    end

    if Input.backend == "vim" then
        local ok, err = pcall(function()
            Input.vim:SendMouseMoveEvent(x, y, inputLayerCollector())
        end)
        if not ok then
            Input.lastError = tostring(err)
            return false, tostring(err)
        end
        return true
    elseif Input.backend == "real" then
        local ok, err = pcall(mousemoveabs, x, y)
        if not ok then
            Input.lastError = tostring(err)
            return false, tostring(err)
        end
        return true
    elseif Input.backend == "virtual" then
        return virtualCall("MoveMouse", Vector2.new(x, y), virtualCameraCFrame())
    end
    return false, "ไม่มี API อินพุต"
end

function Input.press(button)
    if Input.backend == "virtualinput" then
        local object = Input.virtualInput
        local inputType = button == "Right"
            and Enum.UserInputType.MouseButton2
            or Enum.UserInputType.MouseButton1
        if object then
            local ok, err = pcall(function()
                object:SendMouseButton(Input.point, inputType, true, 0)
            end)
            if ok then
                return true
            end
            if not demoteToVim(err) then
                Input.lastError = tostring(err)
                return false, tostring(err)
            end
        elseif not demoteToVim("VirtualInput หายไป") then
            return false, "VirtualInput ไม่พร้อมใช้งาน"
        end
    end

    if Input.backend == "vim" then
        local mouseButton = button == "Right" and 1 or 0
        local ok, err = pcall(function()
            Input.vim:SendMouseButtonEvent(
                math.floor(Input.point.X),
                math.floor(Input.point.Y),
                mouseButton,
                true,
                inputLayerCollector(),
                1
            )
        end)
        if not ok then
            Input.lastError = tostring(err)
            return false, tostring(err)
        end
        return true
    elseif Input.backend == "real" then
        local ok, err
        if button == "Right" then
            ok, err = pcall(mouse2press)
        else
            ok, err = pcall(mouse1press)
        end
        if not ok then
            Input.lastError = tostring(err)
            return false, tostring(err)
        end
        return true
    elseif Input.backend == "virtual" then
        local point = Input.point
        if button == "Right" then
            return virtualCall("Button2Down", point, virtualCameraCFrame())
        end
        return virtualCall("Button1Down", point, virtualCameraCFrame())
    end
    return false, "ไม่มี API อินพุต"
end

function Input.release(button)
    if Input.backend == "virtualinput" then
        local object = Input.virtualInput
        local inputType = button == "Right"
            and Enum.UserInputType.MouseButton2
            or Enum.UserInputType.MouseButton1
        if object then
            local ok, err = pcall(function()
                object:SendMouseButton(Input.point, inputType, false, 0)
            end)
            if ok then
                return true
            end
            if not demoteToVim(err) then
                Input.lastError = tostring(err)
                return false, tostring(err)
            end
        elseif not demoteToVim("VirtualInput หายไป") then
            return false, "VirtualInput ไม่พร้อมใช้งาน"
        end
    end

    if Input.backend == "vim" then
        local mouseButton = button == "Right" and 1 or 0
        local ok, err = pcall(function()
            Input.vim:SendMouseButtonEvent(
                math.floor(Input.point.X),
                math.floor(Input.point.Y),
                mouseButton,
                false,
                inputLayerCollector(),
                1
            )
        end)
        if not ok then
            Input.lastError = tostring(err)
            return false, tostring(err)
        end
        return true
    elseif Input.backend == "real" then
        local ok, err
        if button == "Right" then
            ok, err = pcall(mouse2release)
        else
            ok, err = pcall(mouse1release)
        end
        if not ok then
            Input.lastError = tostring(err)
            return false, tostring(err)
        end
        return true
    elseif Input.backend == "virtual" then
        local point = Input.point
        if button == "Right" then
            return virtualCall("Button2Up", point, virtualCameraCFrame())
        end
        return virtualCall("Button1Up", point, virtualCameraCFrame())
    end
    return false, "ไม่มี API อินพุต"
end

local function keyCodeFrom(vk, keyName)
    if type(keyName) == "string" and keyName ~= "" then
        local ok, code = pcall(function()
            return Enum.KeyCode[keyName]
        end)
        if ok and code then
            return code
        end
    end
    vk = numberOr(vk, nil)
    if vk then
        local ok, code = pcall(function()
            return Enum.KeyCode:FromValue(vk)
        end)
        if ok and code then
            return code
        end
    end
    return nil
end

function Input.keyDown(vk, keyName)
    -- keypress/keyrelease ของ executor ไม่ย้ายเมาส์ จึงใช้ก่อนเสมอเมื่อมี
    if type(keypress) == "function" then
        vk = numberOr(vk, keyName and VK_BY_NAME[keyName])
        if not vk then
            return false, "ไม่พบรหัสปุ่ม " .. tostring(keyName)
        end
        local ok, err = pcall(keypress, vk)
        if not ok then
            Input.lastError = tostring(err)
            return false, tostring(err)
        end
        return true
    end

    local keyCode = keyCodeFrom(vk, keyName)
    if Input.backend == "virtualinput" and keyCode then
        local ok, err = pcall(function()
            Input.virtualInput:SendKey(true, keyCode, false)
        end)
        if not ok then
            if not demoteToVim(err) then
                Input.lastError = tostring(err)
                return false, tostring(err)
            end
        else
            return true
        end
    end
    if Input.backend == "vim" and keyCode then
        local ok, err = pcall(function()
            Input.vim:SendKeyEvent(true, keyCode, false, inputLayerCollector())
        end)
        if not ok then
            Input.lastError = tostring(err)
            return false, tostring(err)
        end
        return true
    elseif Input.backend == "virtual" then
        if type(keyName) ~= "string" or keyName == "" then
            return false, "VirtualUser ต้องใช้ชื่อปุ่ม"
        end
        return virtualCall("SetKeyDown", keyName)
    end
    return false, "ไม่มี API อินพุต"
end

function Input.keyUp(vk, keyName)
    if type(keyrelease) == "function" then
        vk = numberOr(vk, keyName and VK_BY_NAME[keyName])
        if not vk then
            return false, "ไม่พบรหัสปุ่ม " .. tostring(keyName)
        end
        local ok, err = pcall(keyrelease, vk)
        if not ok then
            Input.lastError = tostring(err)
            return false, tostring(err)
        end
        return true
    end

    local keyCode = keyCodeFrom(vk, keyName)
    if Input.backend == "virtualinput" and keyCode then
        local ok, err = pcall(function()
            Input.virtualInput:SendKey(false, keyCode, false)
        end)
        if not ok then
            if not demoteToVim(err) then
                Input.lastError = tostring(err)
                return false, tostring(err)
            end
        else
            return true
        end
    end
    if Input.backend == "vim" and keyCode then
        local ok, err = pcall(function()
            Input.vim:SendKeyEvent(false, keyCode, false, inputLayerCollector())
        end)
        if not ok then
            Input.lastError = tostring(err)
            return false, tostring(err)
        end
        return true
    elseif Input.backend == "virtual" then
        if type(keyName) ~= "string" or keyName == "" then
            return false, "VirtualUser ต้องใช้ชื่อปุ่ม"
        end
        return virtualCall("SetKeyUp", keyName)
    end
    return false, "ไม่มี API อินพุต"
end

function Input.scroll(amount)
    amount = numberOr(amount, 0)
    local point = Input.point or getMousePosition() or Vector2.new(0, 0)

    -- ต้องเลื่อนที่ตำแหน่งเป้าหมายของ Macro ไม่ใช่ตำแหน่งเมาส์จริง
    -- (mousescroll ของ executor ใช้ตำแหน่งเคอร์เซอร์จริง ซึ่งอาจทำให้กล้องเกมขยับ)
    if Input.backend == "virtualinput" then
        local object = Input.virtualInput
        if object then
            local ok, err = pcall(function()
                object:SendPointerAction(point, { Wheel = amount })
            end)
            if ok then
                return true
            end
            if not demoteToVim(err) then
                Input.lastError = tostring(err)
                return false, tostring(err)
            end
        elseif not demoteToVim("VirtualInput หายไป") then
            return false, "VirtualInput ไม่พร้อมใช้งาน"
        end
    end

    if Input.backend == "vim" then
        local ok, err = pcall(function()
            Input.vim:SendMouseWheelEvent(
                math.floor(point.X),
                math.floor(point.Y),
                amount >= 0,
                inputLayerCollector()
            )
        end)
        if not ok then
            Input.lastError = tostring(err)
            return false, tostring(err)
        end
        return true
    end

    if type(mousescroll) == "function" then
        local ok, err = pcall(mousescroll, amount)
        if not ok then
            Input.lastError = tostring(err)
            return false, tostring(err)
        end
        return true
    end
    return false, "backend นี้ไม่รองรับการเลื่อนล้อเมาส์"
end

function Input.nudge()
    -- AFK Guard: ขยับเคอร์เซอร์เสมือนเท่านั้น ไม่แตะเมาส์จริง
    if Input.backend == "virtualinput" and Input.virtualInput then
        local base = getMousePosition() or Input.point
        local ok1 = pcall(function()
            Input.virtualInput:SendMousePosition(base + Vector2.new(1, 0))
        end)
        local ok2 = pcall(function()
            Input.virtualInput:SendMousePosition(base)
        end)
        if ok1 and ok2 then
            return true
        end
        return false, "VirtualInput nudge ไม่สำเร็จ"
    elseif Input.backend == "vim" and Input.vim then
        local base = getMousePosition() or Input.point
        local layer = inputLayerCollector()
        local ok1 = pcall(function()
            Input.vim:SendMouseMoveEvent(base.X + 1, base.Y, layer)
        end)
        local ok2 = pcall(function()
            Input.vim:SendMouseMoveEvent(base.X, base.Y, layer)
        end)
        if ok1 and ok2 then
            return true
        end
        return false, "VirtualInputManager nudge ไม่สำเร็จ"
    elseif Input.backend == "real" and type(mousemoverel) == "function" then
        local position = getMousePosition()
        local deltaX = 1
        if position then
            local viewport = getViewport()
            if position.X >= viewport.X - 20 then
                deltaX = -1
            end
        end
        local ok1 = pcall(mousemoverel, deltaX, 0)
        local ok2 = pcall(mousemoverel, -deltaX, 0)
        if ok1 and ok2 then
            return true
        end
        return false, "mousemoverel ใช้งานไม่ได้"
    end
    return false, "AFK Guard ไม่รองรับบน backend นี้"
end

-- ============================================================================
-- 08.2) Game Adapter (จุดเชื่อมที่ต้องได้รับการยืนยันจากผู้ใช้)
-- ============================================================================

local ADAPTER_CAPABILITIES = {
    "mapState",
    "restoreSet",
    "captureSet",
    "autoStart",
    "autoRestart",
    "autoNext",
    "autoExp",
}

local function adapterGet()
    return App.gameAdapter
end

local function adapterSupports(name)
    local adapter = App.gameAdapter
    if not adapter or type(adapter.capabilities) ~= "table" then
        return false
    end
    return adapter.capabilities[name] == true
end

local function adapterCall(methodName, ...)
    local adapter = App.gameAdapter
    if not adapter or type(adapter[methodName]) ~= "function" then
        return false, "adapter ไม่มีฟังก์ชัน " .. tostring(methodName)
    end
    local args = { ... }
    local ok, result, extra = pcall(function()
        return adapter[methodName](adapter, table.unpack(args))
    end)
    if not ok then
        return false, tostring(result)
    end
    return true, result, extra
end

local function adapterState()
    if not App.gameAdapter then
        return nil, "ไม่มี adapter"
    end
    local ok, state, extra = adapterCall("getState")
    if not ok then
        return nil, tostring(state)
    end
    if type(state) ~= "table" then
        return nil, "adapter.getState() ต้องคืนตารางสถานะ"
    end
    return state, extra
end

function App.getAdapterStatus()
    local adapter = App.gameAdapter
    if not adapter then
        return "ไม่ได้ติดตั้ง", Theme.muted
    end
    return tostring(adapter.name or "Adapter") .. " (ติดตั้งแล้ว)", Theme.success
end

function App.installGameAdapter(adapter)
    if type(adapter) ~= "table" then
        return false, "adapter ต้องเป็นตาราง"
    end
    if adapter.verified ~= true then
        return false, "adapter ต้องระบุ verified = true หลังผู้ใช้ตรวจสอบกับเกมจริงแล้ว"
    end
    if type(adapter.name) ~= "string" or trimText(adapter.name) == "" then
        return false, "adapter ต้องมีชื่อ"
    end
    if type(adapter.getState) ~= "function" then
        return false, "adapter ต้องมีฟังก์ชัน getState()"
    end
    if type(adapter.capabilities) ~= "table" then
        return false, "adapter ต้องมีตาราง capabilities"
    end

    local caps = {}
    for _, name in ipairs(ADAPTER_CAPABILITIES) do
        caps[name] = adapter.capabilities[name] == true
    end

    -- ตรวจว่าความสามารถที่ประกาศมีฟังก์ชันรองรับจริง ไม่เปิดปุ่มหลอก
    local requiredMethods = {
        { cap = "restoreSet", method = "restoreSet" },
        { cap = "captureSet", method = "captureSet" },
        { cap = "autoRestart", method = "restartStage" },
        { cap = "autoNext", method = "nextStage" },
        { cap = "autoExp", method = "evolveExp" },
    }
    for _, item in ipairs(requiredMethods) do
        if caps[item.cap] and type(adapter[item.method]) ~= "function" then
            return false, string.format(
                "adapter ประกาศ %s แต่ไม่มีฟังก์ชัน %s()",
                item.cap,
                item.method
            )
        end
    end

    adapter.capabilities = caps
    App.gameAdapter = adapter
    App.gameAdapterLabel = trimText(adapter.name)
    App.gameAdapterReason = "adapter ที่ผู้ใช้ติดตั้ง"
    Log.add("info", "ติดตั้ง game adapter: " .. App.gameAdapterLabel)
    if type(App.refreshAutoUI) == "function" then
        pcall(App.refreshAutoUI)
    end
    return true
end

function App.removeGameAdapter()
    App.gameAdapter = nil
    App.gameAdapterLabel = "ไม่ได้ติดตั้ง"
    App.gameAdapterReason = "ยังไม่มี adapter ที่ตรวจสอบสถานะเกม/คืนค่าเซ็ตได้"
    Settings.auto.start = false
    Settings.auto.restart = false
    Settings.auto.next = false
    Settings.auto.exp = false
    saveSettings()
    Log.add("warn", "ถอด game adapter — ปิดฟังก์ชัน Auto และการคืนค่าเซ็ต")
    if type(App.refreshAutoUI) == "function" then
        pcall(App.refreshAutoUI)
    end
end

-- ============================================================================
-- 08.3) Recovery (กู้คืนการบันทึกที่ยังไม่ตั้งชื่อ)
-- ============================================================================

local Recovery = {
    warned = false,
}

function Recovery.exists()
    return fileExists(RECOVERY_PATH)
end

function Recovery.clear()
    if not Recovery.exists() then
        return true
    end
    return deleteFile(RECOVERY_PATH)
end

function Recovery.write(pending)
    if not pending or type(pending.events) ~= "table" then
        return false, "ไม่มีข้อมูลกู้คืน"
    end
    local payload = {
        format = "astd-macro-recovery",
        version = 1,
        appVersion = APP_VERSION,
        recordedAt = math.floor(numberOr(pending.recordedAt, os.time())),
        profileId = pending.profileId,
        profileName = pending.profileName,
        screen = pending.screen,
        set = pending.set,
        context = sanitizeGameContext(pending.context),
        events = pending.events,
    }
    local ok, err = writeJsonFile(RECOVERY_PATH, payload)
    if not ok and not Recovery.warned then
        Recovery.warned = true
        Log.add("warn", "เขียนไฟล์กู้คืนไม่สำเร็จ: " .. tostring(err))
    end
    return ok, err
end

function Recovery.read()
    if not Recovery.exists() then
        return nil, "ไม่พบไฟล์กู้คืน"
    end
    local data, err = readJsonFile(RECOVERY_PATH)
    if not data then
        return nil, tostring(err)
    end
    if data.format ~= "astd-macro-recovery" then
        return nil, "ไฟล์กู้คืนไม่ใช่รูปแบบของ ASTD Macro"
    end
    local events, eventErr = validateEvents(data.events or {}, true)
    if not events then
        return nil, "เหตุการณ์ในไฟล์กู้คืนเสียหาย: " .. tostring(eventErr)
    end
    if #events == 0 then
        return nil, "ไฟล์กู้คืนไม่มีเหตุการณ์"
    end
    return {
        events = events,
        set = sanitizeSet(data.set),
        recordedAt = math.floor(numberOr(data.recordedAt, os.time())),
        profileId = type(data.profileId) == "string" and data.profileId or nil,
        profileName = type(data.profileName) == "string" and trimText(data.profileName):sub(1, 60) or nil,
        screen = sanitizeScreen(data.screen),
        context = sanitizeGameContext(data.context),
    }
end

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
    local enabled = true
    local rowHeight = hintText and 58 or 40
    local row = addRow(parent, rowHeight)

    local titleLabel = makeLabel(row, labelText, 13, Theme.text, UDim2.new(1, -140, 0, hintText and 24 or 40))

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
        if not enabled then
            switch.BackgroundColor3 = Theme.dark
            knob.BackgroundColor3 = Theme.muted
            knob.Position = UDim2.new(0, 4, 0.5, -9)
            stateLabel.Text = "ไม่พร้อม"
            stateLabel.TextColor3 = Theme.danger
            titleLabel.TextColor3 = Theme.muted
            switch.BackgroundTransparency = 0.45
        else
            switch.BackgroundColor3 = value and Theme.accent or Theme.panel3
            knob.BackgroundColor3 = Theme.white
            knob.Position = value and UDim2.new(1, -22, 0.5, -9) or UDim2.new(0, 4, 0.5, -9)
            stateLabel.Text = value and "เปิด" or "ปิด"
            stateLabel.TextColor3 = value and Theme.success or Theme.muted
            titleLabel.TextColor3 = Theme.text
            switch.BackgroundTransparency = 0
        end
    end

    local function setValue(newValue, fire)
        if not enabled then
            render()
            return false
        end
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
        return true
    end

    switch.MouseButton1Click:Connect(function()
        if not enabled then
            return
        end
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
        setEnabled = function(newValue)
            enabled = newValue == true
            switch.Active = enabled
            switch.Selectable = enabled
            render()
        end,
        isEnabled = function()
            return enabled
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

local function openModal(title, subtitle, width, height, options)
    if not UI.main then
        return nil
    end
    options = options or {}
    closeModal()

    local viewport = getViewport()
    local maxWidth = math.max(260, viewport.X - 20)
    local maxHeight = math.max(180, viewport.Y - 20)
    local modalWidth = math.clamp(math.floor(numberOr(width, 440)), math.min(280, maxWidth), maxWidth)
    local modalHeight = math.clamp(math.floor(numberOr(height, 220)), math.min(200, maxHeight), maxHeight)

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
    if options.dismissable ~= false then
        overlay.MouseButton1Click:Connect(function()
            closeModal()
        end)
    end

    local card = newInstance("Frame", {
        Name = "ModalCard",
        Size = UDim2.fromOffset(modalWidth, modalHeight),
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

local function showConfirm(title, message, confirmText, onConfirm, isDanger, onCancel, messageHeight)
    local height = math.max(80, math.floor(numberOr(messageHeight, 80)))
    local modal = openModal(title, nil, 460, height + 130, { dismissable = onCancel == nil })
    if not modal then
        return
    end

    local messageLabel = newInstance("TextLabel", {
        Size = UDim2.new(1, 0, 0, height),
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

    local function cancel()
        closeModal()
        if onCancel then
            local ok, err = pcall(onCancel)
            if not ok then
                Log.add("error", "ยกเลิกไม่สำเร็จ: " .. tostring(err))
            end
        end
    end

    modal.addAction("ยกเลิก", Theme.panel3, cancel)
    modal.addAction(confirmText or "ยืนยัน", isDanger and Theme.danger or Theme.accent, function()
        closeModal()
        local ok, err = pcall(onConfirm)
        if not ok then
            Log.add("error", "ดำเนินการไม่สำเร็จ: " .. tostring(err))
        end
    end)
end

local setMenuVisible

local function showNotice(title, message, confirmText)
    if setMenuVisible and not State.menuVisible then
        setMenuVisible(true)
    end
    local modal = openModal(title, nil, 480, 230)
    if not modal then
        return
    end
    newInstance("TextLabel", {
        Size = UDim2.new(1, 0, 0, 118),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = tostring(message or ""),
        TextSize = 12,
        TextColor3 = Theme.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        TextWrapped = true,
        LineHeight = 1.15,
        Parent = modal.content,
    })
    modal.addAction(confirmText or "ปิด", Theme.accent, closeModal)
end

local function showExportDialog(jsonText, subtitle)
    local modal = openModal("ส่งออกโปรไฟล์", subtitle, 560, 480)
    if not modal then
        return
    end

    local box = newInstance("TextBox", {
        Size = UDim2.new(1, 0, 1, -26),
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
        Size = UDim2.new(1, 0, 0, 22),
        Position = UDim2.new(0, 0, 1, -22),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = subtitle or "",
        TextSize = 10,
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
        Size = UDim2.new(1, 0, 1, -26),
        BackgroundColor3 = Theme.dark,
        BorderSizePixel = 0,
        Font = FONT,
        Text = "",
        PlaceholderText = "วาง JSON ที่นี่ (แตะแล้ววาง / Ctrl+V)",
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
        Size = UDim2.new(1, 0, 0, 22),
        Position = UDim2.new(0, 0, 1, -22),
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
-- 10.1) บริบทเกม — ตรวจจาก GUI/ข้อความที่เกมเปิดเผยเท่านั้น
-- ============================================================================

local GameContext = {
    current = nil,
    lastPollAt = 0,
    pollInterval = 1,
    missionIndex = nil,
    missionIndexSource = nil,
    warned = {},
    fields = { "map", "mode", "event", "difficulty", "act", "wave" },
    labels = {
        map = "แมพ",
        mode = "โหมด",
        event = "Event/Raid",
        difficulty = "ความยาก",
        act = "Act/Stage",
        wave = "Wave",
    },
}

function GameContext.text(instance)
    if not instance or (not instance:IsA("TextLabel") and not instance:IsA("TextButton")) then
        return nil
    end
    local ok, value = pcall(function()
        return tostring(instance.Text or "")
    end)
    if not ok or not value then
        return nil
    end
    value = value:gsub("%s+", " ")
    value = trimText(value)
    if value == "" then
        return nil
    end
    return value
end

function GameContext.playerGui()
    local player = Players.LocalPlayer
    if not player then
        return nil
    end
    return player:FindFirstChild("PlayerGui")
end

function GameContext.hud()
    local gui = GameContext.playerGui()
    return gui and gui:FindFirstChild("HUD") or nil
end

function GameContext.readWave()
    local hud = GameContext.hud()
    local label = hud and hud:FindFirstChild("Wave")
    if not label or not label:IsA("TextLabel") then
        return nil
    end
    local visible = false
    pcall(function()
        visible = label.Visible == true
    end)
    if not visible then
        return nil
    end
    local text = GameContext.text(label)
    local current, total = nil, nil
    if text then
        current, total = text:match("^Wave%s*(%d+)%s*/%s*(%d+)%s*$")
    end
    if not current or not total then
        return nil
    end
    return {
        values = {
            wave = tostring(tonumber(current)) .. "/" .. tostring(tonumber(total)),
        },
        sources = { wave = "HUD.Wave" },
        notes = { wave = "จำนวน Wave ที่เกมแสดงระหว่างด่าน" },
        fresh = true,
    }
end

function GameContext.modeForCategory(category)
    if category == "World1" or category == "World2" then
        return "Story"
    elseif category == "Challenges" then
        return "Challenge"
    elseif category == "Infinite" then
        return "Infinite"
    elseif category == "Trials" then
        return "Trial"
    elseif category == "Adventures" then
        return "Adventure"
    elseif category == "Misc" then
        return "Misc"
    end
    return nil
end

function GameContext.buildMissionIndex(chooser)
    local main = chooser and chooser:FindFirstChild("Main")
    if not main then
        return nil
    end
    local index = {}
    local count = 0
    for _, category in ipairs(main:GetChildren()) do
        if category:IsA("ScrollingFrame") then
            local mode = GameContext.modeForCategory(category.Name)
            for _, entry in ipairs(category:GetChildren()) do
                if entry:IsA("GuiObject") then
                    local titleLabel = entry:FindFirstChild("MissionTitle", true)
                    local title = GameContext.text(titleLabel)
                    if title then
                        local clean = trimText((title:gsub("^%s*%d+%.%s*", "")))
                        local key = string.lower(clean)
                        if clean ~= "" then
                            local existing = index[key]
                            if existing == nil then
                                index[key] = {
                                    title = clean,
                                    category = category.Name,
                                    mode = mode,
                                }
                                count += 1
                            elseif existing.category ~= category.Name then
                                -- ชื่อซ้ำหลายหมวด: ไม่เดาโหมด ให้แสดง Unknown
                                existing.ambiguous = true
                            end
                        end
                    end
                end
            end
        end
    end
    if count == 0 then
        return nil
    end
    GameContext.missionIndex = index
    GameContext.missionIndexSource = chooser
    return index
end

function GameContext.readMenu()
    local hud = GameContext.hud()
    local missions = hud and hud:FindFirstChild("MissionsV2")
    if not missions then
        return nil
    end
    local chooser = missions:FindFirstChild("MissionChooser")
    local frame = missions:FindFirstChild("MissionFrame")
    local frameOpen = frame and frame:IsA("GuiObject") and frame.Visible == true
    if not frameOpen then
        return nil
    end

    local textLabel = frame and frame:FindFirstChild("MissionText", true)
    local missionText = GameContext.text(textLabel)
    if not missionText then
        return nil
    end

    local index = GameContext.missionIndex
    if not index or GameContext.missionIndexSource ~= chooser then
        index = GameContext.buildMissionIndex(chooser)
    end
    local clean = trimText((missionText:gsub("^%s*%d+%.%s*", "")))
    local key = string.lower(clean)
    local info = index and index[key] or nil
    if not info then
        -- บางหน้าจอต่อท้ายด้วยลำดับ เช่น "ชื่อด่าน (1)" — ใช้ได้เฉพาะเมื่อพบชื่อตรงในดัชนี
        local base = trimText((clean:gsub("%s*%(%d+%)%s*$", "")))
        if base ~= "" then
            info = index and index[string.lower(base)] or nil
        end
    end
    local map = info and info.title or clean
    if not map or map == "" then
        return nil
    end

    local values = { map = map }
    local sources = { map = "เมนู MissionsV2" }
    local notes = { map = "ชื่อด่านที่เมนูเกมแสดงอยู่ (ไม่ใช่ชื่อแมพระหว่างเล่น)" }
    if info and info.mode and not info.ambiguous then
        values.mode = info.mode
        sources.mode = "หมวดในเมนู MissionsV2"
        notes.mode = "จับคู่ชื่อด่านกับหมวด " .. tostring(info.category)
    end
    return {
        values = values,
        sources = sources,
        notes = notes,
        fresh = true,
    }
end

function GameContext.readResult()
    local hud = GameContext.hud()
    local missionEnd = hud and hud:FindFirstChild("MissionEnd")
    local endedNow = missionEnd and missionEnd:IsA("GuiObject") and missionEnd.Visible == true
    local gui = GameContext.playerGui()
    local rewards = gui and gui:FindFirstChild("StageRewards")
    if not rewards then
        return nil
    end
    if not endedNow then
        local enabled = false
        pcall(function()
            enabled = rewards.Enabled == true
        end)
        if not enabled then
            return nil
        end
    end

    local stats = rewards:FindFirstChild("2LevelStats", true)
    if not stats then
        return nil
    end
    local title = GameContext.text(stats:FindFirstChild("1Title", true))
    local difficulty = GameContext.text(stats:FindFirstChild("3Difficulty", true))
    local values = {}
    local sources = {}
    local notes = {}
    if title then
        values.event = title
        sources.event = "StageRewards"
        notes.event = "ชื่อ Event ที่สรุปผลด่านแสดง"
    end
    if difficulty then
        values.difficulty = difficulty
        sources.difficulty = "StageRewards"
        notes.difficulty = "ระดับความยากที่สรุปผลด่านแสดง"
    end
    if next(values) == nil then
        return nil
    end
    return {
        values = values,
        sources = sources,
        notes = notes,
        fresh = true,
    }
end

function GameContext.readEventPanel()
    local gui = GameContext.playerGui()
    if not gui then
        return nil
    end
    -- อ่านเฉพาะสำเนาที่เกมสร้างใน PlayerGui (ตัวใน Workspace เป็น template ที่ไม่แสดงผล)
    for _, name in ipairs({ "HeatFrame", "SummerFrame" }) do
        local frame = gui:FindFirstChild(name)
        if frame and frame:IsA("LayerCollector") then
            local enabled = false
            pcall(function()
                enabled = frame.Enabled == true
            end)
            if enabled then
                local background = frame:FindFirstChild("Background")
                local open = background == nil
                if background and background:IsA("GuiObject") then
                    local visible = false
                    local backgroundTransparency = 1
                    local imageTransparency = 1
                    pcall(function()
                        visible = background.Visible == true
                        backgroundTransparency = numberOr(background.BackgroundTransparency, 1)
                        if background:IsA("ImageLabel") or background:IsA("ImageButton") then
                            imageTransparency = numberOr(background.ImageTransparency, 1)
                        end
                    end)
                    open = visible and (backgroundTransparency < 0.95 or imageTransparency < 0.95)
                end
                if open then
                    local banner = frame:FindFirstChild("Banner")
                    local title = GameContext.text(banner and banner:FindFirstChild("Title", true))
                    if not title then
                        title = GameContext.text(frame:FindFirstChild("Title", true))
                    end
                    if title then
                        return {
                            values = { event = title },
                            sources = { event = "แผง Event ใน PlayerGui" },
                            notes = { event = "ชื่อ Event ที่แผงเกมเปิดอยู่แสดง" },
                            fresh = true,
                        }
                    end
                end
            end
        end
    end
    return nil
end

function GameContext.addField(snapshot, key, value, source, note)
    if type(value) ~= "string" then
        return
    end
    value = trimText((value:gsub("%s+", " ")))
    if value == "" then
        return
    end
    if #value > GAME_CONTEXT_TEXT_LIMIT then
        value = value:sub(1, GAME_CONTEXT_TEXT_LIMIT)
    end
    if snapshot[key] and string.lower(snapshot[key]) ~= string.lower(value) then
        snapshot.conflicts[key] = tostring(snapshot[key]) .. " / " .. value
        return
    end
    snapshot[key] = value
    if type(source) == "string" then
        snapshot.sources[key] = source
    end
    if type(note) == "string" then
        snapshot.notes[key] = note
    end
end

function GameContext.capture()
    local snapshot = {
        capturedAt = os.time(),
        verified = false,
        status = "unknown",
        map = nil,
        mode = nil,
        event = nil,
        difficulty = nil,
        act = nil,
        wave = nil,
        sources = {},
        notes = {},
        conflicts = {},
    }

    local function merge(pack)
        if type(pack) ~= "table" then
            return
        end
        local values = pack.values or pack
        for _, key in ipairs(GameContext.fields) do
            GameContext.addField(
                snapshot,
                key,
                values[key],
                pack.sources and pack.sources[key],
                pack.notes and pack.notes[key]
            )
        end
    end

    local menu = GameContext.readMenu()
    merge(menu)
    merge(GameContext.readResult())
    merge(GameContext.readEventPanel())
    merge(GameContext.readWave())

    local detected = 0
    local identityConflict = false
    for _, key in ipairs(GameContext.fields) do
        if snapshot[key] then
            detected += 1
        end
        if (key == "map" or key == "mode") and snapshot.conflicts[key] then
            identityConflict = true
        end
    end
    if detected == 0 then
        snapshot.status = "unknown"
    elseif snapshot.map and snapshot.mode then
        snapshot.status = "detected"
    else
        snapshot.status = "partial"
    end
    if menu and snapshot.map and snapshot.mode and not identityConflict then
        snapshot.verified = true
    end
    return snapshot
end

function GameContext.safeCapture()
    local ok, snapshot = pcall(GameContext.capture)
    if ok and type(snapshot) == "table" then
        return snapshot
    end
    return {
        capturedAt = os.time(),
        verified = false,
        status = "unknown",
        sources = {},
        notes = {},
        conflicts = {},
    }
end

function GameContext.mergeContexts(base, extra)
    if type(base) ~= "table" then
        return extra
    end
    if type(extra) ~= "table" then
        return base
    end

    local merged = {
        capturedAt = math.max(numberOr(base.capturedAt, 0), numberOr(extra.capturedAt, 0)),
        verified = base.verified == true or extra.verified == true,
        status = "unknown",
        map = nil,
        mode = nil,
        event = nil,
        difficulty = nil,
        act = nil,
        wave = nil,
        sources = {},
        notes = {},
        conflicts = {},
    }

    for _, sourceContext in ipairs({ base, extra }) do
        for _, key in ipairs(GameContext.fields) do
            if key ~= "wave" then
                local value = type(sourceContext[key]) == "string" and sourceContext[key] or nil
                local source = type(sourceContext.sources) == "table" and sourceContext.sources[key] or nil
                local note = type(sourceContext.notes) == "table" and sourceContext.notes[key] or nil
                GameContext.addField(merged, key, value, source, note)
            end
        end
        if type(sourceContext.conflicts) == "table" then
            for key, value in pairs(sourceContext.conflicts) do
                if key ~= "wave" then
                    merged.conflicts[key] = tostring(value)
                end
            end
        end
    end

    -- Wave เปลี่ยนตลอดระหว่างเล่น: ใช้ค่าล่าสุดแทนการฟันธงว่าขัดแย้ง
    local waveContext = nil
    if type(extra.wave) == "string" and extra.wave ~= "" then
        waveContext = extra
    elseif type(base.wave) == "string" and base.wave ~= "" then
        waveContext = base
    end
    if waveContext then
        GameContext.addField(
            merged,
            "wave",
            waveContext.wave,
            type(waveContext.sources) == "table" and waveContext.sources.wave or nil,
            type(waveContext.notes) == "table" and waveContext.notes.wave or nil
        )
        merged.conflicts.wave = nil
    end

    local detected = 0
    for _, key in ipairs(GameContext.fields) do
        if merged[key] then
            detected += 1
        end
    end
    if detected == 0 then
        merged.status = "unknown"
    elseif merged.map and merged.mode then
        merged.status = "detected"
    else
        merged.status = "partial"
    end
    merged.verified = merged.verified == true and merged.map ~= nil and merged.mode ~= nil
    for key in pairs(merged.conflicts) do
        if key == "map" or key == "mode" then
            merged.verified = false
        end
    end
    return merged
end

function GameContext.formatStored(context, compact)
    if type(context) ~= "table" then
        return "ยังไม่มีข้อมูลบริบทที่เก็บไว้"
    end
    local function part(value)
        if type(value) == "string" and value ~= "" then
            return value
        end
        return "Unknown"
    end
    if compact then
        local text = string.format(
            "แมพ: %s • โหมด: %s • Wave %s",
            part(context.map),
            part(context.mode),
            part(context.wave)
        )
        if not context.map or not context.mode then
            text = text .. " • ยังไม่ยืนยัน"
        end
        if #text > 96 then
            text = text:sub(1, 93) .. "..."
        end
        return text
    end
    return string.format(
        "แมพ: %s • โหมด: %s • Event/Raid: %s • ความยาก: %s • Act/Stage: %s • Wave: %s",
        part(context.map),
        part(context.mode),
        part(context.event),
        part(context.difficulty),
        part(context.act),
        part(context.wave)
    )
end

function GameContext.normalize(value)
    if type(value) ~= "string" then
        return nil
    end
    local text = trimText((value:gsub("%s+", " ")))
    if text == "" then
        return nil
    end
    text = trimText((text:gsub("^%s*%d+%.%s*", "")))
    if text == "" then
        return nil
    end
    return string.lower(text)
end

function GameContext.preflight(stored, current)
    current = current or GameContext.safeCapture()
    local result = {
        current = current,
        blocked = {},
        warnings = {},
        missing = {},
        needsConfirm = false,
        summary = "",
    }
    local function get(context, key)
        if type(context) ~= "table" then
            return nil
        end
        local value = context[key]
        if type(value) ~= "string" then
            return nil
        end
        value = trimText(value)
        if value == "" then
            return nil
        end
        return value
    end
    local function same(a, b)
        local left = GameContext.normalize(a)
        local right = GameContext.normalize(b)
        return left ~= nil and right ~= nil and left == right
    end

    if type(stored) ~= "table" then
        result.warnings[#result.warnings + 1] = "Macro นี้ยังไม่มีข้อมูลบริบทเกมที่เก็บไว้"
        result.missing[#result.missing + 1] = "แมพ, โหมด"
        result.needsConfirm = true
    else
        for _, item in ipairs({ { "map", "แมพ" }, { "mode", "โหมด" } }) do
            local key = item[1]
            local label = item[2]
            local storedValue = get(stored, key)
            local currentValue = get(current, key)
            if storedValue and currentValue then
                if not same(storedValue, currentValue) then
                    result.blocked[#result.blocked + 1] = string.format(
                        "%sไม่ตรง (Macro: %s • ปัจจุบัน: %s)",
                        label,
                        storedValue,
                        currentValue
                    )
                end
            else
                result.needsConfirm = true
                local reason
                if not storedValue and not currentValue then
                    reason = "Macro ไม่มีข้อมูล และเกมไม่ได้แสดงตอนนี้"
                elseif not storedValue then
                    reason = "Macro ไม่มีข้อมูล"
                else
                    reason = "เกมไม่ได้แสดงตอนนี้"
                end
                result.missing[#result.missing + 1] = label .. " (" .. reason .. ")"
                result.warnings[#result.warnings + 1] = label .. ": " .. reason
            end
        end
        for _, item in ipairs({ { "event", "Event/Raid" }, { "difficulty", "ความยาก" }, { "act", "Act/Stage" } }) do
            local key = item[1]
            local label = item[2]
            local storedValue = get(stored, key)
            local currentValue = get(current, key)
            if storedValue and currentValue and not same(storedValue, currentValue) then
                result.warnings[#result.warnings + 1] = string.format(
                    "%sต่างจากที่เก็บไว้ (Macro: %s • ปัจจุบัน: %s)",
                    label,
                    storedValue,
                    currentValue
                )
            end
        end
    end

    local conflicts = current and current.conflicts
    if type(conflicts) == "table" then
        for _, item in ipairs({
            { "map", "แมพ" },
            { "mode", "โหมด" },
            { "event", "Event/Raid" },
            { "difficulty", "ความยาก" },
            { "act", "Act/Stage" },
        }) do
            local value = conflicts[item[1]]
            if value then
                if item[1] == "map" or item[1] == "mode" then
                    result.blocked[#result.blocked + 1] = item[2] .. "มีข้อมูลขัดแย้งกัน: " .. tostring(value)
                else
                    result.warnings[#result.warnings + 1] = item[2] .. "มีข้อมูลขัดแย้งกัน: " .. tostring(value)
                end
            end
        end
    end

    if type(stored) == "table" and stored.verified ~= true and (get(stored, "map") or get(stored, "mode")) then
        result.needsConfirm = true
        result.warnings[#result.warnings + 1] = "บริบทที่เก็บไว้ไม่ได้ยืนยันจากเมนูเกม"
    end

    if #result.missing > 0 then
        result.summary = "ยืนยันไม่ได้: " .. table.concat(result.missing, ", ")
    elseif result.needsConfirm then
        result.summary = "ยังยืนยันบริบทได้ไม่ครบ"
    else
        result.summary = "ตรวจบริบทแล้ว"
    end
    return result
end

function GameContext.buildBlockedMessage(gate)
    local lines = { "ไม่เริ่มเล่น เพราะบริบทเกมไม่ตรงกับ Macro:" }
    for _, item in ipairs(gate.blocked or {}) do
        lines[#lines + 1] = "• " .. tostring(item)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "กลับไปยังด่าน/โหมดที่ Macro บันทึกไว้ หรือบันทึก Macro ใหม่ในบริบทนี้"
    return table.concat(lines, "\n")
end

function GameContext.buildConfirmMessage(gate, stored)
    local first = "ยังยืนยันบริบทเกมไม่ได้"
    if #(gate.missing or {}) > 0 then
        first = first .. ": " .. table.concat(gate.missing, ", ")
    end
    local lines = { first }
    local shown = 0
    for _, warning in ipairs(gate.warnings or {}) do
        if shown >= 3 then
            break
        end
        lines[#lines + 1] = "• " .. tostring(warning)
        shown += 1
    end
    lines[#lines + 1] = "Macro: " .. GameContext.formatStored(stored, true)
    lines[#lines + 1] = "เกมไม่เปิดเผยชื่อแมพระหว่างเล่น — เล่นต่อเฉพาะเมื่อแน่ใจว่าอยู่ด่าน/โหมดเดียวกัน"
    return table.concat(lines, "\n")
end

function GameContext.buildUI(parent)
    local _, body = makeCard(parent, "สถานะเกมปัจจุบัน")
    UI.refs.gameContextRows = {}
    for _, key in ipairs({ "map", "mode", "event", "difficulty" }) do
        UI.refs.gameContextRows[key] = makeLabel(
            body,
            GameContext.labels[key] .. ": กำลังตรวจ...",
            11,
            Theme.muted,
            UDim2.new(1, 0, 0, 16)
        )
    end
    UI.refs.gameContextRows.actWave = makeLabel(
        body,
        "Act/Stage: ... • Wave: ...",
        11,
        Theme.muted,
        UDim2.new(1, 0, 0, 16)
    )
    UI.refs.gameContextStatus = makeLabel(
        body,
        "สถานะ: กำลังตรวจ... • อัปเดตล่าสุด: -",
        10,
        Theme.muted,
        UDim2.new(1, 0, 0, 16)
    )
    makeWrappedLabel(
        body,
        "ตรวจจาก GUI/ข้อความที่เกมแสดงจริงเท่านั้น • ชื่อแมพระหว่างเล่นเกมไม่เปิดเผย จึงแสดง Unknown และไม่เดา • เปิดเมนู MissionsV2 เพื่อให้ตรวจแมพ/โหมดได้",
        9,
        Theme.muted,
        32
    )
end

function GameContext.refreshUI(snapshot)
    local rows = UI.refs.gameContextRows
    if not rows then
        return
    end
    snapshot = snapshot or GameContext.current

    local function setRow(key, text, color)
        local label = rows[key]
        if label then
            label.Text = text
            label.TextColor3 = color
        end
    end

    if not snapshot then
        setRow("map", "แมพ: กำลังตรวจ...", Theme.muted)
        setRow("mode", "โหมด: กำลังตรวจ...", Theme.muted)
        setRow("event", "Event/Raid: กำลังตรวจ...", Theme.muted)
        setRow("difficulty", "ความยาก: กำลังตรวจ...", Theme.muted)
        setRow("actWave", "Act/Stage: ... • Wave: ...", Theme.muted)
        if UI.refs.gameContextStatus then
            UI.refs.gameContextStatus.Text = "สถานะ: กำลังตรวจ... • อัปเดตล่าสุด: -"
            UI.refs.gameContextStatus.TextColor3 = Theme.muted
        end
        return
    end

    for _, key in ipairs({ "map", "mode", "event", "difficulty" }) do
        local value = snapshot[key]
        local source = snapshot.sources and snapshot.sources[key]
        local conflict = snapshot.conflicts and snapshot.conflicts[key]
        if conflict then
            setRow(
                key,
                GameContext.labels[key] .. ": ข้อมูลขัดแย้งกัน (" .. tostring(conflict) .. ")",
                Theme.warning
            )
        elseif value then
            local suffix = source and ("  [" .. tostring(source) .. "]") or ""
            setRow(key, GameContext.labels[key] .. ": ตรวจพบ — " .. tostring(value) .. suffix, Theme.text)
        else
            setRow(key, GameContext.labels[key] .. ": Unknown — ยังตรวจจับไม่ได้", Theme.muted)
        end
    end

    local act = snapshot.act
    local wave = snapshot.wave
    local actConflict = snapshot.conflicts and snapshot.conflicts.act
    local waveConflict = snapshot.conflicts and snapshot.conflicts.wave
    local actText = act and ("ตรวจพบ — " .. tostring(act)) or "Unknown — ยังตรวจจับไม่ได้"
    local waveText = wave and ("ตรวจพบ — " .. tostring(wave)) or "Unknown — ยังตรวจจับไม่ได้"
    if actConflict then
        actText = "ข้อมูลขัดแย้งกัน"
    end
    if waveConflict then
        waveText = "ข้อมูลขัดแย้งกัน"
    end
    setRow(
        "actWave",
        "Act/Stage: " .. actText .. " • Wave: " .. waveText,
        (actConflict or waveConflict) and Theme.warning or ((act or wave) and Theme.text or Theme.muted)
    )

    if UI.refs.gameContextStatus then
        local detected = 0
        local conflict = false
        for _, key in ipairs(GameContext.fields) do
            if snapshot[key] then
                detected += 1
            end
            if snapshot.conflicts and snapshot.conflicts[key] then
                conflict = true
            end
        end
        local stateText
        local complete = snapshot.map ~= nil and snapshot.mode ~= nil
        if conflict then
            stateText = "ข้อมูลขัดแย้งกัน"
        elseif detected == 0 then
            stateText = "ยังตรวจจับไม่ได้"
        elseif complete then
            stateText = "ตรวจพบแมพ/โหมดจากเมนู"
        else
            stateText = "ตรวจได้บางส่วน — ฟิลด์ที่เหลือ Unknown"
        end
        local timeText = snapshot.capturedAt and os.date("%H:%M:%S", snapshot.capturedAt) or "-"
        UI.refs.gameContextStatus.Text = string.format("สถานะ: %s • อัปเดตล่าสุด: %s", stateText, timeText)
        UI.refs.gameContextStatus.TextColor3 = conflict and Theme.warning
            or (complete and Theme.success or (detected > 0 and Theme.warning or Theme.muted))
    end
end

function GameContext.poll(force)
    local now = clock()
    if force ~= true and now - (GameContext.lastPollAt or 0) < GameContext.pollInterval then
        return
    end
    GameContext.lastPollAt = now
    local snapshot = GameContext.safeCapture()
    GameContext.current = snapshot
    if State.mode == "recording" and snapshot.status ~= "unknown" then
        -- เก็บบริบทที่เกมเปิดเผยระหว่างบันทึก เช่น เปิดเมนู MissionsV2 ระหว่างเล่น
        State.recordingContext = GameContext.mergeContexts(State.recordingContext, snapshot)
    end
    pcall(GameContext.refreshUI, snapshot)
end

-- ============================================================================
-- 11) สร้าง GUI
-- ============================================================================

setMenuVisible = function(visible)
    visible = visible == true
    if not UI.main then
        return
    end
    if not visible and (State.pendingRecording or UI.modal) then
        -- ห้ามซ่อนเมนูขณะรอตั้งชื่อ/ยืนยันข้อมูล เพื่อไม่ให้ข้อมูลกู้คืนค้างโดยไม่มีทางเลือก
        return
    end
    UI.main.Visible = visible
    if UI.dock then
        UI.dock.Visible = not visible
    end
    State.menuVisible = visible
    if visible then
        State.autoHidden = false
        if type(App.refreshTransport) == "function" then
            pcall(App.refreshTransport)
        end
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

    local viewport = getViewport()
    local mobile = Cap.mobile == true
    UI.mobile = mobile

    local screenGui = newInstance("ScreenGui", {
        Name = GUI_NAME,
        ResetOnSpawn = false,
        IgnoreGuiInset = not mobile,
        DisplayOrder = 999999,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        Parent = parent,
    })
    UI.screenGui = screenGui

    local mainWidth = mobile and math.max(320, math.floor(viewport.X)) or 840
    local mainHeight = mobile and math.max(360, math.floor(viewport.Y)) or 600
    local initialX = mobile and 0 or math.max(8, math.floor((viewport.X - mainWidth) / 2))
    local initialY = mobile and 0 or math.max(8, math.floor((viewport.Y - mainHeight) / 2))

    local main = newInstance("Frame", {
        Name = "Main",
        Size = mobile and UDim2.fromScale(1, 1) or UDim2.fromOffset(mainWidth, mainHeight),
        Position = mobile and UDim2.fromOffset(0, 0) or UDim2.fromOffset(initialX, initialY),
        BackgroundColor3 = Theme.bg,
        BorderSizePixel = 0,
        ClipsDescendants = true,
        Parent = screenGui,
    })
    UI.main = main
    addCorner(main, mobile and 0 or 12)
    if not mobile then
        addStroke(main, Theme.stroke, 1)
    end

    local headerHeight = mobile and 46 or 62
    local footerHeight = mobile and 22 or 28
    local navHeight = mobile and 44 or 0
    local sidebarWidth = mobile and 0 or 176

    -- Header ---------------------------------------------------------------
    local header = newInstance("Frame", {
        Name = "Header",
        Size = UDim2.new(1, 0, 0, headerHeight),
        BackgroundColor3 = Theme.panel,
        BorderSizePixel = 0,
        Parent = main,
    })

    newInstance("Frame", {
        Size = UDim2.new(1, 0, 0, 1),
        Position = UDim2.new(0, 0, 1, -1),
        BackgroundColor3 = Theme.stroke,
        BorderSizePixel = 0,
        Parent = header,
    })

    local titleArea = newInstance("Frame", {
        Name = "DragArea",
        Size = mobile and UDim2.new(1, -60, 1, 0) or UDim2.new(0, 520, 1, 0),
        BackgroundTransparency = 1,
        Active = true,
        Parent = header,
    })

    newInstance("TextLabel", {
        Size = mobile and UDim2.new(1, -24, 0, 20) or UDim2.new(1, -20, 0, 24),
        Position = mobile and UDim2.fromOffset(12, 4) or UDim2.fromOffset(20, 8),
        BackgroundTransparency = 1,
        Font = FONT_TITLE,
        Text = APP_NAME,
        TextSize = mobile and 15 or 19,
        TextColor3 = Theme.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        Parent = titleArea,
    })

    if not mobile then
        newInstance("TextLabel", {
            Size = UDim2.new(1, -20, 0, 18),
            Position = UDim2.fromOffset(20, 33),
            BackgroundTransparency = 1,
            Font = FONT,
            Text = "บันทึก/เล่นซ้ำอินพุต • เก็บข้อมูลในเครื่อง • v" .. APP_VERSION,
            TextSize = 11,
            TextColor3 = Theme.muted,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Center,
            Parent = titleArea,
        })
    end

    local statusWidth = mobile and math.min(178, math.max(120, viewport.X - 236)) or 170
    local statusPill = newInstance("Frame", {
        Size = UDim2.fromOffset(statusWidth, 26),
        Position = mobile and UDim2.new(1, -(statusWidth + 52), 0, 10) or UDim2.new(1, -250, 0, 18),
        BackgroundColor3 = Theme.panel2,
        BorderSizePixel = 0,
        Parent = header,
    })
    addCorner(statusPill, 13)
    UI.statusStroke = addStroke(statusPill, Theme.success, 1)
    UI.statusStroke.Transparency = 0.25

    UI.statusDot = newInstance("Frame", {
        Size = UDim2.fromOffset(8, 8),
        Position = UDim2.new(0, 9, 0.5, -4),
        BackgroundColor3 = Theme.success,
        BorderSizePixel = 0,
        Parent = statusPill,
    })
    addCorner(UI.statusDot, 4)

    UI.statusText = newInstance("TextLabel", {
        Size = UDim2.new(1, -24, 1, 0),
        Position = UDim2.fromOffset(22, 0),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = "พร้อมใช้งาน",
        TextSize = mobile and 9 or 11,
        TextColor3 = Theme.success,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = statusPill,
    })

    local minimizeButton = makeButton(header, "—", UDim2.fromOffset(38, 34), Theme.panel3, function()
        setMenuVisible(false)
    end, { textSize = 17 })
    minimizeButton.Position = UDim2.new(1, -46, 0, mobile and 6 or 14)

    titleArea.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1
            and input.UserInputType ~= Enum.UserInputType.Touch then
            return
        end
        if UI.modal then
            return
        end
        State.dragging = true
        State.dragStart = input.Position
        State.dragOrigin = main.Position
        State.dragTouchId = input.UserInputType == Enum.UserInputType.Touch and input.Position or nil
    end)

    -- Navigation -----------------------------------------------------------
    if mobile then
        local navBar = newInstance("Frame", {
            Name = "MobileNav",
            Size = UDim2.new(1, 0, 0, navHeight),
            Position = UDim2.new(0, 0, 0, headerHeight),
            BackgroundColor3 = Theme.panel,
            BorderSizePixel = 0,
            Parent = main,
        })
        newInstance("Frame", {
            Size = UDim2.new(1, 0, 0, 1),
            Position = UDim2.new(0, 0, 1, -1),
            BackgroundColor3 = Theme.stroke,
            BorderSizePixel = 0,
            Parent = navBar,
        })

        local navLayout = Instance.new("UIListLayout")
        navLayout.FillDirection = Enum.FillDirection.Horizontal
        navLayout.Padding = UDim.new(0, 4)
        navLayout.SortOrder = Enum.SortOrder.LayoutOrder
        navLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        navLayout.VerticalAlignment = Enum.VerticalAlignment.Center
        navLayout.Parent = navBar

        local navItems = {
            { key = "macro", label = "Macro" },
            { key = "profiles", label = "Profiles" },
            { key = "auto", label = "Auto" },
            { key = "settings", label = "Settings" },
            { key = "logs", label = "Logs" },
        }
        for index, item in ipairs(navItems) do
            local button = newInstance("TextButton", {
                Size = UDim2.new(0.2, -4, 1, -6),
                BackgroundColor3 = Theme.panel,
                BorderSizePixel = 0,
                AutoButtonColor = false,
                Font = FONT,
                Text = item.label,
                TextSize = 11,
                TextColor3 = Theme.muted,
                TextXAlignment = Enum.TextXAlignment.Center,
                TextYAlignment = Enum.TextYAlignment.Center,
                Parent = navBar,
                LayoutOrder = index,
            })
            addCorner(button, 7)
            local bar = newInstance("Frame", {
                Size = UDim2.new(1, -14, 0, 2),
                Position = UDim2.new(0, 7, 1, -3),
                BackgroundColor3 = Theme.accent,
                BorderSizePixel = 0,
                Visible = false,
                Parent = button,
            })
            addCorner(bar, 1)
            button.MouseButton1Click:Connect(function()
                switchPage(item.key)
            end)
            UI.nav[item.key] = { button = button, bar = bar }
        end
    else
        local sidebar = newInstance("Frame", {
            Name = "Sidebar",
            Size = UDim2.new(0, sidebarWidth, 1, -(headerHeight + footerHeight)),
            Position = UDim2.new(0, 0, 0, headerHeight),
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
            Position = UDim2.fromOffset(14, 14),
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
            { key = "macro", label = "Macro" },
            { key = "profiles", label = "Profiles" },
            { key = "auto", label = "Auto" },
            { key = "settings", label = "Settings" },
            { key = "logs", label = "Logs" },
        }
        for index, item in ipairs(navItems) do
            local button = newInstance("TextButton", {
                Size = UDim2.new(1, -24, 0, 42),
                Position = UDim2.fromOffset(12, 40 + (index - 1) * 48),
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

            UI.nav[item.key] = { button = button, bar = bar }
        end

        newInstance("TextLabel", {
            Size = UDim2.new(1, -24, 0, 52),
            Position = UDim2.new(0, 12, 1, -66),
            BackgroundTransparency = 1,
            Font = FONT,
            Text = "F7  ซ่อน / แสดงเมนู\nF8  หยุดฉุกเฉิน (ซ่อน)\nข้อมูลแยกตามอุปกรณ์",
            TextSize = 10,
            TextColor3 = Theme.muted,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Top,
            TextWrapped = true,
            LineHeight = 1.2,
            Parent = sidebar,
        })
    end

    -- Footer ---------------------------------------------------------------
    local footer = newInstance("Frame", {
        Name = "Footer",
        Size = UDim2.new(1, 0, 0, footerHeight),
        Position = UDim2.new(0, 0, 1, -footerHeight),
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
        Size = UDim2.new(1, -120, 1, 0),
        Position = UDim2.fromOffset(12, 0),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = "โปรไฟล์: — / Macro: —",
        TextSize = mobile and 9 or 10,
        TextColor3 = Theme.muted,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = footer,
    })

    newInstance("TextLabel", {
        Size = UDim2.fromOffset(110, footerHeight),
        Position = UDim2.new(1, -118, 0, 0),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = "v" .. APP_VERSION,
        TextSize = 10,
        TextColor3 = Theme.muted,
        TextXAlignment = Enum.TextXAlignment.Right,
        TextYAlignment = Enum.TextYAlignment.Center,
        Parent = footer,
    })

    -- Page host ------------------------------------------------------------
    local pageHost = newInstance("Frame", {
        Name = "PageHost",
        Size = UDim2.new(1, -sidebarWidth, 1, -(headerHeight + navHeight + footerHeight)),
        Position = UDim2.new(0, sidebarWidth, 0, headerHeight + navHeight),
        BackgroundTransparency = 1,
        Parent = main,
    })
    applyPadding(pageHost, mobile and 8 or 10, 2, mobile and 8 or 16, mobile and 8 or 10)

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
        applyPadding(page, 0, 14, 0, 4)

        local layout = Instance.new("UIListLayout")
        layout.Padding = UDim.new(0, mobile and 8 or 10)
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.Parent = page

        local titleLabel = makeLabel(page, title, mobile and 17 or 20, Theme.text, UDim2.new(1, 0, 0, mobile and 22 or 26))
        makeLabel(page, subtitle, mobile and 10 or 12, Theme.muted, UDim2.new(1, 0, 0, mobile and 30 or 18))

        UI.pages[key] = {
            frame = page,
            title = titleLabel,
        }
        return page
    end

    local function makeButtonRow(parent, height)
        local row = addRow(parent, height or (mobile and 44 or 36))
        local layout = Instance.new("UIListLayout")
        layout.FillDirection = Enum.FillDirection.Horizontal
        layout.Padding = UDim.new(0, 8)
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.Parent = row
        return row
    end

    -- หน้า Macro -----------------------------------------------------------
    local macroPage = makePage("macro", "Macro", "เลือกโปรไฟล์/มาโคร บันทึก เล่นซ้ำ และจัดการขั้นตอน")
    do
        local _, body = makeCard(macroPage, "โปรไฟล์และ Macro ที่เลือก")
        UI.refs.macroProfileName = makeLabel(body, "ยังไม่มีโปรไฟล์", 17, Theme.text, UDim2.new(1, 0, 0, 24))
        UI.refs.macroName = makeLabel(body, "ยังไม่มี Macro", 13, Theme.accent, UDim2.new(1, 0, 0, 20))
        UI.refs.macroProfileMeta = makeLabel(body, "0 ขั้นตอน • 0:00", 11, Theme.muted, UDim2.new(1, 0, 0, 16))
        UI.refs.macroContext = makeWrappedLabel(body, "บริบท: ยังไม่มีข้อมูล", 9, Theme.muted, 26)

        local row = makeButtonRow(body)
        makeButton(row, "จัดการโปรไฟล์", UDim2.new(0.5, -4, 1, 0), Theme.panel3, function()
            switchPage("profiles")
        end, { textSize = 12 })
        UI.refs.saveNowButton = makeButton(row, "บันทึกตอนนี้", UDim2.new(0.5, -4, 1, 0), Theme.successDark, function()
            App.saveCurrentProfile()
        end, { textSize = 12 })
    end

    do
        local _, body = makeCard(macroPage, "บันทึกอินพุต")
        makeWrappedLabel(body, "กดเริ่มบันทึก แล้วรอ 3 วินาที • ค่าเริ่มต้นไม่บันทึกการขยับเมาส์/กล้องหรือปุ่มเดิน แต่ยังเก็บคลิกวาง/อัปเกรดและปุ่มจำเป็น • ปรับได้ใน Settings • หลังหยุดต้องตั้งชื่อ Macro", 11, Theme.muted, 52)

        local row = makeButtonRow(body, mobile and 44 or 38)
        local recordButton = makeButton(row, "●  เริ่มบันทึก", UDim2.new(0.58, -4, 1, 0), Theme.danger, function()
            App.requestRecordToggle()
        end, { textSize = mobile and 13 or 12 })
        UI.refs.recordButton = recordButton
        table.insert(UI.transport.record, recordButton)

        makeButton(row, mobile and "ซ่อนเมนู" or "ซ่อนเมนู (F7)", UDim2.new(0.42, -4, 1, 0), Theme.panel3, function()
            setMenuVisible(false)
        end, { textSize = 11 })

        UI.refs.recordInfo = makeLabel(body, "เวลา 0:00 • 0 ขั้นตอน", 11, Theme.muted, UDim2.new(1, 0, 0, 16))
        UI.refs.recordCapability = makeWrappedLabel(body, "กำลังตรวจสอบความสามารถ...", 10, Theme.muted, 42)
    end

    do
        local _, body = makeCard(macroPage, "เล่นซ้ำ")
        UI.refs.playbackSummary = makeLabel(body, "1 รอบ • พัก 2 วิ • ความเร็ว 1x", 12, Theme.text, UDim2.new(1, 0, 0, 18))

        UI.refs.loopsInput = makeNumberRow(body, "จำนวนรอบ", Settings.loops, {
            min = 1,
            max = 9999,
            integer = true,
        }, function(value)
            Settings.loops = value
            saveSettings()
            App.refreshTransport()
        end)

        UI.refs.infiniteToggle = makeToggleRow(body, "วนซ้ำไม่จำกัด", Settings.infinite, "เล่นซ้ำจนกว่าจะกดหยุด", function(value)
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

        local row = makeButtonRow(body, mobile and 46 or 38)
        local playButton = makeButton(row, "▶  เล่น", UDim2.new(0.40, -6, 1, 0), Theme.accent, function()
            App.playOrResume()
        end, { textSize = 12 })
        table.insert(UI.transport.play, playButton)

        local stopButton = makeButton(row, "⏹  หยุด", UDim2.new(0.32, -6, 1, 0), Theme.dangerDark, function()
            App.stopPlayback()
        end, { textSize = 12 })
        table.insert(UI.transport.stop, stopButton)

        local pauseButton = makeButton(row, "⏸  พัก", UDim2.new(0.28, -6, 1, 0), Theme.panel3, function()
            App.togglePause()
        end, { textSize = 11 })
        table.insert(UI.transport.pause, pauseButton)

        UI.refs.macroPlayInfo = makeLabel(body, "ยังไม่มีข้อมูล — เริ่มบันทึกก่อน", 11, Theme.muted, UDim2.new(1, 0, 0, 16))
        local _, fill = makeProgressBar(body)
        table.insert(UI.progressFills, fill)
        local progressText = makeLabel(body, "0 / 0", 10, Theme.muted, UDim2.new(1, 0, 0, 14), Enum.TextXAlignment.Right)
        table.insert(UI.progressTexts, progressText)

        makeWrappedLabel(body, "ปุ่มหยุดปกติอยู่ข้างปุ่มเล่น • ซ่อนเมนูได้โดยงานเบื้องหลังไม่หยุด • F8 เป็นทางลัดหยุดฉุกเฉินที่ซ่อนไว้", 10, Theme.muted, 32)
    end

    GameContext.buildUI(macroPage)

    do
        local _, body = makeCard(macroPage, "ขั้นตอนที่บันทึก")
        UI.refs.stepsInfo = makeLabel(body, "ยังไม่มีขั้นตอน", 10, Theme.muted, UDim2.new(1, 0, 0, 16))

        local scroll = newInstance("ScrollingFrame", {
            Size = UDim2.new(1, 0, 0, mobile and 210 or 180),
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
        applyPadding(scroll, 4, 4, 4, 4)
        addCorner(scroll, 8)
        addStroke(scroll, Theme.stroke, 1)
        local list = Instance.new("UIListLayout")
        list.Padding = UDim.new(0, 3)
        list.SortOrder = Enum.SortOrder.LayoutOrder
        list.Parent = scroll
        UI.refs.stepsScroll = scroll

        UI.refs.deleteStepsButton = makeButton(body, "ลบขั้นตอนที่เลือก", UDim2.new(1, 0, 0, 34), Theme.dangerDark, function()
            App.promptDeleteSelectedSteps()
        end, { textSize = 11 })

        local row = makeButtonRow(body, 34)
        UI.refs.selectAllStepsButton = makeButton(row, "เลือกที่แสดงทั้งหมด", UDim2.new(0.5, -4, 1, 0), Theme.panel3, function()
            App.selectAllRenderedSteps()
        end, { textSize = 10 })
        UI.refs.clearStepsButton = makeButton(row, "ยกเลิกการเลือก", UDim2.new(0.5, -4, 1, 0), Theme.panel3, function()
            App.clearStepSelection()
        end, { textSize = 10 })

        UI.refs.resetMacroButton = makeButton(body, "Reset Macro (ล้างเฉพาะ Macro นี้)", UDim2.new(1, 0, 0, 34), Theme.dangerDark, function()
            App.promptResetMacro()
        end, { textSize = 11 })
        makeWrappedLabel(body, "แสดงสูงสุด " .. tostring(STEPS_RENDER_LIMIT) .. " ขั้นตอนแรก • การลบมีผลทันทีหลังยืนยัน และจะสำรองไฟล์โปรไฟล์เป็น .bak", 10, Theme.muted, 28)
    end

    do
        local _, body = makeCard(macroPage, "เซ็ตตัวละครและออป")
        UI.refs.setStatus = makeWrappedLabel(body, "ยังไม่มีข้อมูลเซ็ต", 10, Theme.muted, 38)
        UI.refs.setButton = makeButton(body, "จัดเซ็ตตัวละครและออปเดิม", UDim2.new(1, 0, 0, mobile and 42 or 36), Theme.panel3, function()
            App.promptRestoreSet()
        end, { textSize = 12 })
        makeWrappedLabel(body, "ระบบจะบันทึกข้อมูลเซ็ตอัตโนมัติพร้อมการอัด โดยแยกตาม Macro • ถ้าไม่มี adapter ที่ตรวจสอบได้ จะแสดงว่าเป็นข้อมูลอนุมานจากอินพุตเท่านั้น", 10, Theme.muted, 40)
    end

    do
        local _, body = makeCard(macroPage, "ข้อมูลกู้คืน")
        UI.refs.recoveryLabel = makeWrappedLabel(body, "ไม่มีไฟล์กู้คืน", 10, Theme.muted, 30)
        local row = makeButtonRow(body, 34)
        UI.refs.recoveryButton = makeButton(row, "กู้คืนข้อมูลที่ค้างอยู่", UDim2.new(0.62, -4, 1, 0), Theme.warning, function()
            App.promptRecovery()
        end, { textSize = 10 })
        UI.refs.recoveryDeleteButton = makeButton(row, "ลบไฟล์กู้คืน", UDim2.new(0.38, -4, 1, 0), Theme.panel3, function()
            App.promptDeleteRecovery()
        end, { textSize = 10 })
    end

    -- หน้า Profiles --------------------------------------------------------
    local profilesPage = makePage("profiles", "Profiles", "สร้าง เลือก จัดการ Macro หลัก และย้ายข้อมูลระหว่างอุปกรณ์")
    do
        local _, body = makeCard(profilesPage, "รายการโปรไฟล์")
        local listScroll = newInstance("ScrollingFrame", {
            Size = UDim2.new(1, 0, 0, mobile and 190 or 210),
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

        local row = makeButtonRow(body)
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
        UI.refs.selectedProfileMeta = makeLabel(body, "0 Macro • 0 ขั้นตอน", 10, Theme.muted, UDim2.new(1, 0, 0, 16))

        local row = makeButtonRow(body, 34)
        UI.refs.profileSaveButton = makeButton(row, "บันทึก", UDim2.new(1 / 3, -6, 1, 0), Theme.successDark, function()
            App.saveCurrentProfile()
        end, { textSize = 10 })
        makeButton(row, "เปลี่ยนชื่อ", UDim2.new(1 / 3, -6, 1, 0), Theme.panel3, function()
            App.promptRenameProfile()
        end, { textSize = 10 })
        makeButton(row, "ส่งออก", UDim2.new(1 / 3, -6, 1, 0), Theme.panel3, function()
            App.exportCurrentProfile()
        end, { textSize = 10 })

        UI.refs.profileDeleteButton = makeButton(body, "ลบโปรไฟล์นี้", UDim2.new(1, 0, 0, 34), Theme.dangerDark, function()
            App.promptDeleteProfile()
        end, { textSize = 12 })

        makeWrappedLabel(body, "ลบโปรไฟล์จะลบไฟล์ของโปรไฟล์นี้เท่านั้น และสำรอง .bak ไว้ก่อน • Macro ของโปรไฟล์อื่นไม่ถูกแตะต้อง", 10, Theme.muted, 30)
    end

    do
        local _, body = makeCard(profilesPage, "Macro ในโปรไฟล์นี้")
        local listScroll = newInstance("ScrollingFrame", {
            Size = UDim2.new(1, 0, 0, 170),
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
        UI.refs.macroList = listScroll

        local row = makeButtonRow(body, 34)
        UI.refs.setMainMacroButton = makeButton(row, "ตั้งเป็น Macro หลัก", UDim2.new(0.5, -4, 1, 0), Theme.accent, function()
            App.promptSetMainMacro()
        end, { textSize = 10 })
        UI.refs.renameMacroButton = makeButton(row, "เปลี่ยนชื่อ Macro", UDim2.new(0.5, -4, 1, 0), Theme.panel3, function()
            App.promptRenameMacro()
        end, { textSize = 10 })

        UI.refs.deleteMacroButton = makeButton(body, "ลบ Macro ที่เลือก", UDim2.new(1, 0, 0, 32), Theme.dangerDark, function()
            App.promptDeleteMacro()
        end, { textSize = 11 })
        makeWrappedLabel(body, "Macro หลัก (★) ใช้เป็นค่าเริ่มต้นเมื่อไม่มีการเลือกที่ถูกต้อง • การเลือก Macro ล่าสุดถูกจำไว้ในโปรไฟล์ • ต้องมีอย่างน้อย 1 Macro (ใช้ Reset Macro เพื่อล้างข้อมูล)", 10, Theme.muted, 34)
    end

    -- หน้า Auto -----------------------------------------------------------
    local autoPage = makePage("auto", "Auto", "ฟังก์ชันอัตโนมัติที่ต้องใช้สถานะเกมจริงจาก adapter ที่ยืนยันแล้ว")
    do
        local _, body = makeCard(autoPage, "สถานะ Adapter")
        UI.refs.autoAdapterStatus = makeLabel(body, "Game adapter: ไม่ได้ติดตั้ง", 12, Theme.warning, UDim2.new(1, 0, 0, 20))
        UI.refs.autoAdapterDetail = makeWrappedLabel(body, "ยังไม่มี adapter ที่ตรวจสอบได้ จึงปิด Auto ทุกตัวและปุ่มคืนค่าเซ็ต • ไม่มีการสร้างสถานะเกมขึ้นเอง", 10, Theme.muted, 42)
        UI.refs.autoInputStatus = makeLabel(body, "Input: —", 10, Theme.muted, UDim2.new(1, 0, 0, 16))
    end

    do
        local _, body = makeCard(autoPage, "ฟังก์ชันอัตโนมัติ")
        UI.refs.autoStart = makeToggleRow(body, "Auto Start", Settings.auto.start, "เริ่ม Macro เมื่อ adapter ตรวจว่าเข้าแผนที่แล้ว", function(value)
            Settings.auto.start = value
            saveSettings()
            App.refreshAutoUI()
        end)
        UI.refs.autoRestart = makeToggleRow(body, "Auto Restart", Settings.auto.restart, "เริ่มด่านใหม่หลังตรวจว่าด่านจบ", function(value)
            Settings.auto.restart = value
            saveSettings()
            App.refreshAutoUI()
        end)
        UI.refs.autoNext = makeToggleRow(body, "Auto Next", Settings.auto.next, "ไปด่าน/รอบถัดไปหลังตรวจว่าด่านจบ", function(value)
            Settings.auto.next = value
            saveSettings()
            App.refreshAutoUI()
        end)
        UI.refs.autoExp = makeToggleRow(body, "Auto EXP Evolution", Settings.auto.exp, "Evolution 4★/5★ → 6★ ตามเงื่อนไขที่ adapter ตรวจสอบ", function(value)
            Settings.auto.exp = value
            saveSettings()
            App.refreshAutoUI()
        end)
        UI.refs.autoFeatureNotes = makeWrappedLabel(body, "กำลังตรวจสอบความสามารถของ adapter...", 10, Theme.muted, 52)
        makeWrappedLabel(body, "ทุกคำสั่งมี lock ป้องกันคำสั่งซ้อน • ถ้า adapter ตรวจวัตถุดิบ/เงื่อนไขไม่ผ่าน ระบบจะไม่สั่ง Evolution • Auto Restart/Next จะหยุด Macro เมื่อ adapter ยืนยันจบด่าน แล้วส่งคำสั่งเปลี่ยนด่าน; เปิด Auto Start ร่วมเพื่อเริ่ม Macro เมื่อเข้าด่านถัดไป", 10, Theme.muted, 44)
    end

    do
        local _, body = makeCard(autoPage, "เป้าหมาย Auto EXP Evolution")
        makeLabel(body, "ชื่อ/ID ตัวละครเป้าหมาย", 11, Theme.muted, UDim2.new(1, 0, 0, 16))
        local box = newInstance("TextBox", {
            Size = UDim2.new(1, 0, 0, 34),
            BackgroundColor3 = Theme.dark,
            BorderSizePixel = 0,
            Font = FONT,
            Text = Settings.auto.target,
            PlaceholderText = "พิมพ์ชื่อหรือ ID ที่ adapter รองรับ",
            PlaceholderColor3 = Theme.muted,
            TextSize = 12,
            TextColor3 = Theme.text,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Center,
            ClearTextOnFocus = false,
            Parent = body,
        })
        box.LayoutOrder = nextLayoutOrder(body)
        applyPadding(box, 0, 0, 10, 10)
        addCorner(box, 6)
        addStroke(box, Theme.stroke, 1)
        box.FocusLost:Connect(function()
            Settings.auto.target = trimText(box.Text):sub(1, 80)
            saveSettings()
            App.refreshAutoUI()
        end)
        UI.refs.expTargetBox = box

        local row = makeButtonRow(body, 34)
        UI.refs.expGoal4 = makeButton(row, "จาก 4★ → 6★", UDim2.new(0.5, -4, 1, 0), Theme.panel3, function()
            Settings.auto.goal = 4
            saveSettings()
            App.refreshAutoUI()
        end, { textSize = 10 })
        UI.refs.expGoal5 = makeButton(row, "จาก 5★ → 6★", UDim2.new(0.5, -4, 1, 0), Theme.panel3, function()
            Settings.auto.goal = 5
            saveSettings()
            App.refreshAutoUI()
        end, { textSize = 10 })
        makeWrappedLabel(body, "ระดับเป้าหมายต้องเป็น 6★ ตามที่ระบุ • adapter ต้องเป็นผู้ตรวจว่ามีวัตถุดิบและตัวละครเป้าหมายจริงก่อนทำ", 10, Theme.muted, 30)
    end

    do
        local _, body = makeCard(autoPage, "สถานะ Auto")
        UI.refs.autoStatus = makeWrappedLabel(body, "ยังไม่ทำงาน", 10, Theme.muted, 38)
        UI.refs.autoLastAction = makeInfoRow(body, "คำสั่งล่าสุด", "—")
        UI.refs.autoLastError = makeInfoRow(body, "ข้อผิดพลาดล่าสุด", "—")
        makeWrappedLabel(body, "Auto ทำงานเบื้องหลังได้แม้ซ่อนเมนู • Auto Next/Restart และ Auto EXP จะหยุด Macro เมื่อ adapter ยืนยันสถานะ แล้วจึงสั่งงาน • ไม่ทำงานถ้าไม่มี adapter หรือกำลังบันทึก", 10, Theme.muted, 40)
    end

    -- หน้า Settings -------------------------------------------------------
    local settingsPage = makePage("settings", "Settings", "พฤติกรรม Macro, AFK Guard, พิกัด และข้อมูลระบบ")
    do
        local _, body = makeCard(settingsPage, "การทำงาน")
        UI.refs.noMouseMoveToggle = makeToggleRow(body, "เมาส์จริงอยู่กับที่ (Virtual Input)", Settings.noMouseMove ~= false, "เล่นซ้ำโดยไม่ย้ายเมาส์ OS • ถ้าอินพุตไม่ถึงเกม ให้ปิดเพื่อกลับไปใช้ executor แบบเดิม (เมาส์จะขยับ)", function(value)
            if State.mode == "playing" or State.mode == "paused" then
                showNotice(
                    "สลับอินพุตระหว่างเล่นไม่ได้",
                    "หยุด Macro ก่อนเปลี่ยน backend อินพุต\nเพื่อไม่ให้เมาส์ค้างหรือคลิกผิดตำแหน่ง"
                )
                if UI.refs.noMouseMoveToggle then
                    UI.refs.noMouseMoveToggle.set(Settings.noMouseMove ~= false, false)
                end
                return
            end
            Settings.noMouseMove = value
            saveSettings()
            Input.init()
            if UI.refs.noMouseMoveToggle then
                UI.refs.noMouseMoveToggle.set(Settings.noMouseMove ~= false, false)
            end
            if UI.refs.infoInput then
                UI.refs.infoInput.Text = Cap.inputLabel
                UI.refs.infoInput.TextColor3 = Cap.input == "none" and Theme.danger
                    or ((Cap.input == "real" or Cap.input == "virtual") and Theme.warning or Theme.success)
            end
            if UI.refs.autoInputStatus then
                UI.refs.autoInputStatus.Text = "Input: " .. Cap.inputLabel
                UI.refs.autoInputStatus.TextColor3 = Cap.input == "none" and Theme.danger
                    or ((Cap.input == "real" or Cap.input == "virtual") and Theme.warning or Theme.success)
            end
            if UI.refs.recordCapability then
                UI.refs.recordCapability.Text = "Input: " .. Cap.inputLabel .. " • " .. Cap.inputDetail
                UI.refs.recordCapability.TextColor3 = Theme.muted
            end
            Log.add("info", "อินพุตที่ใช้: " .. Input.describe() .. (Input.isVirtual() and " (ไม่ย้ายเมาส์จริง)" or ""))
        end)

        UI.refs.guardFocusToggle = makeToggleRow(body, "พักเมื่อเกมไม่ active", Settings.guardFocus, "ถ้าปิด การเล่นจะดำเนินต่อ แต่ executor อาจไม่ส่งอินพุต", function(value)
            Settings.guardFocus = value
            saveSettings()
        end)

        UI.refs.autosaveToggle = makeToggleRow(body, "สำรองการอัดทุก 5 วินาที", Settings.autosave, "สร้างไฟล์ recovery ระหว่างบันทึกเพื่อกู้คืนหากสคริปต์หยุด", function(value)
            Settings.autosave = value
            saveSettings()
        end)

        -- เมนูหลักบังจุดคลิกเกือบทั้งจอ จึงต้องซ่อนระหว่างเล่น/บันทึกเสมอ
        -- เปลี่ยนจาก toggle เป็นแถวข้อมูลเพื่อไม่ให้ผู้ใช้เข้าใจว่าปิดได้
        UI.refs.autoHideInfo = makeInfoRow(body, "ซ่อนเมนูระหว่างเล่น/บันทึก", "บังคับเปิด")

        UI.refs.recordMotionToggle = makeToggleRow(body, "บันทึกการขยับเมาส์/กล้อง", Settings.recordMotion, "ปิดเป็นค่าเริ่มต้น • เปิดเฉพาะเมื่อจำเป็น เพราะการเล่นซ้ำอาจเลื่อนเมาส์หรือหมุนกล้อง", function(value)
            Settings.recordMotion = value
            saveSettings()
        end)

        UI.refs.recordMovementKeysToggle = makeToggleRow(body, "บันทึกปุ่มเดิน WASD/ลูกศร", Settings.recordMovementKeys, "ปิดเป็นค่าเริ่มต้น • ปุ่มเดินและกระโดดจะไม่ถูกบันทึกหรือเล่นซ้ำ", function(value)
            Settings.recordMovementKeys = value
            saveSettings()
        end)

        UI.refs.worldAnchorToggle = makeToggleRow(body, "ยึดคลิกบนแผนที่กับจุดในโลก (ทดลอง)", Settings.worldAnchor, "เฉพาะคลิกในโลกเกมที่ไม่ใช่ UI • ถ้ายืนยันตำแหน่ง/เป้าหมายไม่ได้จะหยุดพร้อมแจ้งเตือน • ยังต้องทดสอบในเกมจริง", function(value)
            Settings.worldAnchor = value
            saveSettings()
        end)

        UI.refs.worldFallbackToggle = makeToggleRow(body, "ใช้พิกัดหน้าจอเดิมเมื่อจุดโลกอยู่นอกจอ", Settings.worldFallback, "ทางเลือกสำรองเมื่อกล้องตอนเล่นไม่ตรงกับตอนบันทึก • อาจคลิกผิดตำแหน่ง • ค่าเริ่มต้นปิด", function(value)
            Settings.worldFallback = value
            saveSettings()
        end)

        UI.refs.worldThroughToggle = makeToggleRow(body, "คลิกจุดวางเดิมแม้มีวัตถุอยู่บนจุด", Settings.worldThrough == true, "ใช้เฉพาะเมื่อเกมวางซ้อนจุดเดิมได้ • เสี่ยงคลิกถูกยูนิตแทนการวาง • ค่าเริ่มต้นปิด", function(value)
            Settings.worldThrough = value
            saveSettings()
        end)

        UI.refs.scaleCoordsToggle = makeToggleRow(body, "ปรับพิกัดตามขนาดหน้าจอ", Settings.scaleCoords, "ใช้เมื่อย้าย Macro ระหว่าง PC/มือถือ (ยังไม่ยืนยันความแม่นยำ)", function(value)
            Settings.scaleCoords = value
            saveSettings()
        end)
    end

    do
        local _, body = makeCard(settingsPage, "AFK Guard")
        UI.refs.afkToggle = makeToggleRow(body, "เปิดระบบกัน AFK", Settings.afkEnabled, "ทำงานทุก 5 นาที เมื่อ Macro ว่าง", function(value)
            App.setAfkEnabled(value)
        end)
        UI.refs.afkStatus = makeLabel(body, "ปิดอยู่", 12, Theme.muted, UDim2.new(1, 0, 0, 18))
        UI.refs.afkStopButton = makeButton(body, "หยุดระบบ AFK", UDim2.new(1, 0, 0, 32), Theme.panel3, function()
            App.setAfkEnabled(false)
        end, { textSize = 11 })
        makeWrappedLabel(body, "ขยับเมาส์เสมือนเล็กน้อยทุก 5 นาทีเมื่อหน้าต่างเกม active และ Macro ว่าง • VirtualInput/VIM รองรับ • VirtualUser backend ไม่รองรับ AFK", 10, Theme.muted, 42)
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
        makeWrappedLabel(body, "ค่าเริ่มต้น 0 ทั้งสองแกน • การสเกลพิกัดข้ามอุปกรณ์เป็นการประมาณ ไม่ใช่การรับประกันตำแหน่งคลิก", 10, Theme.muted, 28)
    end

    do
        local _, body = makeCard(settingsPage, "ข้อมูลระบบ")
        UI.refs.infoExecutor = makeInfoRow(body, "Executor", "—")
        UI.refs.infoPlatform = makeInfoRow(body, "แพลตฟอร์ม", "—")
        UI.refs.infoInput = makeInfoRow(body, "API อินพุต", "—")
        UI.refs.infoFiles = makeInfoRow(body, "API ไฟล์", "—")
        UI.refs.infoClipboard = makeInfoRow(body, "คลิปบอร์ด", "—")
        UI.refs.infoGui = makeInfoRow(body, "ตำแหน่ง GUI", "—")
        UI.refs.infoAdapter = makeInfoRow(body, "Game adapter", "—")
        UI.refs.infoPath = makeInfoRow(body, "ที่เก็บข้อมูล", ROOT_DIR .. "/")
        UI.refs.infoRecovery = makeInfoRow(body, "ไฟล์กู้คืน", "—")
        makeWrappedLabel(body, "ข้อมูลแยกตามอุปกรณ์ • GitHub Raw เป็นเพียงลิงก์โหลดสคริปต์ ไม่ใช่ตัวซิงก์โปรไฟล์ • ไม่มีการอัปเดตอัตโนมัติ", 10, Theme.muted, 34)
        UI.refs.removeAdapterButton = makeButton(body, "ถอด Game Adapter", UDim2.new(1, 0, 0, 30), Theme.panel3, function()
            App.removeGameAdapter()
        end, { textSize = 10 })
    end

    do
        local _, body = makeCard(settingsPage, "ย้ายข้อมูลระหว่างอุปกรณ์")
        local row = makeButtonRow(body, 34)
        makeButton(row, "ส่งออกโปรไฟล์", UDim2.new(0.5, -4, 1, 0), Theme.panel3, function()
            App.exportCurrentProfile()
        end, { textSize = 11 })
        makeButton(row, "นำเข้า JSON", UDim2.new(0.5, -4, 1, 0), Theme.panel3, function()
            App.promptImportProfile()
        end, { textSize = 11 })
        makeWrappedLabel(body, "ส่งออกเป็น JSON แล้วนำเข้าในอุปกรณ์อีกเครื่องได้ • ต้องตรวจสอบจำนวน Macro/ขั้นตอนหลังนำเข้าเสมอ", 10, Theme.muted, 28)
    end

    do
        local _, body = makeCard(settingsPage, "จัดการสคริปต์")
        local row = makeButtonRow(body, 34)
        makeButton(row, "รีเซ็ตการตั้งค่า", UDim2.new(0.5, -4, 1, 0), Theme.panel3, function()
            App.promptResetSettings()
        end, { textSize = 10 })
        makeButton(row, "ปิดสคริปต์", UDim2.new(0.5, -4, 1, 0), Theme.dangerDark, function()
            App.promptCloseScript()
        end, { textSize = 10 })
        makeWrappedLabel(body, "ปิดสคริปต์จะหยุดงาน ปล่อยปุ่มที่ค้าง และลบ GUI • ถ้ามีการอัดที่ยังไม่ตั้งชื่อ ระบบจะเก็บ recovery ไว้", 10, Theme.muted, 28)
    end

    -- หน้า Logs -----------------------------------------------------------
    local logsPage = makePage("logs", "Logs", "ประวัติการทำงาน ข้อผิดพลาด และสถานะความสามารถ")
    do
        local _, body = makeCard(logsPage, "สถานะปัจจุบัน")
        UI.refs.statusPageStatus = makeInfoRow(body, "สถานะ", "พร้อมใช้งาน", Theme.success)
        UI.refs.statusPageProfile = makeInfoRow(body, "โปรไฟล์", "—")
        UI.refs.statusPageMacro = makeInfoRow(body, "Macro", "—")
        UI.refs.statusPageStep = makeInfoRow(body, "ขั้นตอน", "ยังไม่เริ่ม")
        UI.refs.statusPageAfk = makeInfoRow(body, "AFK Guard", "ปิดอยู่")
        UI.refs.statusPageAuto = makeInfoRow(body, "Auto", "ปิด")
        UI.refs.statusPageAdapter = makeInfoRow(body, "Adapter", "ไม่ได้ติดตั้ง")
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
            Size = UDim2.new(1, 0, 0, mobile and 270 or 310),
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

    -- Dock (visible while menu hidden) -------------------------------------
    local dockWidth = math.min(374, math.max(280, viewport.X - 16))
    local dock = newInstance("Frame", {
        Name = "Dock",
        Size = UDim2.fromOffset(dockWidth, 50),
        Position = UDim2.new(0.5, 0, 0, mobile and 6 or 10),
        AnchorPoint = Vector2.new(0.5, 0),
        BackgroundColor3 = Theme.panel,
        BorderSizePixel = 0,
        Visible = false,
        Parent = screenGui,
    })
    addCorner(dock, 10)
    addStroke(dock, Theme.stroke, 1)
    UI.dock = dock

    local dockPlay = makeButton(dock, "▶", UDim2.fromOffset(40, 36), Theme.accent, function()
        App.playOrResume()
    end, { textSize = 15 })
    dockPlay.Position = UDim2.fromOffset(7, 7)
    table.insert(UI.transport.play, dockPlay)
    UI.dockPlay = dockPlay

    local dockStop = makeButton(dock, "■", UDim2.fromOffset(40, 36), Theme.danger, function()
        App.requestStop()
    end, { textSize = 14 })
    dockStop.Position = UDim2.fromOffset(51, 7)
    table.insert(UI.transport.stop, dockStop)
    UI.dockStop = dockStop

    newInstance("TextLabel", {
        Size = UDim2.fromOffset(80, 14),
        Position = UDim2.fromOffset(100, 5),
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
        Size = UDim2.new(1, -174, 0, 20),
        Position = UDim2.fromOffset(100, 20),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = "พร้อมใช้งาน",
        TextSize = 11,
        TextColor3 = Theme.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = dock,
    })

    local dockMenuButton = makeButton(dock, "เมนู", UDim2.fromOffset(62, 34), Theme.panel3, function()
        setMenuVisible(true)
    end, { textSize = 11 })
    dockMenuButton.Position = UDim2.new(1, -69, 0, 8)

    switchPage("macro")
    return true
end

-- 12) รีเฟรช UI
-- ============================================================================

local AfkGuard = {
    lastNudge = nil,
    lastCheck = 0,
    lastResult = "",
}

local Auto = {
    lastAction = "",
    lastError = "",
    lastState = nil,
    lastCheck = 0,
    lockUntil = 0,
    failures = {},
    lastAutoStartAt = 0,
}

local function formatEventTime(seconds)
    seconds = math.max(0, numberOr(seconds, 0))
    local minutes = math.floor(seconds / 60)
    local secs = seconds - minutes * 60
    return string.format("%d:%06.3f", minutes, secs)
end

local function eventSummary(index, event)
    local text = eventLabel(event)
    if event.type == "mouseMove" or event.type == "mouseDown" or event.type == "mouseUp" then
        text = string.format("%s (%d, %d)", text, math.floor(numberOr(event.x, 0)), math.floor(numberOr(event.y, 0)))
    elseif event.type == "keyDown" or event.type == "keyUp" then
        text = text .. " [" .. tostring(event.key or "?") .. "]"
    elseif event.type == "wheel" then
        text = text .. " " .. formatNumber(event.z)
    end
    return string.format("%03d  %s  %s", index, formatEventTime(event.t), text)
end

local function countSelectedSteps()
    local count = 0
    for _ in pairs(State.selectedSteps) do
        count += 1
    end
    return count
end

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
    if State.pendingRecording then
        stepText = "รอตั้งชื่อ Macro"
    elseif State.finished then
        stepText = "เล่นจบแล้ว"
    elseif index <= 0 then
        stepText = "ยังไม่เริ่ม"
    else
        local event = (State.playbackEvents and State.playbackEvents[index]) or Profiles.events[index]
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
        if State.pendingRecording then
            UI.refs.macroPlayInfo.Text = "รอตั้งชื่อ Macro — ยังเล่นไม่ได้"
        elseif State.finished then
            UI.refs.macroPlayInfo.Text = string.format("เล่นจบแล้ว • %d/%d", index, total)
        elseif index > 0 then
            UI.refs.macroPlayInfo.Text = string.format("รอบ %d/%s • ขั้นตอน %d/%d", loop, loopsDisplay, index, total)
        elseif total > 0 then
            UI.refs.macroPlayInfo.Text = string.format("พร้อมเล่น • %d ขั้นตอน", total)
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
    local macro = selectedMacro()
    if macro then
        table.insert(extras, macro.name)
    end
    if State.pendingRecording then
        table.insert(extras, "รอตั้งชื่อ")
    end
    if Settings.afkEnabled then
        table.insert(extras, "AFK")
    end
    if App.gameAdapter and (Settings.auto.start or Settings.auto.restart or Settings.auto.next or Settings.auto.exp) then
        table.insert(extras, "Auto")
    end
    local text = State.statusText
    if #extras > 0 then
        text = text .. " • " .. table.concat(extras, " • ")
    end
    UI.dockStatus.Text = text
end

function App.updateAfkUI()
    if not Cap.afk and Settings.afkEnabled then
        Settings.afkEnabled = false
        saveSettings()
    end
    if UI.refs.afkToggle then
        UI.refs.afkToggle.setEnabled(Cap.afk)
        UI.refs.afkToggle.set(Settings.afkEnabled, false)
    end

    local text = "ปิดอยู่"
    local color = Theme.muted
    if not Cap.afk then
        text = "ไม่รองรับ: backend นี้ไม่มี mousemoverel ที่ปลอดภัย"
        color = Theme.danger
    elseif Settings.afkEnabled then
        if not Input.available() then
            text = "เปิด • API อินพุตไม่พร้อม"
            color = Theme.danger
        elseif State.mode ~= "idle" or State.pendingRecording then
            text = "เปิด • รอ Macro ว่าง"
            color = Theme.warning
        elseif AfkGuard.lastNudge then
            text = "เปิด • ขยับล่าสุด " .. os.date("%H:%M:%S", AfkGuard.lastNudge) .. " • ทุก 5 นาที"
            color = Theme.success
        else
            text = "เปิด • รอรอบ 5 นาที"
            color = Theme.success
        end
    end

    if UI.refs.afkStatus then
        UI.refs.afkStatus.Text = text
        UI.refs.afkStatus.TextColor3 = color
    end
    if UI.refs.afkStopButton then
        setButtonEnabled(UI.refs.afkStopButton, Settings.afkEnabled and Cap.afk)
    end
    if UI.refs.statusPageAfk then
        UI.refs.statusPageAfk.Text = text
        UI.refs.statusPageAfk.TextColor3 = color
    end
    if type(App.updateDockStatus) == "function" then
        pcall(App.updateDockStatus)
    end
end

local function autoFeatureSupport(key)
    local adapter = App.gameAdapter
    if not adapter then
        return false, "ยังไม่มี adapter"
    end
    local caps = adapter.capabilities or {}
    if key == "start" then
        if caps.autoStart ~= true then
            return false, "adapter ไม่รองรับ autoStart"
        end
        if caps.mapState ~= true then
            return false, "adapter ไม่ได้ตรวจสถานะแผนที่"
        end
        return true
    elseif key == "restart" then
        if caps.autoRestart ~= true then
            return false, "adapter ไม่รองรับ autoRestart"
        end
        if caps.mapState ~= true then
            return false, "adapter ไม่ได้ตรวจสถานะด่าน"
        end
        return true
    elseif key == "next" then
        if caps.autoNext ~= true then
            return false, "adapter ไม่รองรับ autoNext"
        end
        if caps.mapState ~= true then
            return false, "adapter ไม่ได้ตรวจสถานะด่าน"
        end
        return true
    elseif key == "exp" then
        if caps.autoExp ~= true then
            return false, "adapter ไม่รองรับ autoExp"
        end
        return true
    end
    return false, "ไม่รู้จักฟังก์ชัน"
end

function App.refreshAutoUI()
    local adapter = App.gameAdapter
    local adapterText, adapterColor = App.getAdapterStatus()
    if UI.refs.autoAdapterStatus then
        UI.refs.autoAdapterStatus.Text = "Game adapter: " .. adapterText
        UI.refs.autoAdapterStatus.TextColor3 = adapterColor
    end
    if UI.refs.autoAdapterDetail then
        if adapter then
            local caps = {}
            for _, key in ipairs({ "mapState", "restoreSet", "captureSet", "autoStart", "autoRestart", "autoNext", "autoExp" }) do
                if adapter.capabilities and adapter.capabilities[key] == true then
                    table.insert(caps, key)
                end
            end
            UI.refs.autoAdapterDetail.Text = "ความสามารถที่ประกาศ: " .. (#caps > 0 and table.concat(caps, ", ") or "ไม่มี") .. " • adapter เป็นผู้รับผิดชอบตรวจสอบสถานะ/วัตถุดิบเอง"
            UI.refs.autoAdapterDetail.TextColor3 = Theme.muted
        else
            UI.refs.autoAdapterDetail.Text = "ยังไม่มี adapter ที่ตรวจสอบได้ จึงปิด Auto ทุกตัวและปุ่มคืนค่าเซ็ต • ไม่มีการสร้างสถานะเกมขึ้นเอง"
            UI.refs.autoAdapterDetail.TextColor3 = Theme.muted
        end
    end
    if UI.refs.autoInputStatus then
        UI.refs.autoInputStatus.Text = "Input: " .. Cap.inputLabel
            .. (Cap.input == "real" and " • เมาส์จริงจะขยับ" or (Cap.input == "virtual" and " • ยังไม่ยืนยันบน Delta" or ""))
        UI.refs.autoInputStatus.TextColor3 = Cap.input == "none" and Theme.danger
            or ((Cap.input == "real" or Cap.input == "virtual") and Theme.warning or Theme.success)
    end

    local support = {}
    local supportReasons = {}
    for _, key in ipairs({ "start", "restart", "next", "exp" }) do
        local ok, reason = autoFeatureSupport(key)
        support[key] = ok == true
        supportReasons[key] = reason
    end
    local changed = false
    for key, toggle in pairs({
        start = UI.refs.autoStart,
        restart = UI.refs.autoRestart,
        next = UI.refs.autoNext,
        exp = UI.refs.autoExp,
    }) do
        local supported = support[key]
        if toggle then
            toggle.setEnabled(supported)
            if not supported and Settings.auto[key] then
                Settings.auto[key] = false
                changed = true
            end
            toggle.set(Settings.auto[key] == true, false)
        end
        Auto.failures[key] = Auto.failures[key] or 0
    end
    if changed then
        saveSettings()
    end

    if UI.refs.autoFeatureNotes then
        local labels = {
            start = "Auto Start",
            restart = "Auto Restart",
            next = "Auto Next",
            exp = "Auto EXP",
        }
        local missing = {}
        for _, key in ipairs({ "start", "restart", "next", "exp" }) do
            if not support[key] then
                table.insert(missing, labels[key] .. ": " .. tostring(supportReasons[key] or "ไม่รองรับ"))
            end
        end
        if #missing > 0 then
            UI.refs.autoFeatureNotes.Text = "ฟังก์ชันที่ยังใช้ไม่ได้ — " .. table.concat(missing, " • ")
            UI.refs.autoFeatureNotes.TextColor3 = adapter and Theme.warning or Theme.muted
        else
            UI.refs.autoFeatureNotes.Text = "adapter ประกาศรองรับ Auto ครบทุกฟังก์ชัน — ยังต้องตรวจสอบกับเกมจริงก่อนเชื่อถือผล"
            UI.refs.autoFeatureNotes.TextColor3 = Theme.success
        end
    end

    local goalEnabled = adapter ~= nil and adapter.capabilities ~= nil and adapter.capabilities.autoExp == true
    if UI.refs.expTargetBox then
        UI.refs.expTargetBox.TextEditable = goalEnabled
        UI.refs.expTargetBox.TextColor3 = goalEnabled and Theme.text or Theme.muted
        UI.refs.expTargetBox.Text = Settings.auto.target or ""
    end
    if UI.refs.expGoal4 then
        setButtonEnabled(UI.refs.expGoal4, goalEnabled)
        UI.refs.expGoal4.BackgroundColor3 = Settings.auto.goal == 4 and Theme.accent or Theme.panel3
    end
    if UI.refs.expGoal5 then
        setButtonEnabled(UI.refs.expGoal5, goalEnabled)
        UI.refs.expGoal5.BackgroundColor3 = Settings.auto.goal == 5 and Theme.accent or Theme.panel3
    end
    if UI.refs.removeAdapterButton then
        setButtonEnabled(UI.refs.removeAdapterButton, adapter ~= nil)
    end

    local enabledCount = 0
    for _, key in ipairs({ "start", "restart", "next", "exp" }) do
        if Settings.auto[key] then
            enabledCount += 1
        end
    end
    if UI.refs.autoStatus then
        if not adapter then
            UI.refs.autoStatus.Text = "ปิดทุกฟังก์ชัน: ยังไม่มี adapter ที่ยืนยันสถานะเกม • ไม่มีการเดาสถานะหรือกดแทน"
            UI.refs.autoStatus.TextColor3 = Theme.warning
        elseif enabledCount == 0 then
            UI.refs.autoStatus.Text = "adapter พร้อม แต่ยังไม่ได้เปิดฟังก์ชัน Auto • ตรวจความสามารถของ adapter ก่อนเปิด"
            UI.refs.autoStatus.TextColor3 = Theme.muted
        else
            UI.refs.autoStatus.Text = string.format("ทำงานทุก %d วิ • เปิด %d ฟังก์ชัน • มี lock กันคำสั่งซ้อน", AUTO_TICK_SECONDS, enabledCount)
            UI.refs.autoStatus.TextColor3 = Theme.success
        end
    end
    if UI.refs.autoLastAction then
        UI.refs.autoLastAction.Text = Auto.lastAction ~= "" and Auto.lastAction or "—"
    end
    if UI.refs.autoLastError then
        UI.refs.autoLastError.Text = Auto.lastError ~= "" and Auto.lastError or "—"
        UI.refs.autoLastError.TextColor3 = Auto.lastError ~= "" and Theme.danger or Theme.text
    end
    if UI.refs.statusPageAuto then
        UI.refs.statusPageAuto.Text = enabledCount > 0 and ("เปิด " .. tostring(enabledCount) .. " ฟังก์ชัน") or "ปิด"
        UI.refs.statusPageAuto.TextColor3 = enabledCount > 0 and Theme.success or Theme.muted
    end
    if UI.refs.statusPageAdapter then
        UI.refs.statusPageAdapter.Text = adapterText
        UI.refs.statusPageAdapter.TextColor3 = adapterColor
    end
    if type(App.updateDockStatus) == "function" then
        pcall(App.updateDockStatus)
    end
end

function App.refreshProfileSummary()
    local meta = selectedProfileMeta()
    local macro = selectedMacro()
    local name = meta and meta.name or "ยังไม่มีโปรไฟล์"
    local macroName = macro and macro.name or "ยังไม่มี Macro"
    local count = macro and #macro.events or 0
    local duration = macro and macro.duration or 0
    local macroCount = Profiles.data and #Profiles.data.macros or 0
    local mainMarker = macro and Profiles.data and macro.id == Profiles.data.mainMacroId and "  ★ Macro หลัก" or ""
    local metaText = string.format("%d ขั้นตอน • %s • %d Macro", count, formatDuration(duration), macroCount)

    if UI.refs.macroProfileName then
        UI.refs.macroProfileName.Text = name
    end
    if UI.refs.macroName then
        UI.refs.macroName.Text = macroName .. mainMarker
    end
    if UI.refs.macroProfileMeta then
        UI.refs.macroProfileMeta.Text = metaText
    end
    if UI.refs.macroContext then
        local context = macro and macro.context or nil
        UI.refs.macroContext.Text = "บริบท: " .. GameContext.formatStored(context, true)
        local incomplete = type(context) == "table" and (not context.map or not context.mode)
        UI.refs.macroContext.TextColor3 = incomplete and Theme.warning or Theme.muted
    end
    if UI.refs.selectedProfileName then
        UI.refs.selectedProfileName.Text = name
    end
    if UI.refs.selectedProfileMeta then
        UI.refs.selectedProfileMeta.Text = string.format("%d Macro • %d ขั้นตอน", macroCount, count)
    end
    if UI.refs.statusPageProfile then
        UI.refs.statusPageProfile.Text = name
    end
    if UI.refs.statusPageMacro then
        UI.refs.statusPageMacro.Text = macroName .. mainMarker
    end
    if UI.footerProfile then
        UI.footerProfile.Text = "โปรไฟล์: " .. name .. " / Macro: " .. macroName .. (State.dirty and " • ยังไม่บันทึก" or "")
    end
end

function App.refreshSetUI()
    local macro = selectedMacro()
    local set = macro and macro.set or nil
    local canUse = macro ~= nil and Profiles.data ~= nil

    if UI.refs.setButton then
        setButtonEnabled(UI.refs.setButton, canUse)
    end

    local text = "ยังไม่มีข้อมูลเซ็ต"
    local color = Theme.muted
    if not canUse then
        text = "เลือกโปรไฟล์และ Macro ก่อนใช้ปุ่มนี้"
        color = Theme.warning
    elseif not set then
        text = "ยังไม่มีข้อมูลเซ็ตของ Macro นี้ • ระบบจะเก็บข้อมูลอัตโนมัติเมื่อบันทึกครั้งถัดไป"
        color = Theme.muted
    elseif set.status == "detected" then
        text = string.format("ตรวจพบโดย adapter: %s • %s", tostring(set.source or "adapter"), set.capturedAt and os.date("%Y-%m-%d %H:%M", set.capturedAt) or "ไม่ทราบเวลา")
        color = Theme.success
    elseif set.status == "input-only" then
        local inferred = set.inferred or {}
        text = string.format("อนุมานจากอินพุต (ยังไม่ยืนยันตัวละคร/ออป) • ปุ่ม %d ชนิด • คลิก %d ครั้ง", numberOr(inferred.keyCount, 0), numberOr(inferred.clickCount, 0))
        color = Theme.warning
    else
        text = "ข้อมูลเซ็ตไม่พร้อมใช้งาน" .. (set.note and (": " .. tostring(set.note)) or "")
        color = Theme.danger
    end
    if UI.refs.setStatus then
        UI.refs.setStatus.Text = text
        UI.refs.setStatus.TextColor3 = color
    end
end

function App.refreshRecoveryUI()
    local exists = Recovery.exists()
    if UI.refs.recoveryLabel then
        if State.pendingRecording then
            UI.refs.recoveryLabel.Text = string.format("กำลังรอตั้งชื่อ Macro • %d ขั้นตอนในหน่วยความจำ (ยังไม่เขียนเป็น Macro)", #State.pendingRecording.events)
            UI.refs.recoveryLabel.TextColor3 = Theme.warning
        elseif exists then
            UI.refs.recoveryLabel.Text = "พบไฟล์กู้คืนจากการบันทึกที่ยังไม่ตั้งชื่อ • ตรวจสอบก่อนกู้คืน"
            UI.refs.recoveryLabel.TextColor3 = Theme.warning
        else
            UI.refs.recoveryLabel.Text = "ไม่มีไฟล์กู้คืน"
            UI.refs.recoveryLabel.TextColor3 = Theme.muted
        end
    end
    if UI.refs.recoveryButton then
        -- ถ้ามีข้อมูลรอตั้งชื่อ (เช่นเขียนไฟล์ล้มเหลว) ต้องเปิดหน้าตั้งชื่อซ้ำได้เสมอ
        setButtonEnabled(UI.refs.recoveryButton, State.pendingRecording ~= nil or exists)
    end
    if UI.refs.recoveryDeleteButton then
        setButtonEnabled(UI.refs.recoveryDeleteButton, exists and not State.pendingRecording)
    end
    if UI.refs.infoRecovery then
        UI.refs.infoRecovery.Text = exists and "มีไฟล์" or "ไม่มี"
        UI.refs.infoRecovery.TextColor3 = exists and Theme.warning or Theme.muted
    end
end

function App.refreshSteps()
    local macro = selectedMacro()
    if not macro or not Profiles.data then
        State.selectedSteps = {}
        State.stepMacroId = nil
    elseif State.stepMacroId ~= macro.id then
        State.selectedSteps = {}
        State.stepMacroId = macro.id
    end

    local scroll = UI.refs.stepsScroll
    if not scroll then
        return
    end
    for _, child in ipairs(scroll:GetChildren()) do
        if child:IsA("GuiObject") then
            child:Destroy()
        end
    end
    UI.stepRows = {}

    local events = macro and macro.events or {}
    local total = #events
    local renderCount = math.min(total, STEPS_RENDER_LIMIT)
    local selected = countSelectedSteps()
    if UI.refs.stepsInfo then
        if total == 0 then
            UI.refs.stepsInfo.Text = "ยังไม่มีขั้นตอน"
        else
            UI.refs.stepsInfo.Text = string.format("%d ขั้นตอน • แสดง %d • เลือกแล้ว %d", total, renderCount, selected)
        end
    end

    if total == 0 then
        local empty = makeLabel(scroll, "ยังไม่มีขั้นตอน — กดเริ่มบันทึกที่ด้านบน", 11, Theme.muted, UDim2.new(1, -8, 0, 40), Enum.TextXAlignment.Center)
        empty.TextYAlignment = Enum.TextYAlignment.Center
    else
        for index = 1, renderCount do
            local event = events[index]
            local row = newInstance("TextButton", {
                Size = UDim2.new(1, -4, 0, UI.mobile and 34 or 28),
                BackgroundColor3 = State.selectedSteps[index] and Theme.accentDark or Theme.panel2,
                BorderSizePixel = 0,
                AutoButtonColor = false,
                Font = FONT,
                Text = eventSummary(index, event),
                TextSize = UI.mobile and 10 or 9,
                TextColor3 = Theme.text,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextYAlignment = Enum.TextYAlignment.Center,
                TextTruncate = Enum.TextTruncate.AtEnd,
                Parent = scroll,
            })
            row.LayoutOrder = index
            applyPadding(row, 0, 0, 8, 6)
            addCorner(row, 5)
            row.MouseButton1Click:Connect(function()
                App.toggleStepSelection(index)
            end)
            UI.stepRows[index] = row
        end
        if total > STEPS_RENDER_LIMIT then
            local more = makeLabel(scroll, string.format("แสดงเฉพาะ %d ขั้นตอนแรกจาก %d • ลบขั้นตอนที่แสดงได้", STEPS_RENDER_LIMIT, total), 9, Theme.muted, UDim2.new(1, 0, 0, 22), Enum.TextXAlignment.Center)
            more.LayoutOrder = renderCount + 1
        end
    end

    if UI.refs.deleteStepsButton then
        setButtonEnabled(UI.refs.deleteStepsButton, selected > 0)
    end
    if UI.refs.selectAllStepsButton then
        setButtonEnabled(UI.refs.selectAllStepsButton, total > 0)
    end
    if UI.refs.clearStepsButton then
        setButtonEnabled(UI.refs.clearStepsButton, selected > 0)
    end
    if UI.refs.resetMacroButton then
        local hasData = macro ~= nil and (total > 0 or macro.set ~= nil)
        setButtonEnabled(UI.refs.resetMacroButton, hasData)
    end
end

function App.updateStepSelectionUI()
    local selected = countSelectedSteps()
    for index, row in pairs(UI.stepRows or {}) do
        row.BackgroundColor3 = State.selectedSteps[index] and Theme.accentDark or Theme.panel2
    end
    if UI.refs.deleteStepsButton then
        setButtonEnabled(UI.refs.deleteStepsButton, selected > 0)
    end
    if UI.refs.clearStepsButton then
        setButtonEnabled(UI.refs.clearStepsButton, selected > 0)
    end
    local macro = selectedMacro()
    local total = macro and #macro.events or 0
    if UI.refs.stepsInfo then
        UI.refs.stepsInfo.Text = total == 0 and "ยังไม่มีขั้นตอน" or string.format("%d ขั้นตอน • แสดง %d • เลือกแล้ว %d", total, math.min(total, STEPS_RENDER_LIMIT), selected)
    end
end

function App.toggleStepSelection(index)
    if not index then
        return
    end
    if State.selectedSteps[index] then
        State.selectedSteps[index] = nil
    else
        State.selectedSteps[index] = true
    end
    App.updateStepSelectionUI()
end

function App.selectAllRenderedSteps()
    local macro = selectedMacro()
    if not macro then
        return
    end
    local limit = math.min(#macro.events, STEPS_RENDER_LIMIT)
    State.selectedSteps = {}
    for index = 1, limit do
        State.selectedSteps[index] = true
    end
    App.updateStepSelectionUI()
end

function App.clearStepSelection()
    State.selectedSteps = {}
    App.updateStepSelectionUI()
end

function App.refreshMacros()
    local scroll = UI.refs.macroList
    if not scroll then
        return
    end
    for _, child in ipairs(scroll:GetChildren()) do
        if child:IsA("GuiObject") then
            child:Destroy()
        end
    end

    local data = Profiles.data
    if not data or #data.macros == 0 then
        local empty = makeWrappedLabel(scroll, "ยังไม่มี Macro ในโปรไฟล์นี้", 11, Theme.muted, 40)
        empty.TextXAlignment = Enum.TextXAlignment.Center
        empty.TextYAlignment = Enum.TextYAlignment.Center
        empty.Size = UDim2.new(1, -8, 0, 48)
        if UI.refs.setMainMacroButton then
            setButtonEnabled(UI.refs.setMainMacroButton, false)
        end
        if UI.refs.renameMacroButton then
            setButtonEnabled(UI.refs.renameMacroButton, false)
        end
        if UI.refs.deleteMacroButton then
            setButtonEnabled(UI.refs.deleteMacroButton, false)
        end
        return
    end

    for _, macro in ipairs(data.macros) do
        local selected = macro.id == data.selectedMacroId
        local isMain = macro.id == data.mainMacroId
        local row = makeButton(scroll, "", UDim2.new(1, -4, 0, 66), selected and Theme.panel2 or Theme.panel, function()
            App.selectMacro(macro.id)
        end, { textSize = 11 })
        if selected then
            addStroke(row, Theme.accent, 1)
        end

        local title = (isMain and "★ " or "") .. macro.name
        local nameLabel = makeLabel(row, title, 12, selected and Theme.accent or Theme.text, UDim2.new(1, -78, 0, 20))
        nameLabel.Position = UDim2.fromOffset(10, 6)

        local setStatus = macro.set and macro.set.status or "none"
        local setText = setStatus == "detected" and "set: detected" or (setStatus == "input-only" and "set: input-only" or "set: -")
        local metaLabel = makeLabel(row, string.format("%d ขั้นตอน • %s • %s", #macro.events, formatDuration(macro.duration or 0), setText), 9, Theme.muted, UDim2.new(1, -78, 0, 16))
        metaLabel.Position = UDim2.fromOffset(10, 26)

        local contextIncomplete = type(macro.context) == "table" and (not macro.context.map or not macro.context.mode)
        local contextLabel = makeLabel(row, "บริบท: " .. GameContext.formatStored(macro.context, true), 9, contextIncomplete and Theme.warning or Theme.muted, UDim2.new(1, -78, 0, 14))
        contextLabel.Position = UDim2.fromOffset(10, 43)

        local stateLabel = makeLabel(row, isMain and "หลัก" or (selected and "ใช้งาน" or "เลือก"), 9, isMain and Theme.warning or (selected and Theme.accent or Theme.muted), UDim2.fromOffset(62, 66), Enum.TextXAlignment.Right)
        stateLabel.Position = UDim2.new(1, -70, 0, 0)
    end

    local macro = selectedMacro()
    local canEdit = macro ~= nil and State.mode == "idle" and not State.pendingRecording
    if UI.refs.setMainMacroButton then
        setButtonEnabled(UI.refs.setMainMacroButton, canEdit and macro.id ~= data.mainMacroId)
    end
    if UI.refs.renameMacroButton then
        setButtonEnabled(UI.refs.renameMacroButton, canEdit)
    end
    if UI.refs.deleteMacroButton then
        setButtonEnabled(UI.refs.deleteMacroButton, canEdit and #data.macros > 1)
    end
end

function App.refreshTransport()
    local mode = State.mode
    -- หลังเล่นจบให้ใช้จำนวนขั้นตอนที่เล่นจริง (หลังกรอง) เป็นตัวหาร เพื่อให้แถบครบ 100%
    -- ขั้นตอนอื่นใช้จำนวนใน Macro ปกติ
    local total
    if State.finished and State.playbackIndex > 0 then
        total = State.playbackIndex
    else
        total = #(State.playbackEvents or Profiles.events)
    end
    local loopsDisplay = Settings.infinite and "∞" or formatNumber(Settings.loops)
    local pending = State.pendingRecording ~= nil

    local recordEnabled = mode == "idle" and not pending
    local recordText = "●  เริ่มบันทึก"
    if pending then
        recordText = "●  รอตั้งชื่อ Macro"
    elseif mode == "recording" then
        recordText = "■  หยุดบันทึก"
    elseif mode == "countdown" then
        recordText = "ยกเลิก"
    end
    for _, button in ipairs(UI.transport.record) do
        setButtonText(button, recordText)
        setButtonEnabled(button, recordEnabled or mode == "recording" or mode == "countdown")
    end

    local playText = "▶  เล่น"
    if mode == "paused" then
        playText = "▶  เล่นต่อ"
    end
    local playEnabled = (mode == "idle") and not pending and total > 0 and Input.available()
    for _, button in ipairs(UI.transport.play) do
        setButtonText(button, playText)
        setButtonEnabled(button, button == UI.dockPlay and (mode == "playing" or mode == "paused") or playEnabled)
    end

    local pauseText = mode == "paused" and "▶  เล่นต่อ" or "⏸  พัก"
    for _, button in ipairs(UI.transport.pause) do
        setButtonText(button, pauseText)
        setButtonEnabled(button, mode == "playing" or mode == "paused")
    end
    for _, button in ipairs(UI.transport.stop) do
        if button == UI.dockStop then
            setButtonEnabled(button, mode == "playing" or mode == "paused" or mode == "recording" or mode == "countdown")
        else
            setButtonEnabled(button, mode == "playing" or mode == "paused")
        end
    end

    if UI.refs.playbackSummary then
        local loopText = Settings.infinite and "วนไม่จำกัด" or (formatNumber(Settings.loops) .. " รอบ")
        UI.refs.playbackSummary.Text = string.format("%s • พัก %s วิ • ความเร็ว %sx", loopText, formatNumber(Settings.loopDelay), formatNumber(Settings.speed))
    end

    local meta = selectedProfileMeta()
    local macro = selectedMacro()
    local canSave = meta ~= nil and macro ~= nil and mode == "idle" and not pending and total > 0
    if UI.refs.saveNowButton then
        setButtonEnabled(UI.refs.saveNowButton, canSave)
    end
    if UI.refs.profileSaveButton then
        setButtonEnabled(UI.refs.profileSaveButton, canSave)
    end
    if UI.refs.profileDeleteButton then
        setButtonEnabled(UI.refs.profileDeleteButton, meta ~= nil and mode == "idle" and not pending)
    end

    App.refreshMacros()
    updateProgress(State.playbackIndex, total, State.loop, loopsDisplay)
end

function App.refreshProfiles()
    local scroll = UI.refs.profileList
    if scroll then
        for _, child in ipairs(scroll:GetChildren()) do
            if child:IsA("GuiObject") then
                child:Destroy()
            end
        end

        if #Profiles.list == 0 then
            local empty = makeWrappedLabel(scroll, "ยังไม่มีโปรไฟล์ กดสร้างใหม่ หรือเริ่มบันทึกเพื่อสร้างโปรไฟล์อัตโนมัติ", 11, Theme.muted, 44)
            empty.TextXAlignment = Enum.TextXAlignment.Center
            empty.TextYAlignment = Enum.TextYAlignment.Center
            empty.Size = UDim2.new(1, -8, 0, 48)
        else
            for _, item in ipairs(Profiles.list) do
                local selected = item.id == Profiles.selectedId
                local row = makeButton(scroll, "", UDim2.new(1, -4, 0, 56), selected and Theme.panel2 or Theme.panel, function()
                    App.selectProfile(item.id)
                end, { textSize = 12 })
                if selected then
                    addStroke(row, Theme.accent, 1)
                end

                local nameLabel = makeLabel(row, item.name, 13, selected and Theme.accent or Theme.text, UDim2.new(1, -86, 0, 20))
                nameLabel.Position = UDim2.fromOffset(10, 6)

                local metaLabel = makeLabel(row, string.format("%d Macro • %d ขั้นตอน • %s", item.macroCount or 0, item.count or 0, formatDuration(item.duration or 0)), 9, Theme.muted, UDim2.new(1, -86, 0, 16))
                metaLabel.Position = UDim2.fromOffset(10, 28)

                local stateLabel = makeLabel(row, selected and "ใช้งาน" or "เลือก", 9, selected and Theme.accent or Theme.muted, UDim2.fromOffset(64, 56), Enum.TextXAlignment.Right)
                stateLabel.Position = UDim2.new(1, -72, 0, 0)
            end
        end
    end

    App.refreshProfileSummary()
    App.refreshMacros()
    App.refreshSteps()
    App.refreshSetUI()
    App.refreshRecoveryUI()
    App.refreshAutoUI()
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
    if UI.refs.guardFocusToggle then
        UI.refs.guardFocusToggle.set(Settings.guardFocus, false)
    end
    if UI.refs.noMouseMoveToggle then
        UI.refs.noMouseMoveToggle.set(Settings.noMouseMove ~= false, false)
    end
    if UI.refs.autosaveToggle then
        UI.refs.autosaveToggle.set(Settings.autosave, false)
    end
    if UI.refs.recordMotionToggle then
        UI.refs.recordMotionToggle.set(Settings.recordMotion == true, false)
    end
    if UI.refs.recordMovementKeysToggle then
        UI.refs.recordMovementKeysToggle.set(Settings.recordMovementKeys == true, false)
    end
    if UI.refs.worldAnchorToggle then
        UI.refs.worldAnchorToggle.set(Settings.worldAnchor ~= false, false)
    end
    if UI.refs.worldFallbackToggle then
        UI.refs.worldFallbackToggle.set(Settings.worldFallback == true, false)
    end
    if UI.refs.worldThroughToggle then
        UI.refs.worldThroughToggle.set(Settings.worldThrough == true, false)
    end
    if UI.refs.scaleCoordsToggle then
        UI.refs.scaleCoordsToggle.set(Settings.scaleCoords, false)
    end
    if UI.refs.infiniteToggle then
        UI.refs.infiniteToggle.set(Settings.infinite, false)
    end

    if UI.refs.infoExecutor then
        local versionText = App.executorVersion ~= "" and (" " .. App.executorVersion) or ""
        UI.refs.infoExecutor.Text = App.executorName .. versionText
    end
    if UI.refs.infoPlatform then
        UI.refs.infoPlatform.Text = Cap.platform
    end
    if UI.refs.infoInput then
        UI.refs.infoInput.Text = Cap.inputLabel
        UI.refs.infoInput.TextColor3 = Cap.input == "none" and Theme.danger
            or ((Cap.input == "real" or Cap.input == "virtual") and Theme.warning or Theme.success)
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
    if UI.refs.infoAdapter then
        local text, color = App.getAdapterStatus()
        UI.refs.infoAdapter.Text = text
        UI.refs.infoAdapter.TextColor3 = color
    end
    if UI.refs.infoRecovery then
        if State.pendingRecording then
            UI.refs.infoRecovery.Text = "รอตั้งชื่อ"
            UI.refs.infoRecovery.TextColor3 = Theme.warning
        elseif Recovery.exists() then
            UI.refs.infoRecovery.Text = "มีไฟล์"
            UI.refs.infoRecovery.TextColor3 = Theme.warning
        else
            UI.refs.infoRecovery.Text = "ไม่มี"
            UI.refs.infoRecovery.TextColor3 = Theme.muted
        end
    end

    App.updateAfkUI()
    App.refreshAutoUI()
end

-- 13) ตัวช่วยบันทึกและปล่อยอินพุต
-- ============================================================================

local function releaseHeld()
    for vk, keyName in pairs(State.heldKeys) do
        pcall(function()
            Input.keyUp(vk, type(keyName) == "string" and keyName or nil)
        end)
    end
    State.heldKeys = {}

    if State.heldMouse.Left then
        pcall(function()
            Input.release("Left")
        end)
    end
    if State.heldMouse.Right then
        pcall(function()
            Input.release("Right")
        end)
    end
    State.heldMouse = {}
    State.heldMousePoints = {}
    State.skippedClicks = {}
    State.lastSyntheticWorldId = nil
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

-- Dock ของสคริปต์ลอยอยู่กลางด้านบนและบังคลิกได้ ต้องซ่อนชั่วคราวเฉพาะตอนส่งคลิก
local function pointInDock(x, y)
    local dock = UI.dock
    if not dock or not dock.Visible or type(x) ~= "number" or type(y) ~= "number" then
        return false
    end
    local origin = dock.AbsolutePosition
    local size = dock.AbsoluteSize
    return x >= origin.X - 2 and x <= origin.X + size.X + 2
        and y >= origin.Y - 2 and y <= origin.Y + size.Y + 2
end

-- UI ของเกม (ช่องเลือกตัวละคร ปุ่มอัปเกรด จอยมือถือ) อยู่กับที่บนหน้าจอ
-- จึงไม่ควรฝัง world anchor เพราะเมื่อกล้องเปลี่ยนจะทำให้คลิกพลาดปุ่ม
-- Phase 1: เก็บเส้นทางของ GUI เป้าหมายเพื่อตรวจซ้ำก่อนคลิก
-- ฟังก์ชันกลุ่มนี้อยู่ใน do-block เพื่อลดจำนวน local ของ chunk หลัก
-- (Luau จำกัด 200 local registers; ถ้าเกิน executor จะ compile ไม่ผ่านและเมนูไม่ขึ้น)
local GuiTargeting = {}
do
local function guiRootEntries()
    local entries = {}
    local okCore, coreGui = pcall(function()
        return game:GetService("CoreGui")
    end)
    if okCore and coreGui then
        table.insert(entries, { root = coreGui, name = "CoreGui" })
    end
    if LocalPlayer then
        local playerGui = nil
        pcall(function()
            playerGui = LocalPlayer:FindFirstChild("PlayerGui")
        end)
        if playerGui then
            table.insert(entries, { root = playerGui, name = "PlayerGui" })
        end
    end
    return entries
end

local function guiObjectsAt(x, y)
    local entries = guiRootEntries()
    if #entries == 0 then
        return {}, false
    end
    local objects = {}
    local checked = false
    for _, entry in ipairs(entries) do
        local ok, found = pcall(function()
            return entry.root:GetGuiObjectsAtPosition(x, y)
        end)
        if ok then
            checked = true
            for _, object in ipairs(type(found) == "table" and found or {}) do
                table.insert(objects, object)
            end
        end
    end
    return objects, checked
end

local function isOwnGuiObject(object)
    if not object or not UI.screenGui then
        return false
    end
    if object == UI.screenGui then
        return true
    end
    local ok, descendant = pcall(function()
        return object:IsDescendantOf(UI.screenGui)
    end)
    return ok and descendant == true
end

local function guiRootForObject(object, entries)
    for _, entry in ipairs(entries or guiRootEntries()) do
        local ok, descendant = pcall(function()
            return object == entry.root or object:IsDescendantOf(entry.root)
        end)
        if ok and descendant then
            return entry
        end
    end
    return nil
end

local function interactiveGuiAncestor(object, root)
    local node = object
    while node and node ~= root do
        local isButton = false
        local isTextBox = false
        local active = false
        pcall(function()
            isButton = node:IsA("GuiButton")
            isTextBox = node:IsA("TextBox")
            active = node.Active == true
        end)
        if isButton or isTextBox or active then
            return node
        end
        node = node.Parent
    end
    return nil
end

local function guiPathOf(object, root)
    local parts = {}
    local node = object
    local depth = 0
    while node and node ~= root do
        local parent = node.Parent
        if not parent then
            return nil
        end
        local name = nil
        local className = nil
        pcall(function()
            name = node.Name
            className = node.ClassName
        end)
        if not name or name == "" then
            return nil
        end
        local childIndex = 0
        local sameCount = 0
        local ok = pcall(function()
            for _, child in ipairs(parent:GetChildren()) do
                if child.Name == name and child.ClassName == className then
                    sameCount += 1
                    if child == node then
                        childIndex = sameCount
                    end
                end
            end
        end)
        if not ok or childIndex < 1 then
            return nil
        end
        table.insert(parts, 1, {
            name = limitedText(name, 120),
            class = limitedText(className, 80),
            index = childIndex,
        })
        node = parent
        depth += 1
        if depth > 24 then
            return nil
        end
    end
    if node ~= root or #parts == 0 then
        return nil
    end
    return parts
end

local function buildGuiTarget(object, entry, x, y)
    local path = guiPathOf(object, entry.root)
    if not path then
        return nil
    end
    local position = object.AbsolutePosition
    local size = object.AbsoluteSize
    if typeof(position) ~= "Vector2" or typeof(size) ~= "Vector2" then
        return nil
    end
    if size.X < 1 or size.Y < 1 then
        return nil
    end
    local text = nil
    pcall(function()
        if object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
            text = limitedText(object.Text, 120)
        end
    end)
    local fullName = nil
    pcall(function()
        fullName = limitedText(object:GetFullName(), 300)
    end)
    local isButton = false
    pcall(function()
        isButton = object:IsA("GuiButton")
    end)
    return {
        root = entry.name,
        path = path,
        relativeX = clampSafe((x - position.X) / size.X, 0, 1),
        relativeY = clampSafe((y - position.Y) / size.Y, 0, 1),
        isButton = isButton,
        className = limitedText(object.ClassName, 80),
        text = text,
        fullName = fullName,
    }, object
end

-- GetGuiObjectsAtPosition อาจคืนลูกของ Frame ที่ซ่อนอยู่ (แล้วแต่เวอร์ชัน)
-- จึงเดินเช็ค Visible/Enabled ของทุกชั้น ไม่งั้นเมนูที่ซ่อนแล้วจะยังบล็อกคลิก
local function guiObjectVisible(object)
    local node = object
    local depth = 0
    while node and depth < 32 do
        local visible = true
        local enabled = true
        local isGuiObject = false
        local isLayerCollector = false
        pcall(function()
            isGuiObject = node:IsA("GuiObject")
            isLayerCollector = node:IsA("LayerCollector")
            if isGuiObject then
                visible = node.Visible ~= false
            elseif isLayerCollector then
                enabled = node.Enabled ~= false
            end
        end)
        if not visible or not enabled then
            return false
        end
        if isLayerCollector then
            break
        end
        node = node.Parent
        depth += 1
    end
    return true
end

local function guiTargetAt(x, y)
    x = numberOr(x, 0)
    y = numberOr(y, 0)
    local entries = guiRootEntries()
    if #entries == 0 then
        return nil, nil, false, false
    end
    local objects, checked = guiObjectsAt(x, y)
    for _, object in ipairs(objects) do
        if object then
            if guiObjectVisible(object) then
                if isOwnGuiObject(object) then
                    return nil, nil, checked, true
                end
                local entry = guiRootForObject(object, entries)
                if entry then
                    local interactive = interactiveGuiAncestor(object, entry.root)
                    if interactive then
                        local target, targetObject = buildGuiTarget(interactive, entry, x, y)
                        if target then
                            return target, targetObject, checked, false
                        end
                    end
                end
            end
        end
    end
    return nil, nil, checked, false
end

local function captureGuiTarget(x, y)
    local target, _, _, ownBlocked = guiTargetAt(x, y)
    if ownBlocked then
        return nil, "own"
    end
    return target
end

local function pointOverGameGui(x, y)
    local target, _, checked, ownBlocked = GuiTargeting.guiTargetAt(x, y)
    if target or ownBlocked then
        return true
    end
    -- ตรวจไม่ได้ = ถือว่าอยู่บน GUI เพื่อไม่ให้ world anchor ไปคลิกปุ่มเกมโดยไม่ตั้งใจ
    if not checked then
        return true
    end
    return false
end

local function guiTextSignature(text)
    local value = tostring(text or ""):lower()
    value = value:gsub("%d+", "#")
    value = value:gsub("%s+", " ")
    return trimText(value)
end

local UPGRADE_GUI_WORDS = {
    "upgrade",
    "level up",
    "level",
    "lvl",
    "อัปเกรด",
    "อัพเกรด",
    "อัป",
    "เลเวล",
    "พัฒนา",
}

local function textLooksLikeUpgrade(text)
    local value = guiTextSignature(text)
    if value == "" then
        return false
    end
    for _, word in ipairs(UPGRADE_GUI_WORDS) do
        if string.find(value, word, 1, true) then
            return true
        end
    end
    return false
end

local function isLikelyUpgradeGui(gui)
    if type(gui) ~= "table" or gui.isButton ~= true then
        return false
    end
    return textLooksLikeUpgrade(gui.text) or textLooksLikeUpgrade(gui.fullName)
end

local GENERIC_WORLD_MODELS = {
    "baseplate",
    "ground",
    "floor",
    "terrain",
    "map",
    "placement",
    "grid",
    "plot",
    "land",
    "spawn",
}

local function isGenericWorldModel(name)
    local value = tostring(name or ""):lower()
    if value == "" then
        return true
    end
    for _, word in ipairs(GENERIC_WORLD_MODELS) do
        if string.find(value, word, 1, true) then
            return true
        end
    end
    return false
end

local function isLikelySelectionWorld(world)
    local hit = type(world) == "table" and world.hit or nil
    if not hit or hit.isTerrain then
        return false
    end
    if not hit.modelName then
        return false
    end
    return not isGenericWorldModel(hit.modelName)
end

local function bindUpgradeSelection(gui)
    if not isLikelyUpgradeGui(gui) then
        return nil
    end
    local target = State.lastWorldSelection
    if not target or not target.world or not target.id then
        return nil
    end
    local now = clock() - (State.recordStart or clock())
    if target.t and now - target.t > 120 then
        return nil
    end
    return {
        worldId = target.id,
        world = target.world,
    }
end

local function findGuiChild(parent, part)
    local matches = {}
    local ok = pcall(function()
        for _, child in ipairs(parent:GetChildren()) do
            if child.Name == part.name and (not part.class or child.ClassName == part.class) then
                table.insert(matches, child)
            end
        end
    end)
    if not ok then
        return nil, "อ่านโครงสร้าง GUI ไม่ได้"
    end
    local childIndex = math.floor(numberOr(part.index, 1))
    if childIndex < 1 then
        childIndex = 1
    end
    return matches[childIndex], nil
end

local function guiRootByName(name)
    for _, entry in ipairs(guiRootEntries()) do
        if entry.name == name then
            return entry.root
        end
    end
    return nil
end

local function resolveGuiObject(gui)
    if type(gui) ~= "table" then
        return nil, "ไม่มีข้อมูล GUI เป้าหมาย"
    end
    local root = guiRootByName(gui.root)
    if not root then
        return nil, "ไม่พบ " .. tostring(gui.root) .. " สำหรับ GUI เป้าหมาย"
    end
    local object = root
    for _, part in ipairs(gui.path or {}) do
        local child, childError = findGuiChild(object, part)
        if not child then
            return nil, string.format(
                "ไม่พบ GUI ตามเส้นทางที่บันทึก (%s)%s",
                tostring(part.name),
                childError and (" • " .. childError) or ""
            )
        end
        object = child
    end
    if object == root then
        return nil, "เส้นทาง GUI ว่าง"
    end
    local visible = false
    local size = nil
    pcall(function()
        visible = object.Visible ~= false
        size = object.AbsoluteSize
    end)
    if not visible then
        return nil, "GUI เป้าหมายถูกซ่อนอยู่"
    end
    if not size or typeof(size) ~= "Vector2" or size.X < 1 or size.Y < 1 then
        return nil, "GUI เป้าหมายมีขนาดศูนย์"
    end
    local chainVisible = true
    local chainNode = object
    while chainNode and chainNode ~= root do
        local nodeVisible = true
        local nodeEnabled = true
        pcall(function()
            nodeVisible = chainNode.Visible ~= false
            if chainNode:IsA("LayerCollector") then
                nodeEnabled = chainNode.Enabled ~= false
            end
        end)
        if not nodeVisible or not nodeEnabled then
            chainVisible = false
            break
        end
        chainNode = chainNode.Parent
    end
    if not chainVisible then
        return nil, "GUI เป้าหมายหรือ parent ถูกซ่อนอยู่"
    end
    if gui.className then
        local className = nil
        pcall(function()
            className = object.ClassName
        end)
        if className ~= gui.className then
            return nil, string.format(
                "ชนิด GUI เปลี่ยนจาก %s เป็น %s",
                tostring(gui.className),
                tostring(className)
            )
        end
    end
    if gui.text then
        local currentText = nil
        pcall(function()
            if object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
                currentText = object.Text
            end
        end)
        if currentText and guiTextSignature(currentText) ~= guiTextSignature(gui.text) then
            return nil, string.format(
                "ข้อความ GUI เปลี่ยนจาก \"%s\" เป็น \"%s\"",
                tostring(gui.text),
                tostring(currentText)
            )
        end
    end
    return object, nil
end

local function resolveGuiTargetPoint(gui)
    local object, objectError = resolveGuiObject(gui)
    if not object then
        return nil, objectError
    end
    local position = object.AbsolutePosition
    local size = object.AbsoluteSize
    local relativeX = clampSafe(numberOr(gui.relativeX, 0.5), 0, 1)
    local relativeY = clampSafe(numberOr(gui.relativeY, 0.5), 0, 1)
    -- GUI ที่หาได้ตามเส้นทางใช้ AbsolutePosition/AbsoluteSize ปัจจุบันเป็นหลัก
    -- จึงไม่นำ offsetX/offsetY (ค่าชดเชยพิกัดหน้าจอ) มาใช้ซ้ำ เพราะจะคลิกนอกปุ่ม
    local x = position.X + size.X * relativeX
    local y = position.Y + size.Y * relativeY
    local viewport = getViewport()
    if x < 0 or y < 0 or x > viewport.X or y > viewport.Y then
        return nil, "GUI เป้าหมายอยู่นอกจอ"
    end
    if pointInGui(Vector2.new(x, y)) then
        return nil, nil, "own"
    end
    local topTarget, topObject, checked, ownBlocked = guiTargetAt(x, y)
    if ownBlocked then
        return nil, nil, "own"
    end
    if topTarget and topObject then
        local sameObject = topObject == object
        local descendant = false
        pcall(function()
            descendant = object:IsAncestorOf(topObject)
        end)
        if not sameObject and not descendant then
            return nil, "GUI เป้าหมายถูกบังโดย " .. tostring(topTarget.fullName or topTarget.className or "GUI อื่น")
        end
    end
    if not checked then
        return nil, "ตรวจสอบลำดับชั้น GUI ไม่ได้ จึงยืนยันว่าปุ่มเป้าหมายไม่ถูกบังไม่ได้"
    end
    return x, y
end

-- ส่งออกเฉพาะฟังก์ชันที่ถูกเรียกจากภายนอก do-block
GuiTargeting.guiTargetAt = guiTargetAt
GuiTargeting.captureGuiTarget = captureGuiTarget
GuiTargeting.pointOverGameGui = pointOverGameGui
GuiTargeting.isLikelyUpgradeGui = isLikelyUpgradeGui
GuiTargeting.isLikelySelectionWorld = isLikelySelectionWorld
GuiTargeting.bindUpgradeSelection = bindUpgradeSelection
GuiTargeting.resolveGuiTargetPoint = resolveGuiTargetPoint
end

-- ฟังก์ชันกลุ่มบันทึก/โปรไฟล์ย้ายไปอยู่ในตาราง Rec เพื่อลดจำนวน local register ของ chunk หลัก
-- (Luau จำกัด 200 registers ต่อฟังก์ชัน; ถ้าเกิน executor จะ compile ไม่ผ่านและเมนูไม่ขึ้น)
local Rec = {}

function Rec.roundedPosition(position)
    return math.floor(position.X + 0.5), math.floor(position.Y + 0.5)
end

function Rec.removeRecordedEvent(events, target)
    if type(events) ~= "table" or not target then
        return false
    end
    for index = #events, 1, -1 do
        if events[index] == target then
            table.remove(events, index)
            return true
        end
    end
    return false
end

function Rec.unregisterWorldTarget(held)
    if not held or not held.worldId then
        return
    end
    if State.worldTargets then
        State.worldTargets[held.worldId] = nil
    end
    if State.lastWorldTarget and State.lastWorldTarget.id == held.worldId then
        State.lastWorldTarget = nil
    end
    if State.lastWorldSelection and State.lastWorldSelection.id == held.worldId then
        State.lastWorldSelection = nil
    end
end

function Rec.updateHeldMouseDistance(held, position)
    if not held then
        return 0
    end
    if position then
        held.lastPosition = position
        if held.startPosition then
            local distance = (position - held.startPosition).Magnitude
            if distance > (held.maxDistance or 0) then
                held.maxDistance = distance
            end
        end
    end
    return held.maxDistance or 0
end

function Rec.shouldDropHeldClick(held, position)
    if not held or Settings.recordMotion then
        return false
    end
    local distance = Rec.updateHeldMouseDistance(held, position)
    if held.button == "Right" then
        return distance > MOUSE_DRAG_THRESHOLD
    end
    if held.source == "touch" then
        return distance > TOUCH_DRAG_THRESHOLD
    end
    return false
end

function Rec.closeRecordingInputs(events, endTime)
    if type(events) ~= "table" then
        return
    end

    local position = getMousePosition()
    local fallbackX, fallbackY = 0, 0
    if position then
        fallbackX, fallbackY = Rec.roundedPosition(position)
    elseif Input.point then
        fallbackX, fallbackY = math.floor(Input.point.X), math.floor(Input.point.Y)
    end

    local appended = false
    for _, held in pairs(State.recordingMouse) do
        local heldPosition = held.lastPosition
        if not heldPosition and held.source ~= "touch" then
            heldPosition = position
        end
        if not heldPosition then
            heldPosition = held.startPosition
        end

        if Rec.shouldDropHeldClick(held, heldPosition) then
            Rec.removeRecordedEvent(events, held.downEvent)
            Rec.unregisterWorldTarget(held)
        elseif heldPosition then
            local x, y = Rec.roundedPosition(heldPosition)
            table.insert(events, {
                t = endTime,
                type = "mouseUp",
                button = held.button,
                x = x,
                y = y,
                source = held.source,
                world = held.world,
                worldId = held.worldId,
                gui = held.gui,
                selection = held.selection,
                guiUnknown = held.guiUnknown,
            })
            appended = true
        else
            table.insert(events, {
                t = endTime,
                type = "mouseUp",
                button = held.button,
                x = fallbackX,
                y = fallbackY,
                source = held.source,
                world = held.world,
                worldId = held.worldId,
                gui = held.gui,
                selection = held.selection,
                guiUnknown = held.guiUnknown,
            })
            appended = true
        end
    end
    for keyName, held in pairs(State.recordingKeys) do
        if not held.filtered then
            table.insert(events, {
                t = endTime,
                type = "keyUp",
                key = keyName,
                vk = held and held.vk or VK_BY_NAME[keyName],
            })
            appended = true
        end
    end

    if appended then
        table.sort(events, function(a, b)
            return a.t < b.t
        end)
    end

    State.recordingMouse = {}
    State.recordingKeys = {}
end

function Rec.warnUnsupportedKey(keyName)
    if App.warnedKeys[keyName] then
        return
    end
    App.warnedKeys[keyName] = true
    Log.add("warn", "ไม่รองรับปุ่ม " .. tostring(keyName) .. " — ปุ่มนี้จะไม่ถูกบันทึก")
end

function Rec.updateRecordInfo()
    if not UI.refs.recordInfo then
        return
    end
    if State.pendingRecording then
        UI.refs.recordInfo.Text = string.format("รอตั้งชื่อ Macro • %d ขั้นตอน", #State.pendingRecording.events)
    elseif State.mode == "recording" then
        local elapsed = clock() - State.recordStart
        UI.refs.recordInfo.Text = string.format("เวลา %s • %d ขั้นตอน", formatDuration(elapsed), #State.events)
    elseif State.mode == "countdown" then
        UI.refs.recordInfo.Text = "กำลังเตรียมบันทึก..."
    else
        local macro = selectedMacro()
        UI.refs.recordInfo.Text = macro and string.format("%d ขั้นตอน • %s", #macro.events, formatDuration(macro.duration or 0)) or "ยังไม่มี Macro"
    end
    if UI.refs.recordCapability then
        if State.mode == "recording" and App.gameAdapter and adapterSupports("captureSet") then
            local autoStop = adapterSupports("mapState") and " • หยุดเองเมื่อ adapter ยืนยันจบด่าน" or ""
            UI.refs.recordCapability.Text = "กำลังพยายามเก็บเซ็ตจาก adapter • สถานะจะบอกตามจริงเมื่อหยุด" .. autoStop
            UI.refs.recordCapability.TextColor3 = Theme.success
        elseif State.mode == "recording" and App.gameAdapter and adapterSupports("mapState") then
            UI.refs.recordCapability.Text = "adapter ตรวจสถานะได้ • จะหยุดบันทึกอัตโนมัติเมื่อยืนยันจบด่าน (ไม่มีข้อมูลเซ็ตจาก adapter)"
            UI.refs.recordCapability.TextColor3 = Theme.success
        elseif Cap.input == "virtual" then
            UI.refs.recordCapability.Text = "Input: VirtualUser (ทดลอง) • Recording ใช้ UserInputService • ยังไม่ยืนยันบน Delta"
            UI.refs.recordCapability.TextColor3 = Theme.warning
        elseif Cap.input == "none" then
            UI.refs.recordCapability.Text = "บันทึกได้ แต่เล่นซ้ำไม่ได้: ไม่พบ API อินพุตที่ใช้ได้"
            UI.refs.recordCapability.TextColor3 = Theme.danger
        else
            UI.refs.recordCapability.Text = "Input: " .. Cap.inputLabel .. " • " .. Cap.inputDetail
            UI.refs.recordCapability.TextColor3 = Theme.muted
        end
    end
end

function Rec.updateMetaFromEvents(meta, events)
    if not meta then
        return
    end
    meta.count = #events
    meta.duration = #events > 0 and events[#events].t or 0
    meta.modified = os.time()
end

function Rec.ensureProfileForRecording()
    local meta = selectedProfileMeta()
    if meta and Profiles.data and Profiles.data.id == meta.id then
        return meta
    end
    if meta then
        local loaded = readProfileFromDisk(meta.id, { migrate = true })
        if loaded then
            Profiles.data = loaded
            Profiles.selectedMacroId = loaded.selectedMacroId
            Profiles.events = loaded.events
            return meta
        end
    end

    meta = {
        id = newProfileId(),
        name = uniqueProfileName("โปรไฟล์ 1"),
        created = os.time(),
        modified = os.time(),
        duration = 0,
        count = 0,
        macroCount = 1,
    }
    local macro = {
        id = newMacroId(),
        name = "มาโคร 1",
        created = os.time(),
        modified = os.time(),
        events = {},
        set = nil,
        screen = nil,
    }
    Profiles.data = {
        format = PROFILE_FORMAT,
        version = PROFILE_VERSION,
        id = meta.id,
        name = meta.name,
        created = meta.created,
        modified = meta.modified,
        macros = { macro },
        mainMacroId = macro.id,
        selectedMacroId = macro.id,
        events = macro.events,
        count = 0,
        duration = 0,
        macroCount = 1,
    }
    Profiles.events = macro.events
    Profiles.selectedMacroId = macro.id
    addProfileMeta(meta)
    Profiles.selectedId = meta.id
    saveProfileToDisk(meta, {})
    saveIndex()
    App.refreshProfiles()
    Log.add("info", "สร้างโปรไฟล์อัตโนมัติ: " .. meta.name)
    return meta
end

function Rec.captureAdapterSet()
    if not App.gameAdapter or not adapterSupports("captureSet") then
        return
    end
    if type(App.gameAdapter.captureSet) ~= "function" then
        return
    end
    local ok, snapshot = adapterCall("captureSet")
    if not ok or type(snapshot) ~= "table" then
        return
    end

    -- ต้อง serialize ได้จริงก่อนเก็บลง recovery มิฉะนั้นไฟล์ recovery จะเขียนไม่สำเร็จ
    local signature, encodeError = encodeJson(snapshot)
    if type(signature) ~= "string" then
        if not State.recoveryWarned then
            State.recoveryWarned = true
            Log.add("warn", "adapter ส่งข้อมูลเซ็ตที่แปลงเป็น JSON ไม่ได้: " .. tostring(encodeError))
        end
        return
    end
    if #signature > 120000 then
        if not State.recoveryWarned then
            State.recoveryWarned = true
            Log.add("warn", "adapter ส่งข้อมูลเซ็ตใหญ่เกิน 120KB — ไม่บันทึกเพื่อป้องกันไฟล์เสีย")
        end
        return
    end

    local now = os.time()
    State.recordingSetSnapshot = snapshot
    State.recordingSetCapturedAt = now
    State.recordingSetHistory = State.recordingSetHistory or {}
    local previous = State.recordingSetHistory[#State.recordingSetHistory]
    if not previous or previous.signature ~= signature then
        table.insert(State.recordingSetHistory, {
            t = math.max(0, clock() - (State.recordStart or clock())),
            capturedAt = now,
            signature = signature,
            data = snapshot,
        })
        while #State.recordingSetHistory > 20 do
            table.remove(State.recordingSetHistory, 1)
        end
    end
end

function Rec.buildInferredSet(events)
    local keys = {}
    local keyCount = 0
    local clicks = {}
    local clickCount = 0
    for _, event in ipairs(events or {}) do
        if event.type == "keyDown" then
            local key = tostring(event.key or "?")
            if keys[key] == nil then
                keys[key] = 0
                keyCount += 1
            end
            keys[key] = keys[key] + 1
        elseif event.type == "mouseDown" then
            clickCount += 1
            if #clicks < 40 then
                table.insert(clicks, {
                    x = math.floor(numberOr(event.x, 0)),
                    y = math.floor(numberOr(event.y, 0)),
                    t = numberOr(event.t, 0),
                    button = event.button == "Right" and "Right" or "Left",
                })
            end
        end
    end

    local snapshot = State.recordingSetSnapshot
    local history = {}
    for _, item in ipairs(State.recordingSetHistory or {}) do
        if #history < 20 then
            table.insert(history, {
                t = item.t,
                capturedAt = item.capturedAt,
                data = item.data,
            })
        end
    end

    local set = {
        status = snapshot and "detected" or "input-only",
        source = snapshot and "adapter.captureSet" or "input-events",
        capturedAt = snapshot and (State.recordingSetCapturedAt or os.time()) or os.time(),
        note = snapshot
            and "adapter ตรวจจับข้อมูลเซ็ตระหว่างบันทึก (ยังต้องตรวจซ้ำก่อนคืนค่า)"
            or "อนุมานจากอินพุตเท่านั้น ยังไม่ยืนยันตัวละคร/ตำแหน่ง/ออป",
        inferred = {
            keys = keys,
            keyCount = keyCount,
            clickCount = clickCount,
            clicks = clicks,
        },
        detected = snapshot,
        history = history,
    }
    return sanitizeSet(set) or {
        status = "unavailable",
        source = "unknown",
        capturedAt = os.time(),
        note = "ไม่สามารถสร้างข้อมูลเซ็ตได้",
    }
end

function Rec.makePendingRecording(events, set, screen)
    local meta = selectedProfileMeta()
    return {
        events = events,
        set = set,
        profileId = meta and meta.id or nil,
        profileName = meta and meta.name or nil,
        recordedAt = os.time(),
        screen = screen or State.recordViewport or { w = getViewport().X, h = getViewport().Y },
        context = GameContext.mergeContexts(State.recordingContext, GameContext.safeCapture()),
        source = "recording",
    }
end

function Rec.addRecordedEvent(event)
    if State.mode ~= "recording" then
        return
    end
    if #State.events >= MAX_EVENTS then
        Log.add("warn", string.format("ถึงขีดจำกัด %d ขั้นตอน — หยุดบันทึกอัตโนมัติ", MAX_EVENTS))
        App.stopRecording()
        return
    end
    event.t = math.max(0, clock() - State.recordStart)
    table.insert(State.events, event)
end

function Rec.writeLiveRecovery()
    if not Settings.autosave or State.mode ~= "recording" or #State.events == 0 then
        return
    end
    local set = Rec.buildInferredSet(State.events)
    local pending = Rec.makePendingRecording(State.events, set, State.recordViewport)
    Recovery.write(pending)
end

function Rec.startRecordingNow()
    State.token += 1
    local token = State.token
    State.recordingContext = GameContext.safeCapture()
    State.mode = "countdown"
    State.events = {}
    State.recordStart = 0
    State.lastMoveSample = 0
    State.lastRecordedMove = nil
    State.recordingMouse = {}
    State.recordingKeys = {}
    State.nextWorldId = 1
    State.worldTargets = {}
    State.lastWorldTarget = nil
    State.lastWorldSelection = nil
    State.recordingSetSnapshot = nil
    State.recordingSetCapturedAt = nil
    State.recordingSetHistory = {}
    State.lastSetSample = 0
    State.lastRecoveryWrite = 0
    State.recordingStageArmed = false
    State.lastStageSample = 0
    State.stageWarned = false
    State.recordViewport = { w = math.floor(getViewport().X), h = math.floor(getViewport().Y) }
    State.playbackIndex = 0
    State.loop = 0
    State.finished = false
    State.paused = false
    State.selectedSteps = {}
    setStatus("เตรียมบันทึก 3...", "warn")
    App.refreshTransport()
    Rec.updateRecordInfo()

    local meta = selectedProfileMeta()
    Log.add("info", "เตรียมบันทึก: " .. (meta and meta.name or "ไม่มีโปรไฟล์"))

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

        State.recordingContext = GameContext.mergeContexts(State.recordingContext, GameContext.safeCapture())
        State.mode = "recording"
        State.recordStart = clock()
        State.lastMoveSample = 0
        State.lastRecordedMove = nil
        State.recordingSetHistory = {}
        State.recordingStageArmed = false
        State.lastStageSample = 0
        State.stageWarned = false

        -- ต้องซ่อนเมนูก่อนเริ่มเก็บเหตุการณ์เสมอ เพราะเมนูหลักบังจุดคลิกเกือบทั้งจอ
        -- และคลิกที่โดนเมนูบังจะไม่ถูกบันทึก (เดิมพึ่ง autoHide)
        if State.menuVisible then
            setMenuVisible(false)
            State.autoHidden = true
            Log.add("info", "ซ่อนเมนูระหว่างบันทึกเพื่อไม่ให้บังการเก็บคลิก")
        end

        setStatus("กำลังบันทึก", "recording")
        App.refreshTransport()
        Log.add("info", string.format(
            "เริ่มบันทึกอินพุตแล้ว — motion=%s • movementKeys=%s • worldAnchor=%s",
            Settings.recordMotion and "on" or "off",
            Settings.recordMovementKeys and "on" or "off",
            Settings.worldAnchor and "on" or "off"
        ))
        if Settings.worldAnchor and GuiTargeting.pointOverGameGui(-1, -1) then
            Log.add("warn", "ตรวจ UI เกมไม่ได้หรือมี GUI บังจุดทดสอบ — world anchor อาจถูกข้ามเพื่อความปลอดภัย")
        end

        local position = getMousePosition()
        if Settings.recordMotion and position and not pointInGui(position) then
            local x, y = Rec.roundedPosition(position)
            State.lastRecordedMove = position
            Rec.addRecordedEvent({ type = "mouseMove", x = x, y = y })
        end
        Rec.captureAdapterSet()
        Rec.updateRecordInfo()
    end)
end

function App.requestRecordToggle()
    if State.mode == "recording" or State.mode == "countdown" then
        App.stopRecording()
        return
    end
    App.requestStartRecording()
end

function App.requestStartRecording()
    if State.pendingRecording then
        Log.add("warn", "มีข้อมูลรอตั้งชื่อ Macro อยู่ — บันทึกหรือทิ้งก่อน")
        return
    end
    if State.mode ~= "idle" then
        Log.add("warn", "หยุดงานที่กำลังทำก่อนเริ่มบันทึก")
        return
    end
    if Recovery.exists() then
        showConfirm(
            "มีข้อมูลกู้คืนอยู่",
            "การเริ่มบันทึกใหม่จะเขียนทับไฟล์กู้คืนเดิม (ข้อมูลที่ยังไม่ตั้งชื่อจะหาย)",
            "เริ่มบันทึกใหม่",
            function()
                Recovery.clear()
                Rec.ensureProfileForRecording()
                Rec.startRecordingNow()
            end,
            true
        )
        return
    end
    Rec.ensureProfileForRecording()
    Rec.startRecordingNow()
end

function App.saveCurrentProfile(silent)
    local meta = selectedProfileMeta()
    local macro = selectedMacro()
    if not meta or not macro then
        Log.add("warn", "ยังไม่ได้เลือกโปรไฟล์/Macro")
        return false
    end
    if State.mode ~= "idle" or State.pendingRecording then
        Log.add("warn", "หยุดงาน/ตั้งชื่อ Macro ก่อนบันทึก")
        return false
    end
    if #Profiles.events == 0 then
        Log.add("warn", "ยังไม่มีขั้นตอนให้บันทึก")
        return false
    end

    local ok, err = saveProfileToDisk(meta, Profiles.events)
    if not ok then
        Log.add("error", "บันทึกไฟล์โปรไฟล์ไม่สำเร็จ: " .. tostring(err))
        return false
    end
    Rec.updateMetaFromEvents(meta, Profiles.events)
    State.dirty = false
    saveIndex()
    if not silent then
        Log.add("success", string.format("บันทึก \"%s\" / \"%s\" แล้ว (%d ขั้นตอน)", meta.name, macro.name, #Profiles.events))
    end
    App.refreshProfiles()
    return true
end

function App.openMacroNameDialog(pending, suggestedName)
    if not pending or #pending.events == 0 then
        return
    end
    if not State.menuVisible then
        setMenuVisible(true)
    end
    local meta = selectedProfileMeta()
    local macroCount = Profiles.data and #Profiles.data.macros or 0
    local defaultName = suggestedName or ("มาโคร " .. tostring(macroCount + 1))
    if Profiles.data then
        defaultName = uniqueMacroNameIn(Profiles.data.macros or {}, defaultName)
    end

    local modal = openModal(
        "ตั้งชื่อ Macro",
        "ต้องตั้งชื่อก่อนบันทึก • ชื่อซ้ำจะถามยืนยันก่อนเขียนทับ Macro เดิม",
        480,
        310,
        { dismissable = false }
    )
    if not modal then
        Log.add("warn", "เปิดหน้าตั้งชื่อไม่ได้ — ข้อมูลอยู่ใน recovery")
        return
    end

    local summary = newInstance("TextLabel", {
        Size = UDim2.new(1, 0, 0, 42),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = string.format("โปรไฟล์: %s\n%d ขั้นตอน • %s • เซ็ต: %s", meta and meta.name or pending.profileName or "—", #pending.events, formatDuration(pending.events[#pending.events].t), pending.set and pending.set.status or "ไม่มี"),
        TextSize = 11,
        TextColor3 = Theme.muted,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        TextWrapped = true,
        LineHeight = 1.15,
        Parent = modal.content,
    })

    local box = newInstance("TextBox", {
        Size = UDim2.new(1, 0, 0, 36),
        Position = UDim2.fromOffset(0, 50),
        BackgroundColor3 = Theme.dark,
        BorderSizePixel = 0,
        Font = FONT,
        Text = defaultName,
        PlaceholderText = "ชื่อ Macro",
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
        Size = UDim2.new(1, 0, 0, 30),
        Position = UDim2.fromOffset(0, 94),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = "",
        TextSize = 11,
        TextColor3 = Theme.danger,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        TextWrapped = true,
        Parent = modal.content,
    })

    local function reopen(text)
        closeModal()
        task.defer(function()
            App.openMacroNameDialog(pending, text)
        end)
    end

    local function tryCommit()
        local name, nameError = normalizeMacroName(box.Text)
        if not name then
            errorLabel.Text = nameError
            return
        end
        local existing = nil
        if Profiles.data then
            for _, macro in ipairs(Profiles.data.macros or {}) do
                if string.lower(macro.name) == string.lower(name) then
                    existing = macro
                    break
                end
            end
        end
        if existing then
            closeModal()
            showConfirm(
                "ชื่อ Macro ซ้ำ",
                string.format("มี Macro ชื่อ \"%s\" อยู่ (%d ขั้นตอน) — เขียนทับเฉพาะ Macro นี้หรือไม่?", existing.name, #existing.events),
                "เขียนทับ",
                function()
                    App.commitPendingRecording(pending, name, existing.id)
                end,
                true,
                function()
                    reopen(name)
                end
            )
            return
        end
        closeModal()
        App.commitPendingRecording(pending, name, nil)
    end

    modal.addAction("ทิ้งข้อมูล", Theme.dangerDark, function()
        closeModal()
        showConfirm(
            "ทิ้งการบันทึกนี้?",
            string.format("ข้อมูล %d ขั้นตอนที่ยังไม่ตั้งชื่อจะถูกลบ และไฟล์ recovery จะถูกล้าง", #pending.events),
            "ทิ้งข้อมูล",
            function()
                State.pendingRecording = nil
                Recovery.clear()
                State.selectedSteps = {}
                setStatus("ทิ้งข้อมูลบันทึกแล้ว", "warn")
                Log.add("warn", "ผู้ใช้ทิ้งข้อมูลบันทึกที่ยังไม่ตั้งชื่อ")
                App.refreshProfiles()
                Rec.updateRecordInfo()
            end,
            true,
            function()
                reopen(box.Text)
            end
        )
    end, { width = 104 })

    modal.addAction("บันทึก Macro", Theme.accent, tryCommit, { width = 120 })

    task.defer(function()
        pcall(function()
            box:CaptureFocus()
            box.CursorPosition = -1
        end)
    end)
end

function Rec.resolvePendingProfile(pending)
    if Profiles.data and pending.profileId and Profiles.data.id == pending.profileId then
        return selectedProfileMeta(), Profiles.data
    end

    local meta = findProfileMeta(pending.profileId)
    if meta then
        local loaded = readProfileFromDisk(meta.id, { migrate = true })
        if loaded then
            Profiles.data = loaded
            Profiles.selectedId = meta.id
            Profiles.selectedMacroId = loaded.selectedMacroId
            Profiles.events = loaded.events
            meta.macroCount = loaded.macroCount
            return meta, loaded
        end
    end

    meta = {
        id = newProfileId(),
        name = uniqueProfileName(pending.profileName or "กู้คืน"),
        created = os.time(),
        modified = os.time(),
        duration = 0,
        count = 0,
        macroCount = 1,
    }
    local macro = {
        id = newMacroId(),
        name = "มาโคร 1",
        created = os.time(),
        modified = os.time(),
        events = {},
        set = nil,
        screen = nil,
    }
    local data = {
        format = PROFILE_FORMAT,
        version = PROFILE_VERSION,
        id = meta.id,
        name = meta.name,
        created = meta.created,
        modified = meta.modified,
        macros = { macro },
        mainMacroId = macro.id,
        selectedMacroId = macro.id,
        events = macro.events,
        count = 0,
        duration = 0,
        macroCount = 1,
    }
    addProfileMeta(meta)
    Profiles.selectedId = meta.id
    Profiles.data = data
    Profiles.selectedMacroId = macro.id
    Profiles.events = macro.events
    return meta, data
end

function App.commitPendingRecording(pending, name, overwriteId)
    if not pending or not name then
        return false
    end
    local meta, data = Rec.resolvePendingProfile(pending)
    if not meta or not data then
        showNotice("บันทึกไม่สำเร็จ", "ไม่สามารถเตรียมโปรไฟล์สำหรับบันทึกได้")
        return false
    end

    local backupOk, backupError = backupProfileFile(meta)
    if not backupOk then
        Log.add("warn", "สำรองโปรไฟล์ก่อนเขียนทับไม่สำเร็จ: " .. tostring(backupError))
    end

    local target = nil
    if overwriteId then
        target = findMacro(data, overwriteId)
    end
    if target then
        target.name = name
        target.events = pending.events
        target.set = pending.set
        target.screen = pending.screen
        target.context = sanitizeGameContext(pending.context)
        target.modified = os.time()
    else
        target = {
            id = newMacroIdUnique(data.macros),
            name = uniqueMacroNameIn(data.macros, name),
            created = os.time(),
            modified = os.time(),
            events = pending.events,
            set = pending.set,
            screen = pending.screen,
            context = sanitizeGameContext(pending.context),
        }
        table.insert(data.macros, 1, target)
    end

    target.count = #target.events
    target.duration = #target.events > 0 and target.events[#target.events].t or 0
    data.selectedMacroId = target.id
    data.mainMacroId = data.mainMacroId or target.id
    data.events = target.events
    data.count = target.count
    data.duration = target.duration
    data.macroCount = #data.macros
    Profiles.selectedMacroId = target.id
    Profiles.events = target.events

    local ok, err = saveProfileToDisk(meta, target.events)
    if not ok then
        State.dirty = true
        Recovery.write(pending)
        setStatus("บันทึก Macro ไม่สำเร็จ", "error")
        Log.add("error", "บันทึก Macro ลงไฟล์ไม่สำเร็จ: " .. tostring(err))
        showNotice("บันทึกไม่สำเร็จ", "ข้อมูลยังอยู่ในหน่วยความจำและ recovery\n" .. tostring(err))
        return false
    end

    State.pendingRecording = nil
    State.dirty = false
    State.selectedSteps = {}
    State.playbackIndex = 0
    State.loop = 0
    State.finished = false
    Recovery.clear()
    saveIndex()
    Rec.updateMetaFromEvents(meta, target.events)
    setStatus("บันทึก Macro แล้ว", "ready")
    Log.add("success", string.format(
        "บันทึก Macro \"%s\" • %d ขั้นตอน • %s • เซ็ต %s",
        target.name,
        target.count,
        formatDuration(target.duration),
        target.set and target.set.status or "ไม่มี"
    ))
    Log.add("info", "บริบทที่เก็บกับ Macro: " .. GameContext.formatStored(target.context, true))
    App.refreshProfiles()
    Rec.updateRecordInfo()
    return true
end

function App.stopRecording()
    if State.mode == "countdown" then
        State.token += 1
        State.mode = "idle"
        State.events = {}
        State.recordingContext = nil
        State.playbackIndex = 0
        State.loop = 0
        if not State.pendingRecording then
            Recovery.clear()
        end
        setStatus("ยกเลิกการบันทึก", "warn")
        Log.add("info", "ยกเลิกการบันทึก")
        App.refreshTransport()
        Rec.updateRecordInfo()
        return
    end

    if State.mode ~= "recording" then
        return
    end

    local events = State.events
    local endTime = math.max(0, clock() - State.recordStart)
    Rec.closeRecordingInputs(events, endTime)
    State.token += 1
    State.mode = "idle"
    State.events = {}
    State.recordingMouse = {}
    State.recordingKeys = {}
    State.playbackIndex = 0
    State.loop = 0
    State.finished = false

    if #events == 0 then
        State.recordingContext = nil
        Recovery.clear()
        setStatus("ไม่ได้บันทึกขั้นตอน", "warn")
        Log.add("warn", "หยุดบันทึกแต่ไม่มีขั้นตอนใดถูกบันทึก")
        App.refreshTransport()
        Rec.updateRecordInfo()
        return
    end

    local set = Rec.buildInferredSet(events)
    local pending = Rec.makePendingRecording(events, set, State.recordViewport)
    State.pendingRecording = pending
    State.recordingContext = nil
    Recovery.write(pending)

    local worldClicks = 0
    local guiClicks = 0
    local upgradeClicks = 0
    local guiUnknownClicks = 0
    local totalClicks = 0
    for _, event in ipairs(events) do
        if event.type == "mouseDown" then
            totalClicks += 1
            if event.world then
                worldClicks += 1
            end
            if event.gui then
                guiClicks += 1
            end
            if event.selection then
                upgradeClicks += 1
            end
            if event.guiUnknown then
                guiUnknownClicks += 1
            end
        end
    end

    setStatus("รอตั้งชื่อ Macro", "warn")
    Log.add("info", string.format(
        "หยุดบันทึก: %d ขั้นตอน • คลิก %d ครั้ง • world=%d • gui=%d • upgrade-bound=%d • gui-unknown=%d • motion=%s • movementKeys=%s • set status %s",
        #events,
        totalClicks,
        worldClicks,
        guiClicks,
        upgradeClicks,
        guiUnknownClicks,
        Settings.recordMotion and "on" or "off",
        Settings.recordMovementKeys and "on" or "off",
        set.status
    ))
    App.refreshProfiles()
    Rec.updateRecordInfo()
    if not State.menuVisible then
        setMenuVisible(true)
    end
    App.openMacroNameDialog(pending)
end

function App.requestStop()
    if State.pendingRecording then
        App.openMacroNameDialog(State.pendingRecording)
        return
    end
    if State.mode == "recording" or State.mode == "countdown" then
        App.stopRecording()
        return
    end
    if State.mode == "playing" or State.mode == "paused" then
        App.stopPlayback()
        return
    end
    Log.add("info", "ไม่มีงานที่กำลังทำงาน")
end

function App.emergencyStop()
    if State.pendingRecording then
        setStatus("มีข้อมูลรอตั้งชื่อ Macro", "warn")
        if not State.menuVisible then
            setMenuVisible(true)
        end
        App.openMacroNameDialog(State.pendingRecording)
        return
    end

    local previousMode = State.mode
    local hadAfk = Settings.afkEnabled
    if hadAfk then
        Settings.afkEnabled = false
        saveSettings()
    end

    if previousMode == "recording" or previousMode == "countdown" then
        App.stopRecording()
    elseif previousMode == "playing" or previousMode == "paused" then
        App.stopPlayback()
    else
        State.token += 1
        State.dragging = false
        releaseHeld()
        setStatus("พร้อมใช้งาน", "ready")
    end

    if State.autoHidden then
        State.autoHidden = false
        setMenuVisible(true)
    end
    Log.add("warn", "หยุดฉุกเฉิน (F8): หยุดงานและปิด AFK • ข้อมูลที่ยังไม่ตั้งชื่อถูกเก็บไว้")
    App.updateAfkUI()
    Rec.updateRecordInfo()
end

function App.promptDeleteRecovery()
    if State.pendingRecording then
        Log.add("warn", "มีข้อมูลรอตั้งชื่ออยู่ — บันทึกหรือทิ้งก่อน")
        return
    end
    if not Recovery.exists() then
        showNotice("ไม่มีไฟล์กู้คืน", "ไม่พบไฟล์ " .. RECOVERY_PATH)
        return
    end
    showConfirm(
        "ลบไฟล์กู้คืน?",
        "ข้อมูลการบันทึกที่ยังไม่ตั้งชื่อจะหายถาวร",
        "ลบไฟล์",
        function()
            local ok, err = Recovery.clear()
            if ok then
                setStatus("ลบไฟล์กู้คืนแล้ว", "warn")
                Log.add("warn", "ลบไฟล์กู้คืน")
            else
                Log.add("error", "ลบไฟล์กู้คืนไม่สำเร็จ: " .. tostring(err))
            end
            App.refreshProfiles()
        end,
        true
    )
end

function App.promptRecovery()
    if State.pendingRecording then
        App.openMacroNameDialog(State.pendingRecording)
        return
    end
    if State.mode ~= "idle" then
        showNotice("หยุดงานก่อนกู้คืน", "หยุด Macro ที่กำลังบันทึก/เล่นก่อน แล้วจึงกู้คืนข้อมูลที่ยังไม่ตั้งชื่อ")
        return
    end
    local pending, err = Recovery.read()
    if not pending then
        showNotice("กู้คืนไม่ได้", tostring(err or "ไม่พบข้อมูลกู้คืน"))
        return
    end

    local modal = openModal("พบข้อมูลบันทึกที่ยังไม่ตั้งชื่อ", nil, 500, 310)
    if not modal then
        return
    end
    local text = string.format(
        "บันทึกเมื่อ: %s\nจำนวน: %d ขั้นตอน • %s\nโปรไฟล์เดิม: %s\nเซ็ต: %s\n\nการกู้คืนจะเปิดหน้าตั้งชื่อ Macro และยังไม่เล่นซ้ำ",
        os.date("%Y-%m-%d %H:%M:%S", pending.recordedAt),
        #pending.events,
        formatDuration(pending.events[#pending.events].t),
        pending.profileName or pending.profileId or "—",
        pending.set and pending.set.status or "ไม่มี"
    )
    newInstance("TextLabel", {
        Size = UDim2.new(1, 0, 0, 160),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = text,
        TextSize = 12,
        TextColor3 = Theme.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        TextWrapped = true,
        LineHeight = 1.15,
        Parent = modal.content,
    })

    modal.addAction("ปิด", Theme.panel3, closeModal, { width = 80 })
    modal.addAction("ทิ้งไฟล์", Theme.dangerDark, function()
        closeModal()
        showConfirm("ทิ้งข้อมูลกู้คืน?", "ข้อมูลนี้จะหายถาวร", "ทิ้งข้อมูล", function()
            Recovery.clear()
            State.pendingRecording = nil
            App.refreshProfiles()
            Log.add("warn", "ผู้ใช้ทิ้งข้อมูลกู้คืน")
        end, true)
    end, { width = 96 })
    modal.addAction("กู้คืน", Theme.accent, function()
        closeModal()
        State.pendingRecording = pending
        setStatus("รอตั้งชื่อ Macro ที่กู้คืน", "warn")
        Log.add("info", "กู้คืนข้อมูลบันทึก: " .. tostring(#pending.events) .. " ขั้นตอน")
        App.refreshProfiles()
        Rec.updateRecordInfo()
        App.openMacroNameDialog(pending)
    end, { width = 88 })
end

-- 14) รับอินพุตเพื่อบันทึก และลากหน้าต่าง
-- ============================================================================

local Running = true
local Connections = {}

local function connectTracked(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(Connections, connection)
    return connection
end

local function inputPosition(input)
    if not input then
        return nil
    end
    if input.UserInputType == Enum.UserInputType.Touch then
        local p = input.Position
        if p then
            return Vector2.new(p.X, p.Y)
        end
        return nil
    end
    return getMousePosition()
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
        if getFocusedTextBox() then
            return
        end

        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.MouseButton2
            or input.UserInputType == Enum.UserInputType.Touch then
            local button = input.UserInputType == Enum.UserInputType.MouseButton2 and "Right" or "Left"
            local position = inputPosition(input)
            if not position or pointInGui(position) then
                return
            end
            if not State.recordingMouse[button] then
                local source = input.UserInputType == Enum.UserInputType.Touch and "touch" or "mouse"
                local x, y = Rec.roundedPosition(position)
                local world = nil
                local worldId = nil
                local gui = nil
                local selection = nil
                local guiUnknown = false
                if button == "Left" then
                    local guiOk, guiTarget, guiReason = pcall(function()
                        return GuiTargeting.captureGuiTarget(position.X, position.Y)
                    end)
                    if not guiOk then
                        guiUnknown = true
                        if not State.guiCaptureWarned then
                            State.guiCaptureWarned = true
                            Log.add("warn", "ตรวจ GUI เกมระหว่างบันทึกไม่ได้: " .. tostring(guiTarget))
                        end
                    elseif guiReason == "own" then
                        return
                    elseif guiTarget then
                        gui = guiTarget
                        selection = GuiTargeting.bindUpgradeSelection(guiTarget)
                        if not selection then
                            -- คลิก GUI อื่นที่ไม่ใช่ปุ่มอัปเกรดอาจเปลี่ยนยูนิตที่เลือก
                            -- ล้างเป้าอัปเกรดเดิมเพื่อไม่ให้ผูกผิดตัว
                            State.lastWorldSelection = nil
                        end
                    elseif GuiTargeting.pointOverGameGui(position.X, position.Y) then
                        guiUnknown = true
                    elseif Settings.worldAnchor then
                        local anchorOk, anchor = pcall(function()
                            return captureWorldAnchor(position.X, position.Y, source)
                        end)
                        if anchorOk then
                            world = anchor
                        end
                    end
                    if world then
                        worldId = State.nextWorldId or 1
                        State.nextWorldId = worldId + 1
                    end
                else
                    -- คลิกขวาอาจใช้ยกเลิกการเลือกยูนิต จึงไม่ควรคงเป้าอัปเกรดเดิม
                    State.lastWorldSelection = nil
                end
                local downEvent = {
                    t = 0,
                    type = "mouseDown",
                    button = button,
                    x = x,
                    y = y,
                    source = source,
                    world = world,
                    worldId = worldId,
                    gui = gui,
                    selection = selection,
                    guiUnknown = guiUnknown or nil,
                }
                State.recordingMouse[button] = {
                    button = button,
                    source = source,
                    startPosition = position,
                    lastPosition = position,
                    maxDistance = 0,
                    world = world,
                    worldId = worldId,
                    gui = gui,
                    selection = selection,
                    guiUnknown = guiUnknown,
                    downEvent = downEvent,
                }
                State.lastRecordedMove = position
                Rec.addRecordedEvent(downEvent)
                if world and State.mode == "recording" then
                    local target = {
                        id = worldId,
                        world = world,
                        t = downEvent.t or math.max(0, clock() - (State.recordStart or clock())),
                        event = downEvent,
                    }
                    State.worldTargets = State.worldTargets or {}
                    State.worldTargets[worldId] = target
                    State.lastWorldTarget = target
                    if GuiTargeting.isLikelySelectionWorld(world) then
                        State.lastWorldSelection = target
                    else
                        -- คลิกพื้น/โซนวางไม่ควรคงยูนิตที่เลือกไว้ก่อนหน้าเป็นเป้าอัปเกรด
                        State.lastWorldSelection = nil
                    end
                end
            end
        elseif input.UserInputType == Enum.UserInputType.Keyboard then
            local keyCode = input.KeyCode
            if keyCode and keyCode ~= Enum.KeyCode.Unknown then
                local keyName = keyCode.Name
                local vk = VK_BY_NAME[keyName]
                if vk then
                    if not State.recordingKeys[keyName] then
                        if Settings.recordMovementKeys or not isMovementKeyName(keyName) then
                            State.recordingKeys[keyName] = { vk = vk }
                            Rec.addRecordedEvent({ type = "keyDown", key = keyName, vk = vk })
                        else
                            State.recordingKeys[keyName] = { vk = vk, filtered = true }
                        end
                    end
                else
                    Rec.warnUnsupportedKey(keyName)
                end
            end
        end
        Rec.updateRecordInfo()
    end)

    connectTracked(UserInputService.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            State.dragging = false
            State.dragTouchId = nil
        end

        if State.mode ~= "recording" then
            return
        end

        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.MouseButton2
            or input.UserInputType == Enum.UserInputType.Touch then
            local button = input.UserInputType == Enum.UserInputType.MouseButton2 and "Right" or "Left"
            local held = State.recordingMouse[button]
            if held then
                State.recordingMouse[button] = nil
                local position = inputPosition(input) or held.lastPosition
                Rec.updateHeldMouseDistance(held, position)
                if Rec.shouldDropHeldClick(held, position) then
                    Rec.removeRecordedEvent(State.events, held.downEvent)
                    Rec.unregisterWorldTarget(held)
                else
                    local finalPosition = position or held.startPosition or held.lastPosition
                    if finalPosition then
                        local x, y = Rec.roundedPosition(finalPosition)
                        Rec.addRecordedEvent({
                            type = "mouseUp",
                            button = button,
                            x = x,
                            y = y,
                            source = held.source,
                            world = held.world,
                            worldId = held.worldId,
                            gui = held.gui,
                            selection = held.selection,
                            guiUnknown = held.guiUnknown,
                        })
                    end
                end
            end
        elseif input.UserInputType == Enum.UserInputType.Keyboard then
            if getFocusedTextBox() then
                return
            end
            local keyCode = input.KeyCode
            if keyCode and keyCode ~= Enum.KeyCode.Unknown then
                local keyName = keyCode.Name
                local held = State.recordingKeys[keyName]
                if held then
                    State.recordingKeys[keyName] = nil
                    if not held.filtered then
                        Rec.addRecordedEvent({ type = "keyUp", key = keyName, vk = held.vk or VK_BY_NAME[keyName] })
                    end
                end
            end
        end
        Rec.updateRecordInfo()
    end)

    connectTracked(UserInputService.InputChanged, function(input)
        if State.dragging and UI.main
            and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
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

        if State.mode ~= "recording" then
            return
        end
        if getFocusedTextBox() then
            return
        end

        if input.UserInputType == Enum.UserInputType.MouseWheel then
            if not Settings.recordMotion then
                return
            end
            local position = getMousePosition()
            if position and pointInGui(position) then
                return
            end
            local amount = input.Position.Z
            if amount and amount ~= 0 then
                Rec.addRecordedEvent({ type = "wheel", z = amount })
            end
            return
        end

        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            local position = inputPosition(input)
            if not position then
                return
            end
            local isTouch = input.UserInputType == Enum.UserInputType.Touch
            for _, held in pairs(State.recordingMouse) do
                if (held.source == "touch") == isTouch then
                    Rec.updateHeldMouseDistance(held, position)
                end
            end
            if pointInGui(position) then
                return
            end
            if not Settings.recordMotion then
                return
            end
            local now = clock()
            if now - State.lastMoveSample < 0.033 then
                return
            end
            State.lastMoveSample = now
            local last = State.lastRecordedMove
            if not last or (position - last).Magnitude >= 2 then
                local x, y = Rec.roundedPosition(position)
                State.lastRecordedMove = position
                Rec.addRecordedEvent({ type = "mouseMove", x = x, y = y })
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
                    Rec.updateRecordInfo()
                end
            end
            return
        end

        local now = clock()
        local pointerPosition = getMousePosition()
        if pointerPosition then
            for _, held in pairs(State.recordingMouse) do
                if held.source ~= "touch" then
                    Rec.updateHeldMouseDistance(held, pointerPosition)
                end
            end
        end
        if Settings.recordMotion and now - State.lastMoveSample >= 0.033 and not Cap.mobile then
            State.lastMoveSample = now
            if pointerPosition then
                local mouseHeld = next(State.recordingMouse) ~= nil
                if mouseHeld or not pointInGui(pointerPosition) then
                    local last = State.lastRecordedMove
                    if not last or (pointerPosition - last).Magnitude >= 2 then
                        local x, y = Rec.roundedPosition(pointerPosition)
                        State.lastRecordedMove = pointerPosition
                        Rec.addRecordedEvent({ type = "mouseMove", x = x, y = y })
                    end
                end
            end
        end

        if App.gameAdapter and adapterSupports("captureSet") then
            if now - (State.lastSetSample or 0) >= 2 then
                State.lastSetSample = now
                Rec.captureAdapterSet()
            end
        end

        -- หยุดบันทึกอัตโนมัติเฉพาะเมื่อ adapter ยืนยันจบด่านจริงเท่านั้น
        -- ต้องเห็น stageEnded = false อย่างน้อยหนึ่งครั้งก่อน เพื่อไม่ให้ state ค้างจากด่านก่อนหน้าทำให้หยุดทันที
        if App.gameAdapter and adapterSupports("mapState") then
            if now - (State.lastStageSample or 0) >= 1 then
                State.lastStageSample = now
                local stageState, stageError = adapterState()
                if stageState then
                    if stageState.stageEnded ~= true then
                        State.recordingStageArmed = true
                    elseif State.recordingStageArmed
                        and stageState.ready == true
                        and stageState.loading ~= true
                        and stageState.frozen ~= true then
                        Log.add("info", "adapter ยืนยันจบด่าน — หยุดบันทึกอัตโนมัติและรอตั้งชื่อ Macro")
                        App.stopRecording()
                        return
                    end
                elseif not State.stageWarned then
                    State.stageWarned = true
                    Log.add("warn", "ตรวจจุดจบด่านไม่ได้ระหว่างบันทึก: " .. tostring(stageError))
                end
            end
        end

        if now - (State.lastRecoveryWrite or 0) >= RECOVERY_SNAPSHOT_SECONDS then
            State.lastRecoveryWrite = now
            local recoveryOk, recoveryError = pcall(Rec.writeLiveRecovery)
            if not recoveryOk and not State.recoveryWarned then
                State.recoveryWarned = true
                Log.add("warn", "บันทึก recovery ระหว่างบันทึกไม่สำเร็จ: " .. tostring(recoveryError))
            end
        end

        if now - lastInfoUpdate >= 0.2 then
            lastInfoUpdate = now
            Rec.updateRecordInfo()
        end
    end)
end

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

local function stateReadiness(state)
    if type(state) ~= "table" then
        return false, "adapter.getState() ไม่ได้คืนตารางสถานะ"
    end
    if state.frozen == true then
        return false, "adapter รายงานว่าเกมค้าง"
    end
    if state.loading == true then
        return false, "adapter รายงานว่าเกมกำลังโหลด"
    end
    if state.ready ~= true then
        return false, "adapter ยังไม่ยืนยัน ready = true"
    end
    return true
end

-- adapter contract: getState() ต้องคืน { ready = true/false, loading = bool?, frozen = bool? }
-- ไม่มี adapter = ตรวจไม่ได้ ระบบจะไม่รอและไม่เดาสถานะ
function App.waitForGameReady(token, reason, options)
    options = options or {}
    if not App.gameAdapter or not adapterSupports("mapState") then
        return false, "ไม่มี adapter ที่ตรวจสถานะเกม"
    end

    local attempts = math.max(1, math.floor(numberOr(options.attempts, GAME_MAX_ATTEMPTS)))
    local timeout = math.max(1, numberOr(options.timeout, GAME_WAIT_SECONDS))
    local lastReason = "ไม่ทราบสถานะ"

    for attempt = 1, attempts do
        local state, stateError = adapterState()
        local ready, why = stateReadiness(state)
        if ready then
            return true
        end
        lastReason = why or stateError or "ไม่พร้อม"

        if token and token ~= State.token then
            return false, "ยกเลิก"
        end

        setStatus(string.format("รอเกมพร้อม %d/%d", attempt, attempts), "paused")
        Log.add("warn", string.format(
            "รอเกมพร้อม %d/%d: %s%s",
            attempt,
            attempts,
            tostring(lastReason),
            reason and (" • " .. tostring(reason)) or ""
        ))

        local deadline = clock() + timeout
        while clock() < deadline do
            if token and token ~= State.token then
                return false, "ยกเลิก"
            end
            task.wait(0.5)
            local state2 = adapterState()
            local ready2, why2 = stateReadiness(state2)
            if ready2 then
                setStatus("เกมพร้อมแล้ว", "playing")
                Log.add("info", "เกมกลับมาพร้อม — ทำต่อได้")
                return true
            end
            lastReason = why2 or lastReason
        end
    end

    return false, string.format("รอเกมพร้อม %d ครั้งแล้วยังไม่พร้อม (%s)", attempts, tostring(lastReason))
end

local function buildPlaybackEvents(events)
    local skip = {}
    local skipped = 0
    local function mark(index)
        if not skip[index] then
            skip[index] = true
            skipped += 1
        end
    end

    for index, event in ipairs(events) do
        if not Settings.recordMotion and (event.type == "mouseMove" or event.type == "wheel") then
            mark(index)
        elseif not Settings.recordMovementKeys and isMovementKeyEvent(event) then
            mark(index)
        end
    end

    if not Settings.recordMotion then
        -- ข้อมูลเก่าอาจมี mouseDown/mouseUp ขวาคั่นด้วยการลากกล้อง
        -- ตัดทั้งคู่เมื่อตำแหน่งเปลี่ยนเกินเกณฑ์ เพื่อไม่ให้ replay แล้วหมุนกล้อง
        local rightDown = nil
        local rightDownIndex = nil
        local rightMaxDistance = 0
        for index, event in ipairs(events) do
            if event.type == "mouseDown" and event.button == "Right" then
                if rightDownIndex then
                    mark(rightDownIndex)
                end
                rightDown = event
                rightDownIndex = index
                rightMaxDistance = 0
            elseif rightDown and (event.type == "mouseMove" or event.type == "mouseDown" or event.type == "mouseUp") then
                local distance = eventPointDistance(rightDown, event)
                if distance > rightMaxDistance then
                    rightMaxDistance = distance
                end
                if event.type == "mouseUp" and event.button == "Right" then
                    if rightMaxDistance > MOUSE_DRAG_THRESHOLD then
                        mark(rightDownIndex)
                        mark(index)
                    end
                    rightDown = nil
                    rightDownIndex = nil
                end
            end
        end

        -- ทัชแบบลาก (หมุนกล้อง) ไม่ควรถูกเล่นเป็นคลิกซ้ำ
        -- ข้อมูลใหม่มี source="touch"; ข้อมูลเก่าที่ไม่มี source ต้องตรวจจากระยะแทน
        local touchDown = nil
        local touchDownIndex = nil
        local touchMaxDistance = 0
        for index, event in ipairs(events) do
            if event.type == "mouseDown" and event.button == "Left" and event.source == "touch" then
                if touchDownIndex then
                    mark(touchDownIndex)
                end
                touchDown = event
                touchDownIndex = index
                touchMaxDistance = 0
            elseif touchDown and (event.type == "mouseMove" or event.type == "mouseDown" or event.type == "mouseUp") then
                local distance = eventPointDistance(touchDown, event)
                if distance > touchMaxDistance then
                    touchMaxDistance = distance
                end
                if event.type == "mouseUp" and event.button == "Left" then
                    if touchMaxDistance > TOUCH_DRAG_THRESHOLD then
                        mark(touchDownIndex)
                        mark(index)
                    end
                    touchDown = nil
                    touchDownIndex = nil
                end
            end
        end

        -- Macro รุ่นก่อนไม่มี source: ปุ่มซ้ายที่ลากไกลมักเป็นทัชหมุนกล้อง
        -- ตัดทั้ง down/up เมื่อระยะเปลี่ยนเกินเกณฑ์ เพื่อไม่ให้ replay เป็นคลิก
        local legacyDown = nil
        local legacyDownIndex = nil
        local legacyMaxDistance = 0
        for index, event in ipairs(events) do
            if event.type == "mouseDown" and event.button == "Left" and event.source == nil then
                if legacyDownIndex then
                    mark(legacyDownIndex)
                end
                legacyDown = event
                legacyDownIndex = index
                legacyMaxDistance = 0
            elseif legacyDown and (event.type == "mouseMove" or event.type == "mouseDown" or event.type == "mouseUp") then
                local distance = eventPointDistance(legacyDown, event)
                if distance > legacyMaxDistance then
                    legacyMaxDistance = distance
                end
                if event.type == "mouseUp" and event.button == "Left" then
                    if legacyMaxDistance > LEGACY_LEFT_DRAG_THRESHOLD then
                        mark(legacyDownIndex)
                        mark(index)
                    end
                    legacyDown = nil
                    legacyDownIndex = nil
                end
            end
        end
    end

    local keptWorldIds = {}
    for index, event in ipairs(events) do
        if not skip[index] and event.type == "mouseDown" and event.world and event.worldId then
            keptWorldIds[event.worldId] = true
        end
    end

    local orphanSelections = 0
    for index, event in ipairs(events) do
        -- ทิ้งเฉพาะ mouseDown ที่เป้าหมายเสีย; ปล่อย mouseUp ให้ทำงานต่อเพื่อกันเมาส์ค้าง
        if not skip[index] and event.type == "mouseDown" and event.selectionInvalid then
            mark(index)
            if event.type == "mouseDown" then
                orphanSelections += 1
                for nextIndex = index + 1, #events do
                    local nextEvent = events[nextIndex]
                    if nextEvent.type == "mouseUp" and nextEvent.button == event.button then
                        mark(nextIndex)
                        break
                    end
                    if nextEvent.type == "mouseDown" and nextEvent.button == event.button then
                        break
                    end
                end
            end
        end
    end

    for index, event in ipairs(events) do
        -- เช่นเดียวกับ selectionInvalid: ไม่ทิ้ง mouseUp เดี่ยว ๆ เพราะจะทำให้ปล่อยเมาส์ไม่ได้
        if not skip[index] and event.type == "mouseDown" and event.selection and event.selection.worldId
            and not keptWorldIds[event.selection.worldId] then
            mark(index)
            if event.type == "mouseDown" then
                orphanSelections += 1
                for nextIndex = index + 1, #events do
                    local nextEvent = events[nextIndex]
                    if nextEvent.type == "mouseUp" and nextEvent.button == event.button then
                        mark(nextIndex)
                        break
                    end
                    if nextEvent.type == "mouseDown" and nextEvent.button == event.button then
                        break
                    end
                end
            end
        end
    end
    if orphanSelections > 0 then
        Log.add("warn", string.format(
            "ข้าม %d คลิก GUI ที่ผูกกับยูนิตแต่ข้อมูลเป้าหมายใช้ไม่ได้/ถูกกรองออก — ไม่คลิกอัปเกรดโดยไม่รู้เป้าหมาย",
            orphanSelections
        ))
    end

    local result = {}
    for index, event in ipairs(events) do
        if not skip[index] then
            table.insert(result, event)
        end
    end
    return result, skipped
end

local function scaledPoint(event)
    local scale = State.playbackScale or { x = 1, y = 1 }
    local sx = clampSafe(numberOr(scale.x, 1), 0.1, 10)
    local sy = clampSafe(numberOr(scale.y, 1), 0.1, 10)
    local x = math.floor(numberOr(event.x, 0) * sx + Settings.offsetX + 0.5)
    local y = math.floor(numberOr(event.y, 0) * sy + Settings.offsetY + 0.5)
    return math.max(0, x), math.max(0, y)
end

local function projectWorldPoint(world)
    if type(world) ~= "table" then
        return nil, nil, "ไม่มีข้อมูลตำแหน่งโลก"
    end
    local camera = workspace.CurrentCamera
    if not camera then
        return nil, nil, "ไม่พบกล้อง"
    end
    local wx = numberOr(world.x, nil)
    local wy = numberOr(world.y, nil)
    local wz = numberOr(world.z, nil)
    if not wx or not wy or not wz then
        return nil, nil, "ตำแหน่งโลกไม่ถูกต้อง"
    end

    local projected = nil
    local onScreen = false
    local ok = pcall(function()
        local point = Vector3.new(wx, wy, wz)
        if world.space == "screen" then
            projected, onScreen = camera:WorldToScreenPoint(point)
        else
            projected, onScreen = camera:WorldToViewportPoint(point)
        end
    end)
    if not ok or not onScreen or not projected or projected.Z <= 0 then
        return nil, nil, "ตำแหน่งโลกอยู่นอกจอหรืออยู่หลังกล้อง"
    end

    local viewport = getViewport()
    local x = math.floor(projected.X + Settings.offsetX + 0.5)
    local y = math.floor(projected.Y + Settings.offsetY + 0.5)
    if x < 0 or y < 0 or x > viewport.X or y > viewport.Y then
        return nil, nil, "ตำแหน่งโลกอยู่นอกจอ"
    end
    return x, y
end

local function worldHitLabel(hitInfo)
    if type(hitInfo) ~= "table" then
        return "ไม่ทราบ"
    end
    return tostring(hitInfo.modelName or hitInfo.modelPath or hitInfo.name or hitInfo.path or hitInfo.class or "ไม่ทราบ")
end

local function verifyWorldHit(world, x, y)
    if type(world) ~= "table" then
        return false, "ไม่มีข้อมูลตำแหน่งโลก", { kind = "invalid" }
    end
    local hit = raycastFromScreen(x, y, world.space)
    if not hit or not hit.Position then
        return false, "ไม่พบพื้นผิวที่จุดคลิก", { kind = "none" }
    end
    local dx = hit.Position.X - numberOr(world.x, 0)
    local dy = hit.Position.Y - numberOr(world.y, 0)
    local dz = hit.Position.Z - numberOr(world.z, 0)
    local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
    local horizontal = math.sqrt(dx * dx + dz * dz)
    local current = describeWorldHit(hit)
    local recorded = type(world.hit) == "table" and world.hit or nil
    local info = {
        hit = hit,
        current = current,
        distance = distance,
        horizontal = horizontal,
        dx = dx,
        dy = dy,
        dz = dz,
        kind = "ok",
    }

    if distance > WORLD_MATCH_RADIUS then
        -- แยก "มีวัตถุอยู่บนจุดวาง" (กดแล้วจะโดนวัตถุ) ออกจาก "พื้นผิวเดิมหาย/ถูกย้าย"
        local sameModel = recorded and recorded.modelPath and current
            and current.modelPath == recorded.modelPath
        if current and not current.isTerrain and not sameModel
            and dy > WORLD_MATCH_RADIUS and horizontal <= WORLD_OCCUPIED_RADIUS then
            info.kind = "occupied"
            return false, string.format(
                "จุดนี้มี %s อยู่บนจุดวาง (สูง %.1f สตัด) — ไม่คลิกทับ; เริ่มรอบใหม่/เคลียร์จุด หรือเปิด \"คลิกจุดวางเดิมแม้มีวัตถุอยู่บนจุด\"",
                worldHitLabel(current),
                distance
            ), info
        end
        info.kind = "blocked"
        return false, string.format(
            "ตำแหน่งโลกเปลี่ยนไป %.1f สตัด (เกิน %.1f) — จุดคลิกตอนนี้คือ %s",
            distance,
            WORLD_MATCH_RADIUS,
            worldHitLabel(current)
        ), info
    end

    if not recorded then
        return true, nil, info
    end
    if not current then
        info.kind = "blocked"
        return false, "อ่านลายเซ็นพื้นผิวปัจจุบันไม่ได้", info
    end

    if recorded.modelPath or recorded.modelName then
        if recorded.modelPath and not current.modelPath then
            info.kind = "moved"
            return false, "ไม่พบโมเดลเป้าหมายเดิมที่จุดคลิก", info
        end
        if recorded.modelName and not current.modelName then
            info.kind = "moved"
            return false, "ไม่พบชื่อโมเดลเป้าหมายเดิมที่จุดคลิก", info
        end
        if recorded.modelPath and current.modelPath and recorded.modelPath ~= current.modelPath then
            info.kind = "moved"
            return false, string.format(
                "โมเดลเป้าหมายเปลี่ยนจาก %s เป็น %s",
                tostring(recorded.modelName or recorded.modelPath),
                tostring(current.modelName or current.modelPath)
            ), info
        end
        if recorded.modelName and current.modelName and recorded.modelName ~= current.modelName then
            info.kind = "moved"
            return false, string.format(
                "ชื่อโมเดลเป้าหมายเปลี่ยนจาก %s เป็น %s",
                tostring(recorded.modelName),
                tostring(current.modelName)
            ), info
        end
        return true, nil, info
    end

    if recorded.path and current.path and recorded.path ~= current.path then
        info.kind = "moved"
        return false, "พื้นผิวเป้าหมายเปลี่ยนจาก " .. tostring(recorded.path) .. " เป็น " .. tostring(current.path), info
    end
    if recorded.name and current.name and recorded.name ~= current.name then
        info.kind = "moved"
        return false, "ชื่อพื้นผิวเป้าหมายเปลี่ยนจาก " .. tostring(recorded.name) .. " เป็น " .. tostring(current.name), info
    end
    if recorded.class and current.class and recorded.class ~= current.class then
        info.kind = "moved"
        return false, "ชนิดพื้นผิวเป้าหมายเปลี่ยนจาก " .. tostring(recorded.class) .. " เป็น " .. tostring(current.class), info
    end
    return true, nil, info
end

local function isOwnOrGameGuiAt(x, y)
    if pointInGui(Vector2.new(x, y)) then
        return true, "own"
    end
    local target, _, checked, ownBlocked = GuiTargeting.guiTargetAt(x, y)
    if ownBlocked then
        return true, "own"
    end
    if target then
        return true, tostring(target.fullName or target.className or "GUI")
    end
    if not checked then
        return true, "unknown"
    end
    return false, nil
end

-- ค้นหาพิกเซลใกล้ ๆ ที่ยังยิงโดนพื้นผิวเป้าหมายเดิม (ภายในรัศมีที่ยอมรับ)
-- ใช้เมื่อจุดเดิมถูกบังบางส่วน โดยไม่หมุนกล้องและไม่เปลี่ยนไปคลิกวัตถุที่บัง
local function findVisibleWorldPoint(world, x, y)
    local viewport = getViewport()
    local candidates = {}
    for offsetY = -WORLD_SCAN_RADIUS, WORLD_SCAN_RADIUS, WORLD_SCAN_STEP do
        for offsetX = -WORLD_SCAN_RADIUS, WORLD_SCAN_RADIUS, WORLD_SCAN_STEP do
            local distance = math.sqrt(offsetX * offsetX + offsetY * offsetY)
            if distance > 0 and distance <= WORLD_SCAN_RADIUS then
                table.insert(candidates, { x = offsetX, y = offsetY, d = distance })
            end
        end
    end
    table.sort(candidates, function(a, b)
        return a.d < b.d
    end)

    for _, candidate in ipairs(candidates) do
        local cx = x + candidate.x
        local cy = y + candidate.y
        if cx >= 0 and cy >= 0 and cx <= viewport.X and cy <= viewport.Y then
            local verified, _, info = verifyWorldHit(world, cx, cy)
            if verified and info and info.distance <= WORLD_MATCH_RADIUS then
                local blocked = isOwnOrGameGuiAt(cx, cy)
                if not blocked then
                    return cx, cy, info, candidate.d
                end
            end
        end
    end
    return nil, nil, nil, nil
end

local function resolveWorldEventPoint(event)
    local x, y, projectError = projectWorldPoint(event.world)
    if not x then
        if Settings.worldFallback ~= true then
            return nil, nil, tostring(projectError)
                .. " — หมุนกล้องให้ตรงกับตอนบันทึก หรือเปิดตั้งค่า \"ใช้พิกัดหน้าจอเดิมเมื่อจุดโลกอยู่นอกจอ\""
        end
        -- worldFallback: ใช้พิกัดหน้าจอที่บันทึกไว้ แต่ยังต้องตรวจว่าไม่มี GUI บัง
        local sx, sy = scaledPoint(event)
        if pointInGui(Vector2.new(sx, sy)) then
            return nil, nil, nil, "own"
        end
        local target, _, checked, ownBlocked = GuiTargeting.guiTargetAt(sx, sy)
        if ownBlocked then
            return nil, nil, nil, "own"
        end
        if target then
            return nil, nil, "พิกัดหน้าจอสำรองถูก GUI เกมบัง ("
                .. tostring(target.fullName or target.className or "GUI") .. ")"
        end
        if not checked then
            return nil, nil, "ตรวจสอบ GUI ไม่ได้ จึงยืนยันไม่ได้ว่าพิกัดหน้าจอสำรองไม่ถูก UI บัง"
        end
        if not State.worldProjectionFallbackWarned then
            State.worldProjectionFallbackWarned = true
            Log.add("warn", "worldFallback ทำงาน: จุดโลกอยู่นอกจอ/หลังกล้อง — ใช้พิกัดหน้าจอเดิมโดยไม่ได้ยืนยันตำแหน่งโลก")
        end
        return sx, sy, nil, nil, "screen"
    end
    if pointInGui(Vector2.new(x, y)) then
        return nil, nil, nil, "own"
    end
    local target, _, checked, ownBlocked = GuiTargeting.guiTargetAt(x, y)
    if ownBlocked then
        return nil, nil, nil, "own"
    end
    if target then
        return nil, nil, "ตำแหน่งโลกถูก GUI เกมบัง (" .. tostring(target.fullName or target.className or "GUI") .. ")"
    end
    if not checked then
        return nil, nil, "ตรวจสอบ GUI ไม่ได้ จึงยืนยันไม่ได้ว่าจุดโลกไม่ถูก UI บัง"
    end
    local verified, verifyError, verifyInfo = verifyWorldHit(event.world, x, y)
    if not verified then
        -- เกมบางเกมใช้ preview/ghost ที่ขยับตามเมาส์: ต้องเลื่อนเมาส์เสมือนไปก่อน
        -- แล้วรอหนึ่งเฟรมจึงตรวจซ้ำ ไม่งั้นจะเห็นวัตถุเก่าที่ตำแหน่งเมาส์เดิม
        local moved, moveError = Input.move(x, y)
        if not moved then
            return nil, nil, "เลื่อนเมาส์เพื่อตรวจสอบจุดโลกไม่สำเร็จ: " .. tostring(moveError)
        end
        task.wait()
        verified, verifyError, verifyInfo = verifyWorldHit(event.world, x, y)
    end
    if not verified then
        -- ถ้าจุดเดิมถูกบังเพียงบางส่วน ให้หาพิกเซลใกล้ ๆ ที่ยังโดนพื้นผิวเดิม
        -- โดยจำกัดระยะในโลกไม่เกิน WORLD_MATCH_RADIUS และไม่ทับ GUI เกม
        local nx, ny, nearInfo, shift = findVisibleWorldPoint(event.world, x, y)
        if nx then
            Log.add("warn", string.format(
                "จุดคลิกเดิมถูกบังบางส่วน — เลื่อนจุดคลิก %.0f px (ห่างจากจุดเดิม %.2f สตัด) แต่ยังอยู่บนพื้นผิวเป้าหมาย",
                shift,
                nearInfo.distance
            ))
            x, y = nx, ny
            verifyInfo = nearInfo
            verified = true
        end
    end
    if not verified and verifyInfo and verifyInfo.kind == "occupied" and Settings.worldThrough == true then
        if not State.worldThroughWarned then
            State.worldThroughWarned = true
            Log.add("warn", string.format(
                "จุดวางมี %s อยู่ — คลิกตามพิกัดเดิมเพราะเปิด \"คลิกจุดวางเดิมแม้มีวัตถุอยู่บนจุด\" (อาจคลิกถูกวัตถุแทนการวาง) • จะแจ้งครั้งเดียวต่อการเล่น",
                worldHitLabel(verifyInfo.current)
            ))
        end
        verified = true
    end
    if not verified then
        return nil, nil, verifyError
    end
    return x, y, nil, nil, "world"
end

local function resolveGuiEventPoint(event)
    local first, second, third = GuiTargeting.resolveGuiTargetPoint(event.gui)
    if first then
        return first, second
    end
    if third == "own" then
        return nil, nil, nil, "own"
    end
    return nil, nil, second
end

local function resolveEventPoint(event)
    if event.gui then
        local x, y, resolveError, skip = resolveGuiEventPoint(event)
        if x then
            return x, y, "gui"
        end
        if skip then
            return nil, nil, nil, "skip"
        end
        return nil, nil, nil, nil, resolveError
    end
    if event.world and Settings.worldAnchor == true then
        local x, y, resolveError, skip, mode = resolveWorldEventPoint(event)
        if x then
            return x, y, mode or "world"
        end
        if skip then
            return nil, nil, nil, "skip"
        end
        return nil, nil, nil, nil, resolveError
    end
    if event.world and not State.worldFallbackWarned then
        State.worldFallbackWarned = true
        Log.add("warn", "worldAnchor ปิดอยู่ — ใช้พิกัดหน้าจอที่บันทึกสำหรับคลิกโลก (ไม่ได้ยืนยันตำแหน่ง)")
    end
    if event.guiUnknown and not State.guiFallbackWarned then
        State.guiFallbackWarned = true
        Log.add("warn", "คลิก GUI นี้ไม่มีเส้นทางเป้าหมาย — ใช้พิกัดหน้าจอที่บันทึก (อาจคลิกผิดหาก UI เปลี่ยน)")
    end
    if event.type == "mouseDown" and event.button == "Left"
        and not event.world and not event.gui and not event.guiUnknown
        and not State.screenClickWarned then
        State.screenClickWarned = true
        Log.add("warn", "คลิกซ้ายนี้ไม่มีข้อมูลตำแหน่งโลก/GUI (Macro เก่าหรือตรวจตำแหน่งไม่ได้) — ใช้พิกัดหน้าจอเดิม; ถ้ากล้องเปลี่ยนอาจคลิกผิด")
    end
    local x, y = scaledPoint(event)
    return x, y, "screen"
end

local function moveToPoint(x, y)
    local moved, moveError = Input.move(x, y)
    if not moved then
        error("เลื่อนเมาส์ไม่สำเร็จ: " .. tostring(moveError))
    end
end

local function warnSkippedByOwnGui()
    if not State.strictGuiWarned then
        State.strictGuiWarned = true
        Log.add("warn", "มี GUI ของสคริปต์บังจุดคลิก — ข้ามขั้นตอนที่ถูกบังเพื่อไม่ให้ Macro หยุด")
    end
end

local function confirmSelectionTarget(selection)
    if type(selection) ~= "table" or type(selection.world) ~= "table" then
        return true
    end
    if Settings.worldAnchor ~= true then
        if not State.selectionLimitWarned then
            State.selectionLimitWarned = true
            Log.add("warn", "worldAnchor ปิด — ยืนยันยูนิตเป้าหมายของการอัปเกรดไม่ได้; จะหยุดก่อนกดอัปเกรด")
        end
        return false, "worldAnchor ปิดอยู่ — ไม่สามารถยืนยันยูนิตเป้าหมายของการอัปเกรดได้"
    end

    local x, y, projectError = projectWorldPoint(selection.world)
    if not x then
        return false, "ยืนยันยูนิตเป้าหมายไม่ได้: " .. tostring(projectError)
    end
    local verified, verifyError = verifyWorldHit(selection.world, x, y)
    if not verified then
        return false, "ยืนยันยูนิตเป้าหมายไม่ได้: " .. tostring(verifyError)
    end

    if pointInGui(Vector2.new(x, y)) then
        if State.lastSyntheticWorldId == selection.worldId then
            return true
        end
        return true, nil, "own"
    end
    local target, _, checked, ownBlocked = GuiTargeting.guiTargetAt(x, y)
    if ownBlocked then
        if State.lastSyntheticWorldId == selection.worldId then
            return true
        end
        return true, nil, "own"
    end
    if target then
        return false, "จุดยูนิตเป้าหมายถูก GUI เกมบัง"
    end
    if not checked then
        return false, "ตรวจสอบ GUI ไม่ได้ จึงยืนยันยูนิตเป้าหมายไม่ได้"
    end
    if State.lastSyntheticWorldId == selection.worldId then
        return true
    end
    if State.heldMouse.Left then
        return false, "พบสถานะเมาส์ซ้ายค้างอยู่ก่อนยืนยันยูนิตเป้าหมาย"
    end

    local moved, moveError = Input.move(x, y)
    if not moved then
        return false, "เลื่อนเมาส์ไปยูนิตเป้าหมายไม่สำเร็จ: " .. tostring(moveError)
    end
    State.heldMouse.Left = true
    local pressed, pressError = Input.press("Left")
    if not pressed then
        State.heldMouse.Left = nil
        return false, "คลิกเลือกยูนิตเป้าหมายไม่สำเร็จ: " .. tostring(pressError)
    end
    task.wait(0.05)
    local released, releaseError = Input.release("Left")
    if not released then
        -- คงสถานะกดไว้เพื่อให้ releaseHeld ตอนหยุด/ผิดพลาดลองปล่อยซ้ำ
        return false, "ปล่อยคลิกเลือกยูนิตเป้าหมายไม่สำเร็จ: " .. tostring(releaseError)
    end
    State.heldMouse.Left = nil
    if State.mode ~= "playing" and State.mode ~= "paused" then
        return false, "หยุดระหว่างยืนยันยูนิตเป้าหมาย"
    end
    State.lastSyntheticWorldId = selection.worldId
    task.wait(0.08)
    if State.mode ~= "playing" and State.mode ~= "paused" then
        return false, "หยุดระหว่างยืนยันยูนิตเป้าหมาย"
    end
    if not State.upgradeReselectLogged then
        State.upgradeReselectLogged = true
        Log.add("info", "อัปเกรด: คลิกเลือกยูนิตเป้าหมายเดิมซ้ำก่อนกดปุ่มอัปเกรด")
    end
    return true
end

local function applyEvent(event)
    -- Dock ลอยอยู่กลางด้านบนและอาจทับจุดคลิก: ซ่อนเฉพาะตอนส่ง mouseDown/mouseUp
    local hideDock = false
    if (event.type == "mouseDown" or event.type == "mouseUp") and UI.dock and UI.dock.Visible then
        local px, py = scaledPoint(event)
        if pointInDock(px, py) then
            hideDock = true
        end
        if not hideDock and Settings.worldAnchor == true and event.world then
            local wx, wy = projectWorldPoint(event.world)
            if wx and pointInDock(wx, wy) then
                hideDock = true
            end
        end
        if not hideDock and Settings.worldAnchor == true
            and event.selection and event.selection.world then
            local sx, sy = projectWorldPoint(event.selection.world)
            if sx and pointInDock(sx, sy) then
                hideDock = true
            end
        end
        if not hideDock and event.gui then
            -- GUI ที่บันทึกไว้อาจถูกย้ายตำแหน่งมาอยู่ใต้ dock ในรอบนี้
            local resolved, gx, gy = pcall(GuiTargeting.resolveGuiTargetPoint, event.gui)
            if resolved and gx and pointInDock(gx, gy) then
                hideDock = true
            end
        end
    end
    if hideDock then
        UI.dock.Visible = false
        if not State.dockHiddenWarned then
            State.dockHiddenWarned = true
            Log.add("info", "dock ทับจุดคลิก — ซ่อน dock ชั่วคราวระหว่างส่งคลิก")
        end
    end

    local ok, err = pcall(function()
        if event.type == "mouseMove" then
            local x, y, mode, skip, resolveError = resolveEventPoint(event)
            if resolveError then
                error(resolveError)
            end
            if skip then
                warnSkippedByOwnGui()
                return
            end
            moveToPoint(x, y)
        elseif event.type == "mouseDown" then
            local button = event.button == "Right" and "Right" or "Left"
            if State.skippedClicks[button] then
                return
            end
            -- อัปเกรดที่ผูกยูนิตไว้ต้องเลือกยูนิตเป้าหมายก่อน
            -- เพราะปุ่มอัปเกรดอาจเป็น UI แบบ contextual ที่มีเฉพาะตอนมียูนิตถูกเลือก
            if event.selection and button == "Left" then
                local confirmed, confirmError, confirmSkip = confirmSelectionTarget(event.selection)
                if confirmSkip then
                    State.skippedClicks[button] = true
                    warnSkippedByOwnGui()
                    return
                end
                if not confirmed then
                    error(confirmError)
                end
            end
            local x, y, mode, skip, resolveError = resolveEventPoint(event)
            if resolveError then
                error(resolveError)
            end
            if skip then
                State.skippedClicks[button] = true
                if not event.selection then
                    State.lastSyntheticWorldId = nil
                end
                warnSkippedByOwnGui()
                return
            end
            moveToPoint(x, y)
            State.heldMousePoints[button] = { x = x, y = y }
            if not State.heldMouse[button] then
                State.heldMouse[button] = true
                local pressed, pressError = Input.press(button)
                if not pressed then
                    State.heldMouse[button] = nil
                    error("กดเมาส์ไม่สำเร็จ: " .. tostring(pressError))
                end
                if State.mode ~= "playing" and State.mode ~= "paused" then
                    pcall(function()
                        Input.release(button)
                    end)
                    State.heldMouse[button] = nil
                    error("หยุดระหว่างกดเมาส์")
                end
            end
            if mode == "world" and event.worldId and GuiTargeting.isLikelySelectionWorld(event.world) then
                State.lastSyntheticWorldId = event.worldId
            elseif not event.selection then
                -- คลิกอื่นที่ไม่ใช่ปุ่มอัปเกรดที่ผูกยูนิตอาจเปลี่ยน/ยกเลิกการเลือก
                -- ล้างสถานะเพื่อบังคับเลือกยูนิตเป้าหมายใหม่ก่อนอัปเกรดครั้งถัดไป
                State.lastSyntheticWorldId = nil
            end
        elseif event.type == "mouseUp" then
            local button = event.button == "Right" and "Right" or "Left"
            if State.skippedClicks[button] then
                State.skippedClicks[button] = nil
                State.heldMousePoints[button] = nil
                -- กันเมาส์ค้าง: ถ้ามีการกดจริงก่อนหน้าต้องปล่อยให้ครบ
                if State.heldMouse[button] then
                    local released, releaseError = Input.release(button)
                    if not released then
                        error("ปล่อยเมาส์ไม่สำเร็จ: " .. tostring(releaseError))
                    end
                    State.heldMouse[button] = nil
                end
                return
            end
            local cached = State.heldMousePoints[button]
            if cached then
                moveToPoint(cached.x, cached.y)
            else
                local x, y, mode, skip, resolveError = resolveEventPoint(event)
                if resolveError then
                    error(resolveError)
                end
                if skip then
                    if State.heldMouse[button] then
                        local released, releaseError = Input.release(button)
                        if not released then
                            error("ปล่อยเมาส์ไม่สำเร็จ: " .. tostring(releaseError))
                        end
                        State.heldMouse[button] = nil
                    end
                    State.heldMousePoints[button] = nil
                    warnSkippedByOwnGui()
                    return
                end
                moveToPoint(x, y)
            end
            if State.heldMouse[button] then
                local released, releaseError = Input.release(button)
                if not released then
                    error("ปล่อยเมาส์ไม่สำเร็จ: " .. tostring(releaseError))
                end
                State.heldMouse[button] = nil
            end
            State.heldMousePoints[button] = nil
        elseif event.type == "keyDown" then
            local vk = numberOr(event.vk, VK_BY_NAME[event.key])
            if not vk then
                error("ไม่พบรหัสปุ่ม " .. tostring(event.key))
            end
            if not State.heldKeys[vk] then
                State.heldKeys[vk] = event.key
                local pressed, pressError = Input.keyDown(vk, event.key)
                if not pressed then
                    State.heldKeys[vk] = nil
                    error("กดปุ่มไม่สำเร็จ: " .. tostring(pressError))
                end
                if State.mode ~= "playing" and State.mode ~= "paused" then
                    pcall(function()
                        Input.keyUp(vk, event.key)
                    end)
                    State.heldKeys[vk] = nil
                    error("หยุดระหว่างกดปุ่ม")
                end
            end
        elseif event.type == "keyUp" then
            local vk = numberOr(event.vk, VK_BY_NAME[event.key])
            if not vk then
                error("ไม่พบรหัสปุ่ม " .. tostring(event.key))
            end
            if State.heldKeys[vk] then
                local released, releaseError = Input.keyUp(vk, event.key)
                if not released then
                    error("ปล่อยปุ่มไม่สำเร็จ: " .. tostring(releaseError))
                end
                State.heldKeys[vk] = nil
            end
        elseif event.type == "wheel" then
            local scrolled, scrollError = Input.scroll(numberOr(event.z, 0))
            if not scrolled then
                error("เลื่อนล้อเมาส์ไม่สำเร็จ: " .. tostring(scrollError))
            end
        else
            error("ชนิดเหตุการณ์ไม่รองรับ: " .. tostring(event.type))
        end
    end)

    if hideDock and UI.dock and UI.main and not UI.main.Visible then
        -- รอหนึ่งเฟรมให้เกมประมวลผลอินพุตก่อนแล้วจึงคืน dock
        -- ถ้าคืนทันที dock อาจกลับมาบังคลิกก่อนเกมรับ event
        task.wait()
        if UI.dock and UI.main and not UI.main.Visible then
            UI.dock.Visible = true
        end
    end

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
    setStatus("เกิดข้อผิดพลาด — หยุดแล้ว", "error")
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
    State.playbackEvents = nil
    State.playbackIndex = 0
    showNotice(
        "หยุด Macro แล้ว",
        string.format(
            "เกิดข้อผิดพลาดที่ขั้นตอน %d/%d (%s)\n%s",
            index,
            total,
            eventLabel(event),
            tostring(err)
        ),
        "รับทราบ"
    )
end

local function buildScale(macro)
    local viewport = getViewport()
    local scale = { x = 1, y = 1 }
    if Settings.scaleCoords and macro and type(macro.screen) == "table" then
        local w = numberOr(macro.screen.w, 0)
        local h = numberOr(macro.screen.h, 0)
        if w >= 320 and h >= 320 and viewport.X > 0 and viewport.Y > 0 then
            local sx = viewport.X / w
            local sy = viewport.Y / h
            if sx >= 0.1 and sx <= 10 and sy >= 0.1 and sy <= 10 then
                scale.x = sx
                scale.y = sy
            end
        end
    end
    return scale
end

local function runPlayback(token, events, loops, loopsDisplay, speed)
    local total = #events
    local loop = 1
    local lastProgressUpdate = 0
    local lastStateCheck = 0
    local recoveryUsed = false

    while true do
        if token ~= State.token then
            return
        end

        State.loop = loop
        State.heldMousePoints = {}
        State.skippedClicks = {}
        State.lastSyntheticWorldId = nil
        local timeline = { base = clock(), shift = 0 }
        local retryLoop = false

        for index = 1, total do
            if token ~= State.token then
                return
            end

            local event = events[index]

            -- ตรวจ game freeze/loading ระหว่างเล่นเป็นระยะ เฉพาะเมื่อ adapter ตรวจสถานะได้
            if App.gameAdapter and adapterSupports("mapState")
                and clock() - lastStateCheck >= 1 then
                lastStateCheck = clock()
                local state, stateError = adapterState()
                local ready, why = stateReadiness(state)
                if not ready then
                    releaseHeld()
                    if token ~= State.token then
                        return
                    end
                    if not recoveryUsed then
                        recoveryUsed = true
                        setStatus("เกมไม่พร้อม — รอตรวจสถานะ", "paused")
                        Log.add("warn", "ตรวจพบเกมโหลด/ค้างระหว่างเล่น: " .. tostring(why or stateError))
                        App.refreshTransport()
                        local recovered, recoverError = App.waitForGameReady(token, "ระหว่างเล่น")
                        if token ~= State.token then
                            return
                        end
                        if recovered then
                            Log.add("warn", "เกมพร้อมอีกครั้ง — เริ่มเล่นรอบนี้ใหม่")
                            setStatus("ลองเล่นรอบเดิมอีกครั้ง", "playing")
                            retryLoop = true
                            break
                        end
                        failPlayback(token, index, total, event, "เกมไม่พร้อม: " .. tostring(recoverError or why))
                        return
                    end
                    failPlayback(token, index, total, event, "เกมไม่พร้อม: " .. tostring(why or stateError))
                    return
                end
            end

            local target = timeline.base + (event.t / speed) + timeline.shift
            if not waitTimeline(token, timeline, target) then
                return
            end
            if token ~= State.token then
                return
            end

            State.playbackIndex = index
            local ok, err = applyEvent(event)
            if not ok then
                releaseHeld()
                if token ~= State.token then
                    return
                end

                -- ลองกู้เฉพาะเมื่อ adapter ยืนยันสถานะเกมได้ และยังไม่เคยใช้โควตากู้รอบนี้
                if not recoveryUsed and App.gameAdapter and adapterSupports("mapState") then
                    recoveryUsed = true
                    setStatus("เกิดข้อผิดพลาด — รอเกมพร้อม", "paused")
                    Log.add("warn", "อินพุตล้มเหลว: " .. tostring(err) .. " — เริ่มตรวจสถานะเกม")
                    App.refreshTransport()
                    local recovered, recoverError = App.waitForGameReady(token, "หลังอินพุตล้มเหลว")
                    if token ~= State.token then
                        return
                    end
                    if recovered then
                        Log.add("warn", "เกมพร้อมอีกครั้ง — ลองเล่นรอบเดิมซ้ำหนึ่งครั้ง")
                        setStatus("ลองเล่นรอบเดิมอีกครั้ง", "playing")
                        retryLoop = true
                        break
                    end
                    err = tostring(err) .. " • " .. tostring(recoverError)
                end

                failPlayback(token, index, total, event, err)
                return
            end

            local now = clock()
            if index == total or now - lastProgressUpdate >= 0.08 then
                lastProgressUpdate = now
                updateProgress(index, total, loop, loopsDisplay)
            end
        end

        if retryLoop then
            task.wait(0.2)
            continue
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
    State.playbackEvents = nil
    if State.autoHidden then
        State.autoHidden = false
        setMenuVisible(true)
    end
    App.refreshTransport()
end

function App.startPlayback(options)
    options = options or {}
    if State.mode == "recording" or State.mode == "countdown" then
        Log.add("warn", "หยุดบันทึกก่อนเริ่มเล่น")
        return false
    end
    if State.pendingRecording then
        Log.add("warn", "ตั้งชื่อ Macro ที่ค้างอยู่ก่อนเริ่มเล่น")
        return false
    end
    if State.mode == "playing" then
        return false
    end
    if State.mode == "paused" then
        App.togglePause()
        return true
    end

    local sourceEvents = Profiles.events
    if #sourceEvents == 0 then
        setStatus("ไม่มีข้อมูลให้เล่น", "warn")
        Log.add("warn", "ยังไม่มีเหตุการณ์ใน Macro นี้ — เริ่มบันทึกก่อน")
        return false
    end
    if not Input.available() then
        setStatus("API อินพุตไม่พร้อม", "error")
        Log.add("error", "ไม่สามารถเล่นได้: " .. tostring(Cap.inputDetail))
        showNotice("เล่นไม่ได้", "ไม่พบ API อินพุตที่ใช้ได้\n" .. tostring(Cap.inputDetail))
        return false
    end

    local events, filteredCount = buildPlaybackEvents(sourceEvents)
    if #events == 0 then
        setStatus("ไม่มีขั้นตอนที่ปลอดภัยให้เล่น", "warn")
        Log.add("warn", "หลังกรองการขยับเมาส์/กล้องและปุ่มเดินแล้ว ไม่มีขั้นตอนเหลือให้เล่น")
        showNotice(
            "ไม่มีขั้นตอนให้เล่น",
            "Macro นี้มีแต่เหตุการณ์ที่ถูกปิดตามการตั้งค่า\nเปิด \"บันทึกการขยับเมาส์/กล้อง\" หรือ \"บันทึกปุ่มเดิน\" ใน Settings หากต้องการเล่นเต็มรูปแบบ\n(การเปิดอาจทำให้เมาส์/กล้องหรือตัวละครขยับตามที่บันทึกไว้)"
        )
        return false
    end

    local boundUpgradeCount = 0
    for _, event in ipairs(events) do
        if event.type == "mouseDown" and event.selection then
            boundUpgradeCount += 1
        end
    end
    if boundUpgradeCount > 0 and Settings.worldAnchor ~= true then
        setStatus("ยังเล่นไม่ได้ — ต้องยืนยันยูนิตอัปเกรด", "error")
        Log.add("error", string.format(
            "Macro มีคลิกอัปเกรดที่ผูกยูนิต %d จุด แต่ worldAnchor ปิดอยู่ — ไม่เริ่มเล่นเพื่อไม่ให้อัปเกรดผิดตัว",
            boundUpgradeCount
        ))
        showNotice(
            "ยังเล่นไม่ได้",
            "Macro นี้มีการอัปเกรดที่ผูกกับยูนิตเป้าหมาย\nต้องเปิด \"ยึดคลิกบนแผนที่กับจุดในโลก\" ใน Settings ก่อนเล่น\nเพื่อยืนยันยูนิตเดิมก่อนกดอัปเกรด"
        )
        return false
    end

    local macro = selectedMacro()
    if macro and options.contextConfirmed ~= true then
        local gateOk, gate = pcall(GameContext.preflight, macro.context)
        if not gateOk then
            Log.add("warn", "ตรวจบริบทเกมก่อนเล่นไม่สำเร็จ: " .. tostring(gate))
        elseif type(gate) == "table" then
            if #gate.blocked > 0 then
                local message = GameContext.buildBlockedMessage(gate)
                setStatus("บริบทเกมไม่ตรงกับ Macro", "error")
                Log.add("error", "ไม่เริ่มเล่น — " .. table.concat(gate.blocked, " • "))
                showNotice("บริบทเกมไม่ตรง", message)
                return false
            end
            for _, warning in ipairs(gate.warnings) do
                Log.add("warn", "บริบทเกม: " .. tostring(warning))
            end
            if gate.needsConfirm then
                if options.fromAuto then
                    Log.add("warn", "Auto เล่นต่อทั้งที่ยังยืนยันบริบทไม่ได้: " .. tostring(gate.summary))
                else
                    showConfirm(
                        "ยังยืนยันบริบทเกมไม่ได้",
                        GameContext.buildConfirmMessage(gate, macro.context),
                        "เล่นต่อ",
                        function()
                            App.startPlayback({ contextConfirmed = true, fromAuto = false })
                        end,
                        false,
                        nil,
                        190
                    )
                    return false
                end
            end
        end
    end
    State.playbackScale = buildScale(macro)
    State.token += 1
    local token = State.token
    State.mode = "playing"
    State.paused = false
    State.blocked = false
    State.finished = false
    State.playbackIndex = 0
    State.loop = 1
    State.autoHidden = false
    State.playbackFailures = 0
    State.playbackEvents = events
    State.worldFallbackWarned = false
    State.worldProjectionFallbackWarned = false
    State.worldThroughWarned = false
    State.guiFallbackWarned = false
    State.screenClickWarned = false
    State.strictGuiWarned = false
    State.dockHiddenWarned = false
    State.selectionLimitWarned = false
    State.upgradeReselectLogged = false
    State.heldMousePoints = {}
    State.skippedClicks = {}
    State.lastSyntheticWorldId = nil

    local loops = Settings.infinite and math.huge or math.max(1, math.floor(Settings.loops))
    local loopsDisplay = Settings.infinite and "∞" or tostring(loops)
    local speed = math.max(0.1, Settings.speed)

    setStatus(App.gameAdapter and "รอตรวจสถานะเกม" or "กำลังเล่น", "playing")
    Log.add("info", string.format(
        "เริ่มเล่น: %d/%d เหตุการณ์ • %s • ความเร็ว %sx • scale %.3f/%.3f",
        #events,
        #sourceEvents,
        Settings.infinite and "วนไม่จำกัด" or (tostring(loops) .. " รอบ"),
        formatNumber(speed),
        numberOr(State.playbackScale.x, 1),
        numberOr(State.playbackScale.y, 1)
    ))
    if filteredCount > 0 then
        Log.add("info", string.format(
            "กรอง %d เหตุการณ์เคลื่อนที่/ปุ่มเดินออกจากการเล่น (motion=%s, movementKeys=%s)",
            filteredCount,
            Settings.recordMotion and "on" or "off",
            Settings.recordMovementKeys and "on" or "off"
        ))
    end
    local worldTargetCount = 0
    local guiTargetCount = 0
    local upgradeTargetCount = 0
    local unboundUpgradeCount = 0
    local guiUnknownCount = 0
    local screenOnlyCount = 0
    for _, event in ipairs(events) do
        if event.type == "mouseDown" then
            if event.world then
                worldTargetCount += 1
            end
            if event.gui then
                guiTargetCount += 1
            end
            if event.selection then
                upgradeTargetCount += 1
            elseif event.gui and GuiTargeting.isLikelyUpgradeGui(event.gui) then
                unboundUpgradeCount += 1
            end
            if event.guiUnknown then
                guiUnknownCount += 1
            end
            if event.button == "Left" and not event.world and not event.gui and not event.guiUnknown then
                screenOnlyCount += 1
            end
        end
    end
    Log.add("info", string.format(
        "เป้าหมายที่ต้องยืนยัน: world=%d • GUI=%d • upgrade-bound=%d • upgrade-unbound=%d • gui-unknown=%d • screen-only=%d",
        worldTargetCount,
        guiTargetCount,
        upgradeTargetCount,
        unboundUpgradeCount,
        guiUnknownCount,
        screenOnlyCount
    ))
    if screenOnlyCount > 0 then
        Log.add("warn", "มีคลิกซ้ายที่ใช้พิกัดหน้าจอเท่านั้น — ถ้ากล้อง/หน้าจอเปลี่ยน อาจคลิกผิดตำแหน่ง")
    end
    if unboundUpgradeCount > 0 then
        Log.add("warn", string.format(
            "มีคลิกที่ดูเหมือนปุ่มอัปเกรด %d จุดแต่ไม่ได้ผูกยูนิตเป้าหมาย — จะใช้เส้นทาง GUI ตามที่บันทึก; ถ้ายูนิตที่เลือกเปลี่ยน อาจอัปเกรดผิดตัว",
            unboundUpgradeCount
        ))
    end
    if worldTargetCount > 0 and Settings.worldAnchor ~= true then
        Log.add("warn", "worldAnchor ปิดอยู่ — คลิกโลกจะใช้พิกัดหน้าจอเดิมและยืนยันตำแหน่งไม่ได้")
    end
    if not App.gameAdapter then
        Log.add("warn", "ไม่มี adapter: ตรวจสถานะ map load/เกมค้างไม่ได้ — จะไม่มีการ retry อัตโนมัติ")
    end
    updateProgress(0, #events, 1, loopsDisplay)
    App.refreshTransport()

    task.spawn(function()
        if App.gameAdapter and adapterSupports("mapState") then
            local ready, readyError = App.waitForGameReady(token, "ก่อนเริ่มเล่น")
            if token ~= State.token then
                return
            end
            if not ready then
                State.token += 1
                State.mode = "idle"
                State.paused = false
                State.blocked = false
                State.playbackEvents = nil
                releaseHeld()
                setStatus("เริ่มเล่นไม่ได้: เกมไม่พร้อม", "error")
                Log.add("error", "เริ่มเล่นไม่ได้: " .. tostring(readyError))
                App.refreshTransport()
                showNotice("เริ่มเล่นไม่ได้", "เกมยังไม่พร้อมหลังตรวจ 3 ครั้ง\n" .. tostring(readyError))
                return
            end
            setStatus("กำลังเล่น", "playing")
        end

        -- ต้องซ่อนเมนูระหว่างเล่นเสมอ: เมนูหลักกว้าง 840x600 บังจุดคลิกเกือบทั้งจอ
        -- (เดิมพึ่ง autoHide ทำให้เมื่อผู้ใช้ปิด autoHide Macro จะวิ่งแต่คลิกถูกข้าม)
        if State.menuVisible then
            setMenuVisible(false)
            State.autoHidden = true
            Log.add("info", "ซ่อนเมนูระหว่างเล่นเพื่อไม่ให้บังจุดคลิก")
        end

        local ok, err = pcall(runPlayback, token, events, loops, loopsDisplay, speed)
        if not ok and token == State.token then
            State.token += 1
            State.mode = "idle"
            State.paused = false
            State.blocked = false
            State.playbackEvents = nil
            releaseHeld()
            setStatus("เกิดข้อผิดพลาด", "error")
            Log.add("error", "การเล่นหยุดผิดปกติ: " .. tostring(err))
            App.refreshTransport()
            showNotice("หยุด Macro แล้ว", "การเล่นหยุดผิดปกติ\n" .. tostring(err))
        end
    end)
    return true
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
    local total = #(State.playbackEvents or Profiles.events)
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
    State.playbackEvents = nil
    App.refreshTransport()
end

-- 16) จัดการโปรไฟล์และ Macro
-- ============================================================================

local function makeEmptyProfileData(name)
    local meta = {
        id = newProfileId(),
        name = uniqueProfileName(name or "โปรไฟล์ 1"),
        created = os.time(),
        modified = os.time(),
        duration = 0,
        count = 0,
        macroCount = 1,
    }
    local macro = {
        id = newMacroId(),
        name = "มาโคร 1",
        created = os.time(),
        modified = os.time(),
        events = {},
        set = nil,
        screen = nil,
    }
    local data = {
        format = PROFILE_FORMAT,
        version = PROFILE_VERSION,
        id = meta.id,
        name = meta.name,
        created = meta.created,
        modified = meta.modified,
        macros = { macro },
        mainMacroId = macro.id,
        selectedMacroId = macro.id,
        events = macro.events,
        count = 0,
        duration = 0,
        macroCount = 1,
    }
    return meta, data
end

local function ensureProfileBackup(meta, action)
    if not FileTools.ready or not fileExists(profilePath(meta.id)) then
        return true
    end
    local ok, err = backupProfileFile(meta)
    if not ok then
        Log.add("error", "สำรองโปรไฟล์ก่อน" .. tostring(action) .. "ไม่สำเร็จ: " .. tostring(err))
        showNotice(
            "ดำเนินการไม่ได้",
            "สำรองไฟล์โปรไฟล์ก่อน" .. tostring(action) .. "ไม่สำเร็จ\n" .. tostring(err)
        )
        return false
    end
    return true
end

local function persistProfile(meta, events, actionText)
    local ok, err = saveProfileToDisk(meta, events)
    if not ok then
        State.dirty = true
        Log.add("warn", tostring(actionText or "บันทึกโปรไฟล์") .. "ในหน่วยความจำ แต่เขียนไฟล์ไม่ได้: " .. tostring(err))
    else
        State.dirty = false
    end
    saveIndex()
    return ok, err
end

function App.selectProfile(id, silent, force)
    if State.mode ~= "idle" or State.pendingRecording then
        Log.add("warn", "หยุดงาน/ตั้งชื่อ Macro ก่อนเปลี่ยนโปรไฟล์")
        return false
    end
    if id == Profiles.selectedId and Profiles.data and Profiles.data.id == id and not force then
        return true
    end
    if State.dirty and not force then
        showConfirm(
            "ยังไม่ได้บันทึกโปรไฟล์?",
            "ข้อมูลล่าสุดยังไม่ได้เขียนลงไฟล์ หากเปลี่ยนโปรไฟล์ตอนนี้ข้อมูลในหน่วยความจำจะหาย",
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

    local data, err = readProfileFromDisk(id, { migrate = true })
    if not data then
        Log.add("error", "อ่านโปรไฟล์ไม่สำเร็จ: " .. tostring(err))
        showNotice("เปิดโปรไฟล์ไม่ได้", "ไฟล์โปรไฟล์อ่านไม่ได้หรือเสียหาย\n" .. tostring(err))
        return false
    end

    Profiles.selectedId = id
    Profiles.data = data
    local macro = syncProfileEvents(data)
    Profiles.selectedMacroId = macro and macro.id or nil
    Profiles.events = macro and macro.events or {}
    meta.name = data.name or meta.name
    meta.created = data.created or meta.created
    meta.modified = data.modified or meta.modified
    meta.duration = macro and macro.duration or 0
    meta.count = macro and macro.count or 0
    meta.macroCount = #data.macros

    State.playbackIndex = 0
    State.loop = 0
    State.finished = false
    State.dirty = false
    State.selectedSteps = {}
    State.stepMacroId = nil
    State.playbackScale = { x = 1, y = 1 }

    saveIndex()
    App.refreshProfiles()
    Rec.updateRecordInfo()
    if not silent then
        Log.add("info", "เลือกโปรไฟล์: " .. meta.name .. (macro and (" / " .. macro.name) or ""))
    end
    return true
end

function App.selectMacro(id, silent)
    if State.mode ~= "idle" or State.pendingRecording then
        Log.add("warn", "หยุดงาน/ตั้งชื่อ Macro ก่อนเปลี่ยน Macro")
        return false
    end
    if not Profiles.data then
        return false
    end

    local macro = findMacro(Profiles.data, id)
    if not macro then
        Log.add("warn", "ไม่พบ Macro ที่เลือก")
        return false
    end
    if Profiles.selectedMacroId == id then
        return true
    end

    Profiles.selectedMacroId = id
    Profiles.data.selectedMacroId = id
    syncProfileEvents(Profiles.data)
    Profiles.events = macro.events
    State.playbackIndex = 0
    State.loop = 0
    State.finished = false
    State.selectedSteps = {}
    State.stepMacroId = nil

    local meta = selectedProfileMeta()
    if meta then
        persistProfile(meta, Profiles.events, "เลือก Macro")
    end
    App.refreshProfiles()
    Rec.updateRecordInfo()
    if not silent then
        Log.add("info", "เลือก Macro: " .. macro.name)
    end
    return true
end

function App.promptCreateProfile(force)
    if State.mode ~= "idle" or State.pendingRecording then
        Log.add("warn", "หยุดงาน/ตั้งชื่อ Macro ก่อนสร้างโปรไฟล์")
        return
    end
    if State.dirty and not force then
        showConfirm(
            "ยังไม่ได้บันทึกโปรไฟล์?",
            "ข้อมูลล่าสุดยังไม่ได้เขียนลงไฟล์ การสร้างโปรไฟล์ใหม่จะทำให้ข้อมูลในหน่วยความจำหาย",
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
        "ตั้งชื่อโปรไฟล์ (สูงสุด 40 ตัวอักษร) • ภายในมี 1 Macro เริ่มต้น",
        "โปรไฟล์ " .. tostring(#Profiles.list + 1),
        "สร้าง",
        function(name)
            local meta, data = makeEmptyProfileData(name)
            meta.name = uniqueProfileName(name)
            data.name = meta.name
            addProfileMeta(meta)
            Profiles.selectedId = meta.id
            Profiles.data = data
            Profiles.selectedMacroId = data.selectedMacroId
            Profiles.events = data.events
            State.playbackIndex = 0
            State.loop = 0
            State.finished = false
            State.selectedSteps = {}
            State.stepMacroId = nil
            State.dirty = false
            persistProfile(meta, {}, "สร้างโปรไฟล์")
            App.refreshProfiles()
            Rec.updateRecordInfo()
            Log.add("success", "สร้างโปรไฟล์: " .. meta.name)
        end
    )
end

function App.promptRenameProfile()
    if State.mode ~= "idle" or State.pendingRecording then
        Log.add("warn", "หยุดงาน/ตั้งชื่อ Macro ก่อนเปลี่ยนชื่อ")
        return
    end
    local meta = selectedProfileMeta()
    if not meta or not Profiles.data then
        Log.add("warn", "ยังไม่ได้เลือกโปรไฟล์")
        return
    end

    showPrompt(
        "เปลี่ยนชื่อโปรไฟล์",
        "ตั้งชื่อใหม่ (สูงสุด 40 ตัวอักษร) • ชื่อซ้ำจะถูกเติมเลขต่อท้าย",
        meta.name,
        "บันทึกชื่อ",
        function(name)
            name = uniqueProfileName(name, meta.id)
            meta.name = name
            Profiles.data.name = name
            persistProfile(meta, Profiles.events, "เปลี่ยนชื่อโปรไฟล์")
            App.refreshProfiles()
            Log.add("success", "เปลี่ยนชื่อโปรไฟล์เป็น: " .. name)
        end
    )
end

function App.promptDeleteProfile()
    if State.mode ~= "idle" or State.pendingRecording then
        Log.add("warn", "หยุดงาน/ตั้งชื่อ Macro ก่อนลบโปรไฟล์")
        return
    end
    local meta = selectedProfileMeta()
    if not meta then
        Log.add("warn", "ยังไม่ได้เลือกโปรไฟล์")
        return
    end
    local macroCount = Profiles.data and #Profiles.data.macros or 0
    local eventCount = 0
    if Profiles.data then
        for _, macro in ipairs(Profiles.data.macros) do
            eventCount += #macro.events
        end
    end

    showConfirm(
        "ลบโปรไฟล์?",
        string.format(
            "ลบโปรไฟล์ \"%s\" (%d Macro • %d ขั้นตอน) และไฟล์ของโปรไฟล์นี้?\nสำรอง .bak ก่อนลบ • Macro ของโปรไฟล์อื่นไม่ถูกแตะต้อง",
            meta.name,
            macroCount,
            eventCount
        ),
        "ลบโปรไฟล์",
        function()
            if not ensureProfileBackup(meta, "ลบโปรไฟล์") then
                return
            end
            if FileTools.ready and fileExists(profilePath(meta.id)) then
                local ok, err = deleteFile(profilePath(meta.id))
                if not ok then
                    Log.add("error", "ลบไฟล์โปรไฟล์ไม่สำเร็จ: " .. tostring(err))
                    showNotice("ลบไม่สำเร็จ", tostring(err))
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
                local nextId = Profiles.list[1] and Profiles.list[1].id or nil
                if nextId then
                    Profiles.selectedId = nil
                    Profiles.data = nil
                    App.selectProfile(nextId, true, true)
                else
                    local newMeta, newData = makeEmptyProfileData("โปรไฟล์ 1")
                    addProfileMeta(newMeta)
                    Profiles.selectedId = newMeta.id
                    Profiles.data = newData
                    Profiles.selectedMacroId = newData.selectedMacroId
                    Profiles.events = newData.events
                    persistProfile(newMeta, {}, "สร้างโปรไฟล์ทดแทน")
                    App.refreshProfiles()
                end
            end
            saveIndex()
            App.refreshProfiles()
            Rec.updateRecordInfo()
            Log.add("success", "ลบโปรไฟล์: " .. meta.name)
        end,
        true
    )
end

function App.promptSetMainMacro()
    if State.mode ~= "idle" or State.pendingRecording then
        Log.add("warn", "หยุดงาน/ตั้งชื่อ Macro ก่อนตั้ง Macro หลัก")
        return
    end
    local meta = selectedProfileMeta()
    local macro = selectedMacro()
    if not meta or not Profiles.data or not macro then
        Log.add("warn", "ยังไม่ได้เลือก Macro")
        return
    end
    if Profiles.data.mainMacroId == macro.id then
        Log.add("info", "Macro นี้เป็น Macro หลักอยู่แล้ว")
        return
    end
    Profiles.data.mainMacroId = macro.id
    persistProfile(meta, Profiles.events, "ตั้ง Macro หลัก")
    App.refreshProfiles()
    Log.add("success", "ตั้ง Macro หลัก: " .. macro.name)
end

function App.promptRenameMacro()
    if State.mode ~= "idle" or State.pendingRecording then
        Log.add("warn", "หยุดงาน/ตั้งชื่อ Macro ก่อนเปลี่ยนชื่อ")
        return
    end
    local meta = selectedProfileMeta()
    local macro = selectedMacro()
    if not meta or not Profiles.data or not macro then
        Log.add("warn", "ยังไม่ได้เลือก Macro")
        return
    end

    showPrompt(
        "เปลี่ยนชื่อ Macro",
        "ชื่อต้องไม่ซ้ำกับ Macro อื่นในโปรไฟล์นี้",
        macro.name,
        "บันทึกชื่อ",
        function(name)
            local newName, nameError = normalizeMacroName(name)
            if not newName then
                Log.add("warn", tostring(nameError))
                return
            end
            newName = uniqueMacroNameIn(Profiles.data.macros, newName, macro.id)
            macro.name = newName
            macro.modified = os.time()
            persistProfile(meta, Profiles.events, "เปลี่ยนชื่อ Macro")
            App.refreshProfiles()
            Log.add("success", "เปลี่ยนชื่อ Macro เป็น: " .. newName)
        end
    )
end

function App.promptDeleteMacro()
    if State.mode ~= "idle" or State.pendingRecording then
        Log.add("warn", "หยุดงาน/ตั้งชื่อ Macro ก่อนลบ Macro")
        return
    end
    local meta = selectedProfileMeta()
    local macro = selectedMacro()
    if not meta or not Profiles.data or not macro then
        Log.add("warn", "ยังไม่ได้เลือก Macro")
        return
    end
    if #Profiles.data.macros <= 1 then
        showNotice("ลบไม่ได้", "ต้องมี Macro อย่างน้อย 1 รายการในโปรไฟล์ • ใช้ Reset Macro เพื่อล้างข้อมูลแทน")
        return
    end

    showConfirm(
        "ลบ Macro?",
        string.format(
            "ลบ Macro \"%s\" (%d ขั้นตอน) จากโปรไฟล์ \"%s\"?\nMacro อื่นและโปรไฟล์อื่นไม่ถูกแตะต้อง • จะสำรอง .bak ก่อน",
            macro.name,
            #macro.events,
            meta.name
        ),
        "ลบ Macro",
        function()
            if not ensureProfileBackup(meta, "ลบ Macro") then
                return
            end
            local removed = false
            for index, item in ipairs(Profiles.data.macros) do
                if item.id == macro.id then
                    table.remove(Profiles.data.macros, index)
                    removed = true
                    break
                end
            end
            if not removed then
                return
            end

            if Profiles.data.mainMacroId == macro.id then
                Profiles.data.mainMacroId = Profiles.data.macros[1].id
            end
            if Profiles.data.selectedMacroId == macro.id then
                Profiles.data.selectedMacroId = Profiles.data.mainMacroId
            end
            local nextMacro = syncProfileEvents(Profiles.data)
            Profiles.selectedMacroId = nextMacro and nextMacro.id or nil
            Profiles.events = nextMacro and nextMacro.events or {}
            State.playbackIndex = 0
            State.loop = 0
            State.finished = false
            State.selectedSteps = {}
            State.stepMacroId = nil
            persistProfile(meta, Profiles.events, "ลบ Macro")
            App.refreshProfiles()
            Rec.updateRecordInfo()
            Log.add("success", "ลบ Macro: " .. macro.name)
        end,
        true
    )
end

function App.promptDeleteSelectedSteps()
    if State.mode ~= "idle" or State.pendingRecording then
        Log.add("warn", "หยุดงาน/ตั้งชื่อ Macro ก่อนลบขั้นตอน")
        return
    end
    local meta = selectedProfileMeta()
    local macro = selectedMacro()
    if not meta or not macro then
        Log.add("warn", "ยังไม่ได้เลือก Macro")
        return
    end
    local selected = countSelectedSteps()
    if selected <= 0 then
        return
    end

    showConfirm(
        "ลบขั้นตอนที่เลือก?",
        string.format("ลบ %d ขั้นตอนจาก Macro \"%s\" (%d ขั้นตอน)?\nการลบมีผลทันทีหลังยืนยัน และจะสำรอง .bak ก่อน", selected, macro.name, #macro.events),
        "ลบขั้นตอน",
        function()
            if not ensureProfileBackup(meta, "ลบขั้นตอน") then
                return
            end
            local remove = {}
            for index in pairs(State.selectedSteps) do
                if type(index) == "number" and index >= 1 and index <= #macro.events then
                    remove[index] = true
                end
            end
            local kept = {}
            local removedCount = 0
            for index, event in ipairs(macro.events) do
                if remove[index] then
                    removedCount += 1
                else
                    table.insert(kept, event)
                end
            end
            if removedCount == 0 then
                return
            end

            macro.events = kept
            macro.modified = os.time()
            Profiles.events = macro.events
            syncProfileEvents(Profiles.data)
            State.selectedSteps = {}
            State.playbackIndex = 0
            State.loop = 0
            State.finished = false
            persistProfile(meta, Profiles.events, "ลบขั้นตอน")
            App.refreshProfiles()
            Rec.updateRecordInfo()
            Log.add("success", string.format("ลบ %d ขั้นตอนจาก Macro \"%s\" • เหลือ %d", removedCount, macro.name, #macro.events))
        end,
        true
    )
end

function App.promptResetMacro()
    if State.mode ~= "idle" or State.pendingRecording then
        Log.add("warn", "หยุดงาน/ตั้งชื่อ Macro ก่อน Reset")
        return
    end
    local meta = selectedProfileMeta()
    local macro = selectedMacro()
    if not meta or not macro then
        Log.add("warn", "ยังไม่ได้เลือก Macro")
        return
    end

    showConfirm(
        "Reset Macro?",
        string.format(
            "ล้างขั้นตอนและข้อมูลเซ็ตของ Macro \"%s\" (%d ขั้นตอน)?\nชื่อ Macro เดิมจะอยู่ • โปรไฟล์อื่นและ Macro อื่นไม่ถูกแตะต้อง • จะสำรอง .bak ก่อน",
            macro.name,
            #macro.events
        ),
        "Reset Macro",
        function()
            if not ensureProfileBackup(meta, "Reset Macro") then
                return
            end
            macro.events = {}
            macro.set = nil
            macro.screen = nil
            macro.context = nil
            macro.count = 0
            macro.duration = 0
            macro.modified = os.time()
            Profiles.events = macro.events
            syncProfileEvents(Profiles.data)
            State.selectedSteps = {}
            State.playbackIndex = 0
            State.loop = 0
            State.finished = false
            persistProfile(meta, Profiles.events, "Reset Macro")
            App.refreshProfiles()
            Rec.updateRecordInfo()
            Log.add("success", "Reset Macro: " .. macro.name .. " (ล้างเฉพาะ Macro นี้)")
        end,
        true
    )
end

function App.promptRestoreSet()
    if State.mode ~= "idle" or State.pendingRecording then
        showNotice("ยังคืนค่าไม่ได้", "หยุดบันทึก/เล่น Macro ก่อนใช้ปุ่มคืนค่าเซ็ต")
        return
    end
    local meta = selectedProfileMeta()
    local macro = selectedMacro()
    if not meta or not macro then
        showNotice("ยังเลือกไม่ครบ", "เลือกโปรไฟล์และ Macro ก่อนใช้ปุ่มคืนค่าเซ็ต")
        return
    end
    local set = macro.set
    if type(set) ~= "table" then
        showNotice(
            "ยังไม่มีข้อมูลเซ็ต",
            string.format("Macro \"%s\" ยังไม่มีข้อมูลเซ็ต\nระบบจะเก็บข้อมูลเซ็ตอัตโนมัติเมื่อบันทึกครั้งถัดไป (ถ้า adapter รองรับ)", macro.name)
        )
        return
    end
    if set.status ~= "detected" then
        showNotice(
            "คืนค่าเซ็ตไม่ได้",
            "ข้อมูลเซ็ตของ Macro นี้เป็นเพียงข้อมูลอนุมานจากอินพุต (input-only) ไม่ใช่ข้อมูลตัวละคร/ออปที่ตรวจสอบแล้ว\nจึงไม่สามารถคืนค่าได้อย่างปลอดภัย"
        )
        return
    end
    if not App.gameAdapter then
        showNotice("คืนค่าเซ็ตไม่ได้", "ยังไม่มี game adapter ที่ตรวจสอบและคืนค่าเซ็ตได้")
        return
    end
    if not adapterSupports("restoreSet") then
        showNotice("คืนค่าเซ็ตไม่ได้", "adapter ที่ติดตั้งไม่ได้ประกาศความสามารถ restoreSet")
        return
    end

    showConfirm(
        "คืนค่าเซ็ตตัวละครและออป?",
        string.format(
            "จะใช้ข้อมูลเซ็ตของ Macro \"%s\" ในโปรไฟล์ \"%s\" เท่านั้น\nadapter ต้องตรวจสอบและยืนยันผลเอง • ระบบไม่สร้างข้อมูลหรืออ้างว่าสำเร็จแทน adapter",
            macro.name,
            meta.name
        ),
        "คืนค่าเซ็ต",
        function()
            local ok, result = adapterCall("restoreSet", set.detected, {
                profileId = meta.id,
                macroId = macro.id,
                macroName = macro.name,
            })
            if not ok then
                Log.add("error", "คืนค่าเซ็ตไม่สำเร็จ: " .. tostring(result))
                showNotice("คืนค่าไม่สำเร็จ", tostring(result))
                return
            end

            local success = false
            local message = nil
            if result == true then
                success = true
            elseif type(result) == "table" then
                success = result.ok == true
                message = result.message or result.reason
            end
            if not success then
                local reason = message or "adapter ไม่ได้ยืนยันผลสำเร็จ"
                Log.add("error", "คืนค่าเซ็ตไม่สำเร็จ: " .. tostring(reason))
                showNotice("คืนค่าไม่สำเร็จ", tostring(reason))
                return
            end
            Log.add("success", "adapter ยืนยันคืนค่าเซ็ต Macro \"" .. macro.name .. "\" แล้ว")
            showNotice("คืนค่าเซ็ตแล้ว", message or "adapter ยืนยันว่าคืนค่าเซ็ตของ Macro นี้สำเร็จ")
        end,
        false
    )
end

function App.exportCurrentProfile()
    if State.mode ~= "idle" or State.pendingRecording then
        Log.add("warn", "หยุดงาน/ตั้งชื่อ Macro ก่อนส่งออก")
        return
    end
    local meta = selectedProfileMeta()
    if not meta or not Profiles.data then
        Log.add("warn", "ยังไม่ได้เลือกโปรไฟล์")
        return
    end

    local macro = syncProfileEvents(Profiles.data)
    if macro then
        Profiles.events = macro.events
    end
    local totalEvents = 0
    for _, item in ipairs(Profiles.data.macros) do
        totalEvents += #item.events
    end
    if totalEvents == 0 then
        Log.add("warn", "โปรไฟล์นี้ยังไม่มีขั้นตอนให้ส่งออก")
        showNotice("ไม่มีข้อมูลส่งออก", "โปรไฟล์นี้ยังไม่มีขั้นตอนใน Macro ใดเลย")
        return
    end

    local payload = profileData(meta, Profiles.events)
    payload.exportedAt = os.time()
    payload.appVersion = APP_VERSION
    local json, err = encodeJson(payload)
    if not json then
        Log.add("error", "สร้าง JSON สำหรับส่งออกไม่สำเร็จ: " .. tostring(err))
        showNotice("ส่งออกไม่สำเร็จ", tostring(err))
        return
    end

    local clipboardOk = false
    if Cap.clipboard and type(setclipboard) == "function" then
        clipboardOk = pcall(setclipboard, json)
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
    showExportDialog(json, subtitle .. " • มี " .. tostring(#Profiles.data.macros) .. " Macro")
end

function App.importProfileText(text)
    if State.mode ~= "idle" or State.pendingRecording then
        return false, "หยุดงาน/ตั้งชื่อ Macro ก่อนนำเข้า"
    end
    text = trimText(text)
    if text == "" then
        return false, "ยังไม่มีข้อความ JSON"
    end

    local data, decodeError = decodeJson(text)
    if not data then
        return false, "JSON ไม่ถูกต้อง: " .. tostring(decodeError)
    end

    local profile = nil
    if type(data) == "table" and data.format == PROFILE_FORMAT then
        local sanitized, profileError = sanitizeProfile(data, { strict = true })
        if not sanitized then
            return false, "โปรไฟล์ไม่ถูกต้อง: " .. tostring(profileError)
        end
        profile = sanitized
    elseif type(data) == "table" and type(data.macros) == "table" and #data.macros > 0 then
        local sanitized, profileError = sanitizeProfile(data, { strict = true })
        if not sanitized then
            return false, "โปรไฟล์ไม่ถูกต้อง: " .. tostring(profileError)
        end
        profile = sanitized
    elseif type(data) == "table" and type(data.events) == "table" then
        local sanitized, profileError = sanitizeProfile({
            name = type(data.name) == "string" and data.name or "นำเข้า",
            events = data.events,
        }, { strict = true })
        if not sanitized then
            return false, "โปรไฟล์ไม่ถูกต้อง: " .. tostring(profileError)
        end
        profile = sanitized
    elseif type(data) == "table" and #data > 0 then
        local sanitized, profileError = sanitizeProfile({
            name = "นำเข้า",
            events = data,
        }, { strict = true })
        if not sanitized then
            return false, "โปรไฟล์ไม่ถูกต้อง: " .. tostring(profileError)
        end
        profile = sanitized
    else
        return false, "ไม่พบข้อมูลโปรไฟล์หรือเหตุการณ์ใน JSON"
    end

    local totalEvents = 0
    for _, macro in ipairs(profile.macros or {}) do
        totalEvents += #macro.events
    end
    if totalEvents == 0 then
        return false, "โปรไฟล์ที่นำเข้าไม่มีขั้นตอนที่ใช้งานได้"
    end

    local previousId = Profiles.selectedId
    local meta = {
        id = newProfileId(),
        name = uniqueProfileName(profile.name or "นำเข้า"),
        created = os.time(),
        modified = os.time(),
        duration = profile.duration or 0,
        count = profile.count or 0,
        macroCount = profile.macroCount or #profile.macros,
    }
    profile.id = meta.id
    profile.name = meta.name
    profile.created = meta.created
    profile.modified = meta.modified
    profile.format = PROFILE_FORMAT
    profile.version = PROFILE_VERSION
    local selected = findMacro(profile, profile.selectedMacroId) or mainMacroOf(profile) or profile.macros[1]
    profile.selectedMacroId = selected and selected.id or nil
    profile.mainMacroId = profile.mainMacroId or profile.selectedMacroId
    if not findMacro(profile, profile.mainMacroId) then
        profile.mainMacroId = profile.selectedMacroId
    end
    profile.events = selected and selected.events or {}
    profile.count = selected and selected.count or 0
    profile.duration = selected and selected.duration or 0

    addProfileMeta(meta)
    Profiles.selectedId = meta.id
    Profiles.data = profile
    Profiles.selectedMacroId = profile.selectedMacroId
    Profiles.events = profile.events
    State.playbackIndex = 0
    State.loop = 0
    State.finished = false
    State.selectedSteps = {}
    State.stepMacroId = nil
    State.dirty = false

    local saved, saveError = saveProfileToDisk(meta, profile.events)
    if not saved then
        for index, item in ipairs(Profiles.list) do
            if item.id == meta.id then
                table.remove(Profiles.list, index)
                break
            end
        end
        Profiles.selectedId = previousId
        Profiles.data = nil
        Profiles.events = {}
        Profiles.selectedMacroId = nil
        if previousId then
            App.selectProfile(previousId, true, true)
        end
        App.refreshProfiles()
        return false, "เขียนไฟล์โปรไฟล์ที่นำเข้าไม่ได้: " .. tostring(saveError)
    end

    saveIndex()
    App.refreshProfiles()
    Rec.updateRecordInfo()
    Log.add("success", string.format(
        "นำเข้าโปรไฟล์: %s • %d Macro • %d ขั้นตอน",
        meta.name,
        #profile.macros,
        totalEvents
    ))
    return true
end

function App.promptImportProfile(force)
    if State.mode ~= "idle" or State.pendingRecording then
        Log.add("warn", "หยุดงาน/ตั้งชื่อ Macro ก่อนนำเข้า")
        return
    end
    if State.dirty and not force then
        showConfirm(
            "ยังไม่ได้บันทึกโปรไฟล์?",
            "ข้อมูลล่าสุดยังไม่ได้เขียนลงไฟล์ การนำเข้าโปรไฟล์ใหม่จะทำให้ข้อมูลในหน่วยความจำหาย",
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

-- 17) ระบบกัน AFK (แยกจาก Macro)
-- ============================================================================

function App.setAfkEnabled(value)
    value = value == true
    if value and not Cap.afk then
        Settings.afkEnabled = false
        saveSettings()
        App.updateAfkUI()
        showNotice(
            "AFK Guard ไม่พร้อม",
            "backend อินพุตนี้ยังไม่รองรับการกัน AFK อย่างปลอดภัย\n" .. tostring(Cap.inputDetail)
        )
        return
    end
    if Settings.afkEnabled == value then
        App.updateAfkUI()
        return
    end
    Settings.afkEnabled = value
    saveSettings()
    if value then
        AfkGuard.startedAt = os.time()
        AfkGuard.lastAttempt = os.time()
        AfkGuard.lastNudge = nil
        AfkGuard.lastResult = ""
        Log.add("info", "เปิดระบบกัน AFK (ขยับทุก 5 นาที) — ไม่รับประกันว่าจะไม่ถูก kick")
    else
        Log.add("info", "ปิดระบบกัน AFK")
    end
    App.updateAfkUI()
end

function AfkGuard.nudge(reason)
    if not Settings.afkEnabled then
        return false
    end
    if not Cap.afk or not Input.available() then
        AfkGuard.lastResult = "ข้าม: backend ไม่รองรับ AFK"
        App.updateAfkUI()
        return false
    end
    if State.mode ~= "idle" or State.pendingRecording then
        AfkGuard.lastResult = "ข้าม: Macro กำลังทำงาน"
        App.updateAfkUI()
        return false
    end
    if not isGameActive() then
        AfkGuard.lastResult = "ข้าม: เกมไม่ active"
        App.updateAfkUI()
        return false
    end

    local ok, err = Input.nudge()
    if ok then
        AfkGuard.lastNudge = os.time()
        AfkGuard.lastResult = "สำเร็จ"
        Log.add("info", "กัน AFK: ขยับเมาส์เล็กน้อย (" .. tostring(reason) .. ")")
        App.updateAfkUI()
        return true
    end

    AfkGuard.lastResult = "ล้มเหลว"
    Log.add("warn", "กัน AFK ไม่สำเร็จ: " .. tostring(err))
    App.updateAfkUI()
    return false
end

-- ============================================================================
-- 17.1) Auto supervisor (adapter-gated)
-- ============================================================================
-- adapter contract:
--   getState() -> {
--     ready = true/false, loading = bool?, frozen = bool?,
--     inStage = bool, stageEnded = bool, stageKey = string/number?,
--     runId = string/number?, expReady = bool, expVersion = string/number?
--   }
--   startStage()/restartStage()/nextStage() -> true หรือ { ok = true, message = "..." }
--   evolveExp(target, goal) -> true หรือ { ok = true, message = "..." }
-- adapter ต้องตรวจวัตถุดิบ/เงื่อนไขเอง; supervisor ไม่เดาสถานะและไม่สร้างผลลัพธ์แทน

Auto.busy = false
Auto.wasInStage = nil
Auto.wasExpReady = nil
Auto.lastEndedKey = nil
Auto.lastStageStopKey = nil
Auto.lastExpStopKey = nil
Auto.lastExpKey = nil
Auto.emptyWarned = false
Auto.expTargetWarned = false

local function autoResult(result, extra)
    if result == true then
        return true, nil
    end
    if type(result) == "table" then
        if result.ok == true then
            return true, result.message or result.reason
        end
        return false, result.message or result.reason or "adapter ปฏิเสธคำสั่ง"
    end
    if result == false then
        return false, extra or "adapter ทำงานไม่สำเร็จ"
    end
    return false, "adapter ไม่ได้ยืนยันผลสำเร็จ"
end

local function autoFailure(key, label, message)
    Auto.failures[key] = (Auto.failures[key] or 0) + 1
    Auto.lastError = label .. ": " .. tostring(message)
    Auto.lockUntil = clock() + 5
    Log.add("error", string.format("%s ล้มเหลว (%d/3): %s", label, Auto.failures[key], tostring(message)))
    if Auto.failures[key] >= 3 then
        Settings.auto[key] = false
        saveSettings()
        Log.add("error", label .. " ถูกปิดหลังล้มเหลว 3 ครั้ง — ตรวจ adapter/เงื่อนไขก่อนเปิดใหม่")
        if type(App.refreshAutoUI) == "function" then
            pcall(App.refreshAutoUI)
        end
    end
end

local function autoAction(key, label, action)
    if Auto.busy then
        return false
    end
    Auto.busy = true
    local callOk, result, extra = pcall(action)
    Auto.busy = false

    local success, message
    if not callOk then
        success = false
        message = result
    else
        success, message = autoResult(result, extra)
    end

    if success then
        Auto.failures[key] = 0
        Auto.lastAction = os.date("%H:%M:%S") .. " • " .. label
        Auto.lastError = ""
        Auto.lockUntil = clock() + 3
        Log.add("success", label .. " สำเร็จ" .. (message and (" — " .. tostring(message)) or ""))
        if type(App.refreshAutoUI) == "function" then
            pcall(App.refreshAutoUI)
        end
        return true
    end

    autoFailure(key, label, message)
    if type(App.refreshAutoUI) == "function" then
        pcall(App.refreshAutoUI)
    end
    return false
end

function Auto.tick()
    if not App.gameAdapter then
        Auto.wasInStage = nil
        Auto.wasExpReady = nil
        Auto.lastEndedKey = nil
        return
    end

    local anyOn = Settings.auto.start or Settings.auto.restart or Settings.auto.next or Settings.auto.exp
    if not anyOn then
        return
    end
    -- หลีกเลี่ยงการสั่งงานทับหน้าตั้งชื่อ/กู้คืน/ยืนยันที่ผู้ใช้กำลังทำอยู่
    if UI.modal then
        return
    end
    if clock() < Auto.lockUntil or Auto.busy then
        return
    end

    local state, stateError = adapterState()
    if not state then
        Auto.lastError = "อ่านสถานะเกมไม่ได้: " .. tostring(stateError)
        return
    end
    Auto.lastState = state
    Auto.lastCheck = os.time()

    local inStage = state.inStage == true
    local previousInStage = Auto.wasInStage
    Auto.wasInStage = inStage

    local stageKey = tostring(state.stageKey or "")
        .. "|" .. tostring(state.runId or "")
        .. "|" .. tostring(state.stageEndedAt or "ended")
    local expReady = state.expReady == true
    local expStopKey = tostring(state.stageKey or "")
        .. "|" .. tostring(state.expVersion or state.expReadyAt or "ready")

    if state.stageEnded ~= true then
        Auto.lastEndedKey = nil
        Auto.lastStageStopKey = nil
    end
    if not expReady then
        Auto.lastExpStopKey = nil
    end

    -- จบด่านระหว่างเล่น: หยุด Macro ก่อน เพื่อให้ Auto Next/Restart ทำงานแบบไม่ซ้อน
    -- ต้องมี stageEnded = true จาก adapter เท่านั้น
    if state.stageEnded == true and (Settings.auto.next or Settings.auto.restart) then
        if State.mode == "playing" or State.mode == "paused" then
            if Auto.lastStageStopKey ~= stageKey then
                Auto.lastStageStopKey = stageKey
                Log.add("info", "adapter ยืนยันจบด่าน — หยุด Macro เพื่อให้ Auto เปลี่ยนด่าน")
                App.stopPlayback()
            end
            return
        end
    end

    -- EXP พร้อมระหว่างเล่น: หยุด Macro ก่อน Evolution เพื่อไม่ให้อินพุตซ้อนกับ adapter
    if Settings.auto.exp and expReady then
        if State.mode == "playing" or State.mode == "paused" then
            if Auto.lastExpStopKey ~= expStopKey then
                Auto.lastExpStopKey = expStopKey
                Log.add("info", "adapter ยืนยัน EXP พร้อม — หยุด Macro ก่อน Evolution")
                App.stopPlayback()
            end
            return
        end
    end

    if State.pendingRecording or State.mode == "recording" or State.mode == "countdown" then
        return
    end

    local ready, readyReason = stateReadiness(state)
    if not ready then
        Auto.lastError = "รอเกมพร้อม: " .. tostring(readyReason)
        return
    end
    if State.mode ~= "idle" then
        return
    end

    -- Auto Start: เริ่ม Macro เมื่อ adapter ยืนยันการเข้าสนาม/แผนที่ (rising edge)
    -- ถ้า EXP พร้อมและเปิด Auto EXP ให้ Evolution ก่อน ไม่เริ่ม Macro สลับไปมา
    if Settings.auto.start and not (Settings.auto.exp and expReady) and inStage and previousInStage ~= true then
        if #Profiles.events == 0 then
            if not Auto.emptyWarned then
                Auto.emptyWarned = true
                Auto.lastError = "Auto Start ข้าม: Macro ที่เลือกไม่มีขั้นตอน"
                Log.add("warn", "Auto Start ข้าม: Macro ที่เลือกไม่มีขั้นตอน")
            end
        else
            autoAction("start", "Auto Start", function()
                return App.startPlayback({ fromAuto = true })
            end)
            return
        end
    end

    -- จบด่าน: ต้องมี stageEnded = true จาก adapter เท่านั้น
    if state.stageEnded == true and (Settings.auto.next or Settings.auto.restart) then
        if Auto.lastEndedKey ~= stageKey then
            Auto.lastEndedKey = stageKey
            if Settings.auto.next then
                autoAction("next", "Auto Next", function()
                    local ok, result = adapterCall("nextStage")
                    if not ok then
                        return false, result
                    end
                    return result
                end)
                return
            end
            autoAction("restart", "Auto Restart", function()
                local ok, result = adapterCall("restartStage")
                if not ok then
                    return false, result
                end
                return result
            end)
            return
        end
    end

    -- Auto EXP Evolution: ต้องมี expReady = true และ adapter ตรวจวัตถุดิบเอง
    local previousExpReady = Auto.wasExpReady
    Auto.wasExpReady = expReady
    if Settings.auto.exp and expReady and previousExpReady ~= true then
        local target = trimText(Settings.auto.target or "")
        if target == "" then
            if not Auto.expTargetWarned then
                Auto.expTargetWarned = true
                Auto.lastError = "Auto EXP ข้าม: ยังไม่ได้ระบุเป้าหมาย"
                Log.add("warn", "Auto EXP ข้าม: ยังไม่ได้ระบุชื่อ/ID ตัวละครเป้าหมาย")
            end
            return
        end
        local goal = Settings.auto.goal == 4 and 4 or 5
        local expActionKey = tostring(state.stageKey or "")
            .. "|" .. target
            .. "|" .. tostring(goal)
            .. "|" .. tostring(state.expVersion or state.expReadyAt or "")
        if Auto.lastExpKey ~= expActionKey then
            Auto.lastExpKey = expActionKey
            local evolved = autoAction("exp", "Auto EXP Evolution", function()
                local ok, result = adapterCall("evolveExp", target, goal)
                if not ok then
                    return false, result
                end
                return result
            end)
            if evolved then
                -- ให้ Auto Start เริ่ม Macro อีกครั้งเมื่อ adapter ยืนยันว่า evolution เสร็จและ expReady กลับเป็น false
                Auto.wasInStage = nil
            end
        end
    end
end

-- ============================================================================
-- 18) คำสั่งอื่น ๆ และการปิดสคริปต์
-- ============================================================================

function App.promptResetSettings()
    showConfirm(
        "รีเซ็ตการตั้งค่า?",
        "ค่าจำนวนรอบ ช่วงพัก ความเร็ว ตัวกรองการบันทึก พิกัด Auto และระบบกัน AFK จะกลับเป็นค่าเริ่มต้น (โปรไฟล์/Macro ไม่ถูกลบ)",
        "รีเซ็ต",
        function()
            for key, value in pairs(DEFAULT_SETTINGS) do
                if type(value) ~= "table" then
                    Settings[key] = value
                end
            end
            Settings.auto = defaultAutoSettings()
            Settings.afkEnabled = false
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
    if State.pendingRecording then
        message = message .. " • ข้อมูลที่ยังไม่ตั้งชื่อจะถูกเก็บไว้ใน recovery"
    elseif State.mode == "recording" or State.mode == "countdown" then
        message = message .. " • การบันทึกที่ยังไม่เสร็จจะถูกเก็บไว้ใน recovery"
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

local RuntimeHandle = {
    version = APP_VERSION,
    alive = true,
    -- ใช้ให้สคริปต์รุ่นใหม่ตรวจได้ว่าอินสแตนซ์เดิมยังมี GUI จริงหรือเหลือแต่ handle ค้าง
    getRoot = function()
        return UI.screenGui
    end,
}

function App.destroy()
    if State.destroyed then
        return
    end
    State.destroyed = true
    Running = false
    State.token += 1

    -- เก็บข้อมูลที่ยังไม่ตั้งชื่อก่อนปิด เพื่อให้เปิดสคริปต์ใหม่แล้วกู้คืนได้
    if State.mode == "recording" and #State.events > 0 then
        local set = Rec.buildInferredSet(State.events)
        Recovery.write(Rec.makePendingRecording(State.events, set, State.recordViewport))
    elseif State.pendingRecording then
        Recovery.write(State.pendingRecording)
    end

    State.mode = "idle"
    closeModal()
    releaseHeld()
    Settings.afkEnabled = false

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

    RuntimeHandle.alive = false
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
RuntimeHandle.open = function()
    setMenuVisible(true)
end
RuntimeHandle.toggle = function()
    toggleMenu()
end
RuntimeHandle.status = function()
    return State.mode, State.statusText
end
RuntimeHandle.getCapabilities = function()
    return Cap
end
RuntimeHandle.getInput = function()
    return {
        build = APP_BUILD,
        version = APP_VERSION,
        backend = Input.backend,
        describe = Input.describe(),
        ready = Input.ready,
        virtual = Input.isVirtual(),
        afk = Cap.afk == true,
        virtualInputReady = Cap.virtualInputReady == true,
        virtualInputError = Cap.virtualInputError,
        vimReady = Cap.vimReady == true,
        realReady = Cap.realReady == true,
        realMissing = Cap.realMissing,
    }
end
RuntimeHandle.installGameAdapter = function(adapter)
    return App.installGameAdapter(adapter)
end
RuntimeHandle.removeGameAdapter = function()
    return App.removeGameAdapter()
end
RuntimeHandle.getAdapterStatus = function()
    return App.getAdapterStatus()
end
RuntimeHandle.getGameContext = function()
    return GameContext.current
end
RuntimeHandle.captureGameContext = function()
    return GameContext.safeCapture()
end
RuntimeHandle.preflightGameContext = function(stored, current)
    return GameContext.preflight(stored, current)
end
RuntimeHandle.mergeGameContext = function(base, extra)
    return GameContext.mergeContexts(base, extra)
end
RuntimeHandle.notifyDuplicate = function()
    setMenuVisible(true)
    showNotice(
        "สคริปต์ทำงานอยู่แล้ว",
        "พบ ASTD Macro อีกอินสแตนซ์ในเซสชันนี้\nระบบไม่โหลดซ้ำเพื่อป้องกันการบันทึก/เล่นซ้อนกัน"
    )
end

-- ============================================================================
-- 19) เริ่มต้นสคริปต์
-- ============================================================================

detectCapabilities()
print(string.format(
    "[ASTD Macro] Bootstrap 2/5: ตรวจสอบ Executor แล้ว (%s %s • %s)",
    tostring(Cap.executorName),
    tostring(Cap.executorVersion),
    tostring(Cap.platform)
))
Input.init()

local foldersOk, foldersError = ensureWorkspaceFolders()
App.apiStatus.input = Cap.input ~= "none"
App.apiStatus.files = FileTools.ready and foldersOk
App.apiStatus.clipboard = Cap.clipboard
App.executorName = Cap.executorName
App.executorVersion = Cap.executorVersion

if App.apiStatus.files then
    Log.initFile()
else
    Log.add("warn", "ที่เก็บไฟล์ไม่พร้อมใช้งาน: " .. tostring(foldersError or "writefile/readfile/makefolder ไม่ครบ"))
end

loadSettings()
-- ใช้ค่าตั้งค่าที่เพิ่งโหลด (noMouseMove) กำหนด backend จริงอีกครั้ง
Input.init()
App.apiStatus.input = Cap.input ~= "none"
Log.add("info", "อินพุตที่ใช้: " .. Input.describe()
    .. (Input.isVirtual() and " (เมาส์จริงไม่ถูกย้าย)" or (Cap.input == "real" and " (เมาส์จริงจะขยับ)" or "")))
print("[ASTD Macro] Build " .. APP_BUILD .. " • อินพุต: " .. Input.describe()
    .. (Input.isVirtual() and " • เมาส์จริงไม่ถูกย้าย" or (Cap.input == "real" and " • เมาส์จริงจะขยับ" or "")))
if Cap.virtualInputError and not Cap.vimReady then
    Log.add("warn", "VirtualInput ไม่พร้อม: " .. tostring(Cap.virtualInputError))
end
loadProfiles()
Log.add("info", string.format(
    "Bootstrap 3/5: โหลดตั้งค่า/โปรไฟล์แล้ว (%d โปรไฟล์) • files %s",
    #Profiles.list,
    App.apiStatus.files and "พร้อม" or "จำกัด"
))

if not Profiles.selectedId and #Profiles.list > 0 then
    Profiles.selectedId = Profiles.list[1].id
end
if Profiles.selectedId or Profiles.data then
    local opened = Profiles.data ~= nil and Profiles.data.id == Profiles.selectedId
    if not opened and Profiles.selectedId then
        opened = App.selectProfile(Profiles.selectedId, true, true) == true
    end
    if not opened then
        -- ไฟล์ที่เลือกอ่านไม่ได้: ลองโปรไฟล์อื่นก่อน โดยไม่ลบหรือเขียนทับไฟล์เดิม
        for _, item in ipairs(Profiles.list) do
            if item.id ~= Profiles.selectedId and App.selectProfile(item.id, true, true) then
                opened = true
                Log.add("warn", "เปิดโปรไฟล์ที่เลือกไม่ได้ — เปลี่ยนไปใช้โปรไฟล์: " .. item.name)
                break
            end
        end
    end
    if not opened then
        local meta, data = makeEmptyProfileData("โปรไฟล์สำรอง")
        addProfileMeta(meta)
        Profiles.selectedId = meta.id
        Profiles.data = data
        Profiles.selectedMacroId = data.selectedMacroId
        Profiles.events = data.events
        local saved, saveError = saveProfileToDisk(meta, {})
        if not saved then
            Log.add("error", "สร้างโปรไฟล์สำรองไม่สำเร็จ: " .. tostring(saveError))
        end
        saveIndex()
        Log.add("warn", "เปิดโปรไฟล์เดิมไม่ได้ทุกไฟล์ — เริ่มด้วยโปรไฟล์ใหม่: " .. meta.name)
    end
elseif Profiles.data then
    Profiles.selectedId = Profiles.data.id
end

Log.add("info", "Bootstrap 4/5: กำลังสร้าง GUI...")
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

Log.add("info", "Bootstrap 4/5: สร้าง GUI สำเร็จ (" .. tostring(App.apiStatus.gui) .. ")")
connectInputHandlers()

local localPlayer = Players.LocalPlayer
if localPlayer then
    connectTracked(localPlayer.Idled, function()
        -- ไม่ขยับทันที: AFK Guard ต้องทำงานตามรอบคงที่ 5 นาทีเท่านั้น
        Log.add("info", "เกมรายงานว่าผู้เล่นไม่ได้ใช้งาน (Idled) — AFK Guard จะทำงานตามรอบ 5 นาที")
    end)
end

task.spawn(function()
    while Running do
        task.wait(1)
        if not Running then
            break
        end

        GameContext.poll()
        Auto.tick()

        if Settings.afkEnabled and Cap.afk and Input.available() then
            local now = os.time()
            local last = AfkGuard.lastAttempt or AfkGuard.lastNudge or AfkGuard.startedAt or now
            if now - last >= 300 then
                AfkGuard.lastAttempt = now
                if State.mode == "idle" and not State.pendingRecording then
                    AfkGuard.nudge("ครบรอบ 5 นาที")
                else
                    AfkGuard.lastResult = "ข้าม: Macro กำลังทำงาน"
                    App.updateAfkUI()
                end
            end
        end
    end
end)

App.refreshProfiles()
App.refreshSettingsUI()
App.refreshTransport()
Rec.updateRecordInfo()
GameContext.poll(true)

if Cap.input == "none" then
    setStatus("ไม่พบ API อินพุต", "error")
elseif Cap.input == "virtual" then
    setStatus("พร้อม (VirtualUser ทดลอง)", "warn")
elseif Input.isVirtual() then
    setStatus("พร้อม (เมาส์จริงอยู่กับที่)", "ready")
elseif Cap.input == "real" and Settings.noMouseMove ~= false then
    setStatus("พร้อม (fallback: เมาส์จริงขยับ)", "warn")
else
    setStatus("พร้อมใช้งาน", "ready")
end

Log.add("info", string.format(
    "%s v%s เริ่มทำงาน • executor %s %s • platform %s • GUI %s",
    APP_NAME,
    APP_VERSION,
    tostring(App.executorName),
    tostring(App.executorVersion),
    tostring(Cap.platform),
    tostring(App.apiStatus.gui)
))
Log.add("info", string.format(
    "API: input %s • files %s • clipboard %s • profiles %d",
    Cap.inputLabel,
    App.apiStatus.files and "พร้อม" or "จำกัด",
    App.apiStatus.clipboard and "พร้อม" or "ไม่มี",
    #Profiles.list
))
if #Cap.realMissing > 0 then
    Log.add("warn", "Executor input ที่ขาด: " .. table.concat(Cap.realMissing, ", "))
end
if Cap.input == "virtual" then
    Log.add("warn", "ใช้ VirtualUser (ทดลอง) — ยังไม่ยืนยันการทำงานบน Delta/iOS จนกว่าจะทดสอบจริง")
elseif Cap.input == "none" then
    Log.add("error", "ไม่มี API อินพุต: บันทึกได้ แต่เล่นซ้ำ/Auto/AFK ไม่ได้")
end
if App.apiStatus.files then
    Log.add("info", "ที่เก็บข้อมูล: " .. tostring(ROOT_DIR) .. "/ (workspace ของ executor)")
end
if App.gameAdapter then
    local adapterText = App.getAdapterStatus()
    Log.add("info", "Game adapter: " .. tostring(adapterText))
else
    Log.add("warn", "ยังไม่มี game adapter — Auto/คืนค่าเซ็ต/ตรวจจับจบด่านถูกปิดตามข้อจำกัด")
end

-- แจ้งข้อมูลกู้คืนที่ค้างอยู่หลัง GUI พร้อม
task.delay(0.5, function()
    if not Running then
        return
    end
    if Recovery.exists() and not State.pendingRecording then
        App.promptRecovery()
    end
end)

GENV.__ASTD_MACRO = RuntimeHandle
Log.add("info", "Bootstrap 5/5: พร้อมใช้งาน — F7 ซ่อน/แสดงเมนู, F8 หยุดฉุกเฉิน")
