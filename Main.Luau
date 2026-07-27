repeat
	task.wait()
until game:IsLoaded() and game.PlaceId ~= 0

local executor = "Unknown"
if type(identifyexecutor) == "function" then
	local ok, name = pcall(identifyexecutor)
	if ok and name then
		executor = tostring(name)
	end
end

local env
if type(getgenv) == "function" then
	env = getgenv()
elseif executor:lower():find("xeno", 1, true) then
	env = shared or _G
else
	error("Auto Gatlin requires getgenv (executor: " .. executor .. ")")
end

local prev = env.AutoGatlin

if prev and type(prev.Stop) == "function" then
	pcall(prev.Stop, prev)
end

local repoRoot = env.AutoStratRepo or "https://raw.githubusercontent.com/tessa-says-hi/auto-strat/main/"
local function loadRepo(path)
	local source = type(env.AutoStratSources) == "table" and env.AutoStratSources[path]
	if not source then
		source = game:HttpGet(repoRoot .. path, true)
	end
	local chunk, err = loadstring(source)
	if not chunk then
		error(string.format("Could not load %s: %s", path, tostring(err)), 0)
	end
	return chunk()
end

local Recorder = loadRepo("src/Recorder.Luau")

local function clone(value)
	if type(cloneref) == "function" then
		local ok, ref = pcall(cloneref, value)
		if ok and ref then
			return ref
		end
	end
	return value
end

local function weakKeys()
	return setmetatable({}, { __mode = "k" })
end

local Players = clone(game:GetService("Players"))
local ReplicatedStorage = clone(game:GetService("ReplicatedStorage"))
local RunService = clone(game:GetService("RunService"))
local UserService = clone(game:GetService("UserService"))
local Workspace = clone(game:GetService("Workspace"))
local Draw = Drawing

while not Players.LocalPlayer do
	Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
end

local lp = clone(Players.LocalPlayer)
local towerLib = require(
	ReplicatedStorage:WaitForChild("Client")
		:WaitForChild("Modules")
		:WaitForChild("Replicators")
		:WaitForChild("TowerReplicator")
)
local npcLib = require(ReplicatedStorage.Client.Modules.Replicators:WaitForChild("NPCReplicator"))
local enums = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("Enum"))
local gameState = require(ReplicatedStorage.Shared.Modules:WaitForChild("GameState"))
local gatlinSkins =
	ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Troops"):WaitForChild("Gatling Gun"):WaitForChild("Skins")
local npcs
if debug and type(debug.getupvalue) == "function" then
	npcs = debug.getupvalue(npcLib.GetNPCFromModel, 1)
end

local npcScan = {}
local npcScanAt = -math.huge
local function getNpcs()
	if npcs then
		return npcs
	end

	local now = os.clock()
	if now - npcScanAt < 0.01 then
		return npcScan
	end
	npcScanAt = now
	table.clear(npcScan)

	local folder = Workspace:FindFirstChild("NPCs")
	if not folder then
		return npcScan
	end

	for _, model in ipairs(folder:GetChildren()) do
		local npc = npcLib.GetNPCFromModel(model)
		if npc then
			npcScan[model] = npc
		end
	end

	return npcScan
end

local ability
local aimRemote
local fireRemote
local reloadRemote
local stopRemote
local hitRemote
local hitDrain
local hitSeq = 0
local bulletDrains = {}
local bulletSeq = 0
local drawnHitSeq = 0
local netCheckAt = 0

local AutoGatlin = {
	Running = false,
	Enabled = false,
	Status = "Stopped",
	AutoStacker = false,
	StackAmount = 15,
	StackStatus = "Ready to make tower sandwiches :3",
	ShowUpgradeRanges = false,
	AlwaysShowDjRanges = false,
	UpgradeRangeStatus = "Select a tower to preview every upgrade range :3",
	TowerManagerStatus = "Click an owned tower to manage it :3",
	AutoCommanderChain = false,
	CommanderChainIndex = 1,
	CommanderChainSeq = 0,
	CommanderChainStatus = "Waiting for level 2+ Commanders :3",

	NoCooldown = true,
	AutoReload = true,
	AutoCalibrate = true,
	CrowdControl = true,
	TargetLeads = true,
	PrioritizeBosses = false,
	BypassBossForFast = false,
	Priority = "First",
	ExitThreshold = 0.65,
	MaxBurst = 3,
	MaxTargets = 8,
	ReplayBurst = 100,
	ReplayDelay = 0,
	MissLimit = 4,
	RetryDelay = 0.75,

	AnonymousGatlin = false,
	RainbowGatlin = false,
	CustomGatlin = false,
	GatlinColor = Color3.fromRGB(80, 170, 255),
	ForcefieldGatlin = false,
	RainbowSpeed = 50,
	MuteBarrelSpin = false,
	ShowBulletLines = false,
	ZombieESP = false,
	RainbowESP = false,
	ESPOutlineTransparency = 20,
	CrosshairTransparency = 0,
	ESPStyle = "CSGO",

	HitSoundVolume = 15,
	HitSoundId = "",

	HideUsername = true,
	ProtectedName = "",
	RemoveAccessories = false,
	MorphEnabled = true,
	MorphInput = "1",
	MorphUserId = 1,
	MorphLoadedId = 0,
	MorphVersion = 0,
	MorphName = "",
	MorphDisplayName = "",
	MorphVerified = false,
	MorphPlus = false,
	MorphStatus = "Enter a player ID, username, or server display name.",
	GatlinMorphTemplate = nil,

	FireBurst = 1,
	Tower = nil,
	TowerCount = 0,
	ActiveCount = 0,
	Target = nil,
	TargetInfo = nil,
	ManualTargetName = "",
	MissedRounds = 0,
	TargetQuota = 1,
	Wave = gameState.Wave,
	RoundTimerElapsed = 0,
	RoundTimerRunning = false,
	RoundTimerLastWave = tonumber(gameState.Wave) or 0,
	UIReady = false,
	UILoading = false,
	UIError = nil,
}

local recorder = Recorder.new()
AutoGatlin.Recorder = recorder

local current
local firing = false
local lastAim = 0
local lastFireSync
local aimedNpc
local relockUntil = 0
local fireHoldUntil = 0
local blocked = weakKeys()
local towerRetry = weakKeys()
local aimPhase = weakKeys()
local hitboxOffsets = weakKeys()
local validated = weakKeys()
local resting = weakKeys()
local shotHistory = weakKeys()
local shotReserve = weakKeys()
local turnDone = false
local turnHits = 0
local turnShots = 0
local reloadedWave = -1
local hitWatch = {
	npc = nil,
	hp = 0,
	missed = 0,
	lastHit = 0,
	ack = 0,
	bullet = 0,
	confirmed = false,
	awaiting = false,
	missAt = 0,
	probeAt = 0,
}

local Luna
local statusBox
local protectionStatus
local drawConn
local runSeq = 0
local uiSeq = 0

local esp = {}
local espHighlights = {}
local tracers = {}
local gatlinHidden = weakKeys()
local gatlinColors = weakKeys()
local gatlinMaterials = weakKeys()
local gatlinTextures = weakKeys()
local barrelSounds = weakKeys()
local crosshairBg = weakKeys()
local crosshairStroke = weakKeys()

local nameConns = {}
local nameTracked = weakKeys()
local textSaved = weakKeys()
local textAlignSaved = weakKeys()
local textBusy = weakKeys()
local thumbTracked = weakKeys()
local thumbSaved = weakKeys()
local thumbBusy = weakKeys()
local humSaved = weakKeys()

local accessoryConns = {}
local accessoryParts = weakKeys()
local morphSaved = {}
local morphConn
local morphSeq = 0

local nativeHitSound
local nativeHitId
local nativeHitVolume

local privateNames = { tostring(lp.Name) }
if lp.DisplayName:lower() ~= lp.Name:lower() then
	privateNames[#privateNames + 1] = tostring(lp.DisplayName)
end
table.sort(privateNames, function(a, b)
	return #a > #b
end)

local function getNativeHitSound()
	if nativeHitSound or not (debug and type(debug.getupvalue) == "function") then
		return nativeHitSound
	end

	local content = ReplicatedStorage:FindFirstChild("Content")
	local towers = content and content:FindFirstChild("Tower")
	local gatlin = towers and towers:FindFirstChild("Gatling Gun")
	local module = gatlin and gatlin:FindFirstChild("Animator")
	if not module then
		return
	end

	local ok, animator = pcall(require, module)
	if not ok or type(animator) ~= "table" or type(animator.Initialize) ~= "function" then
		return
	end

	for i = 1, 32 do
		local first, second = debug.getupvalue(animator.Initialize, i)
		if first == nil then
			break
		end
		local value = second ~= nil and second or first
		if typeof(value) == "Instance" and value:IsA("Sound") then
			nativeHitSound = value
			nativeHitId = value.SoundId
			nativeHitVolume = value.Volume
			break
		end
	end

	return nativeHitSound
end

local function syncHitSound()
	local sound = getNativeHitSound()
	if not sound then
		return
	end

	local id = tostring(AutoGatlin.HitSoundId):match("%d+")
	sound.SoundId = id and "rbxassetid://" .. id or nativeHitId
	sound.Volume = AutoGatlin.HitSoundVolume / 100
end

local function restoreHitSound()
	if not nativeHitSound then
		return
	end

	nativeHitSound.SoundId = nativeHitId
	nativeHitSound.Volume = nativeHitVolume
	nativeHitSound = nil
	nativeHitId = nil
	nativeHitVolume = nil
end

local function bindNet()
	local now = os.clock()
	if
		now < netCheckAt
		and ability
		and ability.Parent
		and aimRemote
		and aimRemote.Parent
		and fireRemote
		and fireRemote.Parent
		and reloadRemote
		and reloadRemote.Parent
		and stopRemote
		and stopRemote.Parent
		and (not hitRemote or hitRemote.Parent and hitDrain and hitDrain.Connected)
	then
		return true
	end

	local network = ReplicatedStorage:FindFirstChild("Network")
	local net = network and network:FindFirstChild("GatlingGun")
	if not net then
		return false
	end

	local nextAbility = ReplicatedStorage:FindFirstChild("RemoteFunction")
	local nextAim = net:FindFirstChild("URE:ReplicateAimPosition")
	local nextFire = net:FindFirstChild("RE:Fire")
	local nextReload = net:FindFirstChild("RE:Reload")
	local nextStop = net:FindFirstChild("RE:StopFiring")
	if not (nextAbility and nextAim and nextFire and nextReload and nextStop) then
		return false
	end

	ability = nextAbility
	aimRemote = nextAim
	fireRemote = nextFire
	reloadRemote = nextReload
	stopRemote = nextStop

	local nextHit = net:FindFirstChild("RE:Hit")
	if nextHit ~= hitRemote or nextHit and (not hitDrain or not hitDrain.Connected) then
		if hitDrain then
			hitDrain:Disconnect()
		end

		hitRemote = nextHit
		hitDrain = hitRemote and hitRemote.OnClientEvent:Connect(function()
			hitSeq = hitSeq + 1
		end)
	end

	for _, name in ipairs({ "RE:BulletHit", "URE:BulletHit" }) do
		local remote = net:FindFirstChild(name)
		if remote and not bulletDrains[remote] then
			bulletDrains[remote] = remote.OnClientEvent:Connect(function()
				bulletSeq = bulletSeq + 1
			end)
		end
	end

	for remote, drain in pairs(bulletDrains) do
		if not remote.Parent then
			drain:Disconnect()
			bulletDrains[remote] = nil
		end
	end

	netCheckAt = now + 0.5
	return true
end

local function unbindNet()
	if hitDrain then
		hitDrain:Disconnect()
		hitDrain = nil
	end

	for remote, drain in pairs(bulletDrains) do
		drain:Disconnect()
		bulletDrains[remote] = nil
	end

	ability = nil
	aimRemote = nil
	fireRemote = nil
	reloadRemote = nil
	stopRemote = nil
	hitRemote = nil
	netCheckAt = 0
end

local function addTower(list, seen, tower)
	if tower and not seen[tower] and tower.TowerName == "Gatling Gun" and tower:IsAlive() then
		seen[tower] = true
		list[#list + 1] = tower
	end
end

local function getTowers()
	local list = {}
	local seen = {}
	local folder = Workspace:FindFirstChild("Towers")
	if not folder then
		AutoGatlin.TowerCount = 0
		return list
	end

	for _, model in folder:GetChildren() do
		local tower = towerLib.getTowerByModel(model)

		if tower and tower.OwnerId == lp.UserId then
			addTower(list, seen, tower)

			local copies = tower.Replicator:Get("ClonedTowers")
			if type(copies) == "table" then
				for _, copy in pairs(copies) do
					addTower(list, seen, towerLib.getTowerByModel(copy))
				end
			end
		end
	end

	AutoGatlin.TowerCount = #list
	return list
end

local function hasLead(npc)
	local folder = npc.Replicator and npc.Replicator.Folder
	local states = folder and folder:FindFirstChild("StatusEffects")
	return states and states:GetAttribute("Lead") ~= nil or false
end

local function isBoss(npc)
	local modifiers = npc.Modifiers
	return modifiers and modifiers:Has(enums.Modifier.Boss) or false
end

local function hasLeadDetection(tower)
	local states = tower.StatusEffects
	return states and states:has(enums.StatusEffect.LeadDetection) or false
end

local function canHit(tower, npc)
	local modifiers = npc.Modifiers
	local states = tower.StatusEffects
	if
		modifiers
		and (modifiers:Has("Tank") or modifiers:Has("God") or modifiers:Has("Invincible") or modifiers:Has("Ignore"))
	then
		return false
	end
	if modifiers and modifiers:Has(enums.Modifier.Hidden) and not states:has(enums.StatusEffect.HiddenDetection) then
		return false
	end
	if modifiers and modifiers:Has(enums.Modifier.Flying) and not states:has(enums.StatusEffect.FlyingDetection) then
		return false
	end
	if not hasLead(npc) then
		return true
	end

	if not AutoGatlin.TargetLeads then
		return false
	end

	return hasLeadDetection(tower)
end

local function ramp(value, low, high)
	local x = math.clamp((value - low) / (high - low), 0, 1)
	return x * x * (3 - 2 * x)
end

local function median(values)
	table.sort(values)
	local count = #values
	local mid = math.floor(count / 2)

	if count % 2 == 0 then
		return (values[mid] + values[mid + 1]) / 2
	end

	return values[mid + 1]
end

local function getExitData(npc)
	local path = npc.Path
	if
		not path
		or npc.ShouldLoop
		or npc.ForcePosition
		or (npc.IntroPath and not npc.IntroDone)
		or path.PathDistance <= 0
	then
		return 0, math.huge, 0, false, 0
	end

	local total = path.PathDistance
	local distance = math.clamp(npc.PathDistance or 0, 0, total)
	local progress = npc.Reverse and 1 - distance / total or distance / total
	local left = total * (1 - progress)
	local speed = math.abs(((not npc.Stopped and npc.Speed) or 0) + (npc.ForceSpeed or 0))
	local eta = speed > 0.05 and left / speed or math.huge
	local timeRisk = eta < math.huge and 1 - ramp(eta, 7, 24) or 0
	local risk = math.max(ramp(progress, 0.55, 0.9), timeRisk)

	return progress, eta, risk, true, speed
end

local function scanTargets(tower)
	local origin = tower.Position
	local list = {}
	local totalHealth = 0
	local totalMaxHealth = 0
	local maxHealth = 0
	local maxCurrentHealth = 0
	local minProgress = math.huge
	local maxProgress = -math.huge
	local now = os.clock()
	local misses = blocked[tower]

	for model, npc in pairs(getNpcs()) do
		local retry = misses and misses[npc]
		if retry and retry <= now then
			misses[npc] = nil
			retry = nil
		end

		if not retry and model.Parent and npc.Type ~= "Units" and npc:IsAlive() and canHit(tower, npc) then
			local hitbox = npc.Hitbox or npc.PrimaryPart

			if hitbox then
				local pos = hitbox.Position
				local dist = (pos - origin).Magnitude
				local health = npc.Health
				local maxHp = math.max(npc.MaxHealth, 1)
				local progress = npc.PathDistance or 0
				local exitProgress, eta, exitRisk, hasPath, speed = getExitData(npc)
				local budget = math.max(tower.Ammo, 0) * math.max(tower.Damage, 0)
				local entry = {
					npc = npc,
					pos = pos,
					dist = dist,
					health = health,
					maxHealth = maxHp,
					budget = budget,
					budgetFit = math.clamp(budget / math.max(health, 1), 0, 1),
					progress = progress,
					exitProgress = exitProgress,
					eta = eta,
					exitRisk = exitRisk,
					hasPath = hasPath,
					speed = speed,
					isBoss = isBoss(npc),
					radius = math.max((hitbox.Size.X + hitbox.Size.Z) * 0.25, 0.5),
					cluster = 1,
					clusterHealth = 1,
				}

				list[#list + 1] = entry
				totalHealth = totalHealth + health
				totalMaxHealth = totalMaxHealth + maxHp
				maxHealth = math.max(maxHealth, maxHp)
				maxCurrentHealth = math.max(maxCurrentHealth, health)
				minProgress = math.min(minProgress, progress)
				maxProgress = math.max(maxProgress, progress)
			end
		end
	end

	if #list == 0 then
		return list
	end

	local healths = {}
	local maxHealths = {}
	local speeds = {}
	local nearest = {}
	local sizes = {}

	for i, entry in ipairs(list) do
		healths[i] = entry.health
		maxHealths[i] = entry.maxHealth
		speeds[i] = entry.speed
		sizes[i] = entry.radius

		local closest = math.huge
		for j, other in ipairs(list) do
			if i ~= j then
				local gap = math.max((entry.pos - other.pos).Magnitude - entry.radius - other.radius, 0)
				closest = math.min(closest, gap)
			end
		end

		if closest < math.huge then
			nearest[#nearest + 1] = closest
		end
	end

	local medianHealth = math.max(median(healths), 1)
	local medianMaxHealth = math.max(median(maxHealths), 1)
	local medianSpeed = math.max(median(speeds), 0.01)
	local crowdScale = math.max(#nearest > 0 and median(nearest) or 0, median(sizes) * 2, 1)
	local totalLoad = 0

	for _, entry in ipairs(list) do
		entry.load = math.clamp(math.sqrt(entry.health / medianHealth), 0.25, 3)
		entry.clusterHealth = entry.load
		entry.fastThreat = entry.speed >= math.max(medianSpeed * 1.5, 4)
		totalLoad = totalLoad + entry.load
	end

	local maxCluster = 1
	local maxClusterHealth = 1
	for i = 1, #list do
		local a = list[i]

		for j = i + 1, #list do
			local b = list[j]
			local gap = math.max((a.pos - b.pos).Magnitude - a.radius - b.radius, 0)
			local weight = math.exp(-0.5 * (gap / crowdScale) ^ 2)
			a.cluster = a.cluster + weight
			b.cluster = b.cluster + weight
			a.clusterHealth = a.clusterHealth + b.load * weight
			b.clusterHealth = b.clusterHealth + a.load * weight
		end

		maxCluster = math.max(maxCluster, a.cluster)
		maxClusterHealth = math.max(maxClusterHealth, a.clusterHealth)
	end

	local avgMaxHealth = totalMaxHealth / #list
	local variance = 0
	for _, entry in ipairs(list) do
		variance = variance + (entry.maxHealth - avgMaxHealth) ^ 2
	end

	local deviation = math.sqrt(variance / #list)
	local maxDeviation = 0
	for _, entry in ipairs(list) do
		entry.deviation = deviation > 0 and math.max((entry.maxHealth - avgMaxHealth) / deviation, 0) or 0
		maxDeviation = math.max(maxDeviation, entry.deviation)
	end

	return list,
		{
			count = #list,
			totalHealth = totalHealth,
			totalLoad = totalLoad,
			maxHealth = maxHealth,
			maxCurrentHealth = maxCurrentHealth,
			medianHealth = medianHealth,
			medianMaxHealth = medianMaxHealth,
			medianSpeed = medianSpeed,
			avgMaxHealth = avgMaxHealth,
			maxDeviation = maxDeviation,
			minProgress = minProgress,
			maxProgress = maxProgress,
			maxCluster = maxCluster,
			maxClusterHealth = maxClusterHealth,
		}
end

local function getScore(entry, stats)
	if not AutoGatlin.AutoCalibrate then
		entry.emergency = false
		local mode = AutoGatlin.Priority
		local path = entry.hasPath and entry.exitProgress or entry.progress
		if mode == "Last" then
			return -path * 1000 - entry.dist
		elseif mode == "Strongest" or mode == "Highest Health" then
			return entry.health * 1000 + entry.maxHealth
		elseif mode == "Weakest" or mode == "Lowest Health" then
			return -entry.health + path / 100000
		elseif
			mode == "Max Efficiency ;3"
			or mode == "Max Efficiency"
			or mode == "Max Pierce"
			or mode == "Crowd Control"
		then
			return entry.clusterHealth * 1e6 + entry.cluster * 1000 + entry.progress
		elseif mode == "Zoom Zoom" or mode == "Speed" then
			return entry.speed * 1e6 + path * 1000 - entry.dist
		end

		return path * 1000 - entry.dist
	end

	local pathSpan = stats.maxProgress - stats.minProgress
	local relativePath = pathSpan > 0 and (entry.progress - stats.minProgress) / pathSpan or 0
	local path = entry.hasPath and entry.exitProgress or relativePath
	local maxHealth = math.log(1 + entry.maxHealth / stats.medianMaxHealth)
		/ math.max(math.log(1 + stats.maxHealth / stats.medianMaxHealth), 0.001)
	local currentHealth = math.log(1 + entry.health / stats.medianHealth)
		/ math.max(math.log(1 + stats.maxCurrentHealth / stats.medianHealth), 0.001)
	local healthShare = entry.load / math.max(stats.totalLoad, 1)
	local outlier = stats.maxDeviation > 0 and entry.deviation / stats.maxDeviation or maxHealth
	local cluster = entry.cluster / math.max(stats.maxCluster, 1)
	local clusterHealth = entry.clusterHealth / math.max(stats.maxClusterHealth, 1)
	local cleanup = 1 - entry.health / entry.maxHealth
	local pressure = math.clamp((stats.count - 1) / 9, 0, 1)
	local spread = math.clamp((stats.maxHealth - stats.avgMaxHealth) / math.max(stats.maxHealth, 1), 0, 1)
	local clear = 1 / (1 + entry.health / (stats.medianHealth * 2))
	local healthPart = (
		maxHealth * (1.6 + spread * 1.2)
		+ currentHealth * 1.4
		+ healthShare * (1 + spread)
		+ outlier * (0.8 + spread * 1.4)
	)
		* (0.1 + math.sqrt(entry.budgetFit) * 0.9)
		* (1 - pressure * 0.45)
	local pathPart = path ^ 2 * (1.4 + pressure * 1.4)
	local crowdPart = AutoGatlin.CrowdControl and (cluster * 1.2 + clusterHealth) * (1.5 + pressure * 5) or 0
	local clearPart = AutoGatlin.CrowdControl and pressure * clear * (1 + cluster * 3) or 0
	local basePressure = 1 - math.clamp((gameState.Health or 0) / math.max(gameState.MaxHealth or 1, 1), 0, 1)
	local emergencyThreshold = math.max(AutoGatlin.ExitThreshold - basePressure * 0.2, 0.35)

	entry.healthPart = healthPart
	entry.pathPart = pathPart
	entry.crowdPart = crowdPart
	entry.clearPart = clearPart
	entry.emergency = entry.exitRisk >= emergencyThreshold
	entry.emergencyScore = 1000
		+ entry.exitRisk * 100
		+ path * 10
		+ entry.budgetFit * 20
		+ (1 - currentHealth) * 2
		+ crowdPart * 0.25
	return healthPart + pathPart + crowdPart + clearPart + cleanup * 0.3
end

local function getReason(entry)
	local reason = AutoGatlin.Priority
	if AutoGatlin.AutoCalibrate then
		if entry.emergency then
			reason = "Exit emergency"
		elseif AutoGatlin.PrioritizeBosses and entry.isBoss then
			reason = "Boss priority"
		elseif AutoGatlin.PrioritizeBosses and AutoGatlin.BypassBossForFast and entry.fastThreat then
			reason = "Fast threat"
		elseif
			AutoGatlin.CrowdControl
			and entry.crowdPart + entry.clearPart >= math.max(entry.healthPart, entry.pathPart)
		then
			reason = "Crowd control"
		elseif entry.healthPart >= entry.pathPart then
			reason = "High health"
		else
			reason = "Path danger"
		end
	end

	return reason
end

local function betterGroup(group, best)
	if not best then
		return true
	end

	if group.emergency ~= best.emergency then
		return group.emergency
	end

	if group.emergency then
		if group.saveable ~= best.saveable then
			return group.saveable
		end

		local risk = group.entry.exitRisk - best.entry.exitRisk
		if math.abs(risk) > 0.08 then
			return risk > 0
		end
	end

	if group.resting ~= best.resting then
		return not group.resting
	end

	if AutoGatlin.PrioritizeBosses and not group.emergency then
		if AutoGatlin.BypassBossForFast then
			local fast = group.entry.fastThreat and not group.entry.isBoss
			local bestFast = best.entry.fastThreat and not best.entry.isBoss
			if fast ~= bestFast then
				return fast
			end
		end

		if group.entry.isBoss ~= best.entry.isBoss then
			return group.entry.isBoss
		end
	end

	if group.emergency and group.emergencyScore ~= best.emergencyScore then
		return group.emergencyScore > best.emergencyScore
	end

	if group.coverage ~= best.coverage then
		return group.coverage > best.coverage
	end

	return group.pick > best.pick
end

local function finishGroup(group, count)
	local entry = group.entry
	entry.score = group.score
	entry.pickScore = group.pick
	entry.reason = getReason(entry)
	entry.coverage = group.coverage
	entry.budgetFit = group.budgetFit
	entry.saveable = group.saveable
	entry.towers = group.towers
	entry.candidates = count
	return entry
end

local function selectGroup(towers, keepNpc, forcedNpc, beaconsOnly)
	local groups = {}
	local now = os.clock()

	for _, tower in ipairs(towers) do
		local retry = towerRetry[tower]
		if retry and retry <= now then
			towerRetry[tower] = nil
			retry = nil
		end

		if not retry then
			local list, stats = scanTargets(tower)
			for i = #list, 1, -1 do
				local npc = list[i].npc
				if forcedNpc and npc ~= forcedNpc or beaconsOnly and npc.Name ~= "Ice Beacon" then
					table.remove(list, i)
				end
			end

			for _, entry in ipairs(list) do
				local score = getScore(entry, stats)
				local pick = entry.emergency and entry.emergencyScore or score
				local group = groups[entry.npc]

				if not group then
					group = {
						entry = entry,
						entryPick = pick,
						towers = {},
						coverage = 0,
						budget = 0,
						score = 0,
						pick = 0,
						emergency = false,
						emergencyScore = -math.huge,
					}
					groups[entry.npc] = group
				elseif pick > group.entryPick then
					group.entry = entry
					group.entryPick = pick
				end

				group.towers[#group.towers + 1] = tower
				group.coverage = group.coverage + 1
				group.budget = group.budget + entry.budget
				group.score = group.score + score
				group.pick = group.pick + pick
				group.emergency = group.emergency or entry.emergency
				group.emergencyScore = math.max(group.emergencyScore, entry.emergencyScore or -math.huge)
			end
		end
	end

	local best
	local count = 0
	local ranked = {}
	for _, group in pairs(groups) do
		group.score = group.score / group.coverage
		group.pick = group.pick / group.coverage
		group.budgetFit = math.clamp(group.budget / math.max(group.entry.health, 1), 0, 1)
		group.saveable = group.budgetFit >= 0.75
		group.resting = (resting[group.entry.npc] or 0) > now
		count = count + 1
		ranked[#ranked + 1] = group

		if betterGroup(group, best) then
			best = group
		end
	end

	if not best then
		return
	end

	local held = keepNpc and groups[keepNpc]
	if held then
		local urgent = best.emergency
			and (
				not held.emergency
				or best.saveable and not held.saveable
				or best.entry.exitRisk > held.entry.exitRisk + 0.08
			)
		local bossSwitch = AutoGatlin.PrioritizeBosses and best.entry.isBoss and not held.entry.isBoss
		local fastSwitch = AutoGatlin.PrioritizeBosses
			and AutoGatlin.BypassBossForFast
			and best.entry.fastThreat
			and not best.entry.isBoss
			and (held.entry.isBoss or not held.entry.fastThreat)
		if not (urgent or bossSwitch or fastSwitch) then
			best = held
		end
	end

	table.sort(ranked, function(a, b)
		return betterGroup(a, b)
	end)

	local entry = finishGroup(best, count)
	if forcedNpc then
		entry.reason = "Clicked target"
	elseif beaconsOnly then
		entry.reason = "Frost beacon"
	end
	entry.targets = { entry }
	for _, group in ipairs(ranked) do
		if group ~= best then
			entry.targets[#entry.targets + 1] = finishGroup(group, count)
		end
	end
	return entry
end

local function setFps(tower, enabled)
	if not bindNet() then
		return false
	end

	local ok, result = pcall(ability.InvokeServer, ability, "Troops", "Abilities", "Activate", {
		Troop = tower.Model,
		Name = "FPS",
		Data = { enabled = enabled },
	})

	return ok and result ~= false
end

local function releaseTowers()
	for _, tower in ipairs(getTowers()) do
		if tower.FPS then
			setFps(tower, false)
		end
	end

	AutoGatlin.ActiveCount = 0
end

local function stopFiring()
	if firing then
		if stopRemote and stopRemote.Parent then
			stopRemote:FireServer()
		end
		firing = false
	end

	fireHoldUntil = 0
	aimedNpc = nil
end

local function syncTowers(towers, wanted)
	local keep = {}
	local changed = false
	local stopped = false

	for _, tower in ipairs(wanted) do
		keep[tower] = true
	end

	for _, tower in ipairs(towers) do
		local retry = towerRetry[tower]
		local now = os.clock()

		if retry and retry <= now then
			towerRetry[tower] = nil
			retry = nil
		end

		if keep[tower] and not retry and not tower.FPS then
			if setFps(tower, true) then
				changed = true
			else
				towerRetry[tower] = now + 1
			end
		elseif not keep[tower] and tower.FPS then
			if not stopped then
				stopFiring()
				stopped = true
			end

			setFps(tower, false)
			changed = true
		end
	end

	return changed
end

local function clearTarget()
	current = nil
	AutoGatlin.Target = nil
	AutoGatlin.TargetInfo = nil
	AutoGatlin.FireBurst = 1
end

local aimOffsets = {
	Vector3.zero,
	Vector3.new(0, -0.45, -0.45),
	Vector3.new(0, -0.45, 0.45),
	Vector3.new(-0.45, -0.45, 0),
	Vector3.new(0.45, -0.45, 0),
	Vector3.new(0, 0, -0.45),
	Vector3.new(0, 0, 0.45),
	Vector3.new(-0.45, 0, 0),
	Vector3.new(0.45, 0, 0),
	Vector3.new(0, 0.45, -0.45),
	Vector3.new(0, 0.45, 0.45),
	Vector3.new(-0.45, -0.45, -0.45),
	Vector3.new(0.45, -0.45, -0.45),
	Vector3.new(-0.45, -0.45, 0.45),
	Vector3.new(0.45, -0.45, 0.45),
}

local function resetHitWatch()
	hitWatch.npc = nil
	hitWatch.hp = 0
	hitWatch.missed = 0
	hitWatch.lastHit = 0
	hitWatch.ack = hitSeq
	hitWatch.bullet = bulletSeq
	hitWatch.confirmed = false
	hitWatch.awaiting = false
	hitWatch.missAt = 0
	hitWatch.probeAt = 0
	turnDone = false
	turnHits = 0
	turnShots = 0
	AutoGatlin.MissedRounds = 0
end

local function checkHits(towers, npc)
	local now = os.clock()
	local hp = npc.Health

	if hitWatch.npc ~= npc then
		hitWatch.npc = npc
		hitWatch.hp = hp
		hitWatch.missed = 0
		hitWatch.lastHit = now
		hitWatch.ack = hitSeq
		hitWatch.bullet = bulletSeq
		hitWatch.confirmed = validated[npc] == (aimPhase[npc] or 1)
		hitWatch.awaiting = false
		hitWatch.missAt = 0
		hitWatch.probeAt = 0
		return true
	end

	local acked = math.max(hitSeq - hitWatch.ack, 0)
	local processed = math.max(bulletSeq - hitWatch.bullet, 0)
	local damaged = hp < hitWatch.hp
	if damaged or acked > 0 then
		hitWatch.missed = 0
		hitWatch.lastHit = now
		hitWatch.confirmed = true
		hitWatch.awaiting = false
		hitWatch.missAt = 0
		hitWatch.probeAt = 0
		validated[npc] = aimPhase[npc] or 1
		turnHits = turnHits + math.max(acked, damaged and 1 or 0)
		if turnHits >= AutoGatlin.TargetQuota then
			turnDone = true
		end
	elseif processed > 0 then
		if hitWatch.confirmed then
			hitWatch.missed = hitWatch.missed + processed
		elseif hitWatch.missAt == 0 then
			hitWatch.missAt = now
		end
	end

	hitWatch.hp = hp
	hitWatch.ack = hitSeq
	hitWatch.bullet = bulletSeq
	AutoGatlin.MissedRounds = hitWatch.missed

	if turnDone and current and current.candidates > 1 then
		AutoGatlin.Status = "Rotating targets"
		return false
	end

	local badProbe = not hitWatch.confirmed
		and (
			hitWatch.missAt > 0 and now - hitWatch.missAt >= 0.04
			or hitWatch.awaiting and hitWatch.probeAt > 0 and now - hitWatch.probeAt >= 0.12
		)
	if not badProbe and (hitWatch.missed < AutoGatlin.MissLimit or now - hitWatch.lastHit < 0.2) then
		return true
	end

	local wasConfirmed = hitWatch.confirmed
	local hasAlternates = wasConfirmed and current and current.candidates > 1
	if hasAlternates then
		for _, tower in ipairs(towers) do
			local misses = blocked[tower]
			if not misses then
				misses = weakKeys()
				blocked[tower] = misses
			end

			misses[npc] = now + math.min(AutoGatlin.RetryDelay, 0.3)
		end

		resting[npc] = now + 0.3
	end

	aimPhase[npc] = (aimPhase[npc] or 1) % #aimOffsets + 1
	validated[npc] = nil
	shotHistory[npc] = nil
	shotReserve[npc] = nil
	hitWatch.npc = nil
	hitWatch.missed = 0
	hitWatch.lastHit = now
	hitWatch.ack = hitSeq
	hitWatch.bullet = bulletSeq
	hitWatch.confirmed = false
	hitWatch.awaiting = false
	hitWatch.missAt = 0
	hitWatch.probeAt = 0
	turnDone = false
	turnHits = 0
	turnShots = 0
	AutoGatlin.MissedRounds = 0
	AutoGatlin.Status = string.format("Recalibrating hit point %d", aimPhase[npc])
	relockUntil = now + (wasConfirmed and 0.2 or 0)
	aimedNpc = nil
	clearTarget()
	return false
end

local function recordShots(count)
	turnShots = turnShots + count
end

local function getPathFrame(npc)
	local path = npc.IntroPath and not npc.IntroDone and npc.IntroPath or npc.Path
	if not path then
		return
	end

	local pos, _, from, to = path:GetScalar(npc.PathDistance or 0, npc.PathOffset)
	if not (pos and from and to) then
		return
	end

	pos = pos + npc.PositionOffset * npc.ScalePositionOffset
	if npc.HeightYOffset then
		pos = pos + Vector3.new(0, npc.HeightYOffset, 0)
	end
	if npc.FlyingAnimation and npc.FlyingSeed then
		pos = pos + Vector3.new(0, math.sin((tick() + npc.FlyingSeed) * 6) * 0.8, 0)
	end

	if gameState.Difficulty == "Duck Hunt" then
		from = from - Vector3.new(0, from.Y, 0)
		to = to - Vector3.new(0, to.Y, 0)
		pos = Vector3.new(pos.X, 4.1 + npc.PositionOffset.Y, pos.Z)
	end

	local facing = npc.Reverse and CFrame.lookAt(to, from) or CFrame.lookAt(from, to)
	local rotation = npc.Rotation or facing.Rotation
	return CFrame.new(pos) * rotation + (npc.AdditiveOffset or Vector3.zero)
end

local function getHitboxOffset(npc, hitbox, root)
	local saved = hitboxOffsets[npc]
	if saved and saved.hitbox == hitbox and saved.root == root then
		return saved.offset
	end

	local assets = ReplicatedStorage.Assets
	local folder = npc.Replicator:Get("Legacy") and assets.Enemies or assets.NewEnemies
	local name = npc.Replicator:Get("ModelName") or npc.Name
	local asset = folder and folder:FindFirstChild(name)
	local model = asset and asset:FindFirstChild("Model")
	local assetRoot = model and (model:FindFirstChild(root.Name, true) or model.PrimaryPart)
	local assetHitbox = model and model:FindFirstChild(hitbox.Name, true)

	if assetRoot and assetHitbox then
		local offset = assetRoot.CFrame:ToObjectSpace(assetHitbox.CFrame)
		hitboxOffsets[npc] = {
			hitbox = hitbox,
			root = root,
			offset = offset,
		}
		return offset
	end

	return root.CFrame:ToObjectSpace(hitbox.CFrame)
end

local function getAimPoint(hitbox, npc, tower)
	local frame = hitbox.CFrame
	local target = npc.TargetRenderCFrame or getPathFrame(npc)
	local root = npc.RenderPart or npc.PrimaryPart
	if target and root then
		frame = target * getHitboxOffset(npc, hitbox, root)
	end

	local phase = aimPhase[npc]
	if not phase then
		phase = 1
		aimPhase[npc] = phase
	end

	local offset = aimOffsets[phase]
	local size = hitbox.Size
	local point = frame:PointToWorldSpace(Vector3.new(offset.X * size.X, offset.Y * size.Y, offset.Z * size.Z))
	local model = tower and tower.Model
	local muzzle = model and model:FindFirstChild("Fire", true)
	local origin = muzzle and muzzle:IsA("Attachment") and muzzle.WorldPosition or tower and tower.Position
	local ray = origin and point - origin
	if ray and ray.Magnitude > 0.01 then
		point = point + ray.Unit * math.max(size.Magnitude, 16)
	end

	return point
end

local function aimTowers(towers, point)
	for _, tower in ipairs(towers) do
		local frameData = tower._cframeData
		if tower.FPS and tower:IsAlive() and frameData and frameData.main and type(tower._aim) == "function" then
			tower:_aim(point)
		end
	end
end

local function getReplayShot(npc, point, sync, serverTime, now)
	local history = shotHistory[npc]
	if not history then
		history = {}
		shotHistory[npc] = history
	end

	local fresh = history[#history]
	if not fresh or fresh.sync ~= sync then
		fresh = {
			point = point,
			sync = sync,
			serverTime = serverTime,
			captured = now,
		}
		history[#history + 1] = fresh
	end

	while history[1] and now - history[1].captured > 1 do
		table.remove(history, 1)
	end

	for i = #history, 1, -1 do
		if now - history[i].captured >= AutoGatlin.ReplayDelay then
			return history[i], fresh
		end
	end
	return nil, fresh
end

local function getDamage(towers, npc)
	local damage = 0
	for _, tower in ipairs(towers) do
		if not npc or canHit(tower, npc) then
			damage = damage + math.max(tower.Damage, 0)
		end
	end
	return math.max(damage, 1)
end

local function fillShots(shots, budget)
	local left = budget
	while left > 0 do
		local open = 0
		for _, shot in ipairs(shots) do
			if shot.count < shot.need then
				open = open + 1
			end
		end
		if open == 0 then
			break
		end

		local share = math.max(math.floor(left / open), 1)
		for _, shot in ipairs(shots) do
			local count = math.min(shot.need - shot.count, share, left)
			shot.count = shot.count + count
			left = left - count
			if left == 0 then
				break
			end
		end
	end
end

local function getShotNeed(npc, damage, now)
	local hold = shotReserve[npc]
	if hold and now >= hold.expires then
		shotReserve[npc] = nil
		hold = nil
	elseif hold then
		local applied = math.floor(math.max(hold.hp - npc.Health, 0) / damage)
		hold.count = math.max(hold.count - applied, 0)
		hold.hp = npc.Health
	end

	local pending = hold and hold.count or 0
	return math.max(math.ceil(npc.Health / damage) - pending, 0)
end

local function reserveShots(shot, now)
	if shot.count == 0 then
		return
	end

	local hold = shotReserve[shot.npc]
	if not hold or now >= hold.expires then
		hold = {
			count = 0,
			hp = shot.npc.Health,
			expires = now,
		}
		shotReserve[shot.npc] = hold
	end

	hold.count = hold.count + shot.count
	hold.hp = shot.npc.Health
	hold.expires = now + 0.3
end

local function getBurst(towers, npc)
	if not AutoGatlin.AutoCalibrate then
		return 1
	end

	local rounds = npc.Health / getDamage(towers, npc)
	return math.clamp(math.ceil(rounds / 40), 1, AutoGatlin.MaxBurst)
end

local function getMultiCount(entry)
	if not AutoGatlin.NoCooldown then
		return 1
	end
	return math.clamp(#entry.targets, 1, AutoGatlin.MaxTargets)
end

local function getQuota(entry)
	if not AutoGatlin.AutoCalibrate then
		return 2147483647
	end

	local rounds = math.ceil(entry.npc.Health / getDamage(entry.towers, entry.npc))
	local count = math.max(entry.candidates, 1)
	local split = AutoGatlin.CrowdControl and math.sqrt(count) or 1
	local quota = math.ceil(rounds / split)
	if entry.emergency then
		quota = math.ceil(quota * 1.5)
	end
	return math.clamp(quota, 1, entry.emergency and 36 or 24)
end

local function getRest(entry)
	local pressure = math.clamp((entry.candidates - 1) / 12, 0, 1)
	return 0.12 + pressure * 0.28
end

local function buildReplayShots(entry, towers, targetNpc, confirmed, sync, now)
	local limit = confirmed and getMultiCount(entry) or 1
	local shots = {}

	for _, target in ipairs(entry.targets) do
		if #shots >= limit then
			break
		end

		local npc = target.npc
		local hitbox = npc and (npc.Hitbox or npc.PrimaryPart)
		local usable = npc and hitbox and npc:IsAlive()
		if usable then
			usable = false
			for _, tower in ipairs(towers) do
				if canHit(tower, npc) then
					usable = true
					break
				end
			end
		end
		if usable and npc ~= targetNpc and validated[npc] ~= (aimPhase[npc] or 1) then
			usable = false
		end

		if usable then
			local point = getAimPoint(hitbox, npc, towers[1])
			if point then
				local replay, fresh = getReplayShot(npc, point, sync, Workspace:GetServerTimeNow(), now)
				local ticket = replay or fresh
				local damage = getDamage(towers, npc)
				shots[#shots + 1] = {
					npc = npc,
					point = point,
					sync = ticket.sync,
					serverTime = ticket.serverTime,
					captured = ticket.captured,
					need = getShotNeed(npc, damage, now),
					count = 0,
					confirmed = npc == targetNpc and confirmed or validated[npc] == (aimPhase[npc] or 1),
				}
			end
		end
	end

	return shots
end

local function fireReplayShots(shots, towers, endpoint, ready, confirmed, now)
	local ammo = math.huge
	for _, tower in ipairs(towers) do
		ammo = math.min(ammo, tower.Ammo)
	end

	local budget = math.min(AutoGatlin.ReplayBurst, math.max(ammo, 0))
	for _, shot in ipairs(shots) do
		if not shot.confirmed or hasLead(shot.npc) or now - shot.captured < AutoGatlin.ReplayDelay then
			shot.need = math.min(shot.need, 1)
		end
	end
	fillShots(shots, budget)

	local burst = 0
	for _, shot in ipairs(shots) do
		if shot.count > 0 then
			aimRemote:FireServer(shot.point)
			for _ = 1, shot.count do
				fireRemote:FireServer(shot.point, shot.sync, shot.serverTime)
			end
			if ready then
				reserveShots(shot, now)
			end
			burst = burst + shot.count
		end
	end

	if ready and not confirmed and burst > 0 then
		hitWatch.awaiting = true
		hitWatch.missAt = 0
		hitWatch.probeAt = now
	end
	aimRemote:FireServer(endpoint)
	return burst
end

local function removeGroup(group)
	for _, item in pairs(group) do
		item:Remove()
	end
end

local function clearEsp()
	for model, group in pairs(esp) do
		removeGroup(group)
		esp[model] = nil
	end
end

local function clearHighlights()
	for model, highlight in pairs(espHighlights) do
		highlight:Destroy()
		espHighlights[model] = nil
	end
end

local function clearTracers()
	for tower, tracer in pairs(tracers) do
		tracer.line:Remove()
		tracers[tower] = nil
	end
end

local function rainbowColor()
	return Color3.fromHSV((os.clock() * AutoGatlin.RainbowSpeed / 100) % 1, 0.85, 1)
end

local function getGatlinColor()
	if AutoGatlin.RainbowGatlin then
		return rainbowColor()
	end
	if AutoGatlin.CustomGatlin then
		return AutoGatlin.GatlinColor
	end
end

local function makeEsp()
	local outline = Draw.new("Square")
	outline.Filled = false
	outline.Color = Color3.new()
	outline.Thickness = 3
	outline.Transparency = 1 - AutoGatlin.ESPOutlineTransparency / 100
	outline.ZIndex = 3

	local box = Draw.new("Square")
	box.Filled = false
	box.Thickness = 1
	box.Transparency = 1
	box.ZIndex = 4

	local healthBg = Draw.new("Line")
	healthBg.Color = Color3.new()
	healthBg.Thickness = 5
	healthBg.Transparency = 0.8
	healthBg.ZIndex = 3

	local health = Draw.new("Line")
	health.Thickness = 3
	health.Transparency = 1
	health.ZIndex = 4

	local name = Draw.new("Text")
	name.Center = true
	name.Color = Color3.new(1, 1, 1)
	name.Font = 2
	name.Outline = true
	name.Size = 13
	name.Transparency = 1
	name.ZIndex = 5

	local info = Draw.new("Text")
	info.Center = true
	info.Color = Color3.fromRGB(210, 215, 225)
	info.Font = 2
	info.Outline = true
	info.Size = 12
	info.Transparency = 1
	info.ZIndex = 5

	return {
		outline = outline,
		box = box,
		healthBg = healthBg,
		health = health,
		name = name,
		info = info,
	}
end

local function showGroup(group, visible)
	for _, item in pairs(group) do
		item.Visible = visible
	end
end

local function getScreenBox(part, cam)
	local half = part.Size / 2
	local minX, minY = math.huge, math.huge
	local maxX, maxY = -math.huge, -math.huge
	local found = false

	for x = -1, 1, 2 do
		for y = -1, 1, 2 do
			for z = -1, 1, 2 do
				local world = part.CFrame:PointToWorldSpace(Vector3.new(half.X * x, half.Y * y, half.Z * z))
				local point = cam:WorldToViewportPoint(world)

				if point.Z > 0 then
					found = true
					minX = math.min(minX, point.X)
					minY = math.min(minY, point.Y)
					maxX = math.max(maxX, point.X)
					maxY = math.max(maxY, point.Y)
				end
			end
		end
	end

	if not found or maxX < 0 or maxY < 0 or minX > cam.ViewportSize.X or minY > cam.ViewportSize.Y then
		return
	end

	return Vector2.new(minX, minY), Vector2.new(maxX, maxY)
end

local function drawCsgo(model, npc, cam)
	local group = esp[model]
	if not group then
		group = makeEsp()
		esp[model] = group
	end

	local hitbox = npc.Hitbox or npc.PrimaryPart
	local top, bottom
	if hitbox then
		top, bottom = getScreenBox(hitbox, cam)
	end
	if not top then
		showGroup(group, false)
		return
	end

	local size = bottom - top
	if size.X < 2 or size.Y < 2 then
		showGroup(group, false)
		return
	end

	local target = current and current.npc == npc
	local lead = hasLead(npc)
	local boss = isBoss(npc)
	local color = AutoGatlin.RainbowESP and rainbowColor()
		or target and Color3.fromRGB(255, 85, 85)
		or boss and Color3.fromRGB(190, 85, 255)
		or lead and Color3.fromRGB(235, 190, 70)
		or Color3.fromRGB(65, 185, 255)
	local ratio = math.clamp(npc.Health / math.max(npc.MaxHealth, 1), 0, 1)
	local center = top.X + size.X / 2

	group.outline.Position = top - Vector2.new(1, 1)
	group.outline.Size = size + Vector2.new(2, 2)
	group.outline.Transparency = 1 - AutoGatlin.ESPOutlineTransparency / 100
	group.box.Position = top
	group.box.Size = size
	group.box.Color = color
	group.healthBg.From = Vector2.new(top.X - 6, bottom.Y + 1)
	group.healthBg.To = Vector2.new(top.X - 6, top.Y - 1)
	group.health.From = Vector2.new(top.X - 6, bottom.Y)
	group.health.To = Vector2.new(top.X - 6, bottom.Y - size.Y * ratio)
	group.health.Color = Color3.fromRGB(math.round(255 * (1 - ratio)), math.round(255 * ratio), 55)
	group.name.Text = npc.Name
	group.name.Color = AutoGatlin.RainbowESP and color or Color3.new(1, 1, 1)
	group.name.Position = Vector2.new(center, top.Y - 16)
	group.info.Text = string.format(
		"%d/%d HP%s",
		math.max(math.round(npc.Health), 0),
		math.max(math.round(npc.MaxHealth), 0),
		(lead and " | LEAD" or "") .. (boss and " | BOSS" or "")
	)
	group.info.Position = Vector2.new(center, bottom.Y + 2)
	showGroup(group, true)
end

local espStyles = {
	CSGO = drawCsgo,
}

local function updateEsp()
	if not (AutoGatlin.ZombieESP or AutoGatlin.RainbowESP) then
		return
	end

	local cam = AutoGatlin.ZombieESP and Workspace.CurrentCamera
	local renderer = espStyles[AutoGatlin.ESPStyle] or drawCsgo
	local seen = {}
	local color = AutoGatlin.RainbowESP and rainbowColor()

	for model, npc in pairs(getNpcs()) do
		if model.Parent and npc.Type ~= "Units" and npc:IsAlive() then
			seen[model] = true
			if AutoGatlin.ZombieESP then
				renderer(model, npc, cam)
			end
			if AutoGatlin.RainbowESP then
				local highlight = espHighlights[model]
				if not highlight then
					highlight = Instance.new("Highlight")
					highlight.Name = "AutoGatlinESP"
					highlight.Adornee = model
					highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
					highlight.FillTransparency = 1
					highlight.Parent = model
					espHighlights[model] = highlight
				end
				highlight.OutlineColor = color
				highlight.OutlineTransparency = AutoGatlin.ESPOutlineTransparency / 100
			end
		end
	end

	for model, group in pairs(esp) do
		if not AutoGatlin.ZombieESP or not seen[model] then
			removeGroup(group)
			esp[model] = nil
		end
	end

	for model, highlight in pairs(espHighlights) do
		if not AutoGatlin.RainbowESP or not seen[model] then
			highlight:Destroy()
			espHighlights[model] = nil
		end
	end
end

local function markShots(towers, pos)
	if not AutoGatlin.ShowBulletLines then
		return
	end

	local expires = os.clock() + 0.09
	for _, tower in ipairs(towers) do
		local tracer = tracers[tower]
		if not tracer then
			local line = Draw.new("Line")
			line.Color = Color3.fromRGB(255, 220, 90)
			line.Thickness = 2
			line.Transparency = 1
			line.ZIndex = 6
			tracer = { line = line }
			tracers[tower] = tracer
		end

		tracer.from = tower.Position
		tracer.to = pos
		tracer.expires = expires
	end
end

local function updateTracers()
	if not AutoGatlin.ShowBulletLines then
		return
	end

	local cam = Workspace.CurrentCamera
	local now = os.clock()

	for tower, tracer in pairs(tracers) do
		if not tower.Model.Parent then
			tracer.line:Remove()
			tracers[tower] = nil
		elseif tracer.expires <= now then
			tracer.line.Visible = false
		else
			local from, fromVisible = cam:WorldToViewportPoint(tracer.from)
			local to, toVisible = cam:WorldToViewportPoint(tracer.to)
			tracer.line.Visible = from.Z > 0 and to.Z > 0 and (fromVisible or toVisible)

			if tracer.line.Visible then
				tracer.line.From = Vector2.new(from.X, from.Y)
				tracer.line.To = Vector2.new(to.X, to.Y)
				tracer.line.Transparency = math.clamp((tracer.expires - now) / 0.09, 0.15, 1)
			end
		end
	end
end

local function updateGatlinColors()
	local color = getGatlinColor()
	if not color then
		return
	end

	for part in pairs(gatlinColors) do
		if part.Parent then
			part.Color = color
		else
			gatlinColors[part] = nil
		end
	end
end

local function drawStep()
	local entry = current
	local npc = entry and entry.npc
	local hitbox = npc and (npc.Hitbox or npc.PrimaryPart)
	if npc and hitbox and npc:IsAlive() then
		aimTowers(entry.towers, getAimPoint(hitbox, npc, entry.towers[1]))
	end

	updateEsp()
	updateTracers()
	updateGatlinColors()
end

local function disconnectAll(conns)
	for _, conn in ipairs(conns) do
		conn:Disconnect()
	end
	table.clear(conns)
end

local function replacePlain(text, needle, replacement)
	local lower = text:lower()
	local find = needle:lower()
	local out = {}
	local at = 1

	while true do
		local first, last = lower:find(find, at, true)
		if not first then
			out[#out + 1] = text:sub(at)
			break
		end

		out[#out + 1] = text:sub(at, first - 1)
		out[#out + 1] = replacement
		at = last + 1
	end

	return table.concat(out)
end

local function namesActive()
	return AutoGatlin.HideUsername or (AutoGatlin.MorphEnabled and AutoGatlin.MorphName ~= "")
end

local function redactName(text, obj)
	local prefix = "_TDS_TOOLS_" .. lp.UserId .. "_"
	if AutoGatlin.HideUsername then
		local mark = prefix .. "HIDDEN_"
		local names = table.clone(privateNames)
		for _, name in ipairs({ AutoGatlin.MorphDisplayName, AutoGatlin.MorphName }) do
			if name ~= "" then
				names[#names + 1] = name
			end
		end
		table.sort(names, function(a, b)
			return #a > #b
		end)
		for _, name in ipairs(names) do
			text = replacePlain(text, name, mark)
		end
		for _, badge in ipairs({ utf8.char(0xE000), utf8.char(0xE001) }) do
			text = text:gsub(badge .. "%s*" .. mark, mark)
			text = text:gsub(mark .. "%s*" .. badge, mark)
		end
		return text:gsub(mark, function()
			return AutoGatlin.ProtectedName
		end)
	end

	local tagMark = prefix .. "TAG_"
	local userMark = prefix .. "USERNAME_"
	local displayMark = prefix .. "DISPLAY_"
	local displayName = AutoGatlin.MorphDisplayName ~= "" and AutoGatlin.MorphDisplayName or AutoGatlin.MorphName
	local badges = ""
	if AutoGatlin.MorphVerified then
		badges = badges .. " " .. utf8.char(0xE000)
	end
	local usernameLabel = obj.Name == "TextLabel"
		and obj.Parent
		and obj.Parent.Name == "Player"
		and obj.Parent.Parent
		and obj.Parent.Parent.Name == "Navigation"

	text = replacePlain(text, "@" .. lp.Name, tagMark)
	if lp.DisplayName:lower() == lp.Name:lower() then
		text = replacePlain(text, lp.Name, usernameLabel and userMark or displayMark)
	else
		text = replacePlain(text, lp.DisplayName, displayMark)
		text = replacePlain(text, lp.Name, userMark)
	end
	for _, badge in ipairs({ utf8.char(0xE000), utf8.char(0xE001) }) do
		text = text:gsub(badge .. "%s*" .. displayMark, displayMark)
		text = text:gsub(displayMark .. "%s*" .. badge, displayMark)
	end

	text = text:gsub(tagMark, function()
		return "@" .. AutoGatlin.MorphName
	end)
	text = text:gsub(userMark, function()
		return AutoGatlin.MorphName
	end)
	return text:gsub(displayMark, function()
		return displayName .. badges
	end)
end

local function isText(obj)
	return obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox")
end

local function isImage(obj)
	return obj:IsA("ImageLabel") or obj:IsA("ImageButton")
end

local function morphThumb(image)
	local userId = AutoGatlin.MorphLoadedId
	local lower = image:lower()
	if
		not AutoGatlin.MorphEnabled
		or userId <= 0
		or not lower:find("rbxthumb://", 1, true)
		or not lower:find("type=avatar", 1, true)
	then
		return
	end

	local first, last = lower:find("id=" .. lp.UserId, 1, true)
	if not first or lower:sub(last + 1, last + 1):match("%d") then
		return
	end

	return image:sub(1, first + 2) .. userId .. image:sub(last + 1)
end

local function setThumb(obj, image)
	if obj.Image == image then
		return
	end

	thumbBusy[obj] = image
	obj.Image = image
	task.defer(function()
		if thumbBusy[obj] == image then
			thumbBusy[obj] = nil
		end
	end)
end

local function applyThumb(obj, changed)
	if not obj.Parent then
		return
	end

	local lower = obj.Image:lower()
	local tracked = thumbTracked[obj]
	local isBadge = lower:find("premiumicon", 1, true) or lower:find("verifiedbadgenameicon", 1, true)
	if tracked == true and isBadge then
		tracked = { visible = obj.Visible }
		thumbTracked[obj] = tracked
	elseif type(tracked) == "table" and not isBadge then
		thumbTracked[obj] = true
		obj.Visible = tracked.visible
		tracked = true
	end
	if type(tracked) == "table" then
		local visible = tracked.visible and not AutoGatlin.HideUsername and not AutoGatlin.MorphEnabled
		if obj.Visible ~= visible then
			tracked.busy = visible
			obj.Visible = visible
		end
	end

	local saved = thumbSaved[obj]
	if changed and saved then
		local expected = morphThumb(saved)
		if obj.Image ~= saved and obj.Image ~= expected then
			thumbSaved[obj] = nil
			saved = nil
		end
	end

	local source = saved or obj.Image
	local image = morphThumb(source)
	if image then
		thumbSaved[obj] = saved or source
		setThumb(obj, image)
	elseif saved then
		thumbSaved[obj] = nil
		setThumb(obj, saved)
	end
end

local function isOverheadName(obj)
	local tags = Workspace:FindFirstChild("Nametags")
	local tag = tags and tags:FindFirstChild(lp.Name)
	return tag and obj:IsA("TextLabel") and obj:IsDescendantOf(tag) and obj:FindFirstAncestor("RichText") ~= nil
end

local function applyName(obj, save)
	if not namesActive() or not obj.Parent then
		return
	end

	if save or textSaved[obj] == nil then
		textSaved[obj] = obj.Text
	end

	local text = redactName(textSaved[obj], obj)
	if obj.Text ~= text then
		if isOverheadName(obj) then
			if textAlignSaved[obj] == nil then
				textAlignSaved[obj] = obj.TextXAlignment
			end
			obj.TextXAlignment = Enum.TextXAlignment.Center
		end
		textBusy[obj] = text
		obj.Text = text
		task.defer(function()
			if textBusy[obj] == text then
				textBusy[obj] = nil
			end
		end)
	end

	local tracked = nameTracked[obj]
	if type(tracked) ~= "table" then
		return
	end

	local source = textSaved[obj]:lower()
	local ownName = source:find(lp.Name:lower(), 1, true) ~= nil or source:find(lp.DisplayName:lower(), 1, true) ~= nil
	local visible = ownName and AutoGatlin.MorphEnabled and AutoGatlin.MorphPlus and not AutoGatlin.HideUsername
	local icon = tracked.plus
	if visible and (not icon or not icon.Parent) then
		icon = Instance.new("TextLabel")
		icon.Name = "TDSMorphRobloxPlus"
		icon:SetAttribute("TDSMorphBadge", true)
		icon.BackgroundTransparency = 1
		icon.FontFace = Font.new(
			"rbxasset://LuaPackages/Packages/_Index/BuilderIcons/BuilderIcons/BuilderIcons.json",
			Enum.FontWeight.Regular
		)
		icon.Text = "roblox-plus"
		icon.TextSize = 16
		icon.Size = UDim2.fromOffset(16, 16)
		icon.Parent = obj.Parent
		tracked.plus = icon
	end
	if not icon then
		return
	end

	icon.Visible = visible
	if visible then
		icon.TextColor3 = obj.TextColor3
		icon.TextTransparency = obj.TextTransparency
		icon.ZIndex = obj.ZIndex
		if obj.Parent:FindFirstChildOfClass("UIListLayout") then
			icon.AnchorPoint = Vector2.zero
			icon.LayoutOrder = obj.LayoutOrder + 1
			icon.Position = UDim2.new()
		else
			icon.AnchorPoint = Vector2.new(0, 0.5)
			icon.Position = UDim2.new(
				obj.Position.X.Scale,
				obj.Position.X.Offset + obj.TextBounds.X + 4,
				obj.Position.Y.Scale,
				obj.Position.Y.Offset + obj.AbsoluteSize.Y / 2
			)
		end
	end
end

local function trackText(obj)
	if not isText(obj) or nameTracked[obj] or obj:GetAttribute("TDSMorphBadge") then
		return
	end

	local parent = obj.Parent
	local playerList = obj:FindFirstAncestor("ReactUniversalPlayerList")
	if
		playerList
		and (
			(obj.Name == "displayName" and parent.Name == "banner")
			or (obj.Name == "title" and parent.Name == "username")
		)
	then
		nameTracked[obj] = {}
	else
		nameTracked[obj] = true
	end
	applyName(obj, true)
	nameConns[#nameConns + 1] = obj:GetPropertyChangedSignal("Text"):Connect(function()
		if textBusy[obj] == obj.Text then
			return
		end

		textBusy[obj] = nil
		applyName(obj, true)
	end)
	if type(nameTracked[obj]) == "table" then
		nameConns[#nameConns + 1] = obj:GetPropertyChangedSignal("TextBounds"):Connect(function()
			applyName(obj, false)
		end)
		nameConns[#nameConns + 1] = obj.Destroying:Connect(function()
			local tracked = nameTracked[obj]
			if type(tracked) == "table" and tracked.plus then
				tracked.plus:Destroy()
			end
		end)
	end
end

local function trackThumb(obj)
	if not isImage(obj) or thumbTracked[obj] then
		return
	end

	local lower = obj.Image:lower()
	if lower:find("premiumicon", 1, true) or lower:find("verifiedbadgenameicon", 1, true) then
		thumbTracked[obj] = { visible = obj.Visible }
	else
		thumbTracked[obj] = true
	end
	applyThumb(obj, false)
	nameConns[#nameConns + 1] = obj:GetPropertyChangedSignal("Image"):Connect(function()
		if thumbBusy[obj] == obj.Image then
			return
		end

		thumbBusy[obj] = nil
		applyThumb(obj, true)
	end)
	nameConns[#nameConns + 1] = obj:GetPropertyChangedSignal("Visible"):Connect(function()
		local tracked = thumbTracked[obj]
		if type(tracked) ~= "table" then
			return
		end
		if tracked.busy == obj.Visible then
			tracked.busy = nil
			return
		end

		tracked.visible = obj.Visible
		applyThumb(obj, false)
	end)
end

local function trackNameRoot(root)
	for _, obj in ipairs(root:GetDescendants()) do
		trackText(obj)
		trackThumb(obj)
	end
	nameConns[#nameConns + 1] = root.DescendantAdded:Connect(function(obj)
		trackText(obj)
		trackThumb(obj)
	end)
end

local function protectHum(hum)
	local saved = humSaved[hum]
	if not saved then
		saved = {
			displayName = hum.DisplayName,
			distance = hum.DisplayDistanceType,
		}
		humSaved[hum] = saved
	end

	if AutoGatlin.HideUsername and AutoGatlin.ProtectedName == "" then
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	elseif AutoGatlin.HideUsername then
		hum.DisplayName = AutoGatlin.ProtectedName
		hum.DisplayDistanceType = saved.distance
	else
		hum.DisplayName = AutoGatlin.MorphDisplayName ~= "" and AutoGatlin.MorphDisplayName or AutoGatlin.MorphName
		hum.DisplayDistanceType = saved.distance
	end
end

local function protectCharacter(char)
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then
		protectHum(hum)
	end

	nameConns[#nameConns + 1] = char.ChildAdded:Connect(function(child)
		if child:IsA("Humanoid") then
			protectHum(child)
		end
	end)
end

local function refreshNames()
	for obj in pairs(nameTracked) do
		applyName(obj, false)
	end
	for obj in pairs(thumbTracked) do
		applyThumb(obj, false)
	end
	for hum in pairs(humSaved) do
		if hum.Parent then
			protectHum(hum)
		end
	end
end

local function enableNamePrivacy()
	if #nameConns > 0 then
		refreshNames()
		return
	end

	local playerGui = lp:FindFirstChildOfClass("PlayerGui")
	if playerGui then
		trackNameRoot(playerGui)
	end

	local coreGui = clone(game:GetService("CoreGui"))
	local uiRoot = coreGui
	if type(gethui) == "function" then
		local ok, root = pcall(gethui)
		if ok and typeof(root) == "Instance" then
			uiRoot = root
		end
	end

	trackNameRoot(coreGui)
	if uiRoot ~= coreGui then
		trackNameRoot(uiRoot)
	end

	trackNameRoot(Workspace)
	nameConns[#nameConns + 1] = lp.ChildAdded:Connect(function(child)
		if child:IsA("PlayerGui") then
			trackNameRoot(child)
		end
	end)
	if lp.Character then
		protectCharacter(lp.Character)
	end
	nameConns[#nameConns + 1] = lp.CharacterAdded:Connect(protectCharacter)
end

local function disableNamePrivacy()
	disconnectAll(nameConns)

	for obj, text in pairs(textSaved) do
		if obj.Parent then
			obj.Text = text
			if textAlignSaved[obj] then
				obj.TextXAlignment = textAlignSaved[obj]
			end
		end
	end
	for obj, image in pairs(thumbSaved) do
		if obj.Parent then
			obj.Image = image
		end
	end
	for obj, tracked in pairs(thumbTracked) do
		if type(tracked) == "table" and obj.Parent then
			obj.Visible = tracked.visible
		end
	end
	for hum, saved in pairs(humSaved) do
		if hum.Parent then
			hum.DisplayName = saved.displayName
			hum.DisplayDistanceType = saved.distance
		end
	end
	for _, tracked in pairs(nameTracked) do
		if type(tracked) == "table" and tracked.plus then
			tracked.plus:Destroy()
		end
	end

	table.clear(nameTracked)
	table.clear(textSaved)
	table.clear(textAlignSaved)
	table.clear(textBusy)
	table.clear(thumbTracked)
	table.clear(thumbSaved)
	table.clear(thumbBusy)
	table.clear(humSaved)
end

local function syncNames()
	if namesActive() then
		enableNamePrivacy()
	else
		disableNamePrivacy()
	end
end

local function hideAccessory(obj)
	if obj:IsA("Accessory") then
		for _, child in ipairs(obj:GetDescendants()) do
			hideAccessory(child)
		end
		return
	end
	if
		not obj:IsA("BasePart")
		or not (obj:FindFirstAncestorOfClass("Accessory") or obj:GetAttribute("TDSMorphAccessory"))
	then
		return
	end

	if accessoryParts[obj] == nil then
		accessoryParts[obj] = obj.LocalTransparencyModifier
	end
	obj.LocalTransparencyModifier = 1
end

local function hideCharacterAccessories(char)
	for _, obj in ipairs(char:GetDescendants()) do
		hideAccessory(obj)
	end
	accessoryConns[#accessoryConns + 1] = char.DescendantAdded:Connect(hideAccessory)
end

local function enableAccessoryPrivacy()
	if #accessoryConns > 0 then
		return
	end

	if lp.Character then
		hideCharacterAccessories(lp.Character)
	end
	accessoryConns[#accessoryConns + 1] = lp.CharacterAdded:Connect(hideCharacterAccessories)
end

local function disableAccessoryPrivacy()
	disconnectAll(accessoryConns)
	for part, transparency in pairs(accessoryParts) do
		if part.Parent then
			part.LocalTransparencyModifier = transparency
		end
	end
	table.clear(accessoryParts)
end

local function isAppearance(obj)
	return obj:IsA("Accessory")
		or obj:IsA("Shirt")
		or obj:IsA("Pants")
		or obj:IsA("ShirtGraphic")
		or obj:IsA("BodyColors")
		or obj:IsA("CharacterMesh")
end

local function isPartVisual(obj)
	return obj:IsA("Decal")
		or obj:IsA("Texture")
		or obj:IsA("SurfaceAppearance")
		or obj:IsA("SpecialMesh")
		or obj:IsA("WrapTarget")
		or obj:IsA("FaceControls")
		or (obj:IsA("ValueBase") and (obj.Name == "OriginalSize" or obj.Name == "AvatarPartScaleType"))
end

local function stopAnimTracks(hum)
	local animator = hum:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end

	for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
		track:Stop(0)
		track:Destroy()
	end
end

local function saveMorph(char, hum)
	local saved = morphSaved[hum]
	if saved then
		for _, obj in ipairs(saved.added) do
			if obj.Parent then
				obj:Destroy()
			end
		end
		table.clear(saved.added)
		return saved
	end

	saved = {
		storage = Instance.new("Folder"),
		objects = {},
		visuals = {},
		parts = {},
		attachments = {},
		scales = {},
		added = {},
		hipHeight = hum.HipHeight,
		displayName = hum.DisplayName,
		distance = hum.DisplayDistanceType,
		animate = char:FindFirstChild("Animate"),
		animations = {},
		animationWeights = {},
	}
	morphSaved[hum] = saved
	if saved.animate and saved.animate:IsA("LocalScript") then
		saved.animateDisabled = saved.animate.Disabled
		for _, obj in ipairs(saved.animate:GetDescendants()) do
			if obj:IsA("Animation") then
				saved.animations[obj] = obj.AnimationId
				local weight = obj:FindFirstChild("Weight")
				if weight and weight:IsA("NumberValue") then
					saved.animationWeights[weight] = weight.Value
				end
			end
		end
	else
		saved.animate = nil
	end

	for _, obj in ipairs(char:GetChildren()) do
		if isAppearance(obj) then
			saved.objects[#saved.objects + 1] = obj
			obj.Parent = saved.storage
		elseif obj:IsA("BasePart") and obj.Name ~= "HumanoidRootPart" then
			local props = {
				color = obj.Color,
				material = obj.Material,
				materialVariant = obj.MaterialVariant,
				reflectance = obj.Reflectance,
				transparency = obj.Transparency,
				size = obj.Size,
				pivotOffset = obj.PivotOffset,
			}
			if obj:IsA("MeshPart") then
				props.mesh = obj:Clone()
				props.mesh:ClearAllChildren()
				props.mesh.Parent = saved.storage
				props.meshId = obj.MeshId
				props.textureId = obj.TextureID
			end
			saved.parts[obj] = props

			for _, child in ipairs(obj:GetChildren()) do
				if isPartVisual(child) then
					saved.visuals[#saved.visuals + 1] = { obj = child, parent = obj }
					child.Parent = nil
				elseif child:IsA("Attachment") then
					saved.attachments[child] = child.CFrame
				end
			end
		end
	end

	local root = char:FindFirstChild("HumanoidRootPart")
	if root then
		for _, child in ipairs(root:GetChildren()) do
			if child:IsA("Attachment") then
				saved.attachments[child] = child.CFrame
			end
		end
	end

	for _, obj in ipairs(hum:GetChildren()) do
		if obj:IsA("NumberValue") and obj.Name:find("Scale", 1, true) then
			saved.scales[obj] = obj.Value
		end
	end
	return saved
end

local function copyPart(target, source, saved)
	if target:IsA("MeshPart") and source:IsA("MeshPart") then
		local ok = pcall(target.ApplyMesh, target, source)
		if not ok then
			target.MeshId = source.MeshId
			target.TextureID = source.TextureID
		end
	end
	target.Color = source.Color
	target.Material = source.Material
	target.MaterialVariant = source.MaterialVariant
	target.Reflectance = source.Reflectance
	target.Transparency = source.Transparency
	target.Size = source.Size
	target.PivotOffset = source.PivotOffset

	for _, child in ipairs(source:GetChildren()) do
		if isPartVisual(child) then
			local clone = child:Clone()
			clone.Parent = target
			saved.added[#saved.added + 1] = clone
		elseif child:IsA("Attachment") then
			local attachment = target:FindFirstChild(child.Name)
			if attachment and attachment:IsA("Attachment") then
				attachment.CFrame = child.CFrame
			end
		end
	end
end

local function applyAnimations(hum, saved)
	local animate = saved.animate
	local source = AutoGatlin.MorphTemplate and AutoGatlin.MorphTemplate:FindFirstChild("Animate")
	if not animate or not source then
		return
	end

	animate.Disabled = true
	task.wait()
	stopAnimTracks(hum)
	for _, sourceAnim in ipairs(source:GetDescendants()) do
		if sourceAnim:IsA("Animation") then
			local group = animate:FindFirstChild(sourceAnim.Parent.Name)
			local anim = group and group:FindFirstChild(sourceAnim.Name)
			if anim and anim:IsA("Animation") then
				anim.AnimationId = sourceAnim.AnimationId
				local weight = sourceAnim:FindFirstChild("Weight")
				local targetWeight = anim:FindFirstChild("Weight")
				if weight and weight:IsA("NumberValue") and targetWeight and targetWeight:IsA("NumberValue") then
					targetWeight.Value = weight.Value
				end
			end
		end
	end
	animate.Disabled = false
end

local function restoreAnimations(hum, saved)
	local animate = saved.animate
	if not animate then
		return
	end

	animate.Disabled = true
	task.wait()
	stopAnimTracks(hum)
	for anim, id in pairs(saved.animations) do
		anim.AnimationId = id
	end
	for weight, value in pairs(saved.animationWeights) do
		weight.Value = value
	end
	animate.Disabled = saved.animateDisabled
end

local function mountAccessory(accessory, char, folder)
	local source = accessory:FindFirstChild("Handle")
	if not source or not source:IsA("BasePart") then
		return
	end

	local handle = source:Clone()
	handle.Name = accessory.Name
	handle.CanCollide = false
	handle.Massless = true
	handle:SetAttribute("TDSMorphAccessory", true)

	local weld = handle:FindFirstChild("AccessoryWeld")
	if weld and weld:IsA("Weld") then
		local body = weld.Part1 and char:FindFirstChild(weld.Part1.Name)
		weld.Part0 = handle
		weld.Part1 = body
	else
		local sourceAttachment = handle:FindFirstChildOfClass("Attachment")
		local bodyAttachment
		if sourceAttachment then
			for _, part in ipairs(char:GetChildren()) do
				if part:IsA("BasePart") then
					local attachment = part:FindFirstChild(sourceAttachment.Name)
					if attachment and attachment:IsA("Attachment") then
						bodyAttachment = attachment
						break
					end
				end
			end
		end

		if bodyAttachment then
			weld = Instance.new("Weld")
			weld.Name = "AccessoryWeld"
			weld.Part0 = handle
			weld.Part1 = bodyAttachment.Parent
			weld.C0 = sourceAttachment.CFrame
			weld.C1 = bodyAttachment.CFrame
			weld.Parent = handle
		end
	end

	handle.Parent = folder
end

local function applyMorph(char, source)
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local template = source or AutoGatlin.MorphTemplate
	if not hum or not template then
		return false, "Waiting for character"
	end

	local saved = saveMorph(char, hum)
	local sourceHum = template:FindFirstChildOfClass("Humanoid")
	if sourceHum then
		hum.HipHeight = sourceHum.HipHeight
		for value in pairs(saved.scales) do
			local source = sourceHum:FindFirstChild(value.Name)
			if source and source:IsA("NumberValue") then
				value.Value = source.Value
			end
		end
	end

	local root = char:FindFirstChild("HumanoidRootPart")
	local sourceRoot = template:FindFirstChild("HumanoidRootPart")
	if root and sourceRoot then
		for _, child in ipairs(sourceRoot:GetChildren()) do
			if child:IsA("Attachment") then
				local attachment = root:FindFirstChild(child.Name)
				if attachment and attachment:IsA("Attachment") then
					attachment.CFrame = child.CFrame
				end
			end
		end
	end

	local accessoryFolder
	for _, obj in ipairs(template:GetChildren()) do
		if isAppearance(obj) then
			if obj:IsA("Accessory") then
				if not accessoryFolder then
					accessoryFolder = Instance.new("Folder")
					accessoryFolder.Name = "TDSMorphAccessories"
					accessoryFolder.Parent = char
					saved.added[#saved.added + 1] = accessoryFolder
				end
				mountAccessory(obj, char, accessoryFolder)
			else
				local clone = obj:Clone()
				clone.Parent = char
				saved.added[#saved.added + 1] = clone
			end
		elseif obj:IsA("BasePart") and obj.Name ~= "HumanoidRootPart" then
			local target = char:FindFirstChild(obj.Name)
			if target and target:IsA("BasePart") then
				copyPart(target, obj, saved)
			end
		end
	end

	if char == lp.Character then
		applyAnimations(hum, saved)
		protectHum(hum)
	end
	if char == lp.Character and AutoGatlin.RemoveAccessories then
		for _, obj in ipairs(char:GetDescendants()) do
			hideAccessory(obj)
		end
	end
	return true
end

local function restoreMorph()
	for hum, saved in pairs(morphSaved) do
		if hum.Parent then
			local char = hum.Parent
			char:SetAttribute("TDSGatlinMorph", nil)
			for _, obj in ipairs(saved.added) do
				if obj.Parent then
					obj:Destroy()
				end
			end
			for _, entry in ipairs(saved.visuals) do
				if entry.parent.Parent then
					entry.obj.Parent = entry.parent
				end
			end
			for value, original in pairs(saved.scales) do
				if value.Parent then
					value.Value = original
				end
			end
			hum.HipHeight = saved.hipHeight
			for part, props in pairs(saved.parts) do
				if part.Parent then
					if part:IsA("MeshPart") then
						local ok = pcall(part.ApplyMesh, part, props.mesh)
						if not ok then
							part.MeshId = props.meshId
							part.TextureID = props.textureId
						end
					end
					part.Color = props.color
					part.Material = props.material
					part.MaterialVariant = props.materialVariant
					part.Reflectance = props.reflectance
					part.Transparency = props.transparency
					part.Size = props.size
					part.PivotOffset = props.pivotOffset
				end
			end
			for attachment, cf in pairs(saved.attachments) do
				if attachment.Parent then
					attachment.CFrame = cf
				end
			end
			for _, obj in ipairs(saved.objects) do
				obj.Parent = char
			end
			restoreAnimations(hum, saved)
			hum.DisplayName = saved.displayName
			hum.DisplayDistanceType = saved.distance
		end
		saved.storage:Destroy()
	end
	table.clear(morphSaved)
end

local function morphCharacter(char)
	local seq = morphSeq
	task.spawn(function()
		char:WaitForChild("Humanoid", 10)
		if seq ~= morphSeq or not AutoGatlin.MorphEnabled or AutoGatlin.MorphLoadedId ~= AutoGatlin.MorphUserId then
			return
		end

		local callOk, ok, err = pcall(applyMorph, char)
		if seq ~= morphSeq then
			return
		end
		if callOk and ok then
			AutoGatlin.MorphStatus = string.format(
				"Morphed into %s (@%s, %d).",
				AutoGatlin.MorphDisplayName,
				AutoGatlin.MorphName,
				AutoGatlin.MorphUserId
			)
		else
			AutoGatlin.MorphStatus = "Morph failed: " .. tostring(callOk and err or ok)
		end
	end)
end

local function resolveMorphInput(input)
	local userId = tonumber(input)
	if userId then
		userId = math.floor(userId)
		if userId > 0 then
			return userId
		end
		return nil, "Enter a valid player ID."
	end

	local query = input:lower()
	local matches = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr.Name:lower() == query then
			return plr.UserId
		end
		if plr.DisplayName:lower() == query then
			matches[#matches + 1] = plr
		end
	end

	if #matches == 1 then
		return matches[1].UserId
	elseif #matches > 1 then
		return nil, string.format("Display name %q matches multiple players; use a username or ID.", input)
	end

	local ok, id = pcall(Players.GetUserIdFromNameAsync, Players, input)
	if ok and tonumber(id) and id > 0 then
		return math.floor(id)
	elseif ok then
		return nil, string.format("Player %q was not found.", input)
	end
	return nil, "Username lookup failed: " .. tostring(id)
end

local function getMorphIdentity(userId)
	local plr = Players:GetPlayerByUserId(userId)
	if plr then
		return plr.Name, plr.DisplayName, plr.HasVerifiedBadge == true, plr.HasRobloxSubscription == true
	end

	local infoOk, infos = pcall(UserService.GetUserInfosByUserIdsAsync, UserService, { userId })
	local info = infoOk and infos[1]
	if info then
		local name = tostring(info.Username)
		local displayName = tostring(info.DisplayName)
		return name, displayName ~= "" and displayName or name, info.HasVerifiedBadge == true, false
	end

	local nameOk, name = pcall(Players.GetNameFromUserIdAsync, Players, userId)
	if nameOk and tostring(name) ~= "" then
		name = tostring(name)
		return name, name, false, false
	end

	if nameOk then
		return nil, nil, false, false, string.format("User ID %d was not found.", userId)
	end
	return nil, nil, false, false, tostring(name)
end

local function loadMorph()
	morphSeq = morphSeq + 1
	local seq = morphSeq
	local input = AutoGatlin.MorphInput
	if input == "" then
		AutoGatlin.MorphUserId = 0
		AutoGatlin.MorphStatus = "Enter a player ID, username, or server display name."
		return
	end

	AutoGatlin.MorphStatus = string.format("Finding player %q...", input)
	task.spawn(function()
		local userId, findErr = resolveMorphInput(input)
		if seq ~= morphSeq or not AutoGatlin.MorphEnabled then
			return
		end
		if not userId then
			AutoGatlin.MorphStatus = "Player lookup failed: " .. findErr
			return
		end

		AutoGatlin.MorphUserId = userId
		AutoGatlin.MorphStatus = string.format("Loading User ID %d...", userId)
		local name, displayName, verified, plus, infoErr = getMorphIdentity(userId)
		if seq ~= morphSeq or not AutoGatlin.MorphEnabled then
			return
		end

		if not name then
			AutoGatlin.MorphStatus = "Player lookup failed: " .. infoErr
			return
		end

		local descOk, desc = pcall(Players.GetHumanoidDescriptionFromUserIdAsync, Players, userId)
		if seq ~= morphSeq or not AutoGatlin.MorphEnabled then
			if descOk then
				desc:Destroy()
			end
			return
		end
		if not descOk then
			AutoGatlin.MorphStatus = "Avatar lookup failed: " .. tostring(desc)
			return
		end

		local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
		local rigType = hum and hum.RigType or Enum.HumanoidRigType.R15
		local modelOk, template = pcall(Players.CreateHumanoidModelFromDescriptionAsync, Players, desc, rigType)
		if seq ~= morphSeq or not AutoGatlin.MorphEnabled then
			desc:Destroy()
			if modelOk then
				template:Destroy()
			end
			return
		end
		if not modelOk then
			desc:Destroy()
			AutoGatlin.MorphStatus = "Avatar build failed: " .. tostring(template)
			return
		end

		local gatlinOk, gatlinTemplate =
			pcall(Players.CreateHumanoidModelFromDescriptionAsync, Players, desc, Enum.HumanoidRigType.R6)
		if seq ~= morphSeq or not AutoGatlin.MorphEnabled then
			desc:Destroy()
			template:Destroy()
			if gatlinOk then
				gatlinTemplate:Destroy()
			end
			return
		end
		if not gatlinOk then
			desc:Destroy()
			template:Destroy()
			AutoGatlin.MorphStatus = "Gatlin avatar build failed: " .. tostring(gatlinTemplate)
			return
		end

		if AutoGatlin.MorphTemplate then
			AutoGatlin.MorphTemplate:Destroy()
		end
		if AutoGatlin.GatlinMorphTemplate then
			AutoGatlin.GatlinMorphTemplate:Destroy()
		end
		if AutoGatlin.MorphDescription then
			AutoGatlin.MorphDescription:Destroy()
		end
		pcall(desc.SetEmotes, desc, {})
		pcall(desc.SetEquippedEmotes, desc, {})
		AutoGatlin.MorphName = tostring(name)
		AutoGatlin.MorphDisplayName = displayName
		AutoGatlin.MorphVerified = verified
		AutoGatlin.MorphPlus = plus
		AutoGatlin.MorphDescription = desc
		AutoGatlin.MorphTemplate = template
		AutoGatlin.GatlinMorphTemplate = gatlinTemplate
		AutoGatlin.MorphLoadedId = userId
		AutoGatlin.MorphVersion = AutoGatlin.MorphVersion + 1
		syncNames()

		local callOk, ok, err = pcall(applyMorph, lp.Character)
		if seq ~= morphSeq then
			return
		end
		if callOk and ok then
			AutoGatlin.MorphStatus = string.format("Morphed into %s (@%s, %d).", displayName, name, userId)
		else
			AutoGatlin.MorphStatus = "Morph failed: " .. tostring(callOk and err or ok)
		end
	end)
end

local function setGatlinHidden(char, hidden)
	local saved = gatlinHidden[char]
	if hidden then
		if not saved then
			saved = weakKeys()
			gatlinHidden[char] = saved
		end
		for _, obj in ipairs(char:GetDescendants()) do
			if obj:IsA("BasePart") and saved[obj] == nil then
				saved[obj] = obj.LocalTransparencyModifier
				obj.LocalTransparencyModifier = 1
			end
		end
	elseif saved then
		for part, transparency in pairs(saved) do
			if part.Parent then
				part.LocalTransparencyModifier = transparency
			end
		end
		gatlinHidden[char] = nil
	end
end

local function restoreProperty(saved, property)
	for obj, value in pairs(saved) do
		if obj.Parent then
			obj[property] = value
		end
		saved[obj] = nil
	end
end

local function restoreCrosshair()
	restoreProperty(crosshairBg, "BackgroundTransparency")
	restoreProperty(crosshairStroke, "Transparency")
end

local function syncCrosshair()
	local alpha = AutoGatlin.CrosshairTransparency / 100
	if alpha <= 0 then
		restoreCrosshair()
		return
	end

	local gui = lp:FindFirstChildOfClass("PlayerGui")
	local spotlight = gui and gui:FindFirstChild("ReactOverridesSpotlight")
	local canvas = spotlight and spotlight:FindFirstChild("CanvasGroup")
	local root = canvas and canvas:FindFirstChild("inputSink")
	if not root then
		return
	end

	local function apply(obj)
		if obj:IsA("GuiObject") then
			if crosshairBg[obj] == nil then
				crosshairBg[obj] = obj.BackgroundTransparency
			end
			obj.BackgroundTransparency = alpha
		elseif obj:IsA("UIStroke") then
			if crosshairStroke[obj] == nil then
				crosshairStroke[obj] = obj.Transparency
			end
			obj.Transparency = alpha
		end
	end

	apply(root)
	for _, obj in ipairs(root:GetDescendants()) do
		apply(obj)
	end
end

local function findPart(root, names)
	for _, name in ipairs(names) do
		root = root and root:FindFirstChild(name)
	end
	return root
end

local function getGatlinPart(tower, weapon, part)
	local skin = gatlinSkins:FindFirstChild(tower.Model.Name)
	if not skin then
		return
	end

	local names = {}
	local obj = part
	while obj and obj ~= weapon do
		table.insert(names, 1, obj.Name)
		obj = obj.Parent
	end
	if obj ~= weapon then
		return
	end

	local upgrades = skin:FindFirstChild("Upgrades")
	for level = tonumber(tower.Upgrade) or 0, 1, -1 do
		local source = findPart(upgrades and upgrades:FindFirstChild(tostring(level)), names)
		if source and source:IsA("BasePart") then
			return source
		end
	end

	local source = findPart(skin:FindFirstChild("Weapon"), names)
	return source and source:IsA("BasePart") and source or nil
end

local function refreshGatlinVisuals()
	local color = getGatlinColor()
	local stripTexture = color ~= nil or AutoGatlin.ForcefieldGatlin

	for _, tower in ipairs(getTowers()) do
		local model = tower.Model
		local char = model and model:FindFirstChild("Character")
		if char and char:IsA("Model") then
			if
				AutoGatlin.MorphEnabled
				and AutoGatlin.GatlinMorphTemplate
				and char:GetAttribute("TDSGatlinMorph") ~= AutoGatlin.MorphVersion
			then
				local template = AutoGatlin.GatlinMorphTemplate:Clone()
				local scaleOk, scale = pcall(char.GetScale, char)
				if scaleOk then
					pcall(template.ScaleTo, template, scale)
				end
				local callOk, applied = pcall(applyMorph, char, template)
				template:Destroy()
				if callOk and applied then
					char:SetAttribute("TDSGatlinMorph", AutoGatlin.MorphVersion)
				end
			end
			setGatlinHidden(char, AutoGatlin.AnonymousGatlin)
		end

		local weapon = model and model:FindFirstChild("Weapon")
		if weapon then
			for _, obj in ipairs(weapon:GetDescendants()) do
				if obj:IsA("BasePart") then
					local source = getGatlinPart(tower, weapon, obj)
					if color then
						if gatlinColors[obj] == nil then
							gatlinColors[obj] = source and source.Color or obj.Color
						end
						obj.Color = color
					elseif source then
						obj.Color = source.Color
					end
					if stripTexture and obj:IsA("MeshPart") then
						if gatlinTextures[obj] == nil then
							gatlinTextures[obj] = source and source:IsA("MeshPart") and source.TextureID
								or obj.TextureID
						end
						obj.TextureID = ""
					elseif obj:IsA("MeshPart") and source and source:IsA("MeshPart") then
						obj.TextureID = source.TextureID
					end
					if AutoGatlin.ForcefieldGatlin then
						if gatlinMaterials[obj] == nil then
							gatlinMaterials[obj] = source and source.Material or obj.Material
						end
						obj.Material = Enum.Material.ForceField
					elseif source then
						obj.Material = source.Material
					end
				elseif
					obj:IsA("Sound")
					and AutoGatlin.MuteBarrelSpin
					and (obj.Name == "Start" or obj.Name == "Spin" or obj.Name == "Slow")
				then
					if barrelSounds[obj] == nil then
						barrelSounds[obj] = obj.Volume
					end
					obj.Volume = 0
				end
			end
		end
	end

	for char in pairs(gatlinHidden) do
		if not char.Parent then
			gatlinHidden[char] = nil
		end
	end
	for hum, saved in pairs(morphSaved) do
		if not hum.Parent then
			saved.storage:Destroy()
			morphSaved[hum] = nil
		end
	end

	syncCrosshair()
end

local function syncGatlinAppearance()
	local color = getGatlinColor()
	if not color then
		restoreProperty(gatlinColors, "Color")
	end
	if not AutoGatlin.ForcefieldGatlin then
		restoreProperty(gatlinMaterials, "Material")
	end
	if not color and not AutoGatlin.ForcefieldGatlin then
		restoreProperty(gatlinTextures, "TextureID")
	end
	refreshGatlinVisuals()
end

local function loadLuna()
	local confirmed = env.ConfirmLuna
	env.ConfirmLuna = true
	local ok, lib
	for attempt = 1, 5 do
		ok, lib = pcall(function()
			local source = game:HttpGet(
				"https://raw.githubusercontent.com/Nebula-Softworks/Luna-Interface-Suite/refs/heads/master/source.lua",
				true
			)
			source = source:gsub(
				"ColorPickerV%.Color%s*=%s*Color3ToHex%(ColorPickerSettings%.Color%)",
				"ColorPickerV.Color = ColorPickerSettings.Color"
			)

			local chunk, err = loadstring(source)
			if not chunk then
				error(err)
			end
			return chunk()
		end)
		if ok then
			break
		end
		if attempt < 5 then
			task.wait(1)
		end
	end
	env.ConfirmLuna = confirmed
	if not ok then
		error(lib)
	end
	return lib
end

local function statusText()
	local info = AutoGatlin.TargetInfo
	if not info then
		return string.format(
			"%s\n%d/%d Gatling(s) active",
			AutoGatlin.Status,
			AutoGatlin.ActiveCount,
			AutoGatlin.TowerCount
		)
	end

	local eta = info.eta < math.huge and string.format("%.1fs", info.eta) or "--"
	return string.format(
		"%s\n%s | %d/%d HP | group %.1f | exit %d%% / %s | x%d fire | %s\n%d/%d Gatling(s) firing",
		AutoGatlin.Status,
		info.name,
		info.health,
		info.maxHealth,
		info.cluster,
		math.round(info.exitProgress * 100),
		eta,
		info.burst,
		info.reason,
		info.coverage,
		AutoGatlin.TowerCount
	)
end

local kawaiiUi = {}

function kawaiiUi.tab(window, name, icon)
	return window:CreateTab({
		Name = name,
		Icon = icon,
		ImageSource = "Material",
		ShowTitle = true,
	})
end

function kawaiiUi.main(window)
	local main = kawaiiUi.tab(window, "Main", "auto_awesome")
	local recorderUi = main:CreateSection("Strategy Recorder")

	recorderUi:CreateInput({
		Name = "Strategy Name",
		Description = "Used for the saved file and generated strategy.",
		PlaceholderText = "MyStrategy",
		CurrentValue = recorder.name,
		Numeric = false,
		MaxCharacters = 48,
		Enter = false,
		Callback = function(value)
			recorder:SetName(value)
		end,
	}, "StrategyName")

	recorderUi:CreateButton({
		Name = "Start Recorder",
		Description = "Starts a clean recording from this moment.",
		Callback = function()
			recorder:Start()
		end,
	})

	recorderUi:CreateButton({
		Name = "Stop Recorder",
		Description = "Stops recording without clearing captured actions.",
		Callback = function()
			recorder:Stop()
		end,
	})

	recorderUi:CreateButton({
		Name = "Copy Strategy",
		Description = "Copies the generated replay script.",
		Callback = function()
			recorder:Copy()
		end,
	})

	recorderUi:CreateButton({
		Name = "Save Strategy",
		Description = "Saves the generated replay script in auto-strat.",
		Callback = function()
			recorder:Save()
		end,
	})

	recorderUi:CreateButton({
		Name = "Clear Recording",
		Description = "Clears every captured action.",
		Callback = function()
			recorder:Clear()
		end,
	})

	AutoGatlin.RecorderBox = recorderUi:CreateParagraph({
		Title = "Recorder Status",
		Text = recorder:Status(),
	})

	local stacker = main:CreateSection("Tower Sandwich Maker")

	stacker:CreateToggle({
		Name = "AutoStacker :3",
		Description = "Stacks the chosen amount at your next valid tower placement.",
		CurrentValue = AutoGatlin.AutoStacker,
		Callback = function(value)
			AutoGatlin:SetAutoStacker(value)
		end,
	}, "AutoStacker")

	stacker:CreateSlider({
		Name = "Stack Amount",
		Description = "Includes the tower placed by your original click.",
		Range = { 1, 50 },
		Increment = 1,
		CurrentValue = AutoGatlin.StackAmount,
		Callback = function(value)
			AutoGatlin:SetStackAmount(value)
		end,
	}, "StackAmount")

	AutoGatlin.StackPriceBox = stacker:CreateParagraph({
		Title = "Stack Price Calculator",
		Text = AutoGatlin:StackPriceText(),
	})

	local rangePreview = main:CreateSection("Placement Range Preview")
	rangePreview:CreateToggle({
		Name = "Show All Upgrade Ranges",
		Description = "Draws a colored and labeled circle for every unique range while placing.",
		CurrentValue = AutoGatlin.ShowUpgradeRanges,
		Callback = function(value)
			AutoGatlin:SetShowUpgradeRanges(value)
		end,
	}, "ShowUpgradeRanges")

	rangePreview:CreateToggle({
		Name = "Always Show DJ Ranges",
		Description = "Keeps allied DJ aura circles visible at their current skill-adjusted range.",
		CurrentValue = AutoGatlin.AlwaysShowDjRanges,
		Callback = function(value)
			AutoGatlin:SetAlwaysShowDjRanges(value)
		end,
	}, "AlwaysShowDjRanges")

	AutoGatlin.UpgradeRangeBox = rangePreview:CreateParagraph({
		Title = "Upgrade Ranges",
		Text = AutoGatlin.UpgradeRangeStatus,
	})

	local chain = main:CreateSection("Commander Chain")
	chain:CreateToggle({
		Name = "Auto Chain",
		Description = "Rotates Call to Arms once per buff window across your Commanders.",
		CurrentValue = AutoGatlin.AutoCommanderChain,
		Callback = function(value)
			AutoGatlin:SetAutoCommanderChain(value)
		end,
	}, "AutoCommanderChain")

	AutoGatlin.CommanderChainBox = chain:CreateParagraph({
		Title = "Call to Arms",
		Text = AutoGatlin:CommanderChainText(),
	})

	local manager = main:CreateSection("Tower Manager")
	AutoGatlin.TowerManagerBox = manager:CreateParagraph({
		Title = "Selected Tower",
		Text = AutoGatlin:TowerManagerText(),
	})

	manager:CreateButton({
		Name = "Upgrade Selected Tower Type",
		Description = "Fully upgrades every owned tower matching the one you last clicked.",
		Callback = function()
			AutoGatlin:UpgradeSelectedTower()
		end,
	})

	manager:CreateButton({
		Name = "Sell Selected Tower",
		Description = "Sells the owned tower you last clicked.",
		Callback = function()
			AutoGatlin:SellSelectedTower()
		end,
	})

	manager:CreateButton({
		Name = "Upgrade All Towers",
		Description = "Fully upgrades every tower you own while cash allows.",
		Callback = function()
			AutoGatlin:UpgradeAllTowers()
		end,
	})

	manager:CreateButton({
		Name = "Sell All Towers",
		Description = "Press twice within 3 seconds to sell every tower you own.",
		Callback = function()
			AutoGatlin:SellAllTowers()
		end,
	})
end

function kawaiiUi.combat(window)
	local combat = kawaiiUi.tab(window, "Combat", "track_changes")
	local status = combat:CreateParagraph({
		Title = "Live Status",
		Text = statusText(),
	})

	local automation = combat:CreateSection("Automation")
	automation:CreateToggle({
		Name = "Auto Gatlin",
		Description = "Runs the Gatling without taking over your camera.",
		CurrentValue = AutoGatlin.Enabled,
		Callback = function(value)
			AutoGatlin:SetEnabled(value)
		end,
	}, "AutoGatlinEnabled")

	automation:CreateToggle({
		Name = "No Cooldown",
		Description = "Replays validated shots across the selected targets.",
		CurrentValue = AutoGatlin.NoCooldown,
		Callback = function(value)
			AutoGatlin.NoCooldown = value
		end,
	}, "NoCooldown")

	automation:CreateToggle({
		Name = "Auto Reload on Wave Clear",
		CurrentValue = AutoGatlin.AutoReload,
		Callback = function(value)
			AutoGatlin.AutoReload = value
		end,
	}, "AutoReload")

	local targeting = combat:CreateSection("Targeting")
	targeting:CreateToggle({
		Name = "Auto Calibrate",
		CurrentValue = AutoGatlin.AutoCalibrate,
		Callback = function(value)
			AutoGatlin:SetAutoCalibrate(value)
		end,
	}, "AutoCalibrate")

	targeting:CreateToggle({
		Name = "Crowd Control",
		CurrentValue = AutoGatlin.CrowdControl,
		Callback = function(value)
			AutoGatlin.CrowdControl = value
		end,
	}, "CrowdControl")

	targeting:CreateToggle({
		Name = "Target Leads",
		CurrentValue = AutoGatlin.TargetLeads,
		Callback = function(value)
			AutoGatlin:SetTargetLeads(value)
		end,
	}, "TargetLeads")

	targeting:CreateDropdown({
		Name = "Targeting Mode",
		Description = "Used whenever Auto Calibrate is off.",
		Options = { "First", "Last", "Strongest", "Weakest", "Max Efficiency ;3", "Zoom Zoom" },
		CurrentOption = AutoGatlin.Priority,
		MultipleOptions = false,
		Callback = function(value)
			AutoGatlin:SetPriority(value)
		end,
	}, "Priority")

	targeting:CreateSlider({
		Name = "Max Targets Limit",
		Range = { 1, 16 },
		Increment = 1,
		CurrentValue = AutoGatlin.MaxTargets,
		Callback = function(value)
			AutoGatlin:SetMaxTargets(value)
		end,
	}, "MaxTargets")

	targeting:CreateToggle({
		Name = "Prioritize Bosses",
		CurrentValue = AutoGatlin.PrioritizeBosses,
		Callback = function(value)
			AutoGatlin:SetPrioritizeBosses(value)
		end,
	}, "PrioritizeBosses")

	targeting:CreateToggle({
		Name = "Bypass Boss Targeting for Fast Enemies",
		CurrentValue = AutoGatlin.BypassBossForFast,
		Callback = function(value)
			AutoGatlin:SetBypassBossForFast(value)
		end,
	}, "BypassBossForFast")

	return status
end

function kawaiiUi.visuals(window)
	local visuals = kawaiiUi.tab(window, "Visuals", "visibility")
	local espBox = visuals:CreateSection("Zombie ESP")
	espBox:CreateToggle({
		Name = "Show Bullet Lines",
		CurrentValue = AutoGatlin.ShowBulletLines,
		Callback = function(value)
			AutoGatlin:SetBulletLines(value)
		end,
	}, "ShowBulletLines")

	espBox:CreateToggle({
		Name = "Zombie ESP",
		CurrentValue = AutoGatlin.ZombieESP,
		Callback = function(value)
			AutoGatlin:SetZombieESP(value)
		end,
	}, "ZombieESP")

	espBox:CreateToggle({
		Name = "Rainbow ESP Highlight",
		CurrentValue = AutoGatlin.RainbowESP,
		Callback = function(value)
			AutoGatlin:SetRainbowESP(value)
		end,
	}, "RainbowESP")

	espBox:CreateDropdown({
		Name = "Zombie ESP Style",
		Options = { "CSGO" },
		CurrentOption = AutoGatlin.ESPStyle,
		MultipleOptions = false,
		Callback = function(value)
			AutoGatlin:SetESPStyle(value)
		end,
	}, "ESPStyle")

	espBox:CreateSlider({
		Name = "ESP Outline Transparency",
		Range = { 0, 100 },
		Increment = 1,
		CurrentValue = AutoGatlin.ESPOutlineTransparency,
		Callback = function(value)
			AutoGatlin:SetESPOutlineTransparency(value)
		end,
	}, "ESPOutlineTransparency")

	espBox:CreateSlider({
		Name = "Crosshair Transparency",
		Range = { 0, 100 },
		Increment = 1,
		CurrentValue = AutoGatlin.CrosshairTransparency,
		Callback = function(value)
			AutoGatlin:SetCrosshairTransparency(value)
		end,
	}, "CrosshairTransparency")

	local gatlin = visuals:CreateSection("Gatlin")
	gatlin:CreateToggle({
		Name = "Anonymous Gatlin",
		CurrentValue = AutoGatlin.AnonymousGatlin,
		Callback = function(value)
			AutoGatlin:SetAnonymousGatlin(value)
		end,
	}, "AnonymousGatlin")

	gatlin:CreateToggle({
		Name = "Rainbow Gatling Gun",
		CurrentValue = AutoGatlin.RainbowGatlin,
		Callback = function(value)
			AutoGatlin:SetRainbowGatlin(value)
		end,
	}, "RainbowGatlin")

	gatlin:CreateToggle({
		Name = "Custom Color Gatling Gun",
		CurrentValue = AutoGatlin.CustomGatlin,
		Callback = function(value)
			AutoGatlin:SetCustomGatlin(value)
		end,
	}, "CustomGatlin")

	gatlin:CreateToggle({
		Name = "Forcefield Gatling Gun",
		CurrentValue = AutoGatlin.ForcefieldGatlin,
		Callback = function(value)
			AutoGatlin:SetForcefieldGatlin(value)
		end,
	}, "ForcefieldGatlin")

	gatlin:CreateSlider({
		Name = "Rainbow Speed Scale",
		Range = { 1, 100 },
		Increment = 1,
		CurrentValue = AutoGatlin.RainbowSpeed,
		Callback = function(value)
			AutoGatlin:SetRainbowSpeed(value)
		end,
	}, "RainbowSpeed")

	gatlin:CreateColorPicker({
		Name = "Custom Gatling Color",
		Color = AutoGatlin.GatlinColor,
		Callback = function(color)
			AutoGatlin:SetGatlinColor(color)
		end,
	}, "GatlinColor")
end

function kawaiiUi.audio(window)
	local audio = kawaiiUi.tab(window, "Audio", "volume_up")
	local hitAudio = audio:CreateSection("Hit Sounds")
	hitAudio:CreateSlider({
		Name = "Hit Sound Volume",
		Range = { 0, 100 },
		Increment = 1,
		CurrentValue = AutoGatlin.HitSoundVolume,
		Callback = function(value)
			AutoGatlin:SetHitSoundVolume(value)
		end,
	}, "HitSoundVolume")

	hitAudio:CreateInput({
		Name = "Custom Hit Sound ID",
		Description = "Leave blank to keep TDS's native sound.",
		PlaceholderText = "Enter Sound ID",
		CurrentValue = AutoGatlin.HitSoundId,
		Numeric = true,
		MaxCharacters = 16,
		Enter = true,
		Callback = function(value)
			AutoGatlin:SetHitSoundId(value)
		end,
	}, "HitSoundId")

	local barrelAudio = audio:CreateSection("Gatling Audio")
	barrelAudio:CreateToggle({
		Name = "Mute Barrel Spinning Sound",
		CurrentValue = AutoGatlin.MuteBarrelSpin,
		Callback = function(value)
			AutoGatlin:SetMuteBarrelSpin(value)
		end,
	}, "MuteBarrelSpin")
end

function kawaiiUi.protection(window)
	local protection = kawaiiUi.tab(window, "Protection", "shield")
	local status = protection:CreateParagraph({
		Title = "Player Morph",
		Text = AutoGatlin.MorphStatus,
	})

	local identity = protection:CreateSection("Identity")
	identity:CreateToggle({
		Name = "Hide Username",
		CurrentValue = AutoGatlin.HideUsername,
		Callback = function(value)
			AutoGatlin:SetHideUsername(value)
		end,
	}, "HideUsername")

	identity:CreateInput({
		Name = "Replacement Username",
		Description = "Leave blank to remove your name completely.",
		PlaceholderText = "Blank = hidden",
		CurrentValue = AutoGatlin.ProtectedName,
		Numeric = false,
		MaxCharacters = 24,
		Enter = false,
		Callback = function(value)
			AutoGatlin:SetProtectedName(value)
		end,
	}, "ProtectedName")

	local avatar = protection:CreateSection("Avatar")
	avatar:CreateToggle({
		Name = "Remove Accessories",
		CurrentValue = AutoGatlin.RemoveAccessories,
		Callback = function(value)
			AutoGatlin:SetRemoveAccessories(value)
		end,
	}, "RemoveAccessories")

	avatar:CreateInput({
		Name = "Player ID or Username",
		Description = "Display names work for players in your server.",
		PlaceholderText = "ID, username, or server display name",
		CurrentValue = AutoGatlin.MorphInput,
		Numeric = false,
		MaxCharacters = 32,
		Enter = true,
		Callback = function(value)
			AutoGatlin:SetMorphInput(value)
		end,
	}, "MorphUserId")

	avatar:CreateToggle({
		Name = "Morph into Player",
		CurrentValue = AutoGatlin.MorphEnabled,
		Callback = function(value)
			AutoGatlin:SetMorphEnabled(value)
		end,
	}, "MorphEnabled")

	return status
end

function kawaiiUi.settings(window)
	local settings = kawaiiUi.tab(window, "Settings", "settings")
	local interface = settings:CreateSection("Interface")
	interface:CreateBind({
		Name = "UI Key",
		Description = "Shows Luna again after the close button hides it.",
		CurrentBind = "K",
		HoldToInteract = false,
		Callback = function() end,
		OnChangedCallback = function(bind)
			window.Bind = bind
		end,
	}, "UIKey")

	interface:CreateButton({
		Name = "Unload TDS Tools",
		Description = "Stops every feature and removes the interface.",
		Callback = function()
			task.defer(function()
				AutoGatlin:Stop()
			end)
		end,
	})

	settings:BuildThemeSection()
	settings:BuildConfigSection()
end

function kawaiiUi.build(seq)
	local lib = loadLuna()
	if seq ~= uiSeq or not AutoGatlin.Running then
		pcall(lib.Destroy, lib)
		return false
	end

	Luna = lib
	AutoGatlin.Luna = lib

	local window = lib:CreateWindow({
		Name = "TDS Tools",
		Subtitle = "Mastered by wittle kitty N",
		LogoID = "6031097225",
		LoadingEnabled = false,
		ConfigSettings = {
			ConfigFolder = "TDSTools",
		},
		KeySystem = false,
	})

	AutoGatlin.Window = window
	kawaiiUi.main(window)
	statusBox = kawaiiUi.combat(window)
	kawaiiUi.visuals(window)
	kawaiiUi.audio(window)
	protectionStatus = kawaiiUi.protection(window)
	kawaiiUi.settings(window)

	AutoGatlin.UIError = nil
	AutoGatlin.UIReady = true
	lib:LoadAutoloadConfig()

	if seq ~= uiSeq or not AutoGatlin.Running then
		return false
	end

	task.spawn(function()
		task.wait(0.25)
		while seq == uiSeq and AutoGatlin.Running and AutoGatlin.UIReady do
			statusBox:Set({
				Title = "Live Status",
				Text = statusText(),
			})
			protectionStatus:Set({
				Title = "Player Morph",
				Text = AutoGatlin.MorphStatus,
			})
			if AutoGatlin.StackPriceBox then
				AutoGatlin.StackPriceBox:Set({
					Title = "Stack Price Calculator",
					Text = AutoGatlin:StackPriceText(),
				})
			end
			if AutoGatlin.TowerManagerBox then
				AutoGatlin.TowerManagerBox:Set({
					Title = "Selected Tower",
					Text = AutoGatlin:TowerManagerText(),
				})
			end
			if AutoGatlin.CommanderChainBox then
				AutoGatlin.CommanderChainBox:Set({
					Title = "Call to Arms",
					Text = AutoGatlin:CommanderChainText(),
				})
			end
			if AutoGatlin.UpgradeRangeBox then
				AutoGatlin.UpgradeRangeBox:Set({
					Title = "Upgrade Ranges",
					Text = AutoGatlin.UpgradeRangeStatus,
				})
			end
			if AutoGatlin.RecorderBox then
				AutoGatlin.RecorderBox:Set({
					Title = "Recorder Status",
					Text = recorder:Status(),
				})
			end
			task.wait(0.15)
		end
	end)
	return true
end

function kawaiiUi.destroy()
	uiSeq = uiSeq + 1
	AutoGatlin.UILoading = false
	AutoGatlin.UIReady = false
	AutoGatlin.StackPriceBox = nil
	AutoGatlin.TowerManagerBox = nil
	AutoGatlin.CommanderChainBox = nil
	AutoGatlin.UpgradeRangeBox = nil
	AutoGatlin.RecorderBox = nil
	statusBox = nil
	protectionStatus = nil

	if AutoGatlin.Window then
		pcall(function()
			AutoGatlin.Window.State = true
		end)
	end
	if Luna then
		pcall(Luna.Destroy, Luna)
	end

	Luna = nil
	AutoGatlin.Luna = nil
	AutoGatlin.Window = nil
end

local gatlingGremlin = {}

function gatlingGremlin.fitTowers(towers, npc)
	if #towers < 2 then
		return towers
	end

	local ranked = table.clone(towers)
	table.sort(ranked, function(a, b)
		local aDamage = math.max(a.Damage, 0)
		local bDamage = math.max(b.Damage, 0)
		if aDamage ~= bDamage then
			return aDamage > bDamage
		end
		if a.FPS ~= b.FPS then
			return a.FPS
		end
		return a.Ammo > b.Ammo
	end)

	local wanted = {}
	local damage = 0
	for _, tower in ipairs(ranked) do
		wanted[#wanted + 1] = tower
		damage = damage + math.max(tower.Damage, 0)
		if damage >= npc.Health then
			break
		end
	end
	return wanted
end

function gatlingGremlin.reloadOnClear(towers)
	local wave = gameState.Wave
	AutoGatlin.Wave = wave

	local state = ReplicatedStorage:FindFirstChild("State")
	local timer = state and state:FindFirstChild("Timer")
	local time = timer and timer:FindFirstChild("Time")
	if not time or wave <= 0 or gameState.FinalWave or reloadedWave == wave or not AutoGatlin.AutoReload then
		return false
	end

	local lowAmmo = false
	local reloadTime = 0
	local reloading = false
	for _, tower in ipairs(towers) do
		local maxAmmo = tower.MaxAmmo or tower.Ammo
		local low = tower.Ammo <= maxAmmo * 0.6
		lowAmmo = lowAmmo or low
		reloading = reloading or tower.Reloading

		if low then
			local attrs = tower.Stats and tower.Stats.Attributes
			reloadTime = math.max(reloadTime, tonumber(attrs and attrs.ReloadTime) or 0)
		end
	end

	if not lowAmmo or time.Value > math.ceil(reloadTime + 1) then
		return false
	end
	reloadedWave = wave

	stopFiring()
	if not reloading then
		reloadRemote:FireServer()
	end

	AutoGatlin.Status = "Wave clear - reloading"
	return true
end

function gatlingGremlin.targetStep()
	if not AutoGatlin.Enabled then
		return 0.1
	end

	local towers = getTowers()
	if #towers == 0 then
		AutoGatlin.Tower = nil
		AutoGatlin.ActiveCount = 0
		clearTarget()
		AutoGatlin.Status = "Waiting for Gatling Gun"
		return 0.25
	end

	if not bindNet() then
		AutoGatlin.Tower = towers[1]
		AutoGatlin.ActiveCount = 0
		clearTarget()
		AutoGatlin.Status = "Waiting for Gatling network"
		return 0.1
	end

	local now = os.clock()
	local prevEntry = current
	local prevNpc = prevEntry and prevEntry.npc
	if turnDone and prevEntry then
		resting[prevNpc] = now + getRest(prevEntry)
	end

	local locked = AutoGatlin.ManualTarget
	if locked and (not locked.Model.Parent or not locked:IsAlive()) then
		AutoGatlin.ManualTarget = nil
		AutoGatlin.ManualTargetName = ""
		locked = nil
	end

	local frostSpirit = false
	local iceBeacon = false
	if not locked then
		for model, npc in pairs(getNpcs()) do
			if model.Parent and npc.Type ~= "Units" and npc:IsAlive() then
				frostSpirit = frostSpirit or npc.Name == "Frost Spirit"
				iceBeacon = iceBeacon or npc.Name == "Ice Beacon"
			end
		end
	end
	local beaconsOnly = not locked and frostSpirit and iceBeacon
	local entry = selectGroup(towers, locked or (not turnDone and prevNpc or nil), locked, beaconsOnly)
	if entry then
		entry.towers = gatlingGremlin.fitTowers(entry.towers, entry.npc)
		entry.coverage = #entry.towers
	end
	if entry and (turnDone or entry.npc ~= prevNpc) then
		turnDone = false
		turnHits = 0
		turnShots = 0
		AutoGatlin.TargetQuota = getQuota(entry)
	elseif not entry then
		AutoGatlin.TargetQuota = 1
	end

	local wanted = entry and entry.towers or towers
	local changed = syncTowers(towers, wanted)
	AutoGatlin.Tower = wanted[1] or towers[1]
	current = entry
	AutoGatlin.Target = current and current.npc.Model or nil
	AutoGatlin.ActiveCount = 0
	for _, tower in ipairs(towers) do
		if tower.FPS then
			AutoGatlin.ActiveCount = AutoGatlin.ActiveCount + 1
		end
	end

	local clearReload = gatlingGremlin.reloadOnClear(towers)
	if current then
		current.burst = AutoGatlin.NoCooldown and AutoGatlin.ReplayBurst or getBurst(wanted, current.npc)
		AutoGatlin.FireBurst = current.burst
		AutoGatlin.TargetInfo = {
			name = current.npc.Name,
			health = current.npc.Health,
			maxHealth = current.maxHealth,
			cluster = current.cluster,
			exitProgress = current.exitProgress,
			eta = current.eta,
			burst = current.burst,
			reason = current.reason,
			score = current.score,
			coverage = current.coverage,
			candidates = current.candidates,
			quota = AutoGatlin.TargetQuota,
			hits = turnHits,
			shots = turnShots,
		}
		if changed then
			AutoGatlin.Status = "Syncing Gatlings"
		end
	else
		AutoGatlin.TargetInfo = nil
		if not clearReload then
			local reloading = false
			for _, tower in ipairs(towers) do
				reloading = reloading or tower.Reloading or tower.Ammo <= 0
			end

			if reloading then
				AutoGatlin.Status = "Reloading"
			elseif AutoGatlin.ActiveCount > 0 then
				AutoGatlin.Status = "Waiting for target"
			else
				AutoGatlin.Status = "Activating"
			end
		end
	end

	return changed and 0.05 or 0.02
end

function gatlingGremlin.getActiveTowers(towers, entry)
	local wanted = {}
	for _, tower in ipairs(entry.towers) do
		wanted[tower] = true
	end

	local active = {}
	local syncing = false
	AutoGatlin.ActiveCount = 0

	for _, tower in ipairs(towers) do
		if tower.FPS then
			AutoGatlin.ActiveCount = AutoGatlin.ActiveCount + 1
			if wanted[tower] then
				active[#active + 1] = tower
			else
				syncing = true
			end
		elseif wanted[tower] then
			syncing = true
		end
	end

	return active, syncing
end

function gatlingGremlin.getReloadState(towers)
	local needed = false
	local reloading = false
	for _, tower in ipairs(towers) do
		needed = needed or tower.Ammo <= 0
		reloading = reloading or tower.Reloading
	end
	return needed, reloading
end

function gatlingGremlin.fireStep()
	if not AutoGatlin.Enabled then
		return 0.1
	end

	local towers = getTowers()
	if #towers == 0 then
		AutoGatlin.ActiveCount = 0
		stopFiring()
		return 0.1
	end

	if not bindNet() then
		stopFiring()
		AutoGatlin.Status = "Waiting for Gatling network"
		return 0.1
	end

	local entry = current
	local npc = entry and entry.npc
	local hitbox = npc and (npc.Hitbox or npc.PrimaryPart)
	if not (npc and hitbox and npc:IsAlive()) then
		local now = os.clock()
		if firing and now < fireHoldUntil then
			return false
		end
		if now >= relockUntil then
			stopFiring()
		end
		return 0.01
	end

	local active, syncing = gatlingGremlin.getActiveTowers(towers, entry)

	if syncing or #active ~= #entry.towers then
		stopFiring()
		AutoGatlin.Status = "Syncing Gatlings"
		return 0.03
	end

	local needsReload, reloading = gatlingGremlin.getReloadState(active)

	if needsReload or reloading then
		stopFiring()
		AutoGatlin.Status = "Reloading"

		if needsReload and not reloading then
			reloadRemote:FireServer()
			return 0.25
		end

		return 0.08
	end

	local pos = hitbox.Position
	for _, tower in ipairs(active) do
		if not canHit(tower, npc) then
			stopFiring()
			return 0.03
		end
	end

	local endpoint = getAimPoint(hitbox, npc, active[1])
	if not endpoint then
		AutoGatlin.Status = "Syncing target"
		return false
	end

	local now = os.clock()
	fireHoldUntil = now + 0.4
	aimTowers(active, endpoint)
	local changedTarget = aimedNpc ~= npc
	if changedTarget then
		aimedNpc = npc
		lastFireSync = nil
	end
	if changedTarget or now - lastAim >= 0.05 then
		aimRemote:FireServer(endpoint)
		lastAim = now
	end

	local ready = false
	for _, tower in ipairs(active) do
		ready = ready or not tower.Minigun or tower.CanFire
	end

	if AutoGatlin.ShowBulletLines and hitSeq > drawnHitSeq then
		markShots(active, pos)
		drawnHitSeq = hitSeq
	end

	if ready and not checkHits(active, npc) then
		return 0.01
	end
	if ready and hitWatch.npc == npc and hitWatch.awaiting then
		return false
	end

	local confirmed = ready and hitWatch.npc == npc and hitWatch.confirmed

	local sync = Workspace:GetAttribute("Sync")
	if AutoGatlin.NoCooldown and sync == lastFireSync then
		return false
	end
	lastFireSync = sync

	local burst
	if AutoGatlin.NoCooldown then
		local shots = buildReplayShots(entry, active, npc, confirmed, sync, now)
		burst = fireReplayShots(shots, active, endpoint, ready, confirmed, now)
	else
		burst = getBurst(active, npc)
		for _ = 1, burst do
			fireRemote:FireServer(endpoint, sync, Workspace:GetServerTimeNow())
		end
	end

	AutoGatlin.FireBurst = burst
	if ready then
		recordShots(burst)
	end

	firing = true
	AutoGatlin.Status = string.format("Firing %d Gatlings x%d shots", #active, burst)

	if AutoGatlin.NoCooldown then
		return false
	end

	local cooldown = 0.03
	for _, tower in ipairs(active) do
		cooldown = math.max(cooldown, tower:GetCooldown())
	end
	return cooldown
end

function AutoGatlin:SetHideUsername(value)
	local enabled = value == true
	if self.HideUsername == enabled then
		syncNames()
		return self
	end

	self.HideUsername = enabled
	syncNames()
	return self
end

function AutoGatlin:SetProtectedName(value)
	self.ProtectedName = tostring(value or ""):sub(1, 32)
	if self.HideUsername then
		syncNames()
	end
	return self
end

function AutoGatlin:SetRemoveAccessories(value)
	local enabled = value == true
	if self.RemoveAccessories == enabled then
		if enabled then
			enableAccessoryPrivacy()
		else
			disableAccessoryPrivacy()
		end
		return self
	end

	self.RemoveAccessories = enabled
	if enabled then
		enableAccessoryPrivacy()
	else
		disableAccessoryPrivacy()
	end
	return self
end

function AutoGatlin:SetMorphInput(value)
	local input = tostring(value or ""):match("^%s*(.-)%s*$"):sub(1, 32)
	self.MorphInput = input
	local userId = tonumber(input)
	if userId then
		self.MorphUserId = math.max(math.floor(userId), 0)
	elseif input == "" then
		self.MorphUserId = 0
	end
	if self.MorphEnabled then
		loadMorph()
	end
	return self
end

AutoGatlin.SetMorphUserId = AutoGatlin.SetMorphInput

function AutoGatlin:SetAnonymousGatlin(value)
	self.AnonymousGatlin = value == true
	if self.AnonymousGatlin then
		refreshGatlinVisuals()
	else
		for char in pairs(gatlinHidden) do
			setGatlinHidden(char, false)
		end
	end
	return self
end

function AutoGatlin:SetRainbowGatlin(value)
	self.RainbowGatlin = value == true
	syncGatlinAppearance()
	return self
end

function AutoGatlin:SetCustomGatlin(value)
	self.CustomGatlin = value == true
	syncGatlinAppearance()
	return self
end

function AutoGatlin:SetGatlinColor(value)
	if typeof(value) ~= "Color3" then
		return self
	end

	self.GatlinColor = value
	updateGatlinColors()
	return self
end

function AutoGatlin:SetForcefieldGatlin(value)
	self.ForcefieldGatlin = value == true
	syncGatlinAppearance()
	return self
end

function AutoGatlin:SetRainbowSpeed(value)
	self.RainbowSpeed = math.clamp(tonumber(value) or 50, 1, 100)
	return self
end

function AutoGatlin:SetESPOutlineTransparency(value)
	self.ESPOutlineTransparency = math.clamp(tonumber(value) or 0, 0, 100)
	return self
end

function AutoGatlin:SetCrosshairTransparency(value)
	self.CrosshairTransparency = math.clamp(tonumber(value) or 0, 0, 100)
	syncCrosshair()
	return self
end

function AutoGatlin:SetHitSoundVolume(value)
	self.HitSoundVolume = math.clamp(tonumber(value) or 0, 0, 100)
	syncHitSound()
	return self
end

function AutoGatlin:SetHitSoundId(value)
	self.HitSoundId = tostring(value or ""):match("%d+") or ""
	syncHitSound()
	return self
end

function AutoGatlin:SetMuteBarrelSpin(value)
	self.MuteBarrelSpin = value == true
	if self.MuteBarrelSpin then
		refreshGatlinVisuals()
	else
		restoreProperty(barrelSounds, "Volume")
	end
	return self
end

function AutoGatlin:SetMorphEnabled(value)
	local enabled = value == true
	if self.MorphEnabled == enabled and enabled then
		if not morphConn then
			morphConn = lp.CharacterAdded:Connect(morphCharacter)
		end
		if self.MorphLoadedId ~= self.MorphUserId then
			loadMorph()
		end
		return self
	end

	self.MorphEnabled = enabled
	if enabled then
		morphConn = lp.CharacterAdded:Connect(morphCharacter)
		loadMorph()
		return self
	end

	morphSeq = morphSeq + 1
	if morphConn then
		morphConn:Disconnect()
		morphConn = nil
	end

	local restored = pcall(restoreMorph)
	if self.MorphTemplate then
		self.MorphTemplate:Destroy()
		self.MorphTemplate = nil
	end
	if self.GatlinMorphTemplate then
		self.GatlinMorphTemplate:Destroy()
		self.GatlinMorphTemplate = nil
	end
	if self.MorphDescription then
		self.MorphDescription:Destroy()
		self.MorphDescription = nil
	end
	self.MorphName = ""
	self.MorphDisplayName = ""
	self.MorphVerified = false
	self.MorphPlus = false
	self.MorphLoadedId = 0
	self.MorphStatus = restored and "Original avatar restored." or "Avatar restore failed."
	syncNames()
	return self
end

function AutoGatlin:SetTargetLeads(value)
	self.TargetLeads = value == true

	if not self.TargetLeads and current and hasLead(current.npc) then
		stopFiring()
		clearTarget()
	end

	return self
end

function AutoGatlin:SetAutoCalibrate(value)
	self.AutoCalibrate = value == true
	stopFiring()
	clearTarget()
	return self
end

function AutoGatlin:SetPriority(value)
	local mode = tostring(value)
	if mode == "Max Pierce" or mode == "Crowd Control" then
		mode = "Max Efficiency ;3"
	elseif mode == "Speed" then
		mode = "Zoom Zoom"
	end

	self.Priority = mode
	stopFiring()
	clearTarget()
	return self
end

function AutoGatlin:SetPrioritizeBosses(value)
	self.PrioritizeBosses = value == true
	stopFiring()
	clearTarget()
	return self
end

function AutoGatlin:SetBypassBossForFast(value)
	self.BypassBossForFast = value == true
	stopFiring()
	clearTarget()
	return self
end

function AutoGatlin:SetMaxTargets(value)
	self.MaxTargets = math.clamp(math.floor(tonumber(value) or 1), 1, 16)
	return self
end

function AutoGatlin:SetBulletLines(value)
	self.ShowBulletLines = value == true
	if self.ShowBulletLines then
		drawnHitSeq = hitSeq
	else
		clearTracers()
	end
	return self
end

function AutoGatlin:SetZombieESP(value)
	self.ZombieESP = value == true
	if not self.ZombieESP then
		clearEsp()
	end
	return self
end

function AutoGatlin:SetRainbowESP(value)
	self.RainbowESP = value == true
	if not self.RainbowESP then
		clearHighlights()
	end
	return self
end

function AutoGatlin:SetESPStyle(value)
	if espStyles[value] then
		self.ESPStyle = value
		clearEsp()
	end
	return self
end

function AutoGatlin:SetEnabled(value)
	local enabled = value == true
	if self.Enabled == enabled then
		return self
	end

	self.Enabled = enabled

	if self.Enabled then
		self.Status = "Starting"
		return self
	end

	stopFiring()
	clearTarget()
	resetHitWatch()
	self.Status = "Disabled"
	releaseTowers()

	return self
end

function AutoGatlin:LockTargetFromPart(part)
	if typeof(part) ~= "Instance" then
		return false
	end

	local obj = part
	local npcs = getNpcs()
	while obj and obj ~= Workspace do
		local npc = npcs[obj]
		if npc and npc.Type ~= "Units" and npc:IsAlive() then
			self.ManualTarget = npc
			self.ManualTargetName = tostring(npc.Name)
			stopFiring()
			clearTarget()
			resetHitWatch()
			self.Status = "Target locked: " .. self.ManualTargetName
			return true
		end
		obj = obj.Parent
	end
	return false
end

function AutoGatlin:ClearTargetLock()
	if not self.ManualTarget then
		return self
	end

	self.ManualTarget = nil
	self.ManualTargetName = ""
	stopFiring()
	clearTarget()
	resetHitWatch()
	self.Status = self.Enabled and "Finding target" or "Disabled"
	return self
end

function AutoGatlin:ParseCash(text)
	local clean = tostring(text or ""):upper():gsub(",", "")
	local amount = tonumber(clean:match("%d+%.?%d*"))
	if not amount then
		return nil
	end

	local suffix = clean:match("[KMBT]")
	local scale = suffix == "K" and 1e3 or suffix == "M" and 1e6 or suffix == "B" and 1e9 or suffix == "T" and 1e12 or 1
	return math.round(amount * scale)
end

function AutoGatlin:FormatCash(value)
	if value == math.huge then
		return "$∞"
	end

	local text = tostring(math.max(0, math.round(tonumber(value) or 0)))
	text = text:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
	return "$" .. text
end

function AutoGatlin:GetSelectedStackTower()
	local ok, controller = pcall(require, ReplicatedStorage.Client.Controllers.Game.NewPlacementController)
	if not ok or not controller.Active then
		return nil
	end

	local loaded, store = pcall(require, ReplicatedStorage.Client.Interfaces.Stores.Game.UpgradesStore)
	local state = loaded and store.getState()
	return type(state) == "table" and type(state.tower) == "string" and state.tower or nil
end

function AutoGatlin:GetTowerPrice(towerName, fallback)
	local ok, cache = pcall(require, ReplicatedStorage.Client.Modules.Cache)
	local equipped = ok and cache("Equipped.Troops"):GetValue()
	local hotbar = lp.PlayerGui:FindFirstChild("ReactUniversalHotbar")
	local frame = hotbar and hotbar:FindFirstChild("Frame")
	local troops = frame and frame:FindFirstChild("troops")

	if type(equipped) == "table" and troops then
		for slot, name in pairs(equipped) do
			if name == towerName then
				local entry = troops:FindFirstChild(tostring(slot))
				local content = entry and entry:FindFirstChild("content")
				local cost = content and content:FindFirstChild("Cost")
				local price = cost and self:ParseCash(cost.Text)
				if price then
					return price
				end
			end
		end
	end

	return tonumber(fallback) or 0
end

function AutoGatlin:GetStackInfo(towerName)
	local name = towerName or self:GetSelectedStackTower()
	local requested = math.clamp(math.floor(tonumber(self.StackAmount) or 1), 1, 50)
	local info = {
		name = name,
		requested = requested,
		count = requested,
		placed = 0,
		price = 0,
		total = 0,
	}
	if not name then
		return info
	end

	local ok, assetLib = pcall(require, ReplicatedStorage.Shared.Modules.Asset)
	local loaded, asset = false, nil
	if ok then
		loaded, asset = pcall(assetLib, "Troops", name)
	end
	local stats = loaded and asset.Stats
	local defaults = stats and stats.Default and stats.Default.Defaults
	info.price = self:GetTowerPrice(name, defaults and defaults.Price)

	local limit = defaults and tonumber(defaults.Limit)
	if limit and limit > 0 then
		info.limit = limit
		for _, model in ipairs(Workspace.Towers:GetChildren()) do
			local tower = towerLib.getTowerByModel(model)
			if tower and tower.OwnerId == lp.UserId and tower.TowerName == name and tower:IsAlive() then
				info.placed = info.placed + 1
			end
		end
		info.count = math.min(requested, math.max(limit - info.placed, 0))
	end

	info.total = info.price * info.count
	return info
end

function AutoGatlin:StackPriceText()
	local info = self:GetStackInfo()
	if not info.name then
		return "Select a tower to see the snack bill :3"
	end

	local bill = string.format(
		"%s\n%s each × %d = %s",
		info.name,
		self:FormatCash(info.price),
		info.count,
		self:FormatCash(info.total)
	)
	if not info.limit then
		return bill
	end

	return string.format(
		"%s\nRequested %d | placing %d\nTower cap %d | already placed %d",
		bill,
		info.requested,
		info.count,
		info.limit,
		info.placed
	)
end

function AutoGatlin:GetSkillRangeBonus()
	local rulesOk, rules = pcall(require, ReplicatedStorage.Shared.Modules.GameRules)
	local skillsOk, skills = pcall(require, ReplicatedStorage.Shared.Modules.SkillsUtil)
	local node = enums.SkillTreeNode.EnhancedOptics
	if not rulesOk or not skillsOk or not node then
		return 0
	end

	local hasOk, hasSkill = pcall(rules.HasSkill, node)
	if not hasOk or not hasSkill then
		return 0
	end

	local ok, bonus = pcall(skills.skillEval, lp, node)
	return ok and math.max(0, tonumber(bonus) or 0) or 0
end

function AutoGatlin:IsGoldenTower(towerName)
	local ok, cache = pcall(require, ReplicatedStorage.Client.Modules.Cache)
	if not ok then
		return false
	end

	local inventory = cache("Inventory.Troops"):GetValue()
	local tower = type(inventory) == "table" and inventory[towerName]
	return type(tower) == "table" and tower.GoldenPerks == true
end

function AutoGatlin:GetTowerStats(asset, golden)
	local all = asset and asset.Stats
	if not all then
		return nil
	end
	if not golden then
		return all.Default
	end

	local stats = all.Golden or all.GoldenPerks or asset.Golden or asset.GoldenPerks
	if type(stats) == "table" then
		stats = stats.Stats or stats
		stats = stats.Default or stats
		if stats.Defaults then
			return stats
		end
	end
	return all.Default
end

function AutoGatlin:GetObservedTowerRanges(towerName, golden)
	local key = towerName .. ":" .. tostring(golden)
	local now = os.clock()
	if self.RangeSampleKey == key and self.RangeSample and now - (self.RangeSampleAt or 0) < 0.2 then
		return self.RangeSample, self.RangeSampleSig
	end

	local ranges = {}
	local folder = Workspace:FindFirstChild("Towers")
	if folder then
		for _, model in ipairs(folder:GetChildren()) do
			local tower = towerLib.getTowerByModel(model)
			if
				tower
				and tower.OwnerId == lp.UserId
				and tower.TowerName == towerName
				and tower:IsAlive()
				and (tower.GoldenPerks == true) == golden
			then
				local level = math.max(0, math.floor(tonumber(tower.Replicator:Get("Upgrade")) or 0))
				local range = tonumber(tower.Replicator:Get("Range"))
				if range and range > 0 then
					ranges[level] = range
				end
			end
		end
	end

	local parts = {}
	for level, range in pairs(ranges) do
		parts[#parts + 1] = string.format("%d:%g", level, range)
	end
	table.sort(parts)

	self.RangeSampleKey = key
	self.RangeSample = ranges
	self.RangeSampleSig = table.concat(parts, "|")
	self.RangeSampleAt = now
	return ranges, self.RangeSampleSig
end

function AutoGatlin:GetDjBuffPercent(tower)
	local asset = tower and tower.Asset
	if not asset or not asset.Stats then
		local ok, assetLib = pcall(require, ReplicatedStorage.Shared.Modules.Asset)
		local loaded
		if ok then
			loaded, asset = pcall(assetLib, "Troops", "DJ Booth")
		end
		if not loaded then
			return 0, "Purple"
		end
	end

	local stats = self:GetTowerStats(asset, tower.GoldenPerks == true)
	if not stats or not stats.Defaults then
		return 0, "Purple"
	end

	local track = tostring(tower.Track or tower.Replicator:Get("Track") or "Purple")
	local level = math.max(0, math.floor(tonumber(tower.Upgrade or tower.Replicator:Get("Upgrade")) or 0))
	local buff = 0
	for index = 0, level do
		local attrs
		if index == 0 then
			attrs = stats.Defaults.Attributes
		else
			local upgrade = stats.Upgrades and stats.Upgrades[index]
			attrs = upgrade and upgrade.Stats and upgrade.Stats.Attributes
		end

		local trackBuffs = attrs and attrs[track .. "TrackBuffs"]
		local range = trackBuffs and tonumber(trackBuffs.Range)
		if range then
			buff = range
		end
	end
	return math.max(0, buff), track
end

function AutoGatlin:GetDjs(force)
	local now = os.clock()
	if not force and self.DjCache and now - (self.DjCacheAt or 0) < 0.2 then
		return self.DjCache
	end

	local localTeam
	local playerOk, playerLib = pcall(require, ReplicatedStorage.Client.Modules.Replicators.PlayerReplicator)
	if playerOk then
		local got, player = pcall(playerLib.GetLocalPlayerRaw)
		localTeam = got and player and player.Team
	end

	local list = {}
	local folder = Workspace:FindFirstChild("Towers")
	if folder then
		for _, model in ipairs(folder:GetChildren()) do
			local tower = towerLib.getTowerByModel(model)
			local alive = tower and tower.TowerName == "DJ Booth" and tower:IsAlive()
			local allied = alive
				and ((localTeam ~= nil and tostring(tower.Team) == tostring(localTeam)) or tower.OwnerId == lp.UserId)
			if allied then
				local ok, radius = pcall(tower.GetRange, tower)
				local buff, track = self:GetDjBuffPercent(tower)
				if ok and tonumber(radius) and radius > 0 then
					list[#list + 1] = {
						tower = tower,
						model = model,
						uid = tostring(tower.Replicator:Get("UID") or model),
						level = math.max(0, tonumber(tower.Upgrade) or 0),
						track = track,
						buff = buff,
						radius = radius,
						position = tower.BottomPosition or model:GetPivot().Position,
					}
				end
			end
		end
	end

	self.DjCache = list
	self.DjCacheAt = now
	return list
end

function AutoGatlin:GetDjRangeBuff(position, towerName)
	if towerName == "DJ Booth" or typeof(position) ~= "Vector3" then
		return 0, nil
	end

	local best
	local bestDist = math.huge
	for _, info in ipairs(self:GetDjs()) do
		local dx = position.X - info.position.X
		local dz = position.Z - info.position.Z
		local dist = dx * dx + dz * dz
		if
			info.buff > 0
			and dist <= info.radius * info.radius
			and (not best or info.buff > best.buff or (info.buff == best.buff and dist < bestDist))
		then
			best = info
			bestDist = dist
		end
	end
	return best and best.buff or 0, best
end

function AutoGatlin:GetUpgradeRanges(towerName, golden, skillBuff, djBuff, observed)
	local ok, assetLib = pcall(require, ReplicatedStorage.Shared.Modules.Asset)
	local loaded, asset = false, nil
	if ok then
		loaded, asset = pcall(assetLib, "Troops", towerName)
	end
	if not loaded or not asset or not asset.Stats then
		return {}
	end

	local stats = self:GetTowerStats(asset, golden)
	if not stats or not stats.Defaults then
		return {}
	end
	observed = observed or self:GetObservedTowerRanges(towerName, golden)

	local fogOk, fog = pcall(gameState.IsModifierEnabled, "Fog")
	local multiplier = 1
	local rulesOk, rules = pcall(require, ReplicatedStorage.Shared.Modules.GameRules)
	if rulesOk and type(rules) == "table" and type(rules.Get) == "function" then
		local got, value = pcall(rules.Get, "TowerRangeMultiplier")
		if got then
			multiplier = tonumber(value) or 1
		end
	end

	local ranges = {}
	skillBuff = math.max(0, tonumber(skillBuff) or 0)
	djBuff = math.max(0, tonumber(djBuff) or 0)
	local range = tonumber(stats.Defaults.Range) or 0
	for level = 0, #(stats.Upgrades or {}) do
		if level > 0 then
			local upgrade = stats.Upgrades[level]
			local nextRange = upgrade and upgrade.Stats and tonumber(upgrade.Stats.Range)
			if nextRange then
				range = nextRange
			end
		end

		local base = observed[level] or range
		local shown = base + (base * djBuff / 100) + (base * skillBuff / 100)
		if fogOk and fog then
			shown = math.round(shown * 0.65)
		end
		if multiplier ~= 1 then
			shown = math.round(shown * multiplier)
		end
		if shown > 0 and (#ranges == 0 or math.abs(ranges[#ranges].range - shown) > 0.001) then
			ranges[#ranges + 1] = {
				level = level,
				range = shown,
			}
		end
	end
	return ranges
end

function AutoGatlin:GetRangeAnchorPosition(model, fallback)
	local root = model
		and (model.PrimaryPart or model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("RootPart"))
	local target = root
	local height = root and root:FindFirstChild("HeightOffset")
	if height and (height:IsA("Attachment") or height:IsA("BasePart")) then
		target = height
	end

	local position = fallback
	if target then
		position = target:IsA("Attachment") and target.WorldPosition or target.Position + Vector3.new(0, 0.2, 0)
	elseif position then
		position = position + Vector3.new(0, 0.2, 0)
	end
	if not position then
		return Vector3.zero
	end

	local ground = Workspace:FindFirstChild("Ground")
	if not ground then
		return position
	end

	local params = self.RangeRaycastParams
	if not params then
		params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.IgnoreWater = true
		params.RespectCanCollide = false
		self.RangeRaycastParams = params
	end
	if self.RangeRaycastGround ~= ground then
		self.RangeRaycastGround = ground
		params.FilterDescendantsInstances = { ground }
	end

	local origin = position + Vector3.new(0, 0.25, 0)
	local hit = Workspace:Raycast(origin, Vector3.new(0, -100.25, 0), params)
	return Vector3.new(position.X, hit and hit.Position.Y + 0.2 or position.Y, position.Z)
end

function AutoGatlin:ClearUpgradeRangeVisuals()
	for _, ring in ipairs(self.UpgradeRangeRings or {}) do
		pcall(ring.Destroy, ring)
	end
	self.UpgradeRangeRings = nil
	self.UpgradeRangeRef = nil

	if self.UpgradeRangeAnchor then
		self.UpgradeRangeAnchor:Destroy()
		self.UpgradeRangeAnchor = nil
	end
	self.UpgradeRangeModel = nil
	self.UpgradeRangeTower = nil
	self.UpgradeRangeGolden = nil
	self.UpgradeRangeSkill = nil
	self.UpgradeRangeDjBuff = nil
	self.UpgradeRangeDjUid = nil
	self.UpgradeRangeSample = nil
end

function AutoGatlin:BuildUpgradeRangeVisuals(model, towerName, golden, skillBuff, dj, observed, sample)
	self:ClearUpgradeRangeVisuals()
	local djBuff = dj and dj.buff or 0
	local ranges = self:GetUpgradeRanges(towerName, golden, skillBuff, djBuff, observed)
	if #ranges == 0 then
		self.UpgradeRangeStatus = towerName .. " has no range circles to show."
		return false
	end

	local ok, rangeRing =
		pcall(require, ReplicatedStorage.Client.Interfaces.Game.Components.NewTowerRange.Classes.RangeRing)
	if not ok or type(rangeRing) ~= "table" or type(rangeRing.new) ~= "function" then
		self.UpgradeRangeStatus = "The range rainbow could not be created >_<"
		return false
	end

	local anchor = Instance.new("Part")
	anchor.Name = "AGUpgradeRangeAnchor"
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.CFrame = CFrame.new(self:GetRangeAnchorPosition(model, model:GetPivot().Position))
	anchor.Parent = Workspace.CurrentCamera or Workspace

	self.UpgradeRangeAnchor = anchor
	self.UpgradeRangeRef = { current = anchor }
	self.UpgradeRangeRings = {}
	self.UpgradeRangeModel = model
	self.UpgradeRangeTower = towerName
	self.UpgradeRangeGolden = golden
	self.UpgradeRangeSkill = skillBuff
	self.UpgradeRangeDjBuff = djBuff
	self.UpgradeRangeDjUid = dj and dj.uid
	self.UpgradeRangeSample = sample

	for index, info in ipairs(ranges) do
		local color = Color3.fromHSV((0.55 + (index - 1) * 0.18) % 1, 0.78, 1)
		local made, ring = pcall(rangeRing.new, {
			Radius = info.range,
			Color = color,
			DisableFill = true,
			Offset = Vector3.new(0, index * 0.01, 0),
			ParentRef = self.UpgradeRangeRef,
		})
		if made and ring then
			ring.container.Name = "UpgradeRange_L" .. info.level
			self.UpgradeRangeRings[#self.UpgradeRangeRings + 1] = ring

			local marker = Instance.new("Attachment")
			marker.Name = "LVL_" .. info.level
			marker.Position = Vector3.new(info.range * 0.7, 0.5 + index * 0.05, -info.range * 0.7)
			marker.Parent = anchor

			local gui = Instance.new("BillboardGui")
			gui.Name = "RangeLabel"
			gui.Adornee = marker
			gui.AlwaysOnTop = true
			gui.LightInfluence = 0
			gui.MaxDistance = 1000
			gui.Size = UDim2.fromOffset(112, 30)
			gui.Parent = anchor

			local label = Instance.new("TextLabel")
			label.Size = UDim2.fromScale(1, 1)
			label.BackgroundColor3 = color
			label.BackgroundTransparency = 0.12
			label.BorderSizePixel = 0
			label.Font = Enum.Font.GothamBold
			label.Text = string.format("LVL %d  -  %g RANGE", info.level, info.range)
			label.TextColor3 = Color3.new(1, 1, 1)
			label.TextScaled = true
			label.TextStrokeColor3 = Color3.new(0, 0, 0)
			label.TextStrokeTransparency = 0.45
			label.Parent = gui

			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0, 7)
			corner.Parent = label

			local stroke = Instance.new("UIStroke")
			stroke.Color = Color3.new(1, 1, 1)
			stroke.Transparency = 0.2
			stroke.Thickness = 1
			stroke.Parent = label
		end
	end

	local buffs = {}
	if skillBuff > 0 then
		buffs[#buffs + 1] = string.format("Enhanced Optics +%g%%", skillBuff)
	end
	if dj then
		buffs[#buffs + 1] = string.format("%s DJ +%g%%", dj.track, dj.buff)
	end
	local name = golden and "Golden " .. towerName or towerName
	self.UpgradeRangeStatus = string.format("Showing %d colored range(s) for %s :3", #self.UpgradeRangeRings, name)
		.. (#buffs > 0 and "\n" .. table.concat(buffs, "  |  ") or "")
	return true
end

function AutoGatlin:UpdateUpgradeRangePreview()
	if not self.ShowUpgradeRanges then
		return
	end

	local controllerOk, controller = pcall(require, ReplicatedStorage.Client.Controllers.Game.NewPlacementController)
	local storeOk, store = pcall(require, ReplicatedStorage.Client.Interfaces.Stores.Game.UpgradesStore)
	local state = storeOk and store.getState()
	local model = controllerOk and controller.Active and state and state.model
	local towerName = state and state.tower
	if not model or not model.Parent or type(towerName) ~= "string" or towerName == "" then
		if self.UpgradeRangeModel then
			self:ClearUpgradeRangeVisuals()
		end
		self.UpgradeRangeStatus = "Select a tower to preview every upgrade range :3"
		return
	end

	local camera = Workspace.CurrentCamera or Workspace
	local position = model:GetPivot().Position
	local golden = self:IsGoldenTower(towerName)
	local observed, sample = self:GetObservedTowerRanges(towerName, golden)
	local skillBuff = self:GetSkillRangeBonus()
	local djBuff, dj = self:GetDjRangeBuff(position, towerName)
	local djUid = dj and dj.uid
	if
		model ~= self.UpgradeRangeModel
		or towerName ~= self.UpgradeRangeTower
		or golden ~= self.UpgradeRangeGolden
		or math.abs((self.UpgradeRangeSkill or -1) - skillBuff) > 0.001
		or math.abs((self.UpgradeRangeDjBuff or -1) - djBuff) > 0.001
		or self.UpgradeRangeDjUid ~= djUid
		or self.UpgradeRangeSample ~= sample
		or not self.UpgradeRangeAnchor
		or self.UpgradeRangeAnchor.Parent ~= camera
	then
		self:BuildUpgradeRangeVisuals(model, towerName, golden, skillBuff, dj, observed, sample)
	end

	if self.UpgradeRangeAnchor then
		self.UpgradeRangeAnchor.CFrame = CFrame.new(self:GetRangeAnchorPosition(model, position))
	end
end

function AutoGatlin:SetShowUpgradeRanges(value)
	self.ShowUpgradeRanges = value == true
	if not self.ShowUpgradeRanges then
		if self.UpgradeRangeConn then
			self.UpgradeRangeConn:Disconnect()
			self.UpgradeRangeConn = nil
		end
		self:ClearUpgradeRangeVisuals()
		self.UpgradeRangeStatus = "Upgrade range rainbow is napping zzz"
		return self
	end

	self.UpgradeRangeStatus = "Select a tower to preview every upgrade range :3"
	if not self.UpgradeRangeConn then
		self.UpgradeRangeConn = RunService.RenderStepped:Connect(function()
			local ok, err = pcall(self.UpdateUpgradeRangePreview, self)
			if not ok then
				self.UpgradeRangeStatus = "Range preview error: " .. tostring(err)
				self:ClearUpgradeRangeVisuals()
			end
		end)
	end
	return self
end

function AutoGatlin:ClearDjRangeVisuals()
	for _, entry in pairs(self.DjRangeVisuals or {}) do
		if entry.ring then
			pcall(entry.ring.Destroy, entry.ring)
		end
		if entry.anchor then
			entry.anchor:Destroy()
		end
	end
	self.DjRangeVisuals = nil
end

function AutoGatlin:CreateDjRangeVisual(info)
	local ok, rangeRing =
		pcall(require, ReplicatedStorage.Client.Interfaces.Game.Components.NewTowerRange.Classes.RangeRing)
	if not ok or type(rangeRing) ~= "table" or type(rangeRing.new) ~= "function" then
		return nil
	end

	local color = Color3.fromRGB(175, 90, 255)
	if info.track == "Red" then
		color = Color3.fromRGB(255, 92, 110)
	elseif info.track == "Green" then
		color = Color3.fromRGB(82, 235, 145)
	end

	local anchor = Instance.new("Part")
	anchor.Name = "AGDjRangeAnchor"
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.CFrame = CFrame.new(self:GetRangeAnchorPosition(info.model, info.position))
	anchor.Parent = Workspace.CurrentCamera or Workspace

	local ref = { current = anchor }
	local made, ring = pcall(rangeRing.new, {
		Radius = info.radius,
		Color = color,
		DisableFill = true,
		Offset = Vector3.new(0, 0.01, 0),
		ParentRef = ref,
	})
	if not made or not ring then
		anchor:Destroy()
		return nil
	end
	ring.container.Name = "DJRange_" .. info.uid

	local marker = Instance.new("Attachment")
	marker.Position = Vector3.new(info.radius * 0.7, 0.7, -info.radius * 0.7)
	marker.Parent = anchor

	local gui = Instance.new("BillboardGui")
	gui.Name = "DJRangeLabel"
	gui.Adornee = marker
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 1000
	gui.Size = UDim2.fromOffset(170, 40)
	gui.Parent = anchor

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = color
	label.BackgroundTransparency = 0.1
	label.BorderSizePixel = 0
	label.Font = Enum.Font.GothamBold
	label.Text = string.format(
		"DJ LVL %d  -  %g RANGE\n%s TRACK  -  +%g%%",
		info.level,
		info.radius,
		string.upper(info.track),
		info.buff
	)
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextScaled = true
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.TextStrokeTransparency = 0.45
	label.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 7)
	corner.Parent = label

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Transparency = 0.2
	stroke.Thickness = 1
	stroke.Parent = label

	return {
		anchor = anchor,
		ring = ring,
		ref = ref,
		radius = info.radius,
		level = info.level,
		track = info.track,
		buff = info.buff,
	}
end

function AutoGatlin:UpdateDjRangeVisuals()
	if not self.AlwaysShowDjRanges then
		return
	end

	local visuals = self.DjRangeVisuals or {}
	local live = {}
	local camera = Workspace.CurrentCamera or Workspace
	self.DjRangeVisuals = visuals

	for _, info in ipairs(self:GetDjs()) do
		if info.model.Parent then
			live[info.uid] = true
			local entry = visuals[info.uid]
			if
				entry
				and (
					entry.anchor.Parent ~= camera
					or math.abs(entry.radius - info.radius) > 0.001
					or entry.level ~= info.level
					or entry.track ~= info.track
					or math.abs(entry.buff - info.buff) > 0.001
				)
			then
				pcall(entry.ring.Destroy, entry.ring)
				entry.anchor:Destroy()
				entry = nil
			end

			if not entry then
				entry = self:CreateDjRangeVisual(info)
				visuals[info.uid] = entry
			end
			if entry then
				entry.anchor.CFrame = CFrame.new(self:GetRangeAnchorPosition(info.model, info.position))
			end
		end
	end

	for uid, entry in pairs(visuals) do
		if not live[uid] then
			pcall(entry.ring.Destroy, entry.ring)
			entry.anchor:Destroy()
			visuals[uid] = nil
		end
	end
end

function AutoGatlin:SetAlwaysShowDjRanges(value)
	self.AlwaysShowDjRanges = value == true
	self.DjCache = nil
	self.DjCacheAt = nil
	if not self.AlwaysShowDjRanges then
		if self.DjRangeConn then
			self.DjRangeConn:Disconnect()
			self.DjRangeConn = nil
		end
		self:ClearDjRangeVisuals()
		return self
	end

	if not self.DjRangeConn then
		self.DjRangeConn = RunService.RenderStepped:Connect(function()
			local ok, err = pcall(self.UpdateDjRangeVisuals, self)
			if not ok then
				self.UpgradeRangeStatus = "DJ range error: " .. tostring(err)
				self:ClearDjRangeVisuals()
			end
		end)
	end
	pcall(self.UpdateDjRangeVisuals, self)
	return self
end

function AutoGatlin:GetManagedTower()
	local tower = self.ManagedTower
	local model = self.ManagedTowerModel
	if not tower or not model or not model.Parent or tower.OwnerId ~= lp.UserId or not tower:IsAlive() then
		self.ManagedTower = nil
		self.ManagedTowerModel = nil
		self.ManagedTowerName = nil
		return nil
	end
	return tower, model
end

function AutoGatlin:LockManagedTowerFromPart(part)
	local obj = part
	while obj and obj ~= Workspace do
		if obj:IsA("Model") then
			local tower = towerLib.getTowerByModel(obj)
			if tower and tower.OwnerId == lp.UserId and tower:IsAlive() then
				self.ManagedTower = tower
				self.ManagedTowerModel = tower.Model or obj
				self.ManagedTowerName = tower.TowerName
				self.TowerManagerStatus = "Ready for tower surgery :3"
				return true
			end
		end
		obj = obj.Parent
	end
	return false
end

function AutoGatlin:TowerManagerText()
	if self.SellAllArmedUntil and os.clock() > self.SellAllArmedUntil then
		self.SellAllArmedUntil = nil
		self.TowerManagerStatus = "Sell All confirmation expired."
	end

	local tower = self:GetManagedTower()
	if not tower then
		return self.TowerManagerStatus
	end

	local level = tonumber(tower.Replicator:Get("Upgrade")) or 0
	return string.format("%s | level %d\n%s", tower.TowerName, level, self.TowerManagerStatus)
end

function AutoGatlin:GetOwnedTowerEntries()
	local towers = {}
	for _, model in ipairs(Workspace.Towers:GetChildren()) do
		local tower = towerLib.getTowerByModel(model)
		if tower and tower.OwnerId == lp.UserId and tower:IsAlive() then
			towers[#towers + 1] = {
				model = model,
				tower = tower,
			}
		end
	end
	return towers
end

function AutoGatlin:GetTroopChannel()
	local ok, net = pcall(require, ReplicatedStorage.Shared.Modules.Network)
	if not ok or type(net) ~= "table" or type(net.Channel) ~= "function" then
		return nil
	end
	return net.Channel("Troops")
end

function AutoGatlin:UpgradeTowerModel(model)
	local channel = self:GetTroopChannel()
	if not channel then
		return 0, "Troops channel unavailable"
	end

	local upgraded = 0
	for _ = 1, 20 do
		local tower = model.Parent and towerLib.getTowerByModel(model)
		if not tower or tower.OwnerId ~= lp.UserId or not tower:IsAlive() then
			break
		end

		local path = tonumber(tower.Replicator:Get("Path")) or 0
		local ok, success, msg = pcall(channel.InvokeServer, channel, "Upgrade", "Set", { Troop = model, Path = path })
		if not ok then
			return upgraded, tostring(success)
		end
		if not success then
			return upgraded, tostring(msg or "Already maxed or not enough cash")
		end

		upgraded = upgraded + 1
		task.wait()
	end
	return upgraded
end

function AutoGatlin:SellTowerModel(model)
	if not model or not model.Parent then
		return false, "Tower is gone"
	end

	local channel = self:GetTroopChannel()
	if not channel then
		return false, "Troops channel unavailable"
	end

	local ok, success, msg = pcall(channel.InvokeServer, channel, "Sell", { Troop = model })
	if not ok then
		return false, tostring(success)
	end
	return success == true, tostring(msg or "Sell rejected")
end

function AutoGatlin:RunTowerSweep(towerName, action, maxTries)
	local done = {}
	local tries = {}
	local quiet = 0
	local count = 0
	maxTries = math.max(math.floor(tonumber(maxTries) or 1), 1)

	while quiet < 12 do
		local worked = false
		for _, entry in ipairs(self:GetOwnedTowerEntries()) do
			local model = entry.model
			if
				(not towerName or entry.tower.TowerName == towerName)
				and not done[model]
				and (tries[model] or 0) < maxTries
			then
				worked = true
				tries[model] = (tries[model] or 0) + 1

				local ok, finished = pcall(action, entry)
				if ok and finished ~= false then
					done[model] = true
					count = count + 1
				end
				task.wait()
			end
		end

		quiet = worked and 0 or quiet + 1
		task.wait(0.25)
	end

	return count
end

function AutoGatlin:UpgradeSelectedTower()
	if self.TowerManagerBusy then
		return self
	end

	local tower = self:GetManagedTower()
	if not tower then
		self.TowerManagerStatus = "Click the tower you want to upgrade first >_<"
		return self
	end

	local towerName = tower.TowerName
	self.TowerManagerBusy = true
	self.TowerManagerStatus = "Maxing every " .. towerName .. "..."
	task.spawn(function()
		local upgraded = 0
		local touched = self:RunTowerSweep(towerName, function(entry)
			local count = self:UpgradeTowerModel(entry.model)
			upgraded = upgraded + count
			return true
		end, 2)
		self.TowerManagerStatus =
			string.format("Added %d upgrade(s) across %d %s tower(s) :3", upgraded, touched, towerName)
		self.TowerManagerBusy = false
	end)
	return self
end

function AutoGatlin:SellSelectedTower()
	if self.TowerManagerBusy then
		return self
	end

	local tower, model = self:GetManagedTower()
	if not tower then
		self.TowerManagerStatus = "Click the tower you want to sell first >_<"
		return self
	end

	self.TowerManagerBusy = true
	self.TowerManagerStatus = "Selling " .. tower.TowerName .. "..."
	task.spawn(function()
		local ok, sold, msg = pcall(self.SellTowerModel, self, model)
		self.TowerManagerStatus = ok and sold and "Tower sold, bye-bye~" or tostring(msg or "Sell failed.")
		if ok and sold then
			self.ManagedTower = nil
			self.ManagedTowerModel = nil
			self.ManagedTowerName = nil
		end
		self.TowerManagerBusy = false
	end)
	return self
end

function AutoGatlin:UpgradeAllTowers()
	if self.TowerManagerBusy then
		return self
	end

	self.TowerManagerBusy = true
	self.TowerManagerStatus = "Giving every tower a glow-up..."
	task.spawn(function()
		local upgraded = 0
		local touched = self:RunTowerSweep(nil, function(entry)
			local count = self:UpgradeTowerModel(entry.model)
			upgraded = upgraded + count
			return true
		end, 2)
		self.TowerManagerStatus = touched > 0
				and string.format("Added %d upgrade(s) across %d tower(s) :3", upgraded, touched)
			or "You do not have any towers to upgrade."
		self.TowerManagerBusy = false
	end)
	return self
end

function AutoGatlin:SellAllTowers()
	if self.TowerManagerBusy then
		return self
	end

	local now = os.clock()
	if not self.SellAllArmedUntil or now > self.SellAllArmedUntil then
		self.SellAllArmedUntil = now + 3
		self.TowerManagerStatus = "Press Sell All again within 3 seconds to confirm."
		return self
	end
	self.SellAllArmedUntil = nil

	self.TowerManagerBusy = true
	self.TowerManagerStatus = "Selling every tower..."
	task.spawn(function()
		local sold = self:RunTowerSweep(nil, function(entry)
			return self:SellTowerModel(entry.model)
		end, 3)
		local remaining = #self:GetOwnedTowerEntries()
		self.ManagedTower = nil
		self.ManagedTowerModel = nil
		self.ManagedTowerName = nil
		if sold == 0 and remaining == 0 then
			self.TowerManagerStatus = "You do not have any towers to sell."
		elseif remaining > 0 then
			self.TowerManagerStatus = string.format("Sold %d tower(s); %d could not be sold.", sold, remaining)
		else
			self.TowerManagerStatus = string.format("Sold all %d tower(s).", sold)
		end
		self.TowerManagerBusy = false
	end)
	return self
end

function AutoGatlin:GetCommanderEntries()
	local commanders = {}
	for _, entry in ipairs(self:GetOwnedTowerEntries()) do
		if entry.tower.TowerName == "Commander" then
			entry.level = tonumber(entry.tower.Replicator:Get("Upgrade")) or 0
			entry.uid = tostring(entry.tower.Replicator:Get("UID") or entry.model)
			commanders[#commanders + 1] = entry
		end
	end

	table.sort(commanders, function(a, b)
		return a.uid < b.uid
	end)
	return commanders
end

function AutoGatlin:GetCallToArmsCooldown(model)
	local ok, store = pcall(require, ReplicatedStorage.Client.Interfaces.Stores.Game.AbilitiesStore)
	if not ok or type(store) ~= "table" or type(store.getState) ~= "function" then
		return nil, 30
	end

	local abilities = store.getState()[model]
	local state = abilities and (abilities.CallOfArms or abilities["Call Of Arms"])
	if type(state) ~= "table" then
		return 0, 30
	end

	local started = tonumber(state.deltaTime) or 0
	local cooldown = tonumber(state.maxDeltaTime) or 0
	return math.max(cooldown - (os.clock() - started), 0), cooldown
end

function AutoGatlin:CommanderChainText()
	local commanders = self:GetCommanderEntries()
	local unlocked = 0
	local ready = 0
	for _, entry in ipairs(commanders) do
		if entry.level >= 2 then
			unlocked = unlocked + 1
			local remaining = self:GetCallToArmsCooldown(entry.model)
			if remaining and remaining <= 0.05 then
				ready = ready + 1
			end
		end
	end

	return string.format(
		"%s\n%d placed | %d unlocked | %d ready",
		self.CommanderChainStatus,
		#commanders,
		unlocked,
		ready
	)
end

function AutoGatlin:UseCallToArms(entry)
	if
		not entry
		or not entry.model.Parent
		or entry.tower.OwnerId ~= lp.UserId
		or not entry.tower:IsAlive()
		or entry.level < 2
	then
		return false, 0, "That Commander cannot use Call to Arms."
	end

	local remaining = self:GetCallToArmsCooldown(entry.model)
	if not remaining then
		return false, 0, "Commander cooldown state is unavailable."
	end
	if remaining > 0.05 then
		return false, 0, string.format("Commander is recharging for %.1fs.", remaining)
	end

	local channel = self:GetTroopChannel()
	if not channel then
		return false, 0, "Troops channel unavailable."
	end

	local ok, success, msg = pcall(channel.InvokeServer, channel, "Abilities", "Activate", {
		Name = "Call Of Arms",
		Troop = entry.model,
		Data = {},
	})
	if not ok then
		return false, 0, tostring(success)
	end
	if success ~= true then
		return false, 0, tostring(msg or "Call to Arms was rejected.")
	end

	task.wait(0.05)
	local _, cooldown = self:GetCallToArmsCooldown(entry.model)
	local duration = 10
	if cooldown and cooldown > 0 then
		duration = duration * math.clamp(cooldown / 30, 0.25, 2)
	end
	return true, duration
end

function AutoGatlin:CommanderChainStep(seq)
	local eligible = {}
	for _, entry in ipairs(self:GetCommanderEntries()) do
		if entry.level >= 2 then
			eligible[#eligible + 1] = entry
		end
	end

	if #eligible == 0 then
		self.CommanderChainStatus = "Upgrade a Commander to level 2 first >_<"
		return 0.5
	end

	local start = ((self.CommanderChainIndex or 1) - 1) % #eligible + 1
	local chosen
	local nextReady = math.huge
	for offset = 0, #eligible - 1 do
		local index = (start + offset - 1) % #eligible + 1
		local remaining = self:GetCallToArmsCooldown(eligible[index].model)
		if not remaining then
			self.CommanderChainStatus = "Commander cooldown state is unavailable."
			return 0.5
		end
		if remaining <= 0.05 then
			chosen = index
			break
		end
		nextReady = math.min(nextReady, remaining)
	end

	if not chosen then
		self.CommanderChainStatus = string.format("All %d Commander(s) are recharging (%.1fs).", #eligible, nextReady)
		return math.clamp(nextReady, 0.1, 0.5)
	end

	self.CommanderChainStatus = string.format("Commander %d is calling everyone to arms!", chosen)
	local used, duration, msg = self:UseCallToArms(eligible[chosen])
	if not used then
		self.CommanderChainStatus = msg
		self.CommanderChainIndex = chosen % #eligible + 1
		return 0.25
	end

	self.CommanderChainIndex = chosen % #eligible + 1
	local endsAt = os.clock() + duration
	while self.Running and self.AutoCommanderChain and seq == self.CommanderChainSeq and os.clock() < endsAt do
		self.CommanderChainStatus = string.format(
			"Commander %d buff active: %.1fs -> Commander %d",
			chosen,
			math.max(endsAt - os.clock(), 0),
			self.CommanderChainIndex
		)
		task.wait(0.1)
	end
	return 0
end

function AutoGatlin:RunCommanderChain(seq)
	while self.Running and self.AutoCommanderChain and seq == self.CommanderChainSeq do
		local delay = self:CommanderChainStep(seq)
		if delay > 0 then
			task.wait(delay)
		else
			RunService.Heartbeat:Wait()
		end
	end
end

function AutoGatlin:SetAutoCommanderChain(value)
	self.CommanderChainSeq = (self.CommanderChainSeq or 0) + 1
	self.AutoCommanderChain = value == true
	self.CommanderChainIndex = 1

	if not self.AutoCommanderChain then
		self.CommanderChainStatus = "Commander chain is napping zzz"
		return self
	end
	if not self.Running then
		self.CommanderChainStatus = "Start the script before arming the chain."
		return self
	end

	local seq = self.CommanderChainSeq
	self.CommanderChainStatus = "Looking for ready Commanders :3"
	task.spawn(function()
		self:RunCommanderChain(seq)
	end)
	return self
end

function AutoGatlin:BindStackCollision()
	if self.CollisionCheckOriginal then
		return true
	end

	local ok, shared = pcall(require, ReplicatedStorage.Shared.Modules.SharedGameFunctions)
	local check = ok and shared.CheckTowerCollisions
	if type(check) ~= "function" then
		self.StackStatus = "The placement circle ran away >_<"
		return false
	end

	self.CollisionCheckModule = shared
	self.CollisionCheckOriginal = check
	self.CollisionCheckHook = function(towerName, pos, team, extra)
		local original = AutoGatlin.CollisionCheckOriginal
		if not original then
			return false
		end

		local valid, blocker = original(towerName, pos, team, extra)
		if
			not valid
			and AutoGatlin.AutoStacker
			and type(blocker) == "table"
			and blocker.Model
			and blocker.PrimaryPart
		then
			return true, { Position = pos }
		end
		return valid, blocker
	end
	shared.CheckTowerCollisions = self.CollisionCheckHook
	return true
end

function AutoGatlin:UnbindStackCollision()
	if
		self.CollisionCheckModule
		and self.CollisionCheckOriginal
		and self.CollisionCheckModule.CheckTowerCollisions == self.CollisionCheckHook
	then
		self.CollisionCheckModule.CheckTowerCollisions = self.CollisionCheckOriginal
	end

	self.CollisionCheckModule = nil
	self.CollisionCheckOriginal = nil
	self.CollisionCheckHook = nil
	return self
end

function AutoGatlin:BindStacker()
	if self.PlaceInvokeOriginal then
		return self:BindStackCollision()
	end
	if type(hookfunction) ~= "function" then
		self.StackStatus = "Your executor ate hookfunction >_<"
		return false
	end
	if not self:BindStackCollision() then
		return false
	end

	local ok, net = pcall(require, ReplicatedStorage.Shared.Modules.Network)
	if not ok or type(net) ~= "table" or type(net.Channel) ~= "function" then
		self:UnbindStackCollision()
		self.StackStatus = "Could not find the tower kitchen >_<"
		return false
	end

	local channel = net.Channel("Troops")
	local mt = getmetatable(channel)
	local methods = mt and mt.__index
	local invoke = type(methods) == "table" and methods.InvokeServer or channel.InvokeServer
	if type(invoke) ~= "function" then
		self:UnbindStackCollision()
		self.StackStatus = "The place button ran away >_<"
		return false
	end

	self.StackCall = function(...)
		local original = AutoGatlin.PlaceInvokeOriginal
		if original then
			pcall(original, ...)
		end
	end

	local hooked, original = pcall(hookfunction, invoke, function(ch, action, placement, towerName, ...)
		local call = AutoGatlin.PlaceInvokeOriginal
		if not call then
			return nil
		end

		if
			AutoGatlin.AutoStacker
			and ch.Channel == "Troops"
			and action == "Place"
			and type(placement) == "table"
			and typeof(placement.Position) == "Vector3"
		then
			local info = AutoGatlin:GetStackInfo(towerName)
			local amount = info.count
			if amount < 1 then
				AutoGatlin.StackStatus = towerName .. " tower cap reached >_<"
				return "You have reached this tower's placement limit!"
			end

			AutoGatlin.StackStatus =
				string.format("Stacking %d %s for %s :3", amount, towerName, AutoGatlin:FormatCash(info.total))
			local stacked = table.clone(placement)
			-- Collision checks use the supplied Y, then snap the tower to the raycasted ground.
			stacked.Position = placement.Position + Vector3.new(0, 50, 0)
			for _ = 2, amount do
				task.spawn(AutoGatlin.StackCall, ch, action, stacked, towerName, ...)
			end
			return call(ch, action, stacked, towerName, ...)
		end

		return call(ch, action, placement, towerName, ...)
	end)

	if not hooked or type(original) ~= "function" then
		self.StackCall = nil
		self:UnbindStackCollision()
		self.StackStatus = "AutoStacker could not grab placement >_<"
		return false
	end

	self.PlaceInvoke = invoke
	self.PlaceInvokeOriginal = original
	self.StackStatus = "Tower sandwich maker is ready :3"
	return true
end

function AutoGatlin:UnbindStacker()
	self.AutoStacker = false
	if self.PlaceInvoke and self.PlaceInvokeOriginal and type(hookfunction) == "function" then
		pcall(hookfunction, self.PlaceInvoke, self.PlaceInvokeOriginal)
	end
	self:UnbindStackCollision()

	self.PlaceInvoke = nil
	self.PlaceInvokeOriginal = nil
	self.StackCall = nil
	self.StackStatus = "Ready to make tower sandwiches :3"
	return self
end

function AutoGatlin:SetAutoStacker(value)
	value = value == true
	if value and not self:BindStacker() then
		self.AutoStacker = false
		return self
	end

	self.AutoStacker = value
	self.StackStatus = value and string.format("%d-layer tower sandwich armed ;3", self.StackAmount)
		or "Tower sandwich maker is napping zzz"
	return self
end

function AutoGatlin:SetStackAmount(value)
	self.StackAmount = math.clamp(math.floor(tonumber(value) or 15), 1, 50)
	if self.AutoStacker then
		self.StackStatus = string.format("%d-layer tower sandwich armed ;3", self.StackAmount)
	end
	return self
end

function AutoGatlin:FormatRoundTime(seconds)
	local total = math.max(math.floor((tonumber(seconds) or 0) * 1000), 0)
	local milliseconds = total % 1000
	local whole = math.floor(total / 1000)
	local secs = whole % 60
	local minutes = math.floor(whole / 60) % 60
	local hours = math.floor(whole / 3600)
	return string.format("%02d:%02d:%02d.%03d", hours, minutes, secs, milliseconds)
end

function AutoGatlin:ResetRoundTimer()
	self.RoundTimerStartedAt = nil
	self.RoundTimerElapsed = 0
	self.RoundTimerRunning = false
	if self.RoundTimerLabel then
		self.RoundTimerLabel.Text = "00:00:00.000"
	end
	return self
end

function AutoGatlin:StartRoundTimer()
	self.RoundTimerStartedAt = Workspace:GetServerTimeNow()
	self.RoundTimerElapsed = 0
	self.RoundTimerRunning = true
	if self.RoundTimerLabel then
		self.RoundTimerLabel.Text = "00:00:00.000"
	end
	return self
end

function AutoGatlin:StopRoundTimer()
	if self.RoundTimerRunning and self.RoundTimerStartedAt then
		self.RoundTimerElapsed = math.max(Workspace:GetServerTimeNow() - self.RoundTimerStartedAt, 0)
	end
	self.RoundTimerRunning = false
	self.RoundTimerStartedAt = nil
	return self
end

function AutoGatlin:UpdateRoundTimer()
	local wave = tonumber(gameState.Wave) or 0
	local prevWave = tonumber(self.RoundTimerLastWave) or wave
	if wave <= 0 and prevWave > 0 then
		self:ResetRoundTimer()
	elseif wave > 0 and prevWave <= 0 then
		self:StartRoundTimer()
	end
	self.RoundTimerLastWave = wave

	if gameState.GameOver and self.RoundTimerRunning then
		self:StopRoundTimer()
	end

	local elapsed = self.RoundTimerElapsed or 0
	if self.RoundTimerRunning and self.RoundTimerStartedAt then
		elapsed = math.max(Workspace:GetServerTimeNow() - self.RoundTimerStartedAt, 0)
	end
	if self.RoundTimerLabel then
		self.RoundTimerLabel.Text = self:FormatRoundTime(elapsed)
	end
end

function AutoGatlin:DestroyRoundTimer()
	if self.RoundTimerConn then
		self.RoundTimerConn:Disconnect()
		self.RoundTimerConn = nil
	end
	if self.RoundTimerWaveConn then
		self.RoundTimerWaveConn:Disconnect()
		self.RoundTimerWaveConn = nil
	end
	if self.RoundTimerOverConn then
		self.RoundTimerOverConn:Disconnect()
		self.RoundTimerOverConn = nil
	end
	if self.RoundTimerGui then
		self.RoundTimerGui:Destroy()
		self.RoundTimerGui = nil
	end
	self.RoundTimerLabel = nil
end

function AutoGatlin:BuildRoundTimer()
	self:DestroyRoundTimer()
	self:ResetRoundTimer()
	self.RoundTimerLastWave = tonumber(gameState.Wave) or 0

	local parent = lp:WaitForChild("PlayerGui")
	if type(gethui) == "function" then
		local ok, gui = pcall(gethui)
		if ok and gui then
			parent = gui
		end
	end

	local screen = Instance.new("ScreenGui")
	screen.Name = "TDSRoundStopwatch"
	screen.DisplayOrder = 1000000001
	screen.IgnoreGuiInset = true
	screen.ResetOnSpawn = false
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Parent = parent

	local frame = Instance.new("Frame")
	frame.Name = "Timer"
	frame.AnchorPoint = Vector2.new(1, 1)
	frame.Position = UDim2.new(1, -22, 1, -22)
	frame.Size = UDim2.fromOffset(260, 76)
	frame.BackgroundColor3 = Color3.fromRGB(18, 19, 25)
	frame.BackgroundTransparency = 0.08
	frame.BorderSizePixel = 0
	frame.Parent = screen

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(112, 208, 232)
	stroke.Transparency = 0.15
	stroke.Thickness = 1.5
	stroke.Parent = frame

	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(25, 27, 36)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(35, 25, 35)),
	})
	gradient.Rotation = 18
	gradient.Parent = frame

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Position = UDim2.fromOffset(12, 6)
	title.Size = UDim2.new(1, -24, 0, 18)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamSemibold
	title.Text = "ROUND TIMER"
	title.TextColor3 = Color3.fromRGB(131, 220, 239)
	title.TextSize = 13
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = frame

	local timer = Instance.new("TextLabel")
	timer.Name = "Time"
	timer.Position = UDim2.fromOffset(8, 23)
	timer.Size = UDim2.new(1, -16, 1, -27)
	timer.BackgroundTransparency = 1
	timer.Font = Enum.Font.Code
	timer.Text = "00:00:00.000"
	timer.TextColor3 = Color3.new(1, 1, 1)
	timer.TextScaled = true
	timer.TextStrokeColor3 = Color3.new(0, 0, 0)
	timer.TextStrokeTransparency = 0.6
	timer.Parent = frame

	self.RoundTimerGui = screen
	self.RoundTimerLabel = timer
	self.RoundTimerConn = RunService.RenderStepped:Connect(function()
		self:UpdateRoundTimer()
	end)

	local replicator = gameState.Replicator
	if replicator then
		self.RoundTimerWaveConn = replicator:GetStateChangedSignal("Wave"):Connect(function(value)
			local wave = tonumber(value) or 0
			local prevWave = tonumber(self.RoundTimerLastWave) or 0
			if wave <= 0 then
				self:ResetRoundTimer()
			elseif prevWave <= 0 then
				self:StartRoundTimer()
			end
			self.RoundTimerLastWave = wave
		end)
		self.RoundTimerOverConn = replicator:GetStateChangedSignal("GameOver"):Connect(function(value)
			if value then
				self:StopRoundTimer()
			end
		end)
	end

	if self.RoundTimerLastWave == 1 and gameState.GameStarted and not gameState.GameOver then
		task.defer(function()
			if self.Running and not self.RoundTimerRunning and (tonumber(gameState.Wave) or 0) == 1 then
				self:StartRoundTimer()
			end
		end)
	end
	return self
end

function AutoGatlin:Start()
	if self.Running then
		return self
	end

	runSeq = runSeq + 1
	local seq = runSeq
	self.Running = true
	self.Status = self.Enabled and "Starting" or "Disabled"
	env.AutoGatlin = self
	recorder:Install()
	self:BuildRoundTimer()

	if not self.InspectConn then
		local guiService = clone(game:GetService("GuiService"))
		self.InspectConn = guiService.InspectPlayerFromUserIdWithCtxRequest:Connect(function(userId)
			if userId ~= lp.UserId or not self.MorphEnabled or not self.MorphDescription then
				return
			end

			task.defer(function()
				if not self.Running or not self.MorphEnabled or not self.MorphDescription then
					return
				end
				pcall(
					guiService.InspectPlayerFromHumanoidDescription,
					guiService,
					self.MorphDescription,
					self.MorphDisplayName
				)
			end)
		end)
	end
	if not self.TargetClickConn then
		local mouse = lp:GetMouse()
		local inputService = clone(game:GetService("UserInputService"))
		self.TargetClickConn = inputService.InputBegan:Connect(function(input, processed)
			if not processed and input.UserInputType == Enum.UserInputType.MouseButton1 and mouse.Target then
				self:LockManagedTowerFromPart(mouse.Target)
				self:LockTargetFromPart(mouse.Target)
			end
		end)
	end

	self:SetRainbowESP(false)
	self:SetHideUsername(self.HideUsername)
	self:SetMorphEnabled(self.MorphEnabled)
	self:SetRemoveAccessories(self.RemoveAccessories)
	syncHitSound()
	syncGatlinAppearance()
	drawConn = RunService.RenderStepped:Connect(drawStep)

	task.spawn(function()
		while self.Running and seq == runSeq do
			task.wait(gatlingGremlin.targetStep())
		end
	end)

	task.spawn(function()
		while self.Running and seq == runSeq do
			local delay = gatlingGremlin.fireStep()
			if delay == false then
				RunService.Heartbeat:Wait()
			else
				task.wait(delay)
			end
		end

		if seq == runSeq then
			stopFiring()
		end
	end)

	task.spawn(function()
		while self.Running and seq == runSeq do
			if
				self.AnonymousGatlin
				or self.RainbowGatlin
				or self.CustomGatlin
				or self.ForcefieldGatlin
				or self.MuteBarrelSpin
				or self.CrosshairTransparency > 0
				or (self.MorphEnabled and self.GatlinMorphTemplate)
			then
				pcall(refreshGatlinVisuals)
			end
			task.wait(0.5)
		end
	end)

	return self
end

function AutoGatlin:LoadUI()
	if self.UIReady or self.UILoading then
		return self
	end

	uiSeq = uiSeq + 1
	local seq = uiSeq
	self.UILoading = true
	self.UIError = nil

	task.spawn(function()
		local ok, built = pcall(kawaiiUi.build, seq)
		if seq ~= uiSeq then
			return
		end

		self.UILoading = false

		if not ok then
			local err = tostring(built)
			kawaiiUi.destroy()
			self.UIError = err
		elseif not built then
			kawaiiUi.destroy()
		end
	end)

	return self
end

function AutoGatlin:Stop()
	runSeq = runSeq + 1
	self.Running = false
	self.Enabled = false
	self:SetAutoCommanderChain(false)
	self:SetShowUpgradeRanges(false)
	self:SetAlwaysShowDjRanges(false)
	self:UnbindStacker()
	if recorder.active then
		recorder:Stop()
	end
	recorder:Destroy()
	self:DestroyRoundTimer()

	if drawConn then
		drawConn:Disconnect()
		drawConn = nil
	end
	if self.InspectConn then
		self.InspectConn:Disconnect()
		self.InspectConn = nil
	end
	if self.TargetClickConn then
		self.TargetClickConn:Disconnect()
		self.TargetClickConn = nil
	end
	kawaiiUi.destroy()

	stopFiring()
	clearTarget()
	resetHitWatch()
	releaseTowers()

	self:SetMorphEnabled(false)
	self:SetHideUsername(false)
	self:SetRemoveAccessories(false)
	self:SetAnonymousGatlin(false)
	self:SetRainbowGatlin(false)
	self:SetCustomGatlin(false)
	self:SetForcefieldGatlin(false)
	self:SetMuteBarrelSpin(false)
	self:SetCrosshairTransparency(0)
	self:SetBulletLines(false)
	self:SetZombieESP(false)
	self:SetRainbowESP(false)
	restoreHitSound()

	unbindNet()

	table.clear(blocked)
	table.clear(towerRetry)
	table.clear(aimPhase)
	table.clear(hitboxOffsets)
	table.clear(validated)
	table.clear(resting)
	table.clear(shotHistory)
	table.clear(shotReserve)

	lastAim = 0
	lastFireSync = nil
	relockUntil = 0
	fireHoldUntil = 0
	reloadedWave = -1
	hitSeq = 0
	bulletSeq = 0
	drawnHitSeq = 0
	self.Tower = nil
	self.TowerCount = 0
	self.ActiveCount = 0
	self.ManualTarget = nil
	self.ManualTargetName = ""
	self.ManagedTower = nil
	self.ManagedTowerModel = nil
	self.ManagedTowerName = nil
	self.TowerManagerBusy = false
	self.SellAllArmedUntil = nil
	self.TowerManagerStatus = "Click an owned tower to manage it :3"
	self.CommanderChainIndex = 1
	self.Status = "Stopped"

	if env.AutoGatlin == self then
		env.AutoGatlin = nil
	end
	return self
end

AutoGatlin:Start()

if not env.AutoGatlinSkipUI then
	AutoGatlin:LoadUI()
end
