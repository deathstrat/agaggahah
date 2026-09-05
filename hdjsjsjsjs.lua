--!strict
--[[
    =======================================================
    ADVANCED AUTO ORBIT SYSTEM (Rayfield UI Integrated)
    =======================================================
    Author   : Senior Luau Architect
    Context  : Client-Side (LocalScript)
    Compatibility: Luau / Roblox Studio 2026 Engine
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

-----------------------------------------------------------
-- 15. CONFIGURATION TABLE
-----------------------------------------------------------
local Config = {
    Enabled = false,
    AutoDetect = true,
    
    -- Target Detection
    DetectionRadius = 100,
    MinTargetDistance = 0,
    MaxTargetDistance = 150,
    TargetRefreshRate = 0.25, -- Interval scan target (detik)
    SelectionMode = "Nearest", -- "Nearest", "Lowest Health", "Random"
    
    -- Orbit Mechanics
    OrbitDistance = 8,
    OrbitHeight = 3,
    OrbitSpeed = 2.5,
    Direction = "Clockwise", -- "Clockwise" / "Counter-Clockwise"
    FaceTarget = true,
    
    -- Smoothing & Physics
    PositionSmoothness = 12, -- Nilai k untuk exponential lerp
    RotationSmoothness = 14,
    GroundCorrection = true,
    MinGroundOffset = 2.5,
    
    -- Filters
    IgnorePlayers = true,
    IgnoredFolderNames = { "Debris", "IgnoreList" },
    
    -- Debugging
    Debug = false
}

-----------------------------------------------------------
-- RUNTIME STATE & VARIABLES
-----------------------------------------------------------
type TargetData = {
    Model: Model,
    RootPart: BasePart,
    Humanoid: Humanoid
}

local CurrentTarget: TargetData? = nil
local CurrentAngle: number = 0
local TargetScanTimer: number = 0

local RenderConnection: RBXScriptConnection? = nil
local DebugHighlight: Highlight? = nil

-- Spatial Query Params Cache
local OverlapFilter = OverlapParams.new()
OverlapFilter.FilterType = Enum.RaycastFilterType.Exclude

-- Raycast Ground Params Cache
local GroundRayParams = RaycastParams.new()
GroundRayParams.FilterType = Enum.RaycastFilterType.Exclude
GroundRayParams.IgnoreWater = true

-----------------------------------------------------------
-- HELPER FUNCTIONS
-----------------------------------------------------------

-- Exponential smoothing FPS-Independent: 1 - e^(-speed * dt)
local function getSmoothAlpha(speed: number, dt: number): number
    return 1 - math.exp(-speed * dt)
end

local function getLocalCharacter(): (Model?, BasePart?, Humanoid?)
    local char = LocalPlayer.Character
    if not char then return nil, nil, nil end
    
    local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
    local hum = char:FindFirstChildOfClass("Humanoid") :: Humanoid?
    
    if char and root and hum and hum.Health > 0 then
        return char, root, hum
    end
    return nil, nil, nil
end

-----------------------------------------------------------
-- TARGET VALIDATION & DETECTION
-----------------------------------------------------------

local function isValidTarget(model: Instance): (boolean, TargetData?)
    if not model:IsA("Model") then return false, nil end
    
    local char = LocalPlayer.Character
    if model == char then return false, nil end
    
    -- Cek jika target adalah player lain
    if Config.IgnorePlayers and Players:GetPlayerFromCharacter(model) then
        return false, nil
    end
    
    -- Cek ignored folders
    for _, folderName in ipairs(Config.IgnoredFolderNames) do
        if model:IsDescendantOf(Workspace:FindFirstChild(folderName) or model) then
            return false, nil
        end
    end
    
    local hum = model:FindFirstChildOfClass("Humanoid")
    local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
    
    if not hum or not root then return false, nil end
    if hum.Health <= 0 then return false, nil end
    if not root:IsA("BasePart") then return false, nil end

    return true, {
        Model = model,
        RootPart = root,
        Humanoid = hum
    }
end

local function getNearbyTargets(): {TargetData}
    local _, myRoot, _ = getLocalCharacter()
    if not myRoot then return {} end

    -- Siapkan exclude filter agar query spatial efisien
    local excludeList = {LocalPlayer.Character}
    OverlapFilter.FilterDescendantsInstances = excludeList

    -- Spatial query modern: O(N) hanya pada bounding box lokal
    local parts = Workspace:GetPartBoundsInRadius(myRoot.Position, Config.DetectionRadius, OverlapFilter)
    local foundTargets: {TargetData} = {}
    local processedModels: {[Model]: boolean} = {}

    for _, part in ipairs(parts) do
        local model = part:FindFirstAncestorOfClass("Model")
        if model and not processedModels[model] then
            processedModels[model] = true
            local valid, targetData = isValidTarget(model)
            if valid and targetData then
                local dist = (targetData.RootPart.Position - myRoot.Position).Magnitude
                if dist >= Config.MinTargetDistance and dist <= Config.MaxTargetDistance then
                    table.insert(foundTargets, targetData)
                end
            end
        end
    end

    return foundTargets
end

local function selectBestTarget(): TargetData?
    local targets = getNearbyTargets()
    if #targets == 0 then return nil end

    local _, myRoot, _ = getLocalCharacter()
    if not myRoot then return nil end

    local mode = Config.SelectionMode

    if mode == "Nearest" or mode == "Lowest Distance" then
        local closestTarget: TargetData? = nil
        local shortestDist = math.huge
        for _, tgt in ipairs(targets) do
            local dist = (tgt.RootPart.Position - myRoot.Position).Magnitude
            if dist < shortestDist then
                shortestDist = dist
                closestTarget = tgt
            end
        end
        return closestTarget

    elseif mode == "Lowest Health" then
        local lowestTarget: TargetData? = nil
        local minHealth = math.huge
        for _, tgt in ipairs(targets) do
            if tgt.Humanoid.Health < minHealth then
                minHealth = tgt.Humanoid.Health
                lowestTarget = tgt
            end
        end
        return lowestTarget

    elseif mode == "Random" then
        return targets[math.random(1, #targets)]
    end

    return targets[1]
end

-----------------------------------------------------------
-- ORBIT LIFECYCLE & STATE MANAGEMENT
-----------------------------------------------------------

local function clearTarget()
    CurrentTarget = nil
    if DebugHighlight then
        DebugHighlight.Adornee = nil
    end
end

local function setTarget(target: TargetData)
    CurrentTarget = target
    if Config.Debug then
        if not DebugHighlight then
            DebugHighlight = Instance.new("Highlight")
            DebugHighlight.Name = "OrbitDebugHighlight"
            DebugHighlight.FillColor = Color3.fromRGB(0, 255, 128)
            DebugHighlight.OutlineColor = Color3.fromRGB(255, 255, 255)
            DebugHighlight.Parent = Workspace
        end
        DebugHighlight.Adornee = target.Model
    end
end

local function updateTargetValidation()
    if not CurrentTarget then
        if Config.AutoDetect then
            local best = selectBestTarget()
            if best then setTarget(best) end
        end
        return
    end

    -- Validasi apakah target saat ini masih layak diorbit
    local valid, _ = isValidTarget(CurrentTarget.Model)
    if not valid or not CurrentTarget.RootPart.Parent or not CurrentTarget.Humanoid.Parent then
        clearTarget()
        return
    end

    local _, myRoot, _ = getLocalCharacter()
    if myRoot then
        local dist = (CurrentTarget.RootPart.Position - myRoot.Position).Magnitude
        if dist > Config.MaxTargetDistance then
            clearTarget()
        end
    end
end

-----------------------------------------------------------
-- MATH & CFRAME CALCULATIONS
-----------------------------------------------------------

local function calculateDesiredCFrame(targetRoot: BasePart): CFrame
    local targetPos = targetRoot.Position
    
    local xOffset = math.cos(CurrentAngle) * Config.OrbitDistance
    local zOffset = math.sin(CurrentAngle) * Config.OrbitDistance
    local yOffset = Config.OrbitHeight

    local calculatedPos = targetPos + Vector3.new(xOffset, yOffset, zOffset)

    -- Ground Raycast Correction: Mencegah player amblas ke tanah
    if Config.GroundCorrection then
        local char = LocalPlayer.Character
        GroundRayParams.FilterDescendantsInstances = {char, targetRoot.Parent}
        
        local rayOrigin = calculatedPos + Vector3.new(0, 5, 0)
        local rayDirection = Vector3.new(0, -15, 0)
        local hit = Workspace:Raycast(rayOrigin, rayDirection, GroundRayParams)
        
        if hit then
            local floorHeight = hit.Position.Y + Config.MinGroundOffset
            if calculatedPos.Y < floorHeight then
                calculatedPos = Vector3.new(calculatedPos.X, floorHeight, calculatedPos.Z)
            end
        end
    end

    -- Hitung Orientation
    if Config.FaceTarget then
        -- Menghadap langsung ke target
        return CFrame.lookAt(calculatedPos, Vector3.new(targetPos.X, calculatedPos.Y, targetPos.Z))
    else
        -- Menghadap ke arah tangensial lintasan orbit (vektor kecepatan orbit)
        local dirMultiplier = (Config.Direction == "Clockwise") and 1 or -1
        local tangentVector = Vector3.new(-math.sin(CurrentAngle) * dirMultiplier, 0, math.cos(CurrentAngle) * dirMultiplier)
        return CFrame.lookAt(calculatedPos, calculatedPos + tangentVector)
    end
end

-----------------------------------------------------------
-- MOVEMENT LOOP (FPS INDEPENDENT)
-----------------------------------------------------------

local function updateOrbit(dt: number)
    local _, myRoot, _ = getLocalCharacter()
    if not myRoot then return end

    -- Interval loop untuk target scanning
    TargetScanTimer += dt
    if TargetScanTimer >= Config.TargetRefreshRate then
        TargetScanTimer = 0
        updateTargetValidation()
    end

    if not CurrentTarget or not CurrentTarget.RootPart then return end

    -- Perhitungan sudut orbit berbasis Delta Time
    local dirMultiplier = (Config.Direction == "Clockwise") and 1 or -1
    CurrentAngle += (Config.OrbitSpeed * dirMultiplier) * dt

    -- Normalisasi sudut ke range [0, 2π] untuk mencegah precision error float
    if CurrentAngle > math.pi * 2 then
        CurrentAngle -= math.pi * 2
    elseif CurrentAngle < 0 then
        CurrentAngle += math.pi * 2
    end

    -- Hitung posisi target CFrame
    local targetCFrame = calculateDesiredCFrame(CurrentTarget.RootPart)

    -- Lerp CFrame secara FPS-independent
    local posAlpha = getSmoothAlpha(Config.PositionSmoothness, dt)
    local rotAlpha = getSmoothAlpha(Config.RotationSmoothness, dt)

    local currentCF = myRoot.CFrame
    local blendedPos = currentCF.Position:Lerp(targetCFrame.Position, posAlpha)
    local blendedRot = currentCF.Rotation:Lerp(targetCFrame.Rotation, rotAlpha)

    myRoot.CFrame = CFrame.new(blendedPos) * blendedRot
end

local function startOrbit()
    if RenderConnection then return end
    
    -- Inisialisasi CurrentAngle dari sudut relatif saat ini terhadap target (jika ada)
    local _, myRoot, _ = getLocalCharacter()
    if myRoot and CurrentTarget then
        local offset = myRoot.Position - CurrentTarget.RootPart.Position
        CurrentAngle = math.atan2(offset.Z, offset.X)
    else
        CurrentAngle = 0
    end
    
    RenderConnection = RunService.RenderStepped:Connect(updateOrbit)
end

local function stopOrbit()
    if RenderConnection then
        RenderConnection:Disconnect()
        RenderConnection = nil
    end
    clearTarget()
end

local function resetOrbit()
    CurrentAngle = 0
    clearTarget()
    updateTargetValidation()
end

-----------------------------------------------------------
-- 8. RAYFIELD GUI IMPLEMENTATION
-----------------------------------------------------------

local Rayfield = loadstring(game:HttpGet('https://sirius.menu/rayfield'))()

local Window = Rayfield:CreateWindow({
    Name = "Auto Orbit Hub",
    LoadingTitle = "Initializing Orbit Engine...",
    LoadingSubtitle = "Production Build",
    ConfigurationSaving = {
        Enabled = false
    },
    KeySystem = false
})

-- TAB: MAIN
local MainTab = Window:CreateTab("Main", 4483362458)
MainTab:CreateToggle({
    Name = "Enable Auto Orbit",
    CurrentValue = Config.Enabled,
    Flag = "Toggle_AutoOrbit",
    Callback = function(Value)
        Config.Enabled = Value
        if Value then
            startOrbit()
        else
            stopOrbit()
        end
    end,
})

-- TAB: TARGET
local TargetTab = Window:CreateTab("Target", 4483362458)

TargetTab:CreateToggle({
    Name = "Auto Detect Mob",
    CurrentValue = Config.AutoDetect,
    Flag = "Toggle_AutoDetect",
    Callback = function(Value)
        Config.AutoDetect = Value
    end,
})

TargetTab:CreateSlider({
    Name = "Detection Radius",
    Range = {10, 300},
    Increment = 5,
    Suffix = " Studs",
    CurrentValue = Config.DetectionRadius,
    Flag = "Slider_Radius",
    Callback = function(Value)
        Config.DetectionRadius = Value
    end,
})

TargetTab:CreateSlider({
    Name = "Target Refresh Rate",
    Range = {0.05, 1.0},
    Increment = 0.05,
    Suffix = " s",
    CurrentValue = Config.TargetRefreshRate,
    Flag = "Slider_RefreshRate",
    Callback = function(Value)
        Config.TargetRefreshRate = Value
    end,
})

TargetTab:CreateDropdown({
    Name = "Target Selection Mode",
    Options = {"Nearest", "Lowest Health", "Random"},
    CurrentOption = {Config.SelectionMode},
    MultipleOptions = false,
    Flag = "Dropdown_SelectionMode",
    Callback = function(Option)
        Config.SelectionMode = Option[1]
    end,
})

-- TAB: ORBIT
local OrbitTab = Window:CreateTab("Orbit", 4483362458)

OrbitTab:CreateSlider({
    Name = "Orbit Distance",
    Range = {3, 50},
    Increment = 1,
    Suffix = " Studs",
    CurrentValue = Config.OrbitDistance,
    Flag = "Slider_OrbitDist",
    Callback = function(Value)
        Config.OrbitDistance = Value
    end,
})

OrbitTab:CreateSlider({
    Name = "Orbit Height",
    Range = {-10, 25},
    Increment = 1,
    Suffix = " Studs",
    CurrentValue = Config.OrbitHeight,
    Flag = "Slider_OrbitHeight",
    Callback = function(Value)
        Config.OrbitHeight = Value
    end,
})

OrbitTab:CreateSlider({
    Name = "Orbit Speed",
    Range = {0.5, 15},
    Increment = 0.5,
    Suffix = " rad/s",
    CurrentValue = Config.OrbitSpeed,
    Flag = "Slider_OrbitSpeed",
    Callback = function(Value)
        Config.OrbitSpeed = Value
    end,
})

OrbitTab:CreateSlider({
    Name = "Position Smoothness",
    Range = {1, 30},
    Increment = 1,
    Suffix = " Alpha",
    CurrentValue = Config.PositionSmoothness,
    Flag = "Slider_PosSmooth",
    Callback = function(Value)
        Config.PositionSmoothness = Value
    end,
})

OrbitTab:CreateSlider({
    Name = "Rotation Smoothness",
    Range = {1, 30},
    Increment = 1,
    Suffix = " Alpha",
    CurrentValue = Config.RotationSmoothness,
    Flag = "Slider_RotSmooth",
    Callback = function(Value)
        Config.RotationSmoothness = Value
    end,
})

OrbitTab:CreateDropdown({
    Name = "Orbit Direction",
    Options = {"Clockwise", "Counter-Clockwise"},
    CurrentOption = {Config.Direction},
    MultipleOptions = false,
    Flag = "Dropdown_Direction",
    Callback = function(Option)
        Config.Direction = Option[1]
    end,
})

OrbitTab:CreateToggle({
    Name = "Face Target",
    CurrentValue = Config.FaceTarget,
    Flag = "Toggle_FaceTarget",
    Callback = function(Value)
        Config.FaceTarget = Value
    end,
})

-- TAB: SETTINGS & DEBUG
local SettingsTab = Window:CreateTab("Settings", 4483362458)

SettingsTab:CreateToggle({
    Name = "Ground Correction",
    CurrentValue = Config.GroundCorrection,
    Flag = "Toggle_GroundCorrection",
    Callback = function(Value)
        Config.GroundCorrection = Value
    end,
})

local DebugLabel: any = nil

SettingsTab:CreateToggle({
    Name = "Debug Mode",
    CurrentValue = Config.Debug,
    Flag = "Toggle_Debug",
    Callback = function(Value)
        Config.Debug = Value
        if not Value and DebugHighlight then
            DebugHighlight.Adornee = nil
        end
    end,
})

DebugLabel = SettingsTab:CreateLabel("Target: None")

SettingsTab:CreateButton({
    Name = "Refresh Target",
    Callback = function()
        clearTarget()
        local best = selectBestTarget()
        if best then setTarget(best) end
    end,
})

SettingsTab:CreateButton({
    Name = "Reset Orbit",
    Callback = function()
        resetOrbit()
    end,
})

-- Debug Label Update Loop
task.spawn(function()
    while true do
        task.wait(0.2)
        if Config.Debug and DebugLabel then
            if CurrentTarget and CurrentTarget.Model and CurrentTarget.Humanoid then
                local _, myRoot, _ = getLocalCharacter()
                local dist = myRoot and (CurrentTarget.RootPart.Position - myRoot.Position).Magnitude or 0
                DebugLabel:Set(string.format(
                    "Target: %s | Dist: %.1f | HP: %d/%d",
                    CurrentTarget.Model.Name,
                    dist,
                    math.floor(CurrentTarget.Humanoid.Health),
                    math.floor(CurrentTarget.Humanoid.MaxHealth)
                ))
            else
                DebugLabel:Set("Target: Searching...")
            end
        end
    end
end)
