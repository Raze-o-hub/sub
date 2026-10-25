repeat task.wait(0.1) until game:IsLoaded()

-- Teardown previous running instance
if _G.EverDunV2Cleanup and typeof(_G.EverDunV2Cleanup) == "function" then
    pcall(_G.EverDunV2Cleanup)
end
if _G.EverDunCleanup and typeof(_G.EverDunCleanup) == "function" then
    pcall(_G.EverDunCleanup)
end

-- ============================================================================
-- 1. SERVICES & REMOTES (NO M1 / ATTACK EVENTS)
-- ============================================================================
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local GuiService = game:GetService("GuiService")
local CoreGui = game:GetService("CoreGui")
local VirtualUser = game:GetService("VirtualUser")
local LocalPlayer = Players.LocalPlayer

local VIM_ok, VIM = pcall(function() return game:GetService("VirtualInputManager") end)
local VIM = VIM_ok and VIM or nil

local Net = ReplicatedStorage:WaitForChild("Net", 10)
local QueueFolder = Net and Net:WaitForChild("queue", 10)
local MatchFolder = Net and Net:WaitForChild("match", 10)
local PosRepot = QueueFolder and QueueFolder:WaitForChild("C2S_PosReport", 10)
local SelectDungeon = QueueFolder and QueueFolder:WaitForChild("C2S_SelectDungeon", 10)
local StartMatch = MatchFolder and MatchFolder:WaitForChild("C2S_StartMatch", 10)
local OpenRoomDoorEvent = MatchFolder and MatchFolder:WaitForChild("C2S_OpenRoomDoor", 10)
local UsePortalEvent = MatchFolder and MatchFolder:WaitForChild("C2S_UseDungeonPortal", 10)


-- ============================================================================
-- 2. DUNGEON CONFIGURATION & DATA
-- ============================================================================
local dungeon_list = {"dungeon.goblin_hideout", "dungeon.Witch_Ruin", "dungeon.Elf_Library"}
local dungeon_Name = {"Goblin Hideout", "Witch Ruin", "Elf_Library"}

local tweenHRP = nil
local cancelCurrentTween = nil

local function getDungeonData(name)
    for index, dunName in ipairs(dungeon_Name) do
        if dunName == name then
            return dungeon_list[index], dunName
        end
    end
    return dungeon_list[1], dungeon_Name[1]
end


-- ============================================================================
-- 4. FLUENT UI INITIALIZATION
-- ============================================================================
local Fluent = loadstring(game:HttpGet("https://github.com/dawid-scripts/Fluent/releases/latest/download/main.lua"))()
local SaveManager = loadstring(game:HttpGet("https://raw.githubusercontent.com/dawid-scripts/Fluent/master/Addons/SaveManager.lua"))()
local InterfaceManager = loadstring(game:HttpGet("https://raw.githubusercontent.com/dawid-scripts/Fluent/master/Addons/InterfaceManager.lua"))()

local Window = Fluent:CreateWindow({
    Title = "EverDun V2",
    SubTitle = "Everblue Dungeon (Input Sim)",
    TabWidth = 160,
    Size = UDim2.fromOffset(580, 480),
    Acrylic = false,
    Theme = "Dark",
    MinimizeKey = Enum.KeyCode.LeftControl
})

local Tabs = {
    Dungeon = Window:AddTab({ Title = "Dungeon", Icon = "swords" }),
    Combat = Window:AddTab({ Title = "Combat", Icon = "crosshair" }),
    Settings = Window:AddTab({ Title = "Settings", Icon = "settings" })
}

local Options = Fluent.Options

local function safeNotify(data)
    task.spawn(function()
        pcall(function()
            if Fluent and Fluent.Notify then
                Fluent:Notify(data)
            end
        end)
    end)
end

-- ============================================================================
-- 5. LOBBY QUEUE LOGIC
-- ============================================================================
local autoQueueThread = nil

local function enterDungeonOnce()
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then
        return false, "Character not ready"
    end

    local queueTables = workspace:FindFirstChild("QueueTables")
    if not queueTables then
        return false, "QueueTables not found"
    end

    for _, tableModel in ipairs(queueTables:GetChildren()) do
        local isFree = false
        pcall(function()
            local countLabel = tableModel.Display.BillboardGui.Content.CountLabel
            if countLabel.Text == "" then
                isFree = true
            end
        end)

        if isFree then
            local pivot = tableModel:GetPivot()
            local seatPosition = pivot.Position + Vector3.new(0, 3, 0)

            tweenHRP(CFrame.new(seatPosition))

            local delayTime = Options.ApproachDelay and Options.ApproachDelay.Value or 0.22
            task.wait(delayTime)

            local selectedName = Options.SelectedDungeon and Options.SelectedDungeon.Value or dungeon_Name[1]
            local targetDungeonId, targetDisplayName = getDungeonData(selectedName)
            local diff = Options.Difficulty and Options.Difficulty.Value or 1

            if PosRepot then
                PosRepot:FireServer(tableModel)
            end

            if SelectDungeon then
                SelectDungeon:FireServer(
                    tableModel,
                    targetDungeonId,
                    "Difficulty_" .. tostring(diff)
                )
            end

            task.wait(0.2)

            if StartMatch then
                StartMatch:FireServer()
            end

            return true, targetDisplayName
        end
    end

    return false, "No free table available"
end

local function stopAutoQueue()
    if autoQueueThread then
        task.cancel(autoQueueThread)
        autoQueueThread = nil
    end
end

local function startAutoQueue()
    if autoQueueThread then return end
    autoQueueThread = task.spawn(function()
        while Options.AutoQueue and Options.AutoQueue.Value and not Fluent.Unloaded do
            local success, detail = enterDungeonOnce()
            if success then
                safeNotify({
                    Title = "EverDun V2",
                    Content = "Entered " .. tostring(detail) .. "! Starting match...",
                    Duration = 3
                })
                task.wait(4)
            else
                task.wait(1)
            end
        end
        autoQueueThread = nil
    end)
end

-- ============================================================================
-- 6. COMBAT LOGIC (100% EVENT-FREE INPUT SIMULATION)
-- ============================================================================
local autoAttackThread = nil
local getCurrentDungeon = nil
local getEnemiesLeftCount = nil
local getLivingMonsters = nil

local repService = nil
local world = nil
local charComps = nil
local ENEMY = nil
local HEALTH = nil
local MODEL = nil

local function getLivingEnemyServerIds()
    if not repService or not world then
        pcall(function()
            local ps = LocalPlayer:FindFirstChild("PlayerScripts")
            local client = ps and ps:FindFirstChild("Client")
            local services = client and client:FindFirstChild("services")
            local resMod = services and services:FindFirstChild("replicated-entity-service")
            if resMod then
                repService = require(resMod).ReplicatedEntityService
            end
            world = require(ReplicatedStorage.Shared.world).world
            charComps = require(ReplicatedStorage.Shared.components["character-components"])
            ENEMY = charComps.ENEMY
            HEALTH = charComps.HEALTH
            MODEL = charComps.MODEL
        end)
    end

    local list = {}
    if not repService or not repService.serverMap or not world or not ENEMY then return list end

    for serverId, clientEntity in pairs(repService.serverMap) do
        if world:contains(clientEntity) and world:has(clientEntity, ENEMY) then
            local mdlComp = MODEL and world:get(clientEntity, MODEL)
            local mdl = mdlComp and (mdlComp.model or mdlComp)
            local hasModel = mdl and mdl.Parent and (mdl.PrimaryPart or mdl:FindFirstChild("HumanoidRootPart"))
            if hasModel then
                local hp = HEALTH and world:get(clientEntity, HEALTH)
                local isAlive = (not hp) or (type(hp) == "table" and hp.current and hp.current > 0) or (type(hp) == "number" and hp > 0)
                if isAlive then
                    table.insert(list, serverId)
                    if #list >= 10 then break end
                end
            end
        end
    end
    return list
end

local function hasLivingEnemies()
    local dungeon = getCurrentDungeon and getCurrentDungeon()
    if dungeon then
        local stage = dungeon:GetAttribute("CurrentStage")
        local isTransition = dungeon:GetAttribute("RoomTransitionActive") == true
        if stage == "safe" or stage == "portal" or isTransition then return false end
    end
    if getEnemiesLeftCount then
        local count = getEnemiesLeftCount()
        if count ~= nil and count <= 0 then return false end
    end
    local serverIds = getLivingEnemyServerIds()
    if #serverIds > 0 then return true end
    if getLivingMonsters and #getLivingMonsters() > 0 then return true end
    return false
end

-- Hardware / Input library mouse simulation (Zero RemoteEvents)
local function pressMouse1(duration)
    duration = duration or (Options.HoldDuration and Options.HoldDuration.Value) or 0.03
    local method = Options.InputMethod and Options.InputMethod.Value or "Auto (Hybrid)"

    local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(800, 600)
    local cx, cy = vp.X / 2, vp.Y / 2

    if method == "VirtualInputManager" or method == "Auto (Hybrid)" then
        if VIM then
            pcall(function()
                VIM:SendMouseButtonEvent(cx, cy, 0, true, game, 1)
                task.wait(duration)
                VIM:SendMouseButtonEvent(cx, cy, 0, false, game, 1)
            end)
            if method == "VirtualInputManager" then return end
        end
    end

    if method == "mouse1click (Executor)" or (method == "Auto (Hybrid)" and not VIM) then
        if mouse1click then
            pcall(mouse1click)
            if method == "mouse1click (Executor)" then return end
        elseif mouse1press and mouse1release then
            pcall(function()
                mouse1press()
                task.wait(duration)
                mouse1release()
            end)
            if method == "mouse1click (Executor)" then return end
        end
    end

    if method == "VirtualUser" or (method == "Auto (Hybrid)" and not VIM and not mouse1click) then
        pcall(function()
            VirtualUser:CaptureController()
            local camCF = workspace.CurrentCamera and workspace.CurrentCamera.CFrame or CFrame.new()
            VirtualUser:Button1Down(Vector2.zero, camCF)
            task.wait(duration)
            VirtualUser:Button1Up(Vector2.zero, camCF)
        end)
    end
end

local lastAttackTime = 0
local function performAttack(force)
    if not force and not hasLivingEnemies() then return end
    local now = os.clock()
    local minDelay = Options.AttackDelay and Options.AttackDelay.Value or 0.12
    if (now - lastAttackTime) < minDelay then return end
    lastAttackTime = now

    pressMouse1()
end

local function startAutoAttack()
    if autoAttackThread then return end
    autoAttackThread = task.spawn(function()
        while Options.AutoAttack and Options.AutoAttack.Value and not Fluent.Unloaded do
            if hasLivingEnemies() then
                performAttack()
            end
            local delayTime = Options.AttackDelay and Options.AttackDelay.Value or 0.12
            task.wait(delayTime)
        end
        autoAttackThread = nil
    end)
end

local function stopAutoAttack()
    if autoAttackThread then
        task.cancel(autoAttackThread)
        autoAttackThread = nil
    end
end

-- ============================================================================
-- 7. IN-DUNGEON FARM & AUTO OPEN DOOR
-- ============================================================================
local autoDunThread = nil

getCurrentDungeon = function()
    for _, child in ipairs(workspace:GetChildren()) do
        if child.Name:find("Dungeon") and child:FindFirstChild("RoomProgression") then
            return child
        end
    end
    return nil
end

getLivingMonsters = function()
    local list = {}
    local seen = {}
    local unsynced = workspace:FindFirstChild("Unsynced")
    if unsynced then
        for _, m in ipairs(unsynced:GetChildren()) do
            if m:IsA("Model") then
                local hrp = m:FindFirstChild("HumanoidRootPart") or m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart")
                local hum = m:FindFirstChildOfClass("Humanoid")
                local isAlive = (not hum) or (hum.Health > 0)
                if hrp and isAlive then
                    seen[m] = true
                    table.insert(list, { Model = m, Part = hrp })
                end
            end
        end
    end

    if repService and repService.serverMap and world and ENEMY and MODEL then
        for serverId, clientEntity in pairs(repService.serverMap) do
            if world:contains(clientEntity) and world:has(clientEntity, ENEMY) then
                local mdlComp = world:get(clientEntity, MODEL)
                local mdl = mdlComp and (mdlComp.model or mdlComp)
                if mdl and mdl.Parent and not seen[mdl] then
                    local hrp = mdl:FindFirstChild("HumanoidRootPart") or mdl.PrimaryPart or mdl:FindFirstChildWhichIsA("BasePart")
                    local hp = HEALTH and world:get(clientEntity, HEALTH)
                    local isAlive = (not hp) or (type(hp) == "table" and hp.current and hp.current > 0) or (type(hp) == "number" and hp > 0)
                    if hrp and isAlive then
                        seen[mdl] = true
                        table.insert(list, { Model = mdl, Part = hrp, ServerId = serverId })
                    end
                end
            end
        end
    end
    return list
end

local function getClosestMonster()
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return nil end

    local monsters = getLivingMonsters()
    local closest = nil
    local minDist = math.huge

    for _, data in ipairs(monsters) do
        local dist = (hrp.Position - data.Part.Position).Magnitude
        if dist < minDist then
            minDist = dist
            closest = data
        end
    end
    return closest
end

local function isDungeonMatch()
    local mid = LocalPlayer:GetAttribute("MatchId")
    if mid and tostring(mid) ~= "0" and tostring(mid) ~= "" then
        return true
    end
    return getCurrentDungeon() ~= nil
end

local function getWaveData()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local gh = pg and pg:FindFirstChild("GameplayHUD")
    local canvas = gh and gh:FindFirstChild("Canvas")
    local dh = canvas and canvas:FindFirstChild("DungeonHUD")
    local wd = dh and dh:FindFirstChild("WaveDisplay")
    local wave = wd and wd:FindFirstChild("Wave")

    if wd and wd.Visible and wave and wave.Visible then
        local curStr, totStr = wave.Text:match("(%d+)%s*/%s*(%d+)")
        if curStr and totStr then
            local cur = tonumber(curStr)
            local tot = tonumber(totStr)
            return cur, tot, wave.Text
        end
    end
    return nil, nil, nil
end

getEnemiesLeftCount = function()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local gh = pg and pg:FindFirstChild("GameplayHUD")
    local canvas = gh and gh:FindFirstChild("Canvas")
    local dh = canvas and canvas:FindFirstChild("DungeonHUD")
    local el = dh and dh:FindFirstChild("EnemiesLeft")

    if el and el.Visible and el.Text ~= "" then
        local countStr = el.Text:match("(%d+)")
        if countStr then
            return tonumber(countStr), el.Text
        end
    end
    return nil, nil
end

local function areEnemiesCleared()
    local dungeon = getCurrentDungeon()
    if dungeon and (dungeon:GetAttribute("RoomTransitionActive") == true or dungeon:GetAttribute("CurrentStage") == "safe") then
        return true
    end
    local count = getEnemiesLeftCount()
    if count ~= nil then
        return count <= 0
    end
    return not hasLivingEnemies()
end

local function isWavePending()
    return not areEnemiesCleared()
end

local function getNextRoomPosition(dungeon, gate)
    local rp = dungeon and dungeon:FindFirstChild("RoomProgression")
    if not rp or not gate then return nil end

    local toStage = gate:GetAttribute("ToStage")
    if toStage then
        local rooms = rp:FindFirstChild("Rooms")
        if rooms then
            for _, r in ipairs(rooms:GetChildren()) do
                local cleanName = r.Name:lower():gsub("[^%w]", "")
                local cleanStage = toStage:lower():gsub("[^%w]", "")
                if cleanName == cleanStage or r.Name:lower() == toStage:lower() then
                    local trig = r:FindFirstChild("EntryTrigger") or r:FindFirstChild("StageSpawn") or r.PrimaryPart or r:FindFirstChildWhichIsA("BasePart")
                    if trig then return trig.Position end
                end
            end
        end

        local keyed = rp:FindFirstChild("KeyedRoutes")
        if keyed then
            for _, route in ipairs(keyed:GetChildren()) do
                for _, st in ipairs(route:GetChildren()) do
                    local cleanName = st.Name:lower():gsub("[^%w]", "")
                    local cleanStage = toStage:lower():gsub("[^%w]", "")
                    local stageNum = cleanStage:match("(%d+)")
                    local nameNum = cleanName:match("(%d+)")
                    if cleanName == cleanStage or (stageNum and nameNum and stageNum == nameNum) then
                        local trig = st:FindFirstChild("EntryTrigger") or st:FindFirstChild("StageSpawn")
                        if trig then return trig.Position end
                    end
                end
            end
        end
    end
    return nil
end

local currentBV = nil
local currentBG = nil
local currentPlatform = nil

local function updatePlatform(targetCFrame)
    if not currentPlatform or not currentPlatform.Parent then
        if currentPlatform then pcall(function() currentPlatform:Destroy() end) end
        currentPlatform = Instance.new("Part")
        currentPlatform.Name = "EverDunPlatform"
        currentPlatform.Size = Vector3.new(6, 1, 6)
        currentPlatform.Transparency = 1
        currentPlatform.CanCollide = true
        currentPlatform.Anchored = true
        currentPlatform.Material = Enum.Material.Cobblestone
        currentPlatform.Parent = workspace
    end
    currentPlatform.CFrame = targetCFrame - Vector3.new(0, 3.5, 0)
end

local function removePlatform()
    if currentPlatform then
        pcall(function() currentPlatform:Destroy() end)
        currentPlatform = nil
    end
    local old = workspace:FindFirstChild("EverDunPlatform")
    if old then pcall(function() old:Destroy() end) end
end

local floorSpoofHooked = false
local oldIndexHook = nil

local function enableFloorSpoof()
    if floorSpoofHooked or not hookmetamethod or not newcclosure then return end
    floorSpoofHooked = true
    oldIndexHook = hookmetamethod(game, "__index", newcclosure(function(self, key)
        if not checkcaller() and key == "FloorMaterial" and typeof(self) == "Instance" and self:IsA("Humanoid") then
            local char = LocalPlayer.Character
            if char and self:IsDescendantOf(char) and Options.AlwaysGround and Options.AlwaysGround.Value then
                return Enum.Material.Cobblestone
            end
        end
        return oldIndexHook(self, key)
    end))
end

local function updateBGBV(hrp, targetCFrame)
    if not hrp or not hrp.Parent then return end

    if not currentBV or currentBV.Parent ~= hrp then
        if currentBV then pcall(function() currentBV:Destroy() end) end
        currentBV = Instance.new("BodyVelocity")
        currentBV.Name = "EverDunBV"
        currentBV.MaxForce = Vector3.new(1e9, 1e9, 1e9)
        currentBV.Velocity = Vector3.zero
        currentBV.Parent = hrp
    else
        currentBV.Velocity = Vector3.zero
    end

    if not currentBG or currentBG.Parent ~= hrp then
        if currentBG then pcall(function() currentBG:Destroy() end) end
        currentBG = Instance.new("BodyGyro")
        currentBG.Name = "EverDunBG"
        currentBG.MaxTorque = Vector3.new(1e9, 1e9, 1e9)
        currentBG.P = 10000
        currentBG.D = 100
        currentBG.CFrame = targetCFrame
        currentBG.Parent = hrp
    else
        currentBG.CFrame = targetCFrame
    end
end

local function removeBGBV()
    if currentBV then
        pcall(function() currentBV:Destroy() end)
        currentBV = nil
    end
    if currentBG then
        pcall(function() currentBG:Destroy() end)
        currentBG = nil
    end
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if hrp then
        local oldBV = hrp:FindFirstChild("EverDunBV")
        if oldBV then oldBV:Destroy() end
        local oldBG = hrp:FindFirstChild("EverDunBG")
        if oldBG then oldBG:Destroy() end
    end
end

local currentTween = nil

cancelCurrentTween = function()
    if currentTween then
        pcall(function() currentTween:Cancel() end)
        currentTween = nil
    end
end

tweenHRP = function(targetCFrame, speed)
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return false end

    speed = speed or (Options.TweenSpeed and Options.TweenSpeed.Value) or 60
    local dist = (hrp.Position - targetCFrame.Position).Magnitude
    if dist < 0.5 then
        hrp.CFrame = targetCFrame
        return true
    end

    local time = math.max(dist / speed, 0.05)
    local tweenInfo = TweenInfo.new(time, Enum.EasingStyle.Linear)

    cancelCurrentTween()

    if currentPlatform and currentPlatform.Parent then
        currentPlatform.CFrame = targetCFrame - Vector3.new(0, 3.5, 0)
    end
    if currentBG and currentBG.Parent then
        currentBG.CFrame = targetCFrame
    end

    local tween = TweenService:Create(hrp, tweenInfo, { CFrame = targetCFrame })
    currentTween = tween
    tween:Play()
    tween.Completed:Wait()
    if currentTween == tween then
        currentTween = nil
    end

    if Options.UsePlatform and Options.UsePlatform.Value then
        updatePlatform(targetCFrame)
    end
    if Options.UseBGBV and Options.UseBGBV.Value then
        updateBGBV(hrp, targetCFrame)
    end
    return true
end

local waveStartedAfterDoor = true

local function tryOpenDoors()
    local dungeon = getCurrentDungeon()
    if not dungeon then return false end

    local currentStage = dungeon:GetAttribute("CurrentStage") or "safe"
    local inSafeZone = (currentStage == "safe")
    local roomTransitionActive = (dungeon:GetAttribute("RoomTransitionActive") == true)

    if not inSafeZone and not roomTransitionActive then
        if not waveStartedAfterDoor then
            return false, "Waiting for wave to spawn"
        end
        if isWavePending() then
            return false, "Wave in progress"
        end
    end
    local gates = dungeon.RoomProgression:FindFirstChild("Gates")
    if not gates then return false end

    local matchId = LocalPlayer:GetAttribute("MatchId") or 1
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return false end

    local curRoomNum = tonumber(type(currentStage) == "string" and currentStage:match("^room(%d+)$") or "")
    local targetGate, targetPrompt = nil, nil
    local candidates = {}

    for _, gate in ipairs(gates:GetChildren()) do
        local isOpen = (gate:GetAttribute("Open") == true or gate:GetAttribute("open") == true)
        if isOpen ~= true then
            local prompt = gate:FindFirstChildWhichIsA("ProximityPrompt", true)
            if prompt and OpenRoomDoorEvent then
                local from = gate:GetAttribute("FromStage")
                local to = gate:GetAttribute("ToStage")
                local isArmed = (gate:GetAttribute("Armed") == true)
                local dist = (gate:GetPivot().Position - hrp.Position).Magnitude

                local isKeyed = (prompt:GetAttribute("KeyItemId") ~= nil) or (gate:GetAttribute("KeyItemId") ~= nil) or (prompt:GetAttribute("ManualDungeonPortal") == true) or (type(to) == "string" and to:match("^branch"))
                if not isKeyed then
                    local isNext = (currentStage == "safe" and to == "room1") or (curRoomNum and (to == "room" .. (curRoomNum + 1) or to == "portal"))
                    if (from == currentStage or (not from and inSafeZone)) and isNext then
                        if isArmed and prompt.Enabled then
                            targetGate = gate
                            targetPrompt = prompt
                            break
                        end
                        table.insert(candidates, { gate = gate, prompt = prompt, dist = dist, from = from, to = to, isArmed = isArmed })
                    end
                end
            end
        end
    end

    if not targetGate and #candidates > 0 then
        for _, c in ipairs(candidates) do
            if c.isArmed then
                targetGate = c.gate
                targetPrompt = c.prompt
                break
            end
        end
        if not targetGate then
            table.sort(candidates, function(a, b) return a.dist < b.dist end)
            targetGate = candidates[1].gate
            targetPrompt = candidates[1].prompt
        end
    end

    if not targetGate or not targetPrompt then return false end
    local gate = targetGate
    local prompt = targetPrompt
    local gatePivot = gate:GetPivot()

    local promptPos = prompt.Parent:IsA("Attachment") and prompt.Parent.WorldPosition or prompt.Parent.Position
    tweenHRP(CFrame.new(promptPos + Vector3.new(0, 2, 0), gatePivot.Position))
    task.wait(0.12)

    OpenRoomDoorEvent:FireServer(prompt, matchId, true)
    local opened = true
    waveStartedAfterDoor = false
    task.wait(0.2)

    -- Determine precise forward direction into room (prefer official GateArrival)
    local gateArrival = gate:FindFirstChild("GateArrival")
    local forwardDir = nil
    if gateArrival and gateArrival:IsA("BasePart") then
        forwardDir = (gateArrival.Position - gatePivot.Position).Unit
    else
        local nextPos = getNextRoomPosition(dungeon, gate)
        if nextPos then
            forwardDir = (nextPos - gatePivot.Position).Unit
        else
            local away = (gatePivot.Position - promptPos).Unit
            forwardDir = Vector3.new(away.X, 0, away.Z).Unit
        end
    end
    forwardDir = Vector3.new(forwardDir.X, 0, forwardDir.Z).Unit

    local distStuds = Options.DoorStandDist and Options.DoorStandDist.Value or 50
    local standPos = gatePivot.Position + (forwardDir * distStuds) + Vector3.new(0, 3, 0)
    local standCFrame = CFrame.new(standPos, standPos + forwardDir)
    tweenHRP(standCFrame)

    if Options.UsePlatform and Options.UsePlatform.Value then
        updatePlatform(standCFrame)
    end
    if Options.UseBGBV and Options.UseBGBV.Value then
        updateBGBV(hrp, standCFrame)
    end

    -- Wait for mobs to spawn
    local waitLimit = Options.SpawnWaitTime and Options.SpawnWaitTime.Value or 2.5
    local waited = 0
    while waited < waitLimit and areEnemiesCleared() and #getLivingMonsters() == 0 do
        task.wait(0.25)
        waited = waited + 0.25
    end

    return opened
end

local function advanceToNextRoom()
    local dungeon = getCurrentDungeon()
    if not dungeon then return end
    local rp = dungeon:FindFirstChild("RoomProgression")
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not rp or not hrp then return end

    local candidates = {}
    for _, desc in ipairs(rp:GetDescendants()) do
        if desc.Name == "EntryTrigger" and desc:IsA("BasePart") then
            local dist = (hrp.Position - desc.Position).Magnitude
            if dist > 15 and dist < 300 then
                table.insert(candidates, { trigger = desc, dist = dist })
            end
        end
    end
    table.sort(candidates, function(a, b) return a.dist < b.dist end)
    if #candidates > 0 then
        tweenHRP(candidates[1].trigger.CFrame + Vector3.new(0, 3, 0))
        task.wait(0.3)
    end
end

local function findPortal()
    local dungeon = getCurrentDungeon()
    if not dungeon then return nil, nil end

    local function isValidPortalPrompt(desc)
        if desc:IsA("ProximityPrompt") and desc.Enabled then
            local isPortal = (desc:GetAttribute("DungeonPortal") == true) or (desc.Name == "DungeonPortalPrompt")
            local isNotKeyed = (desc:GetAttribute("KeyItemId") == nil)
            local isNotDoor = (desc:GetAttribute("RoomDoor") ~= true)
            if isPortal and isNotKeyed and isNotDoor then
                local model = desc:FindFirstAncestorOfClass("Model") or desc.Parent
                return model, desc
            end
        end
        return nil, nil
    end

    local rp = dungeon:FindFirstChild("RoomProgression")
    if rp then
        local portalArea = rp:FindFirstChild("PortalArea")
        if portalArea then
            for _, desc in ipairs(portalArea:GetDescendants()) do
                local m, p = isValidPortalPrompt(desc)
                if m and p then return m, p end
            end
        end
        for _, desc in ipairs(rp:GetDescendants()) do
            local m, p = isValidPortalPrompt(desc)
            if m and p then return m, p end
        end
    end

    for _, desc in ipairs(dungeon:GetDescendants()) do
        local m, p = isValidPortalPrompt(desc)
        if m and p then return m, p end
    end

    return nil, nil
end

local isUsingPortal = false
local lastPortalAttemptAt = 0

local function tryUsePortal(force)
    if not force and isUsingPortal then return false end
    if not force and (os.clock() - lastPortalAttemptAt < 2.5) then return false end

    local portal, prompt = findPortal()
    if not portal or not prompt then return false end

    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return false end

    isUsingPortal = true
    lastPortalAttemptAt = os.clock()

    local pPos = prompt.Parent:IsA("Attachment") and prompt.Parent.WorldPosition or prompt.Parent:IsA("BasePart") and prompt.Parent.Position or portal:GetPivot().Position
    local dist = (hrp.Position - pPos).Magnitude
    if dist > 6 then
        tweenHRP(CFrame.new(pPos + Vector3.new(0, 1, 0), pPos))
        task.wait(0.2)
    end

    local holdDuration = (prompt.HoldDuration and prompt.HoldDuration > 0) and prompt.HoldDuration or 0.5
    local waitTime = holdDuration + 0.15

    if fireproximityprompt then
        pcall(fireproximityprompt, prompt)
    end

    pcall(function() prompt:InputHoldBegin() end)
    if VIM then
        pcall(function() VIM:SendKeyEvent(true, Enum.KeyCode.E, false, game) end)
    end
    if keypress then
        pcall(keypress, 0x45)
    end

    task.wait(waitTime)

    if keyrelease then
        pcall(keyrelease, 0x45)
    end
    if VIM then
        pcall(function() VIM:SendKeyEvent(false, Enum.KeyCode.E, false, game) end)
    end
    pcall(function() prompt:InputHoldEnd() end)

    local netMatch = (Net and Net:FindFirstChild("match")) or (ReplicatedStorage:FindFirstChild("Net") and ReplicatedStorage.Net:FindFirstChild("match"))
    local usePortalEvent = netMatch and netMatch:FindFirstChild("C2S_UseDungeonPortal")
    if usePortalEvent then
        local matchStateMod = ReplicatedStorage.Shared.services:FindFirstChild("match-state")
        local matchState = matchStateMod and require(matchStateMod).MatchState
        local sessionId = (matchState and matchState:getSessionId(LocalPlayer)) or LocalPlayer:GetAttribute("MatchId") or 1
        local token = prompt:GetAttribute("DungeonPortalReadyToken")
        pcall(function() usePortalEvent:FireServer(prompt, sessionId, token) end)
        pcall(function() usePortalEvent:FireServer(prompt, sessionId) end)
        pcall(function() usePortalEvent:FireServer() end)
    end
    isUsingPortal = false
    return true
end

local function getEligibleChests()
    local dungeon = getCurrentDungeon()
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    local candidates = {}
    local seen = {}

    local currentStage = (dungeon and dungeon:GetAttribute("CurrentStage")) or ""
    local curRoomNum = tonumber(type(currentStage) == "string" and currentStage:match("^room(%d+)$") or "")
    local curWave, totWave = getWaveData()
    local isEndStage = (currentStage == "portal") or (curWave and totWave and curWave >= totWave)

    local function checkChest(desc)
        if seen[desc] then return end
        if desc:IsA("Model") and (desc.Name == "TreasureChest" or desc:GetAttribute("ChestId") ~= nil) then
            seen[desc] = true
            local isKeyed = (desc:GetAttribute("KeyedBranchChest") == true) or (desc:GetAttribute("ChestType") == "goblin_keyed")
            if isKeyed then return end

            local interaction = desc:GetAttribute("LocalChestInteraction")
            local isClosing = (desc:GetAttribute("VictoryChestClosing") == true or desc:GetAttribute("DungeonChestClosing") == true)
            if interaction ~= "opened" and interaction ~= "rejected" and not isClosing then
                local prompt = desc:FindFirstChildWhichIsA("ProximityPrompt", true)
                if prompt and prompt.Enabled then
                    local isVictory = (desc:GetAttribute("VictorySession") ~= nil)
                    local roomIdx = desc:GetAttribute("RoomIndex")
                    local dist = hrp and (desc:GetPivot().Position - hrp.Position).Magnitude or 0
                    local isMatchRoom = isVictory or isEndStage or (curRoomNum and roomIdx == curRoomNum) or (not roomIdx and dist < 60)
                    if isMatchRoom then
                        table.insert(candidates, { chest = desc, prompt = prompt, dist = dist, isVictory = isVictory, isMatchRoom = isMatchRoom })
                    end
                end
            end
        end
    end

    if dungeon then
        local tcFolder = dungeon:FindFirstChild("TreasureChests")
        if tcFolder then
            for _, desc in ipairs(tcFolder:GetDescendants()) do checkChest(desc) end
        end
        for _, desc in ipairs(dungeon:GetChildren()) do
            if desc.Name == "TreasureChest" then checkChest(desc) end
        end
        local rp = dungeon:FindFirstChild("RoomProgression")
        if rp then
            for _, desc in ipairs(rp:GetDescendants()) do
                if desc.Name == "TreasureChest" then checkChest(desc) end
            end
        end
    end

    for _, child in ipairs(workspace:GetChildren()) do
        if child.Name == "TreasureChest" then checkChest(child) end
    end

    table.sort(candidates, function(a, b)
        if a.isVictory ~= b.isVictory then
            return a.isVictory == true
        end
        if a.isMatchRoom ~= b.isMatchRoom then
            return a.isMatchRoom == true
        end
        return a.dist < b.dist
    end)
    return candidates
end

local function tryOpenChests()
    local candidates = getEligibleChests()
    if #candidates == 0 then return false end

    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return false end

    local openedAny = false
    for _, target in ipairs(candidates) do
        local chest = target.chest
        local prompt = target.prompt
        if chest and chest:GetAttribute("LocalChestInteraction") ~= "opened" then
            local chestPos = chest:GetPivot().Position
            local targetPos = prompt and (prompt.Parent:IsA("Attachment") and prompt.Parent.WorldPosition or prompt.Parent.Position) or chestPos
            tweenHRP(CFrame.new(targetPos + Vector3.new(0, 2, 0), chestPos))
            task.wait(0.2)

            if prompt and prompt.Enabled then
                if fireproximityprompt then
                    pcall(fireproximityprompt, prompt)
                else
                    local origHold = prompt.HoldDuration
                    prompt.HoldDuration = 0
                    prompt:InputHoldBegin()
                    prompt:InputHoldEnd()
                    prompt.HoldDuration = origHold
                end
            end

            local chestId = chest:GetAttribute("ChestId")
            if chestId and Net and Net:FindFirstChild("treasure") and Net.treasure:FindFirstChild("REQ_OpenChest") then
                pcall(function() Net.treasure.REQ_OpenChest:InvokeServer(chestId, chestPos) end)
            elseif chestId and ReplicatedStorage:FindFirstChild("Net") and ReplicatedStorage.Net:FindFirstChild("treasure") and ReplicatedStorage.Net.treasure:FindFirstChild("REQ_OpenChest") then
                pcall(function() ReplicatedStorage.Net.treasure.REQ_OpenChest:InvokeServer(chestId, chestPos) end)
            end
            pcall(function() chest:SetAttribute("LocalChestInteraction", "opened") end)
            openedAny = true
            task.wait(0.3)
        end
    end
    return openedAny
end

local isAutoRetrying = false
local function tryAutoRetry()
    if not (Options.AutoRetry and Options.AutoRetry.Value) then return false end
    if isAutoRetrying then return false end

    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local es = pg and pg:FindFirstChild("EndScreen")
    if not es or not es.Enabled then return false end

    local canvas = es:FindFirstChild("Canvas")
    if not canvas or not canvas.Visible then return false end

    local victory = canvas:FindFirstChild("Victory")
    local fail = canvas:FindFirstChild("Fail")
    local activeContainer = (victory and victory.Visible and victory) or (fail and fail.Visible and fail)
    local cont = activeContainer and activeContainer:FindFirstChild("Continue")

    local replayBtn = es:FindFirstChild("Replay", true)
    local retryBtn = es:FindFirstChild("Retry", true)
    local targetBtn = (replayBtn and replayBtn.Visible and replayBtn) or (retryBtn and retryBtn.Visible and retryBtn) or (cont and cont:FindFirstChild("Replay")) or (cont and cont:FindFirstChild("Retry")) or replayBtn or retryBtn

    if targetBtn then
        isAutoRetrying = true
        task.spawn(function()
            task.wait(1.2)
            if targetBtn and es.Enabled then
                if firesignal then
                    pcall(firesignal, targetBtn.Activated)
                    pcall(firesignal, targetBtn.MouseButton1Click)
                end

                local netMatch = (Net and Net:FindFirstChild("match")) or (ReplicatedStorage:FindFirstChild("Net") and ReplicatedStorage.Net:FindFirstChild("match"))
                local endAction = netMatch and netMatch:FindFirstChild("C2S_EndScreenAction")
                if endAction then
                    local matchStateMod = ReplicatedStorage.Shared.services:FindFirstChild("match-state")
                    local matchState = matchStateMod and require(matchStateMod).MatchState
                    local sessionId = (matchState and matchState:getSessionId(LocalPlayer)) or LocalPlayer:GetAttribute("MatchId") or 1
                    pcall(function() endAction:FireServer("retry", sessionId) end)
                end
            end
            task.wait(3.0)
            isAutoRetrying = false
        end)
        return true
    end
    return false
end

local function setupAutoRetryListener()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local es = pg and pg:FindFirstChild("EndScreen")
    if not es then return end

    es:GetPropertyChangedSignal("Enabled"):Connect(function()
        if es.Enabled and Options.AutoRetry and Options.AutoRetry.Value then
            tryAutoRetry()
        end
    end)
end

local function startAutoDun()
    if autoDunThread then return end
    autoDunThread = task.spawn(function()
        while Options.AutoDun and Options.AutoDun.Value and not Fluent.Unloaded do
            local char = LocalPlayer.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")

            if hrp then
                local monsters = getLivingMonsters()
                if #monsters > 0 or not areEnemiesCleared() then
                    waveStartedAfterDoor = true
                end

                if #monsters > 0 then
                    -- Attack nearest monster with configured offset
                    local targetData = getClosestMonster()
                    if targetData and targetData.Part then
                        local targetPos = targetData.Part.Position
                        local offsetY = Options.OffsetY and Options.OffsetY.Value or 7
                        local offsetDist = Options.OffsetDist and Options.OffsetDist.Value or 0

                        local targetCFrame = CFrame.new(targetPos + Vector3.new(0, offsetY, offsetDist), targetPos)
                        local distToTarget = (hrp.Position - targetCFrame.Position).Magnitude
                        if distToTarget > 2 then
                            tweenHRP(targetCFrame)
                        else
                            hrp.CFrame = targetCFrame
                        end

                        if Options.UsePlatform and Options.UsePlatform.Value then
                            updatePlatform(targetCFrame)
                        else
                            removePlatform()
                        end

                        if Options.UseBGBV and Options.UseBGBV.Value then
                            updateBGBV(hrp, targetCFrame)
                        else
                            removeBGBV()
                        end

                        -- Trigger attack if enabled
                        if Options.AutoAttack and Options.AutoAttack.Value then
                            performAttack()
                        end
                    end
                else
                    local dungeon = getCurrentDungeon()
                    local roomTransitionActive = (dungeon and dungeon:GetAttribute("RoomTransitionActive") == true)
                    local currentStage = (dungeon and dungeon:GetAttribute("CurrentStage")) or "safe"
                    local inSafeZone = (currentStage == "safe")
                    local wavePending = not areEnemiesCleared() and not roomTransitionActive

                    if not waveStartedAfterDoor and not inSafeZone and not roomTransitionActive then
                        task.wait(0.3)
                    elseif wavePending then
                        task.wait(0.3)
                    else
                        removeBGBV()
                        removePlatform()

                        -- Open room and victory chests if available before moving to next area
                        local chestsPending = false
                        if Options.AutoChest and Options.AutoChest.Value then
                            local eligibleChests = getEligibleChests()
                            if #eligibleChests > 0 then
                                chestsPending = true
                                tryOpenChests()
                            end
                        end

                        if chestsPending then
                            task.wait(0.3)
                        else
                            local doorOpened = false
                            if Options.AutoOpenDoor and Options.AutoOpenDoor.Value then
                                doorOpened = tryOpenDoors()
                            end

                            if not doorOpened then
                                local autoPortalEnabled = (not Options.AutoPortal) or Options.AutoPortal.Value
                                local curWave, totWave = getWaveData()
                                local isPortalWave = (currentStage == "portal") or (curWave == 3) or (curWave == 6) or (curWave and totWave and curWave >= totWave)

                                if autoPortalEnabled and isPortalWave then
                                    local portal, prompt = findPortal()
                                    if portal and prompt and prompt.Enabled then
                                        local curWaveBefore = getWaveData()
                                        local stageBefore = (dungeon and dungeon:GetAttribute("CurrentStage")) or ""
                                        local maxRetries = 10
                                        local retryCount = 0

                                        repeat
                                            tryUsePortal(true)
                                            retryCount = retryCount + 1
                                            task.wait(0.5)

                                            local curW = getWaveData()
                                            local nowStage = (dungeon and dungeon:GetAttribute("CurrentStage")) or ""
                                            local transitioned = (curW and curWaveBefore and curW > curWaveBefore) or (nowStage ~= "" and nowStage ~= stageBefore and nowStage ~= "portal")
                                            local p, pr = findPortal()
                                            local portalGone = (not p) or (not pr) or (not pr.Enabled)
                                        until (not AutoDunRunning) or transitioned or portalGone or (retryCount >= maxRetries)
                                    end
                                end
                            end
                        end
                    end
                end
                tryAutoRetry()
            else
                removeBGBV()
                removePlatform()
                tryAutoRetry()
            end
            task.wait(0.08)
        end
        removeBGBV()
        removePlatform()
        autoDunThread = nil
    end)
end

local function stopAutoDun()
    cancelCurrentTween()
    if autoDunThread then
        task.cancel(autoDunThread)
        autoDunThread = nil
    end
    removeBGBV()
    removePlatform()
end

-- ============================================================================
-- 8. PROTECTION LOGIC (ANTI-AFK & AUTO RECONNECT)
-- ============================================================================
local reconnectConns = {}
local afkConn = nil
local reconnecting = false

local function reconnectServer()
    if reconnecting then return end
    reconnecting = true

    Fluent:Notify({
        Title = "EverDun V2",
        Content = "Reconnecting to server...",
        Duration = 5
    })

    pcall(function()
        local queueFn = (syn and syn.queue_on_teleport) or queue_on_teleport
        if queueFn then
            queueFn('loadfile("EverDunV2.lua")()')
        end
    end)

    task.wait(1.5)
    local ok = pcall(function()
        if #Players:GetPlayers() <= 1 then
            TeleportService:Teleport(game.PlaceId, LocalPlayer)
        else
            TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
        end
    end)

    if not ok then
        pcall(function()
            TeleportService:Teleport(game.PlaceId, LocalPlayer)
        end)
    end
end

local function setupAutoReconnect()
    pcall(function()
        local conn = GuiService.ErrorMessageChanged:Connect(function(errorMessage)
            if errorMessage and #errorMessage > 0 and Options.AutoReconnect and Options.AutoReconnect.Value then
                reconnectServer()
            end
        end)
        table.insert(reconnectConns, conn)

        local initialErr = GuiService:GetErrorMessage()
        if initialErr and #initialErr > 0 and Options.AutoReconnect and Options.AutoReconnect.Value then
            task.spawn(reconnectServer)
        end
    end)

    task.spawn(function()
        local promptGui = pcall(function() return CoreGui:FindFirstChild("RobloxPromptGui") end) and CoreGui:FindFirstChild("RobloxPromptGui")
        if not promptGui then
            pcall(function() promptGui = CoreGui:WaitForChild("RobloxPromptGui", 5) end)
        end
        if promptGui then
            local promptOverlay = promptGui:FindFirstChild("promptOverlay") or promptGui:WaitForChild("promptOverlay", 5)
            if promptOverlay then
                if promptOverlay:FindFirstChild("ErrorPrompt") and Options.AutoReconnect and Options.AutoReconnect.Value then
                    task.spawn(reconnectServer)
                end
                local conn = promptOverlay.ChildAdded:Connect(function(child)
                    if (child.Name == "ErrorPrompt" or child.Name:find("Prompt") or child.Name:find("Error")) and Options.AutoReconnect and Options.AutoReconnect.Value then
                        task.wait(0.5)
                        reconnectServer()
                    end
                end)
                table.insert(reconnectConns, conn)
            end
        end
    end)

    pcall(function()
        local conn = TeleportService.TeleportInitFailed:Connect(function(player)
            if player == LocalPlayer and Options.AutoReconnect and Options.AutoReconnect.Value then
                task.wait(2)
                pcall(function() TeleportService:Teleport(game.PlaceId, LocalPlayer) end)
            end
        end)
        table.insert(reconnectConns, conn)
    end)
end

local function enableAntiAfk()
    if afkConn then return end
    afkConn = LocalPlayer.Idled:Connect(function()
        if Options.AntiAfk and Options.AntiAfk.Value then
            pcall(function()
                VirtualUser:CaptureController()
                VirtualUser:ClickButton2(Vector2.zero)
            end)
        end
    end)
end

local function disableAntiAfk()
    if afkConn then
        afkConn:Disconnect()
        afkConn = nil
    end
end

-- ============================================================================
-- 9. UI CONTROLS
-- ============================================================================
do
    -- [TAB 1: DUNGEON]
    Tabs.Dungeon:AddParagraph({
        Title = "Dungeon Auto Farm",
        Content = "Full Auto Clear, Door Opener & Queue Starter"
    })

    local AutoDunToggle = Tabs.Dungeon:AddToggle("AutoDun", {
        Title = "Auto Dungeon (Clear & Farm)",
        Default = false
    })

    AutoDunToggle:OnChanged(function()
        if Options.AutoDun.Value then
            startAutoDun()
        else
            stopAutoDun()
        end
    end)

    local BGBVToggle = Tabs.Dungeon:AddToggle("UseBGBV", {
        Title = "Use BG & BV (Freeze Physics / Anti-Fall)",
        Description = "Applies BodyGyro and BodyVelocity to float stably in the air without falling",
        Default = true
    })

    BGBVToggle:OnChanged(function()
        if not Options.UseBGBV.Value then
            removeBGBV()
        end
    end)

    local PlatToggle = Tabs.Dungeon:AddToggle("UsePlatform", {
        Title = "Invisible Floor Platform",
        Description = "Creates an invisible solid floor beneath your feet so you can stand and attack in mid-air",
        Default = true
    })

    PlatToggle:OnChanged(function()
        if not Options.UsePlatform.Value then
            removePlatform()
        end
    end)

    local GroundToggle = Tabs.Dungeon:AddToggle("AlwaysGround", {
        Title = "Always On Ground (Anti-Air Check)",
        Description = "Spoofs FloorMaterial so the game allows M1 attacks while mid-air",
        Default = true
    })

    local DoorToggle = Tabs.Dungeon:AddToggle("AutoOpenDoor", {
        Title = "Auto Open Door",
        Default = true
    })

    local ChestToggle = Tabs.Dungeon:AddToggle("AutoChest", {
        Title = "Auto Collect Chests (Room & Victory)",
        Description = "Automatically collects chests in cleared rooms and the final Victory chest before exiting",
        Default = true
    })

    local PortalToggle = Tabs.Dungeon:AddToggle("AutoPortal", {
        Title = "Auto Use Portal (Wave 3+)",
        Description = "Automatically uses C2S_UseDungeonPortal when portal appears in Wave 3",
        Default = true
    })

    local RetryToggle = Tabs.Dungeon:AddToggle("AutoRetry", {
        Title = "Auto Retry Dungeon",
        Description = "Automatically votes/clicks Retry on the End Screen after dungeon clear or defeat",
        Default = true
    })

    local WaveToggle = Tabs.Dungeon:AddToggle("CheckWave", {
        Title = "Check Enemies Left Before Door",
        Description = "Waits until '0 Enemies Left' in DungeonHUD before opening the next door",
        Default = true
    })

    local OffsetYSlider = Tabs.Dungeon:AddSlider("OffsetY", {
        Title = "Height Offset (Y)",
        Description = "Height above monsters to stay safe from attacks",
        Default = 7,
        Min = 0,
        Max = 25,
        Rounding = 1
    })

    local OffsetDistSlider = Tabs.Dungeon:AddSlider("OffsetDist", {
        Title = "Distance Offset (Z)",
        Description = "Horizontal distance from monsters",
        Default = 0,
        Min = -15,
        Max = 15,
        Rounding = 1
    })

    local DoorStandSlider = Tabs.Dungeon:AddSlider("DoorStandDist", {
        Title = "Door Stand Distance",
        Description = "Distance past door into the room to trigger monster spawn (studs)",
        Default = 50,
        Min = 10,
        Max = 100,
        Rounding = 1
    })

    local TweenSpeedSlider = Tabs.Dungeon:AddSlider("TweenSpeed", {
        Title = "Tween Speed",
        Description = "Movement speed when tweening between positions (studs/sec)",
        Default = 60,
        Min = 20,
        Max = 150,
        Rounding = 0
    })

    local SpawnWaitSlider = Tabs.Dungeon:AddSlider("SpawnWaitTime", {
        Title = "Spawn Wait Time",
        Description = "Seconds to wait in front of door for monsters to spawn",
        Default = 2.5,
        Min = 1,
        Max = 6,
        Rounding = 1
    })

    Tabs.Dungeon:AddButton({
        Title = "Open Doors (Once)",
        Description = "Manually search and open all nearby closed doors",
        Callback = function()
            if Options.CheckWave and Options.CheckWave.Value and isWavePending() then
                local _, _, waveText = getWaveData()
                safeNotify({
                    Title = "EverDun V2",
                    Content = string.format("Cannot open door: Wave in progress (%s)", waveText or "Active"),
                    Duration = 3
                })
                return
            end
            local res = tryOpenDoors()
            safeNotify({
                Title = "EverDun V2",
                Content = res and "Opened door successfully!" or "No closed door found or door not ready.",
                Duration = 3
            })
        end
    })

    Tabs.Dungeon:AddButton({
        Title = "Collect Chests (Once)",
        Description = "Manually teleports and opens available treasure chests in the area",
        Callback = function()
            local res = tryOpenChests()
            safeNotify({
                Title = "EverDun V2",
                Content = res and "Opened treasure chest!" or "No ready treasure chests found.",
                Duration = 3
            })
        end
    })

    Tabs.Dungeon:AddButton({
        Title = "Use Portal (Once)",
        Description = "Manually teleports to portal and fires C2S_UseDungeonPortal",
        Callback = function()
            local res = tryUsePortal(true)
            safeNotify({
                Title = "EverDun V2",
                Content = res and "Fired C2S_UseDungeonPortal!" or "Portal event not available.",
                Duration = 3
            })
        end
    })

    -- LOBBY QUEUE SECTION
    Tabs.Dungeon:AddParagraph({
        Title = "Lobby Queue",
        Content = "Auto Join Dungeon Match From Hub"
    })

    local DungeonDropdown = Tabs.Dungeon:AddDropdown("SelectedDungeon", {
        Title = "Select Dungeon",
        Values = dungeon_Name,
        Default = 1,
        Multi = false
    })

    local DiffSlider = Tabs.Dungeon:AddSlider("Difficulty", {
        Title = "Difficulty / Tier",
        Description = "Set dungeon difficulty level",
        Default = 1,
        Min = 1,
        Max = 10,
        Rounding = 0
    })

    local DelaySlider = Tabs.Dungeon:AddSlider("ApproachDelay", {
        Title = "Teleport Delay",
        Description = "Wait time after teleport before sending enter event (seconds)",
        Default = 0.22,
        Min = 0.05,
        Max = 1,
        Rounding = 2
    })

    local AutoQueueToggle = Tabs.Dungeon:AddToggle("AutoQueue", {
        Title = "Auto Enter Dungeon (Queue)",
        Default = false
    })

    AutoQueueToggle:OnChanged(function()
        if Options.AutoQueue.Value then
            startAutoQueue()
        else
            stopAutoQueue()
        end
    end)

    Tabs.Dungeon:AddButton({
        Title = "Enter Dungeon (Once)",
        Description = "Find an available table and enter immediately",
        Callback = function()
            local success, msg = enterDungeonOnce()
            Fluent:Notify({
                Title = "EverDun V2",
                Content = success and ("Success: Entered " .. tostring(msg)) or ("Failed: " .. tostring(msg)),
                Duration = 4
            })
        end
    })

    -- [TAB 2: COMBAT]
    Tabs.Combat:AddParagraph({
        Title = "Combat Automation (Input Sim)",
        Content = "100% Event-Free M1 Attack via Hardware/Input Libraries"
    })

    local AutoAttackToggle = Tabs.Combat:AddToggle("AutoAttack", {
        Title = "Auto Attack (M1)",
        Description = "Simulates authentic Mouse1 clicks (No remote events used)",
        Default = false
    })

    AutoAttackToggle:OnChanged(function()
        if Options.AutoAttack.Value then
            startAutoAttack()
        else
            stopAutoAttack()
        end
    end)

    local InputMethodDropdown = Tabs.Combat:AddDropdown("InputMethod", {
        Title = "Input Simulation Method",
        Description = "Select key/mouse library to simulate M1 clicks",
        Values = {"Auto (Hybrid)", "VirtualInputManager", "VirtualUser", "mouse1click (Executor)"},
        Default = 1,
        Multi = false
    })

    local AttackDelaySlider = Tabs.Combat:AddSlider("AttackDelay", {
        Title = "Attack Delay",
        Description = "Delay between consecutive clicks (seconds)",
        Default = 0.12,
        Min = 0.05,
        Max = 0.5,
        Rounding = 2
    })

    local HoldDurationSlider = Tabs.Combat:AddSlider("HoldDuration", {
        Title = "Click Hold Duration",
        Description = "Duration to hold Mouse1 button down per click (seconds)",
        Default = 0.03,
        Min = 0.01,
        Max = 0.10,
        Rounding = 3
    })



    -- [TAB 3: SETTINGS - PROTECTION CONTROLS]
    Tabs.Settings:AddParagraph({
        Title = "Safety & Protection",
        Content = "Anti-AFK idle disconnect bypass and auto-rejoin"
    })

    local AntiAfkToggle = Tabs.Settings:AddToggle("AntiAfk", {
        Title = "Anti AFK",
        Description = "Prevents Roblox 20-minute idle disconnect",
        Default = true
    })

    AntiAfkToggle:OnChanged(function()
        if Options.AntiAfk and Options.AntiAfk.Value then
            enableAntiAfk()
        else
            disableAntiAfk()
        end
    end)

    local AutoReconnectToggle = Tabs.Settings:AddToggle("AutoReconnect", {
        Title = "Auto Reconnect",
        Description = "Automatically rejoins server if kicked or disconnected",
        Default = true
    })

    Tabs.Settings:AddButton({
        Title = "Reconnect Now",
        Description = "Manually rejoin current game server",
        Callback = function()
            reconnectServer()
        end
    })
end

-- ============================================================================
-- 10. SETTINGS & MANAGERS
-- ============================================================================
SaveManager:SetLibrary(Fluent)
InterfaceManager:SetLibrary(Fluent)

SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({})

InterfaceManager:SetFolder("EverDunV2")
SaveManager:SetFolder("EverDunV2/EverblueDungeon")

InterfaceManager:BuildInterfaceSection(Tabs.Settings)
SaveManager:BuildConfigSection(Tabs.Settings)

Window:SelectTab(1)

Fluent:Notify({
    Title = "EverDun V2",
    Content = "Everblue Dungeon V2 (No-Event M1) loaded successfully!",
    Duration = 5
})

SaveManager:LoadAutoloadConfig()
enableFloorSpoof()
enableAntiAfk()
setupAutoReconnect()
setupAutoRetryListener()

-- Teardown handler
_G.EverDunV2Cleanup = function()
    if cancelCurrentTween then pcall(cancelCurrentTween) end
    stopAutoDun()
    removeBGBV()
    removePlatform()
    stopAutoQueue()
    stopAutoAttack()
    disableAntiAfk()
    for _, c in ipairs(reconnectConns) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(reconnectConns)
    if Window and Window.Destroy then
        pcall(function() Window:Destroy() end)
    end
end
