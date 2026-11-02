--[[ YBA Helper v3 (optimized + patrol) | Xeno
     RightShift - скрыть/показать меню | End - выгрузить ]]

local function log(...) print("[YBA]", ...) end

if not game:IsLoaded() then game.Loaded:Wait() end
local Players = game:GetService("Players")
local LP = Players.LocalPlayer
while not LP do task.wait(0.1); LP = Players.LocalPlayer end
log("1/5 игра загружена")

local ENV = (getgenv and getgenv()) or _G
if ENV.__YBA_UNLOAD then pcall(ENV.__YBA_UNLOAD) end

local ok, err = xpcall(function()

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UIS = game:GetService("UserInputService")

local function jitter(a, b) return a + math.random() * (b - a) end
local function randName(n)
    local s = {}
    for i = 1, n or 12 do s[i] = string.char(math.random(97, 122)) end
    return table.concat(s)
end

-- ========== НАСТРОЙКИ ==========
local CFG = {
    ESP = true, ShowName = true, ShowDist = true, Highlight = true,
    MaxDist = 6000, HLLimit = 25,
    AutoCollect = false, Instant = false, Speed = 150,
    Patrol = false, PatrolSpeed = 220, PatrolRadius = 500, PatrolHeight = 40,
    Humanize = true, StopNearPlayers = false, PlayerRadius = 120, MaxPerMin = 20,
    Extended = false,   -- расширенный поиск по всему workspace
}
local Running, Busy = true, false
local Connections, currentTween = {}, nil
local Selected, Known, Blacklist = {}, {}, {}
local stamps = {}
local Unload
local AutoStatus = "выключен"

local function isSelected(name) return Selected[name] ~= false end

-- Известные предметы YBA (названия по памяти; всё остальное добавится в фильтр автоматически)
local KNOWN_ITEMS = {
    "Mysterious Arrow", "Lucky Arrow", "Rokakaka", "Pure Rokakaka",
    "Diary", "Steel Ball", "Stone Mask", "Ancient Scroll",
    "Rib Cage of The Saint's Corpse", "Left Arm of The Saint's Corpse", "Right Arm of The Saint's Corpse",
    "Pelvis of The Saint's Corpse", "Heart of The Saint's Corpse",
    "Left Leg of The Saint's Corpse", "Right Leg of The Saint's Corpse",
    "Zeppelin's Headband", "Quinton's Glove", "Caesar's Headband", "Clackers", "Gold Coin", "Green Baby",
}
local KEYWORDS = {"arrow", "rokakaka", "diary", "mask", "corpse", "saint", "steel ball", "scroll",
    "headband", "glove", "clackers", "coin", "green baby", "lucky", "pure"}

local function looksLikeItem(s)
    s = tostring(s or ""):lower()
    if s == "" then return false end
    for _, k in ipairs(KEYWORDS) do
        if s:find(k, 1, true) then return true end
    end
    return false
end

-- ========== ПОИСК ПРЕДМЕТОВ (событийно, без постоянных обходов) ==========
local function getItemPos(item)
    if item:IsA("Model") then return item:GetPivot().Position end
    if item:IsA("BasePart") then return item.Position end
    local p = item:FindFirstChildWhichIsA("BasePart", true)
    return p and p.Position
end

local function getAdorneePart(item)
    if item:IsA("BasePart") then return item end
    if item:IsA("Model") and item.PrimaryPart then return item.PrimaryPart end
    return item:FindFirstChildWhichIsA("BasePart", true)
end

local function buildEntry(prompt, root)
    if not prompt.Enabled then return nil end
    local par = prompt.Parent
    local pos
    if par and par:IsA("BasePart") then pos = par.Position
    elseif par and par:IsA("Attachment") then pos = par.WorldPosition
    else pos = getItemPos(root) end
    if not pos then return nil end
    local name
    if looksLikeItem(root.Name) then name = root.Name
    elseif prompt.ObjectText ~= "" then name = prompt.ObjectText
    else name = root.Name end
    return {Item = root, Prompt = prompt, Pos = pos, Name = name}
end

-- Основной источник: папка Item_Spawns.Items, слушаем события вместо обхода каждый раз
local FolderRoots = {}   -- root(Model/Part) -> true, пока жив
local folderReady = false
task.spawn(function()
    local sp = workspace:WaitForChild("Item_Spawns", 20)
    local folder = sp and sp:FindFirstChild("Items")
    if not folder then
        local ok2 = pcall(function() folder = sp:WaitForChild("Items", 10) end)
    end
    if not folder then folderReady = true return end
    for _, c in ipairs(folder:GetChildren()) do FolderRoots[c] = true end
    folderReady = true
    table.insert(Connections, folder.ChildAdded:Connect(function(c) FolderRoots[c] = true end))
    table.insert(Connections, folder.ChildRemoved:Connect(function(c) FolderRoots[c] = nil end))
end)

local promptCache = setmetatable({}, {__mode = "k"})
local function promptOf(root)
    local p = promptCache[root]
    if p and p.Parent then return p end
    if root:IsA("ProximityPrompt") then p = root
    else p = root:FindFirstChildWhichIsA("ProximityPrompt", true) end
    promptCache[root] = p
    return p
end

-- Расширенный поиск: событийно + разовый обход порциями при включении тумблера (как раньше, но не каждые 2с)
local ExtRoots, extConn, extToken = {}, nil, 0
local function extAdd(inst)
    if inst:IsA("ProximityPrompt") then
        local root = inst:FindFirstAncestorOfClass("Model") or inst.Parent
        if root and root ~= workspace and not root:FindFirstChildOfClass("Humanoid")
            and not Players:GetPlayerFromCharacter(root)
            and (looksLikeItem(root.Name) or looksLikeItem(inst.ObjectText)) then
            ExtRoots[root] = true
        end
    end
end
local function setExtended(v)
    CFG.Extended = v
    extToken = extToken + 1
    if extConn then extConn:Disconnect(); extConn = nil end
    if v then
        extConn = workspace.DescendantAdded:Connect(extAdd)
        local token = extToken
        task.spawn(function()
            local n = 0
            for _, inst in ipairs(workspace:GetDescendants()) do
                if token ~= extToken or not Running then return end
                extAdd(inst)
                n = n + 1
                if n % 2000 == 0 then task.wait() end
            end
        end)
    else
        ExtRoots = {}
    end
end

-- Если путь к предметам изменится - правь здесь
local function getItems()
    local result, seen = {}, {}
    for root in pairs(FolderRoots) do
        if not root:IsDescendantOf(workspace) then
            FolderRoots[root] = nil
        else
            local p = promptOf(root)
            if p and not seen[root] then
                local e = buildEntry(p, root)
                if e then seen[root] = true; table.insert(result, e) end
            end
        end
    end
    if CFG.Extended or (folderReady and next(FolderRoots) == nil) then
        for root in pairs(ExtRoots) do
            if not root:IsDescendantOf(workspace) then
                ExtRoots[root] = nil
            elseif not seen[root] then
                local p = promptOf(root)
                if p then
                    local e = buildEntry(p, root)
                    if e then seen[root] = true; table.insert(result, e) end
                end
            end
        end
    end
    return result
end

local function getHRP()
    local c = LP.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function stillValid(d)
    return d.Item.Parent ~= nil and d.Prompt.Parent ~= nil and d.Prompt.Enabled
end

local function playersNearby(radius)
    local hrp = getHRP()
    if not hrp then return false end
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP and p.Character then
            local r = p.Character:FindFirstChild("HumanoidRootPart")
            if r and (r.Position - hrp.Position).Magnitude <= radius then return true end
        end
    end
    return false
end

-- ========== ДВИЖЕНИЕ / СБОР ==========
local function moveTo(pos, prompt)
    local hrp = getHRP()
    local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
    if not hrp or not hum or hum.Health <= 0 then return false end

    local reach = math.max(((prompt and prompt.MaxActivationDistance) or 10) * 0.4, 1)
    local h = CFG.Humanize and math.min(reach, 1.2) or 0
    local offset = Vector3.new(jitter(-h, h), 2.5, jitter(-h, h))
    local rot = hrp.CFrame - hrp.CFrame.Position
    local target = CFrame.new(pos + offset) * rot

    if CFG.Instant then hrp.CFrame = target return true end

    local parts = {}
    for _, part in ipairs(LP.Character:GetDescendants()) do
        if part:IsA("BasePart") then parts[#parts + 1] = part end
    end

    local dist = (hrp.Position - target.Position).Magnitude
    local speed = math.clamp(CFG.Speed, 20, 400)
    if CFG.Humanize then speed = speed * jitter(0.9, 1.08) end

    local t = TweenService:Create(hrp, TweenInfo.new(math.max(dist / speed, 0.05), Enum.EasingStyle.Linear), {CFrame = target})
    currentTween = t
    local conn = RunService.Stepped:Connect(function()
        hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
        for _, part in ipairs(parts) do part.CanCollide = false end
    end)
    t:Play()
    t.Completed:Wait()
    conn:Disconnect()
    currentTween = nil
    return Running and hum.Health > 0
end

-- Несколько попыток, проверка что предмет реально исчез
local function collect(d)
    local prompt = d.Prompt
    if CFG.Humanize then task.wait(jitter(0.12, 0.3)) end
    for attempt = 1, 3 do
        if not stillValid(d) then return true end
        if fireproximityprompt and attempt ~= 2 then
            pcall(fireproximityprompt, prompt)
        else
            pcall(function()
                prompt:InputHoldBegin()
                task.wait((prompt.HoldDuration or 0) + 0.15)
                prompt:InputHoldEnd()
            end)
        end
        task.wait(0.3)
        if not stillValid(d) then return true end
    end
    return not stillValid(d)
end

local function canCollect()
    local now = os.clock()
    for i = #stamps, 1, -1 do
        if now - stamps[i] > 60 then table.remove(stamps, i) end
    end
    return #stamps < CFG.MaxPerMin
end

local function visit(d, doCollect)
    if Busy then return false end
    Busy = true
    local success = false
    local okV, eV = pcall(function()
        AutoStatus = "лечу к: " .. d.Name
        if not moveTo(d.Pos, d.Prompt) then AutoStatus = "полёт прерван"; return end
        if doCollect then
            AutoStatus = "собираю: " .. d.Name
            success = collect(d)
            table.insert(stamps, os.clock())
            AutoStatus = success and ("собрано: " .. d.Name) or ("не удалось: " .. d.Name)
        end
    end)
    if not okV then AutoStatus = "ошибка: " .. tostring(eV); warn("[YBA] visit:", eV) end
    Busy = false
    return success
end

local function filteredItems(sortFrom)
    local list = {}
    local now = os.clock()
    for _, d in ipairs(getItems()) do
        local bl = Blacklist[d.Item]
        if bl and now > bl then Blacklist[d.Item] = nil; bl = nil end
        if isSelected(d.Name) and not bl then table.insert(list, d) end
    end
    if sortFrom then
        table.sort(list, function(a, b)
            return (a.Pos - sortFrom).Magnitude < (b.Pos - sortFrom).Magnitude
        end)
    end
    return list
end

-- ========== ПАТРУЛЬ ВОКРУГ АРКАДЫ ==========
local PatrolCenter, PatrolPts, PatrolIdx, PatrolKey = nil, {}, 1, ""
local searchingArcade = false

local function settle(t)
    local hrp = getHRP()
    local t0 = os.clock()
    while hrp and hrp.Parent and os.clock() - t0 < t do
        hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
        RunService.Heartbeat:Wait()
    end
end

-- Полёт в точку без смещения под промпт, с возвратом коллизии после полёта
local function glide(pos, speed)
    local ch, hrp = LP.Character, getHRP()
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    if not (hrp and hum and hum.Health > 0) then return false end
    local parts, saved = {}, {}
    for _, part in ipairs(ch:GetDescendants()) do
        if part:IsA("BasePart") then parts[#parts + 1] = part; saved[part] = part.CanCollide end
    end
    local rot = hrp.CFrame - hrp.CFrame.Position
    local dist = (hrp.Position - pos).Magnitude
    local spd = math.clamp(speed, 20, 500)
    local t = TweenService:Create(hrp, TweenInfo.new(math.max(dist / spd, 0.05), Enum.EasingStyle.Linear), {CFrame = CFrame.new(pos) * rot})
    currentTween = t
    local conn = RunService.Stepped:Connect(function()
        hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
        for _, part in ipairs(parts) do part.CanCollide = false end
    end)
    t:Play()
    t.Completed:Wait()
    conn:Disconnect()
    currentTween = nil
    for part, v in pairs(saved) do
        if part.Parent then pcall(function() part.CanCollide = v end) end
    end
    return Running and hum.Health > 0
end

-- Ищет объект с "arcade" в названии (один обход порциями). Видно только загруженную зону.
local function findArcade()
    if searchingArcade then return nil end
    searchingArcade = true
    local model, part, n = nil, nil, 0
    for _, inst in ipairs(workspace:GetDescendants()) do
        if not Running then break end
        n = n + 1
        if n % 3000 == 0 then task.wait() end
        if (inst:IsA("Model") or inst:IsA("BasePart")) and inst.Name:lower():find("arcade", 1, true) then
            if inst:IsA("Model") and not Players:GetPlayerFromCharacter(inst) then model = inst break end
            if inst:IsA("BasePart") and not part then part = inst end
        end
    end
    searchingArcade = false
    if model then
        local okP, pos = pcall(function() return model:GetPivot().Position end)
        if okP then return pos, model:GetFullName() end
    end
    if part then return part.Position, part:GetFullName() end
    return nil
end

local function ensureCenter()
    if PatrolCenter then return true end
    AutoStatus = "ищу аркаду..."
    local pos, name = findArcade()
    if pos then
        PatrolCenter = pos
        log("центр патруля: аркада " .. tostring(name))
        return true
    end
    local hrp = getHRP()
    if hrp then
        PatrolCenter = hrp.Position
        AutoStatus = "аркада не найдена: центр патруля = твоя позиция"
        return true
    end
    return false
end

local function buildPatrol()
    local step = 300
    pcall(function()
        if workspace.StreamingEnabled then step = math.clamp(math.floor(workspace.StreamingTargetRadius * 0.8), 100, 600) end
    end)
    local key = string.format("%d|%d|%d|%d|%d", CFG.PatrolRadius, CFG.PatrolHeight, step, PatrolCenter.X, PatrolCenter.Z)
    if key == PatrolKey then return end
    PatrolKey = key
    local pts, R = {}, CFG.PatrolRadius
    local y = PatrolCenter.Y + CFG.PatrolHeight
    local rings = {R}
    if R >= 300 then rings[#rings + 1] = R * 0.5 end
    rings[#rings + 1] = 0
    for _, r in ipairs(rings) do
        if r == 0 then
            pts[#pts + 1] = Vector3.new(PatrolCenter.X, y, PatrolCenter.Z)
        else
            local n = math.max(8, math.floor(2 * math.pi * r / step))
            for i = 0, n - 1 do
                local a = (i / n) * 2 * math.pi
                pts[#pts + 1] = Vector3.new(PatrolCenter.X + math.cos(a) * r, y, PatrolCenter.Z + math.sin(a) * r)
            end
        end
    end
    PatrolPts, PatrolIdx = pts, 1
    local hrp = getHRP()
    if hrp then
        local best
        for i, p in ipairs(pts) do
            local d = (p - hrp.Position).Magnitude
            if not best or d < best then best, PatrolIdx = d, i end
        end
    end
end

-- Один шаг патруля: летим к следующей точке, даём клиенту подгрузить предметы вокруг
local function patrolStep()
    if not ensureCenter() then task.wait(1) return end
    buildPatrol()
    if #PatrolPts == 0 then return end
    if PatrolIdx > #PatrolPts then PatrolIdx = 1 end
    local p = PatrolPts[PatrolIdx]
    AutoStatus = string.format("патруль у аркады %d/%d", PatrolIdx, #PatrolPts)
    Busy = true
    local okP, eP = pcall(function()
        if glide(p, CFG.PatrolSpeed) then
            if workspace.StreamingEnabled then pcall(function() LP:RequestStreamAroundAsync(p, 0.6) end) end
            task.wait(0.35)
        end
    end)
    Busy = false
    PatrolIdx = PatrolIdx + 1
    if not okP then warn("[YBA] патруль:", eP) end
end

log("2/5 логика загружена")

-- ========== GUI ==========
local Theme = {
    Bg = Color3.fromRGB(18, 18, 24), Top = Color3.fromRGB(26, 26, 36),
    Elem = Color3.fromRGB(32, 32, 44), Accent = Color3.fromRGB(150, 90, 255),
    Text = Color3.fromRGB(235, 235, 245), Dim = Color3.fromRGB(150, 150, 170),
}

local function colorFor(name)
    local n = name:lower()
    if n:find("lucky") then return Color3.fromRGB(0, 255, 200) end
    if n:find("arrow") then return Color3.fromRGB(255, 200, 60) end
    if n:find("pure") then return Color3.fromRGB(255, 120, 200) end
    if n:find("rokakaka") then return Color3.fromRGB(255, 80, 80) end
    if n:find("mask") then return Color3.fromRGB(180, 120, 255) end
    if n:find("corpse") or n:find("saint") then return Color3.fromRGB(80, 255, 160) end
    if n:find("diary") then return Color3.fromRGB(100, 180, 255) end
    if n:find("steel") then return Color3.fromRGB(200, 200, 210) end
    if n:find("scroll") then return Color3.fromRGB(255, 150, 60) end
    return Theme.Accent
end

local function New(class, props, children)
    local o = Instance.new(class)
    for k, v in pairs(props or {}) do o[k] = v end
    for _, c in ipairs(children or {}) do c.Parent = o end
    return o
end
local function Corner(r) return New("UICorner", {CornerRadius = UDim.new(0, r)}) end

local Gui = New("ScreenGui", {Name = randName(14), ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 999})
local attached = false
local parents = {
    function() return gethui and gethui() end,
    function() return game:GetService("CoreGui") end,
    function() return LP:WaitForChild("PlayerGui", 10) end,
}
for i, getParent in ipairs(parents) do
    local okP, p = pcall(getParent)
    if okP and p then
        local okSet = pcall(function() Gui.Parent = p end)
        if okSet and Gui.Parent == p then
            log("GUI прикреплён, способ №" .. i)
            attached = true
            break
        end
    end
end
if not attached then error("Не удалось прикрепить GUI ни в одно место") end

local ESPFolder = New("Folder", {Name = randName(8), Parent = Gui})

local Main = New("Frame", {
    Size = UDim2.fromOffset(460, 380), Position = UDim2.new(0.5, -230, 0.5, -190),
    BackgroundColor3 = Theme.Bg, BorderSizePixel = 0, Active = true, Parent = Gui,
}, {Corner(12), New("UIStroke", {Color = Theme.Accent, Transparency = 0.6, Thickness = 1.2})})

local Top = New("Frame", {Size = UDim2.new(1, 0, 0, 40), BackgroundColor3 = Theme.Top, BorderSizePixel = 0, Parent = Main}, {Corner(12)})
New("Frame", {Size = UDim2.new(1, 0, 0, 12), Position = UDim2.new(0, 0, 1, -12), BackgroundColor3 = Theme.Top, BorderSizePixel = 0, Parent = Top})
New("TextLabel", {
    Text = "YBA Helper v3", Font = Enum.Font.GothamBold, TextSize = 16, TextColor3 = Theme.Text,
    BackgroundTransparency = 1, Size = UDim2.new(1, -60, 1, 0), Position = UDim2.fromOffset(14, 0),
    TextXAlignment = Enum.TextXAlignment.Left, Parent = Top,
})
local CloseBtn = New("TextButton", {
    Text = "X", Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = Theme.Text,
    BackgroundColor3 = Color3.fromRGB(200, 60, 80), Size = UDim2.fromOffset(28, 24),
    Position = UDim2.new(1, -38, 0.5, -12), Parent = Top,
}, {Corner(6)})

do
    local dragging, startPos, startInput = false, nil, nil
    Top.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging, startInput, startPos = true, i.Position, Main.Position
        end
    end)
    table.insert(Connections, UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - startInput
            Main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end))
    table.insert(Connections, UIS.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end))
end

local TabBar = New("Frame", {Size = UDim2.new(1, -20, 0, 30), Position = UDim2.fromOffset(10, 48), BackgroundTransparency = 1, Parent = Main},
    {New("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6)})})
local Pages, TabButtons = {}, {}

local function SelectTab(name)
    for n, p in pairs(Pages) do
        local on = (n == name)
        p.Visible = on
        TabButtons[n].BackgroundColor3 = on and Theme.Accent or Theme.Elem
        TabButtons[n].TextColor3 = on and Color3.new(1, 1, 1) or Theme.Dim
    end
end

local function AddTab(name)
    local page = New("ScrollingFrame", {
        Size = UDim2.new(1, -20, 1, -92), Position = UDim2.fromOffset(10, 84), BackgroundTransparency = 1,
        BorderSizePixel = 0, ScrollBarThickness = 3, ScrollBarImageColor3 = Theme.Accent,
        CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
        Visible = false, Parent = Main,
    }, {New("UIListLayout", {Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder})})
    local btn = New("TextButton", {
        Text = name, Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = Theme.Dim,
        BackgroundColor3 = Theme.Elem, Size = UDim2.fromOffset(82, 28), AutoButtonColor = false, Parent = TabBar,
    }, {Corner(8)})
    Pages[name], TabButtons[name] = page, btn
    btn.MouseButton1Click:Connect(function() SelectTab(name) end)
    return page
end

local function Toggle(parent, text, default, cb)
    local f = New("TextButton", {Text = "", Size = UDim2.new(1, -6, 0, 34), BackgroundColor3 = Theme.Elem, AutoButtonColor = false, Parent = parent}, {Corner(8)})
    New("TextLabel", {Text = text, Font = Enum.Font.Gotham, TextSize = 13, TextColor3 = Theme.Text, BackgroundTransparency = 1,
        Size = UDim2.new(1, -70, 1, 0), Position = UDim2.fromOffset(12, 0), TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd, Parent = f})
    local sw = New("Frame", {Size = UDim2.fromOffset(40, 20), Position = UDim2.new(1, -52, 0.5, -10), BackgroundColor3 = Theme.Top, Parent = f}, {Corner(10)})
    local knob = New("Frame", {Size = UDim2.fromOffset(16, 16), Position = UDim2.fromOffset(2, 2), BackgroundColor3 = Color3.new(1, 1, 1), Parent = sw}, {Corner(8)})
    local state = false
    local function set(v)
        state = v
        TweenService:Create(knob, TweenInfo.new(0.15), {Position = v and UDim2.fromOffset(22, 2) or UDim2.fromOffset(2, 2)}):Play()
        TweenService:Create(sw, TweenInfo.new(0.15), {BackgroundColor3 = v and Theme.Accent or Theme.Top}):Play()
        cb(v)
    end
    f.MouseButton1Click:Connect(function() set(not state) end)
    set(default)
    return set
end

local function Button(parent, text, cb)
    local b = New("TextButton", {Text = text, Font = Enum.Font.GothamMedium, TextSize = 13, TextColor3 = Color3.new(1, 1, 1),
        BackgroundColor3 = Theme.Accent, Size = UDim2.new(1, -6, 0, 32), Parent = parent}, {Corner(8)})
    b.MouseButton1Click:Connect(cb)
    return b
end

local function Label(parent, text)
    return New("TextLabel", {Text = text, Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = Theme.Dim, TextWrapped = true,
        BackgroundTransparency = 1, Size = UDim2.new(1, -6, 0, 22), Parent = parent})
end

local function Slider(parent, text, min, max, default, cb)
    local f = New("Frame", {Size = UDim2.new(1, -6, 0, 48), BackgroundColor3 = Theme.Elem, Parent = parent}, {Corner(8)})
    local lbl = New("TextLabel", {Text = text .. ": " .. default, Font = Enum.Font.Gotham, TextSize = 13, TextColor3 = Theme.Text,
        BackgroundTransparency = 1, Size = UDim2.new(1, -24, 0, 22), Position = UDim2.fromOffset(12, 4), TextXAlignment = Enum.TextXAlignment.Left, Parent = f})
    local bar = New("Frame", {Size = UDim2.new(1, -24, 0, 6), Position = UDim2.fromOffset(12, 33), BackgroundColor3 = Theme.Top, Parent = f}, {Corner(3)})
    local fill = New("Frame", {Size = UDim2.new((default - min) / (max - min), 0, 1, 0), BackgroundColor3 = Theme.Accent, Parent = bar}, {Corner(3)})
    local dragging = false
    local function update(x)
        local a = math.clamp((x - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
        local v = math.floor(min + (max - min) * a)
        fill.Size = UDim2.new(a, 0, 1, 0)
        lbl.Text = text .. ": " .. v
        cb(v)
    end
    bar.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging = true; update(i.Position.X)
        end
    end)
    table.insert(Connections, UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then update(i.Position.X) end
    end))
    table.insert(Connections, UIS.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end))
end

-- ========== ВКЛАДКИ ==========
local MainPage = AddTab("Главная")
local FilterPage = AddTab("Фильтр")
local ItemsPage = AddTab("Предметы")
local ProtPage = AddTab("Защита")
local SetPage = AddTab("Настройки")

Toggle(MainPage, "ESP предметов (ручной сбор)", CFG.ESP, function(v) CFG.ESP = v end)
Toggle(MainPage, "Авто-сбор выбранных", CFG.AutoCollect, function(v)
    CFG.AutoCollect = v
    AutoStatus = v and "запускаюсь..." or "выключен"
end)
Button(MainPage, "ТП + сбор ближайшего выбранного", function()
    local hrp = getHRP(); if not hrp then return end
    local list = filteredItems(hrp.Position)
    if list[1] then task.spawn(visit, list[1], true) else AutoStatus = "нет подходящих предметов" end
end)
local StatusLbl = Label(MainPage, "Предметов: 0")
local AutoLbl = Label(MainPage, "Авто-сбор: выключен")

Toggle(MainPage, "Патруль вокруг аркады (ищет и собирает предметы)", CFG.Patrol, function(v)
    CFG.Patrol = v
    AutoStatus = v and "патруль запускается..." or "патруль выключен"
end)
Slider(MainPage, "Радиус патруля (studs)", 150, 3000, CFG.PatrolRadius, function(v) CFG.PatrolRadius = v end)
Slider(MainPage, "Высота патруля над землёй", 10, 150, CFG.PatrolHeight, function(v) CFG.PatrolHeight = v end)
Slider(MainPage, "Скорость патруля", 50, 500, CFG.PatrolSpeed, function(v) CFG.PatrolSpeed = v end)
Button(MainPage, "Центр патруля = моя позиция (встань у аркады)", function()
    local h = getHRP()
    if h then PatrolCenter = h.Position; PatrolKey = ""; AutoStatus = "центр патруля сохранён" end
end)
Button(MainPage, "Найти аркаду заново", function()
    PatrolCenter, PatrolKey = nil, ""
    task.spawn(ensureCenter)
end)

local FilterSetters = {}
local b1 = Button(FilterPage, "Выбрать все", function() for _, s in pairs(FilterSetters) do s(true) end end)
local b2 = Button(FilterPage, "Снять все", function() for _, s in pairs(FilterSetters) do s(false) end end)
b1.LayoutOrder = -2; b2.LayoutOrder = -1
local function addFilterRow(name)
    if Known[name] then return end
    Known[name] = true
    FilterSetters[name] = Toggle(FilterPage, name, true, function(v) Selected[name] = v end)
end
for _, n in ipairs(KNOWN_ITEMS) do addFilterRow(n) end

Toggle(ProtPage, "Человекоподобное поведение", CFG.Humanize, function(v) CFG.Humanize = v end)
Toggle(ProtPage, "Пауза рядом с игроками", CFG.StopNearPlayers, function(v) CFG.StopNearPlayers = v end)
Slider(ProtPage, "Радиус проверки игроков", 50, 400, CFG.PlayerRadius, function(v) CFG.PlayerRadius = v end)
Slider(ProtPage, "Подборов в минуту (макс.)", 3, 40, CFG.MaxPerMin, function(v) CFG.MaxPerMin = v end)
Slider(ProtPage, "Скорость полёта к предмету", 20, 400, CFG.Speed, function(v) CFG.Speed = v end)
Toggle(ProtPage, "Мгновенный ТП (рискованно!)", CFG.Instant, function(v) CFG.Instant = v end)

Toggle(SetPage, "Расширенный поиск (весь workspace)", CFG.Extended, setExtended)
Toggle(SetPage, "Подсветка (Highlight)", CFG.Highlight, function(v) CFG.Highlight = v end)
Toggle(SetPage, "Названия", CFG.ShowName, function(v) CFG.ShowName = v end)
Toggle(SetPage, "Дистанция", CFG.ShowDist, function(v) CFG.ShowDist = v end)
Slider(SetPage, "Дистанция ESP", 200, 8000, CFG.MaxDist, function(v) CFG.MaxDist = v end)
Button(SetPage, "Диагностика в консоль", function()
    local sp = workspace:FindFirstChild("Item_Spawns")
    print("[YBA] Item_Spawns:", sp, "| Items:", sp and sp:FindFirstChild("Items"))
    local items = getItems()
    print("[YBA] найдено предметов:", #items, "| fireproximityprompt:", fireproximityprompt ~= nil)
    for i, d in ipairs(items) do
        if i > 20 then break end
        print("  ", d.Name, "|", d.Item:GetFullName(), "| hold:", d.Prompt.HoldDuration, "| dist:", d.Prompt.MaxActivationDistance)
    end
end)
Button(SetPage, "Выгрузить скрипт (End)", function() Unload() end)

SelectTab("Главная")
log("3/5 GUI построен")

CloseBtn.MouseButton1Click:Connect(function() Main.Visible = false end)
table.insert(Connections, UIS.InputBegan:Connect(function(i, gp)
    if i.KeyCode == Enum.KeyCode.End then Unload() return end
    if not gp and i.KeyCode == Enum.KeyCode.RightShift then Main.Visible = not Main.Visible end
end))

-- ========== СПИСОК ПРЕДМЕТОВ (строки переиспользуются, не пересоздаются) ==========
local rows = {}
local function RefreshList(list)
    local alive, n = {}, 0
    local hrp = getHRP()
    for _, d in ipairs(list) do
        n = n + 1
        if n > 50 then break end
        alive[d.Item] = true
        local r = rows[d.Item]
        if not r then
            local row = New("Frame", {Size = UDim2.new(1, -6, 0, 34), BackgroundColor3 = Theme.Elem, Parent = ItemsPage}, {Corner(8)})
            local lbl = New("TextLabel", {Text = "", Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = colorFor(d.Name),
                BackgroundTransparency = 1, Size = UDim2.new(1, -150, 1, 0), Position = UDim2.fromOffset(12, 0),
                TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Parent = row})
            local tp = New("TextButton", {Text = "ТП", Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = Color3.new(1, 1, 1),
                BackgroundColor3 = Theme.Top, Size = UDim2.fromOffset(40, 24), Position = UDim2.new(1, -136, 0.5, -12), Parent = row}, {Corner(6)})
            local tc = New("TextButton", {Text = "ТП+сбор", Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = Color3.new(1, 1, 1),
                BackgroundColor3 = Theme.Accent, Size = UDim2.fromOffset(84, 24), Position = UDim2.new(1, -92, 0.5, -12), Parent = row}, {Corner(6)})
            r = {row = row, lbl = lbl, d = d}
            rows[d.Item] = r
            tp.MouseButton1Click:Connect(function() task.spawn(visit, r.d, false) end)
            tc.MouseButton1Click:Connect(function() task.spawn(visit, r.d, true) end)
        end
        r.d = d
        r.row.LayoutOrder = n
        local dist = hrp and math.floor((d.Pos - hrp.Position).Magnitude) or 0
        local t = d.Name .. "  [" .. dist .. "m]"
        if r.lbl.Text ~= t then r.lbl.Text = t end
    end
    for item, r in pairs(rows) do
        if not alive[item] then r.row:Destroy(); rows[item] = nil end
    end
end

-- ========== ESP ==========
local ESPObjects = {}

local function clearESP(item)
    local e = ESPObjects[item]
    if e then
        if e.hl then e.hl:Destroy() end
        e.bb:Destroy()
        ESPObjects[item] = nil
    end
end

local function ensureESP(d)
    local e = ESPObjects[d.Item]
    if e then return e end
    local adornee = getAdorneePart(d.Item) or d.Prompt.Parent
    if not adornee or not adornee:IsA("BasePart") then return nil end
    local col = colorFor(d.Name)
    local bb = New("BillboardGui", {AlwaysOnTop = true, Size = UDim2.fromOffset(150, 34), StudsOffset = Vector3.new(0, 3, 0),
        Adornee = adornee, Parent = ESPFolder})
    local lbl = New("TextLabel", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Font = Enum.Font.GothamBold,
        TextSize = 13, TextColor3 = col, TextStrokeTransparency = 0.3, Text = d.Name, Parent = bb})
    e = {bb = bb, lbl = lbl, name = d.Name, color = col}
    ESPObjects[d.Item] = e
    return e
end

local function setHighlight(e, item, on)
    if on and not e.hl then
        e.hl = New("Highlight", {FillColor = e.color, FillTransparency = 0.55, OutlineColor = Color3.new(1, 1, 1),
            DepthMode = Enum.HighlightDepthMode.AlwaysOnTop, Adornee = item, Parent = ESPFolder})
    elseif not on and e.hl then
        e.hl:Destroy(); e.hl = nil
    end
end

task.spawn(function()
    while Running do
        local okL, errL = pcall(function()
            local all = getItems()
            local hrp = getHRP()
            local origin = hrp and hrp.Position or Vector3.new(0, 0, 0)

            for _, d in ipairs(all) do addFilterRow(d.Name) end

            local shown = {}
            for _, d in ipairs(all) do
                local dist = (d.Pos - origin).Magnitude
                if CFG.ESP and isSelected(d.Name) and dist <= CFG.MaxDist then
                    d.Dist = dist
                    table.insert(shown, d)
                end
            end
            table.sort(shown, function(a, b) return a.Dist < b.Dist end)

            local alive = {}
            for i, d in ipairs(shown) do
                alive[d.Item] = true
                local e = ensureESP(d)
                if e then
                    setHighlight(e, d.Item, CFG.Highlight and i <= CFG.HLLimit)
                    local t = CFG.ShowName and e.name or ""
                    if CFG.ShowDist then t = (t ~= "" and (t .. "\n") or "") .. string.format("[%d m]", d.Dist) end
                    if e.lbl.Text ~= t then e.lbl.Text = t end
                end
            end
            for item in pairs(ESPObjects) do
                if not alive[item] then clearESP(item) end
            end

            if Main.Visible then
                local sel = 0
                for _, d in ipairs(all) do if isSelected(d.Name) then sel = sel + 1 end end
                StatusLbl.Text = string.format("Предметов: %d (выбрано: %d) | подборов/мин: %d", #all, sel, #stamps)
                AutoLbl.Text = "Авто-сбор: " .. AutoStatus
            end
        end)
        if not okL then warn("[YBA] ESP:", errL) end
        task.wait(0.4)
    end
end)

task.spawn(function()
    while Running do
        if Main.Visible and ItemsPage.Visible then
            local hrp = getHRP()
            pcall(RefreshList, filteredItems(hrp and hrp.Position))
        end
        task.wait(1)
    end
end)
log("4/5 ESP запущен")

-- ========== АВТО-СБОР + ПАТРУЛЬ ==========
task.spawn(function()
    local sinceBreak, breakAfter = 0, math.random(4, 8)
    while Running do
        local okA, errA = pcall(function()
            if not (CFG.AutoCollect or CFG.Patrol) then task.wait(0.3) return end
            if Busy then task.wait(0.2) return end
            local hrp = getHRP()
            if not hrp then AutoStatus = "жду персонажа"; task.wait(1) return end
            if CFG.StopNearPlayers and playersNearby(CFG.PlayerRadius) then
                AutoStatus = "пауза: рядом игрок"; task.wait(2) return
            end

            local d = CFG.AutoCollect and filteredItems(hrp.Position)[1] or nil
            if d then
                if not canCollect() then
                    AutoStatus = "лимит подборов в минуту"; task.wait(3) return
                end
                local got = visit(d, true)
                if not got then Blacklist[d.Item] = os.clock() + 60 end
                task.wait(0.4)
                sinceBreak = sinceBreak + 1
                if CFG.Humanize then
                    task.wait(jitter(0.5, 1.8))
                    if sinceBreak >= breakAfter then
                        AutoStatus = "короткий перерыв"
                        task.wait(jitter(4, 9))
                        sinceBreak, breakAfter = 0, math.random(4, 8)
                    end
                end
            elseif CFG.Patrol then
                patrolStep()
            else
                AutoStatus = "нет подходящих предметов"; task.wait(1)
            end
        end)
        if not okA then warn("[YBA] Авто-сбор:", errA); AutoStatus = "ошибка (см. консоль)"; task.wait(1) end
    end
end)

Unload = function()
    Running = false
    CFG.AutoCollect = false
    CFG.Patrol = false
    extToken = extToken + 1
    if extConn then pcall(function() extConn:Disconnect() end) end
    if currentTween then pcall(function() currentTween:Cancel() end) end
    for _, c in ipairs(Connections) do pcall(function() c:Disconnect() end) end
    pcall(function() Gui:Destroy() end)
    ENV.__YBA_UNLOAD = nil
    log("выгружено")
end
ENV.__YBA_UNLOAD = function() Unload() end

log("5/5 готово! RightShift - меню, End - выгрузка")

end, debug.traceback)

if not ok then warn("[YBA] ОШИБКА ЗАПУСКА:\n" .. tostring(err)) end