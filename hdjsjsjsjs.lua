--!strict
--[[
    AUTO LOCK TARGET + AUTO BASIC ATTACK (M1)
    Letakkan di: StarterPlayer -> StarterPlayerScripts (LocalScript)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local VirtualInputManager = game:GetService("VirtualInputManager")

local LocalPlayer = Players.LocalPlayer

-----------------------------------------------------------
-- KONFIGURASI
-----------------------------------------------------------
local Config = {
    Enabled = true,             -- Aktifkan sistem
    AutoAttack = true,          -- Otomatis pukul/M1
    AttackInterval = 0.25,      -- Jeda antar serangan M1 (detik)
    
    DetectionRadius = 60,       -- Jarak deteksi mob terdekat
    
    -- Posisi Karakter relatif terhadap Mob
    -- Vector3.new(0, 4, 0) = Melayang diam 4 stud di atas kepala mob (aman dari serangan melee)
    -- Vector3.new(0, 0, 3) = Diam 3 stud di depan mob
    OffsetFromTarget = Vector3.new(0, 4, 0),
    
    FaceTarget = true           -- Menghadap ke target
}

-----------------------------------------------------------
-- STATE
-----------------------------------------------------------
local CurrentTarget: Model? = nil
local CurrentTargetRoot: BasePart? = nil
local CurrentTargetHum: Humanoid? = nil

local AttackTimer = 0
local ScanTimer = 0

-----------------------------------------------------------
-- HELPER & DETEKSI MOB
-----------------------------------------------------------
local function getLocalCharacter(): (Model?, BasePart?, Humanoid?)
    local char = LocalPlayer.Character
    if not char then return nil, nil, nil end
    local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
    local hum = char:FindFirstChildOfClass("Humanoid") :: Humanoid?
    if root and hum and hum.Health > 0 then
        return char, root, hum
    end
    return nil, nil, nil
end

local function findNearestTarget(): Model?
    local _, myRoot, _ = getLocalCharacter()
    if not myRoot then return nil end

    local nearestModel: Model? = nil
    local shortestDist = Config.DetectionRadius

    -- Spatial query efisien dalam radius
    local overlap = OverlapParams.new()
    overlap.FilterType = Enum.RaycastFilterType.Exclude
    overlap.FilterDescendantsInstances = {LocalPlayer.Character}

    local parts = Workspace:GetPartBoundsInRadius(myRoot.Position, Config.DetectionRadius, overlap)
    local checkedModels: {[Model]: boolean} = {}

    for _, part in ipairs(parts) do
        local model = part:FindFirstAncestorOfClass("Model")
        if model and not checkedModels[model] and model ~= LocalPlayer.Character then
            checkedModels[model] = true
            
            -- Filter validitas target
            local hum = model:FindFirstChildOfClass("Humanoid")
            local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
            local isPlayer = Players:GetPlayerFromCharacter(model)

            if hum and root and hum.Health > 0 and not isPlayer then
                local dist = (root.Position - myRoot.Position).Magnitude
                if dist < shortestDist then
                    shortestDist = dist
                    nearestModel = model
                end
            end
        end
    end

    return nearestModel
end

-----------------------------------------------------------
-- MEKANIK BASIC ATTACK (M1)
-----------------------------------------------------------
local function executeBasicAttack()
    local char = LocalPlayer.Character
    if not char then return end

    -- Cara 1: Mengaktifkan Tool bawaan jika player sedang memegang senjata
    local tool = char:FindFirstChildOfClass("Tool")
    if tool then
        tool:Activate()
    end

    -- Cara 2: Menembakkan virtual klik kiri mouse (M1) ke layar
    -- Cocok untuk combat system modern yang mendeteksi mouse click
    local viewport = Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize or Vector2.new(500, 500)
    local screenCenter = viewport / 2

    VirtualInputManager:SendMouseButtonEvent(screenCenter.X, screenCenter.Y, 0, true, game, 0)
    task.delay(0.05, function()
        VirtualInputManager:SendMouseButtonEvent(screenCenter.X, screenCenter.Y, 0, false, game, 0)
    end)
end

-----------------------------------------------------------
-- MAIN LOOP
-----------------------------------------------------------
RunService.Heartbeat:Connect(function(dt: number)
    if not Config.Enabled then return end

    local myChar, myRoot, myHum = getLocalCharacter()
    if not myChar or not myRoot or not myHum then return end

    -- Scan target setiap 0.2 detik agar hemat resource
    ScanTimer += dt
    if ScanTimer >= 0.2 then
        ScanTimer = 0
        if not CurrentTarget or not CurrentTargetRoot or not CurrentTargetHum or CurrentTargetHum.Health <= 0 or not CurrentTarget.Parent then
            CurrentTarget = findNearestTarget()
            if CurrentTarget then
                CurrentTargetRoot = CurrentTarget:FindFirstChild("HumanoidRootPart") :: BasePart?
                CurrentTargetHum = CurrentTarget:FindFirstChildOfClass("Humanoid")
            else
                CurrentTargetRoot = nil
                CurrentTargetHum = nil
            end
        end
    end

    -- Eksekusi Lock Position & Auto Attack jika target valid
    if CurrentTargetRoot and CurrentTargetHum and CurrentTargetHum.Health > 0 then
        -- 1. Redam gaya jatuh/lemparan agar karakter tidak mental atau jitter
        myRoot.AssemblyLinearVelocity = Vector3.zero
        myRoot.AssemblyAngularVelocity = Vector3.zero

        -- 2. Tentukan posisi diam player relatif terhadap mob
        local desiredPos = CurrentTargetRoot.Position + Config.OffsetFromTarget
        
        if Config.FaceTarget then
            -- Kunci posisi dan buat karakter selalu menatap mob
            myRoot.CFrame = CFrame.lookAt(desiredPos, CurrentTargetRoot.Position)
        else
            myRoot.CFrame = CFrame.new(desiredPos)
        end

        -- 3. Auto M1 Attack Loop
        if Config.AutoAttack then
            AttackTimer += dt
            if AttackTimer >= Config.AttackInterval then
                AttackTimer = 0
                executeBasicAttack()
            end
        end
    end
end)
