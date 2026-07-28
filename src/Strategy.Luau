repeat
	task.wait()
until game:IsLoaded() and game.PlaceId ~= 0

local autoGatlinRequested = getgenv().AutoGatlin == true
local clone = cloneref or function(value)
	return value
end

local CollectionService = clone(game:GetService("CollectionService"))
local Players = clone(game:GetService("Players"))
local ReplicatedStorage = clone(game:GetService("ReplicatedStorage"))
local RunService = clone(game:GetService("RunService"))
local VirtualUser = clone(game:GetService("VirtualUser"))
local Workspace = clone(game:GetService("Workspace"))

local lp = clone(Players.LocalPlayer)
local clientModules = ReplicatedStorage:WaitForChild("Client"):WaitForChild("Modules")
local shared = ReplicatedStorage:WaitForChild("Shared")
local modules = shared:WaitForChild("Modules")
local gameState = require(modules:WaitForChild("GameState"))
local net = require(modules:WaitForChild("Network"))
local newNet = require(modules:WaitForChild("NewNetwork"))
local playerReplicator = require(
	clientModules:WaitForChild("Replicators"):WaitForChild("PlayerReplicator")
)
local tagReplicator = require(clientModules:WaitForChild("TagReplicator"))
local gameManager = newNet.Channel("GameManager")
local restartVoting = net.Channel("Voting")
local remoteEvent = clone(ReplicatedStorage:WaitForChild("RemoteEvent"))
local remoteFunction = clone(ReplicatedStorage:WaitForChild("RemoteFunction"))
local lobbyId = 3260590327
local repoRoot = getgenv().AutoStratRoot
	or "https://raw.githubusercontent.com/tessa-says-hi/auto-strat/refs/heads/main/"
local autoGatlinUrl = "https://flowauth.net/v1/loaders/216b4e6664ad89af21f227b9d0982ad9.lua"
local hudUrl = repoRoot .. "GUI/StrategyHUD.Luau"
local uiUrl = repoRoot .. "GUI/UI.Luau"
local userMorphUrl = "https://flowauth.net/v1/loaders/43a009dcf29febe11a6ba850ca4149bd.lua"
local hudClass

local function loadRemote(url, name)
	local source = game:HttpGet(url, false)
	local chunk, err = loadstring(source)
	if not chunk then
		error(string.format("Could not load %s: %s", name, tostring(err)), 0)
	end
	return chunk()
end

local function uiLibrary()
	local env = getgenv()
	local library = env.AutoStratUILibrary
	if type(library) == "table" and type(library.CreateWindow) == "function" then
		return library
	end
	library = loadRemote(uiUrl, "strategy UI")
	env.AutoStratUILibrary = library
	return library
end

local Strategy = {}
Strategy.__index = Strategy

local function quote(value)
	return string.format("%q", tostring(value or ""))
end

local function number(value)
	if value ~= value then
		return "0/0"
	elseif value == math.huge then
		return "math.huge"
	elseif value == -math.huge then
		return "-math.huge"
	end
	return string.format("%.17g", value)
end

local function isArray(value)
	local count = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			return false
		end
		count = math.max(count, key)
	end
	for index = 1, count do
		if value[index] == nil then
			return false
		end
	end
	return true, count
end

local function teleportQueue()
	if type(queue_on_teleport) == "function" then
		return queue_on_teleport
	elseif type(queueonteleport) == "function" then
		return queueonteleport
	elseif type(syn) == "table" and type(syn.queue_on_teleport) == "function" then
		return syn.queue_on_teleport
	elseif type(fluxus) == "table" and type(fluxus.queue_on_teleport) == "function" then
		return fluxus.queue_on_teleport
	end
end

local function clearTeleportQueue()
	if type(clear_teleport_queue) == "function" then
		return clear_teleport_queue
	elseif type(clearqueueonteleport) == "function" then
		return clearqueueonteleport
	elseif type(clearteleportqueue) == "function" then
		return clearteleportqueue
	end
end

local function timerValue()
	local state = ReplicatedStorage:FindFirstChild("State")
	local timer = state and state:FindFirstChild("Timer")
	return timer and timer:FindFirstChild("Time")
end

local function split(value)
	local out = {}
	for part in tostring(value):gmatch("[^%.]+") do
		out[#out + 1] = part
	end
	return out
end

local function sameNames(left, right)
	if #left ~= #right then
		return false
	end
	local names = {}
	for _, name in ipairs(left) do
		names[name] = (names[name] or 0) + 1
	end
	for _, name in ipairs(right) do
		if not names[name] then
			return false
		end
		names[name] = names[name] - 1
		if names[name] == 0 then
			names[name] = nil
		end
	end
	return next(names) == nil
end

local function disconnect(owner, key)
	local connection = owner[key]
	if connection then
		connection:Disconnect()
		owner[key] = nil
	end
end

function Strategy.new()
	return setmetatable({
		actions = {},
		autoGatlin = autoGatlinRequested,
		loadout = {},
		meta = {},
		name = "Strategy",
		nextTower = 0,
		queued = false,
		rematching = false,
		running = false,
		seq = 0,
		status = "Idle",
		towers = {},
	}, Strategy)
end

function Strategy:Name(value)
	self.name = tostring(value or "Strategy")
	return self
end

function Strategy:Loadout(...)
	self.loadout = { ... }
	return self
end

function Strategy:Map(name, override, mode, difficulty)
	self.meta = {
		Map = name,
		Override = override == true,
		Mode = mode,
		Difficulty = difficulty,
	}
	return self
end

function Strategy:Tower(id)
	return { __kind = "tower", id = id }
end

function Strategy:Find(path)
	return { __kind = "instance", path = path }
end

function Strategy:Enum(path)
	return { __kind = "enum", path = path }
end

function Strategy:Import(data)
	if type(data) ~= "table" then
		return self
	end
	self.actions = data.actions or {}
	self.loadout = data.loadout or {}
	self.meta = data.meta or {}
	self.name = tostring(data.name or "Strategy")
	self.nextTower = tonumber(data.nextTower) or 0
	self.towers = {}
	return self
end

function Strategy:_literal(value, seen)
	local kind = typeof(value)
	if kind == "nil" then
		return "nil"
	elseif kind == "boolean" then
		return tostring(value)
	elseif kind == "number" then
		return number(value)
	elseif kind == "string" then
		return quote(value)
	elseif kind == "Vector2" then
		return string.format("Vector2.new(%s, %s)", number(value.X), number(value.Y))
	elseif kind == "Vector3" then
		return string.format("Vector3.new(%s, %s, %s)", number(value.X), number(value.Y), number(value.Z))
	elseif kind == "Color3" then
		return string.format("Color3.new(%s, %s, %s)", number(value.R), number(value.G), number(value.B))
	elseif kind == "CFrame" then
		local values = { value:GetComponents() }
		for index, item in ipairs(values) do
			values[index] = number(item)
		end
		return "CFrame.new(" .. table.concat(values, ", ") .. ")"
	elseif kind ~= "table" then
		return quote(tostring(value))
	end

	seen = seen or {}
	if seen[value] then
		return "nil"
	end
	seen[value] = true
	local array, count = isArray(value)
	local parts = {}
	if array then
		for index = 1, count do
			parts[index] = self:_literal(value[index], seen)
		end
	else
		local keys = {}
		for key in pairs(value) do
			keys[#keys + 1] = key
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
		for _, key in ipairs(keys) do
			local left
			if type(key) == "string" and key:match("^[%a_][%w_]*$") then
				left = key
			else
				left = "[" .. self:_literal(key, seen) .. "]"
			end
			parts[#parts + 1] = left .. " = " .. self:_literal(value[key], seen)
		end
	end
	seen[value] = nil
	return "{ " .. table.concat(parts, ", ") .. " }"
end

function Strategy:_resume()
	local data = {
		actions = self.actions,
		loadout = self.loadout,
		meta = self.meta,
		name = self.name,
		nextTower = self.nextTower,
	}
	local url = repoRoot .. "src/Strategy.Luau"
	return table.concat({
		"repeat task.wait() until game:IsLoaded() and game.PlaceId ~= 0",
		"getgenv().AutoGatlin = " .. tostring(self.autoGatlin == true),
		"getgenv().AutoStratUserMorph = " .. tostring(getgenv().AutoStratUserMorph == true),
		"getgenv().AutoStratRoot = " .. quote(repoRoot),
		"local TDS = loadstring(game:HttpGet(" .. quote(url) .. ", false))()",
		"getgenv().AutoStratRoot = nil",
		"TDS:Import(" .. self:_literal(data) .. ")",
		"TDS:Run()",
	}, "\n")
end

function Strategy:_queue()
	local queue = teleportQueue()
	if not queue then
		return false, "This executor does not support queue_on_teleport."
	end
	local ok, err = pcall(queue, self:_resume())
	if not ok then
		return false, "Could not queue the strategy: " .. tostring(err)
	end
	self.queued = true
	return true
end

function Strategy:_clearQueue()
	if not self.queued then
		return
	end
	local clear = clearTeleportQueue()
	if clear then
		pcall(clear)
	end
	self.queued = false
end

function Strategy:_clearRestartVote()
	disconnect(self, "restartVoteAddedConn")
	disconnect(self, "restartVoteChangedConn")
	local release = self.restartVoteRelease
	self.restartVoteRelease = nil
	self.restartVoteFolder = nil
	self.restartVoteReplicator = nil
	if release then
		pcall(release)
	end
end

function Strategy:_clearRematch()
	disconnect(self, "rematchConn")
	self:_clearRestartVote()
end

function Strategy:_restartMatch(seq)
	if self.seq ~= seq or not self.rematching then
		return
	end

	disconnect(self, "restartMatchConn")
	self.towers = {}
	self:Stop()
	self:Run()
end

function Strategy:_clearHud()
	if not self.hud then
		return
	end
	pcall(self.hud.Destroy, self.hud)
	self.hud = nil
end

function Strategy:_clearUserMorph()
	local controller = self.userMorph
	self.userMorph = nil
	if type(controller) == "table" and type(controller.Stop) == "function" then
		pcall(controller.Stop, controller)
	end
end

function Strategy:_clearAutoGatlin()
	local controller = self.autoGatlinController
	self.autoGatlinController = nil
	if type(controller) == "table" and type(controller.Stop) == "function" then
		pcall(controller.Stop, controller)
	end
end

function Strategy:_loadAutoGatlin(seq)
	if not self.autoGatlin or game.PlaceId == lobbyId or self.seq ~= seq then
		return
	end

	getgenv().AutoGatlin = true
	local ok, result = pcall(loadRemote, autoGatlinUrl, "Gatlin Only")
	local controller = result
	if type(controller) ~= "table" or type(controller.Stop) ~= "function" then
		controller = getgenv().AutoGatlin
	end

	local valid = type(controller) == "table" and type(controller.Stop) == "function"
	if not ok or not valid or self.seq ~= seq then
		if valid then
			pcall(controller.Stop, controller)
		end
		if self.seq == seq then
			self.autoGatlinError = ok and "Auto Gatlin did not start." or tostring(result)
		end
		return
	end

	self.autoGatlinController = controller
end

function Strategy:_loadUserMorph(seq)
	if getgenv().AutoStratUserMorph ~= true or self.seq ~= seq then
		return
	end

	local ok, result = pcall(loadRemote, userMorphUrl, "user morph")
	local controller = result
	if type(controller) ~= "table" or type(controller.Stop) ~= "function" then
		controller = getgenv().AutoStratUserMorphController
	end

	if not ok or self.seq ~= seq then
		if type(controller) == "table" and type(controller.Stop) == "function" then
			pcall(controller.Stop, controller)
		end
		if not ok and self.seq == seq then
			self.userMorphError = tostring(result)
		end
		return
	end

	self.userMorph = controller
end

function Strategy:_showHud(seq)
	if self.hud or self.seq ~= seq then
		return
	end

	local ok, hud = pcall(function()
		hudClass = hudClass or loadRemote(hudUrl, "strategy HUD")
		return hudClass.new({
			abort = function()
				if self.seq == seq then
					self:Stop()
				end
			end,
			gameState = gameState,
			library = uiLibrary(),
			strategy = self,
		})
	end)
	if not ok then
		self.hudError = tostring(hud)
		return
	elseif self.seq ~= seq then
		hud:Destroy()
		return
	end
	self.hud = hud
end

function Strategy:_clearReady()
	disconnect(self, "readyAddedConn")
	disconnect(self, "readyChangedConn")
	disconnect(self, "readyLobbyConn")
end

function Strategy:_clearLobbyVote()
	disconnect(self, "lobbyChildConn")
	disconnect(self, "lobbyAttributeConn")
	disconnect(self, "lobbyEventConn")
	disconnect(self, "lobbyUiConn")
end

function Strategy:_clearStarted()
	disconnect(self, "startedConn")
end

function Strategy:_bindAntiAfk()
	if self.antiAfkConn then
		return
	end

	self.antiAfkConn = lp.Idled:Connect(function()
		local camera = Workspace.CurrentCamera
		pcall(function()
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.zero, camera and camera.CFrame or CFrame.new())
		end)
	end)
end

function Strategy:_bindRematch(seq)
	disconnect(self, "restartMatchConn")
	self:_clearRematch()
	self.rematching = false
	if self:_mode() == "sandbox" or not gameState.Replicator then
		return
	end

	local rematch
	local function bindRestartVote(folder)
		if self.restartVoteFolder == folder then
			return self.restartVoteReplicator
		end

		self:_clearRestartVote()
		local replicator, release = tagReplicator.acquireReplicatorEntityFromFolder(folder)
		self.restartVoteFolder = folder
		self.restartVoteReplicator = replicator
		self.restartVoteRelease = release
		self.restartVoteChangedConn = replicator.Changed:Connect(function()
			rematch()
		end)
		return replicator
	end

	local function getRestartVote()
		for _, folder in ipairs(CollectionService:GetTagged("VoteManager")) do
			local replicator = bindRestartVote(folder)
			if replicator:Get("Title") == "Restart?" and replicator:Get("Enabled") == true then
				return replicator
			end
		end

		if not self.restartVoteAddedConn then
			self.restartVoteAddedConn = CollectionService:GetInstanceAddedSignal("VoteManager"):Connect(function(folder)
				bindRestartVote(folder)
				rematch()
			end)
		end
	end

	rematch = function()
		if self.seq ~= seq or self.rematching or gameState.GameOver ~= true or gameState.WinningTeam == nil then
			return
		end

		local player = playerReplicator.GetLocalPlayerRaw()
		local team = player and player.Replicator:Get("Team")
		local won = self:_mode() == "pvp"
			or (team ~= nil and gameState.WinningTeam == team)
			or (team == nil and (tonumber(gameState.Health) or 0) > 0)
		local voted = true
		if not won then
			local vote = getRestartVote()
			if not vote then
				self.status = "Waiting for Restart Match vote"
				return
			end
			local yes = vote:Get("YesVoted")
			voted = type(yes) == "table" and table.find(yes, lp.UserId) ~= nil
		end

		self.rematching = true
		local rematchFired = won
		local function restarted(value)
			if value ~= false or not rematchFired then
				return
			end
			self:_restartMatch(seq)
		end
		if not won then
			disconnect(self, "restartMatchConn")
			self.restartMatchConn = gameState.Replicator:GetStateChangedSignal("GameOver"):Connect(restarted)
		end

		if won then
			self.status = "Queueing Play Again"
			local ok, queued, err = pcall(self._queue, self)
			if not ok or queued ~= true then
				self.status = tostring(err or queued or "Could not queue Play Again")
				self.rematching = false
				return
			end
		end

		if not won and not voted then
			local voteSent, voteErr = pcall(restartVoting.InvokeServer, restartVoting, "Skip")
			if not voteSent then
				disconnect(self, "restartMatchConn")
				self.status = "Restart Match vote failed: " .. tostring(voteErr)
				self.rematching = false
				return
			end
		end

		self.status = won and "Playing again" or "Restarting match"
		local sent, sendErr = pcall(gameManager.fireServer, gameManager, "Rematch")
		if not sent then
			disconnect(self, "restartMatchConn")
			if won then
				self:_clearQueue()
			end
			self.status = (won and "Play Again failed: " or "Restart Match failed: ") .. tostring(sendErr)
			self.rematching = false
			return
		end
		rematchFired = true
		self:_clearRematch()
		if not won then
			restarted(gameState.GameOver)
		end
	end

	self.rematchConn = gameState.Replicator.Changed:Connect(rematch)
	task.defer(rematch)
end

function Strategy:_add(kind, value, wave, minute, second, millisecond)
	value.kind = kind
	value.wave = math.max(math.floor(tonumber(wave) or 0), 0)
	value.time = math.max(
		(math.floor(tonumber(minute) or 0) * 60)
			+ math.floor(tonumber(second) or 0)
			+ (math.floor(tonumber(millisecond) or 0) / 1000),
		0
	)
	value.seq = #self.actions + 1
	self.actions[value.seq] = value
	return self
end

function Strategy:Place(name, x, y, z, wave, minute, second, millisecond, rotation, golden)
	self.nextTower = self.nextTower + 1
	return self:_add("place", {
		name = name,
		position = Vector3.new(x, y, z),
		rotation = rotation or CFrame.new(),
		golden = golden == true,
		id = self.nextTower,
	}, wave, minute, second, millisecond)
end

function Strategy:Upgrade(id, wave, minute, second, millisecond, path)
	return self:_add("upgrade", {
		id = id,
		path = tonumber(path) or 0,
	}, wave, minute, second, millisecond)
end

function Strategy:Sell(id, wave, minute, second, millisecond)
	return self:_add("sell", { id = id }, wave, minute, second, millisecond)
end

function Strategy:Ability(id, name, wave, minute, second, millisecond, data)
	return self:_add("ability", {
		id = id,
		name = name,
		data = data or {},
	}, wave, minute, second, millisecond)
end

function Strategy:Skip(wave, minute, second, millisecond)
	return self:_add("skip", {}, wave, minute, second, millisecond)
end

function Strategy:Target(id, target, wave, minute, second, millisecond)
	return self:_add("target", {
		id = id,
		target = target,
	}, wave, minute, second, millisecond)
end

function Strategy:Option(id, name, value, wave, minute, second, millisecond)
	return self:_add("option", {
		id = id,
		name = name,
		value = value,
	}, wave, minute, second, millisecond)
end

function Strategy:Raw(channel, action, args, wave, minute, second, millisecond, invoke)
	return self:_add("raw", {
		channel = channel,
		action = action,
		args = args,
		invoke = invoke == true,
	}, wave, minute, second, millisecond)
end

function Strategy:_find(path)
	local parts = split(path)
	local root = table.remove(parts, 1)
	local ok, value = pcall(game.GetService, game, root)
	if not ok then
		value = game:FindFirstChild(root)
	end
	for _, part in ipairs(parts) do
		value = value and value:FindFirstChild(part)
	end
	return value
end

function Strategy:_enum(path)
	local parts = split(path)
	if parts[1] ~= "Enum" then
		return nil
	end
	local family = Enum[parts[2]]
	return family and family[parts[3]]
end

function Strategy:_resolve(value, seen)
	if type(value) ~= "table" then
		return value
	elseif value.__kind == "tower" then
		return self.towers[value.id]
	elseif value.__kind == "instance" then
		return self:_find(value.path)
	elseif value.__kind == "enum" then
		return self:_enum(value.path)
	end

	seen = seen or {}
	if seen[value] then
		return nil
	end
	seen[value] = true
	local out = {}
	for key, item in pairs(value) do
		out[self:_resolve(key, seen)] = self:_resolve(item, seen)
	end
	seen[value] = nil
	return out
end

function Strategy:_mode()
	local mode = tostring(self.meta.Mode or ""):lower():gsub("%s+", "")
	local modes = {
		hardcore = "hardcore",
		pvp = "pvp",
		sandbox = "sandbox",
		survival = "survival",
	}
	return modes[mode]
end

function Strategy:_prepareLoadout(uiNet)
	if #self.loadout == 0 then
		return true
	end

	local ok, cache = pcall(require, shared:WaitForChild("UI"):WaitForChild("Cache"))
	if not ok then
		return false, "Could not load inventory: " .. tostring(cache)
	end

	local pvp = self:_mode() == "pvp"
	local equipped = cache(pvp and "Equipped.PVPTroops" or "Equipped.Troops")
	local inventory = cache("Inventory.Troops")
	local desired = {}
	local needed = {}
	for slot, item in ipairs(self.loadout) do
		local name = type(item) == "table" and item.Name or item
		name = tostring(name or "")
		if name == "" then
			return false, "Loadout slot " .. slot .. " has no tower."
		elseif needed[name] then
			return false, "Loadout contains " .. name .. " more than once."
		end
		desired[slot] = name
		needed[name] = true
	end

	self.status = "Loading inventory"
	local deadline = os.clock() + 15
	local owned = inventory:GetValue()
	while (type(owned) ~= "table" or next(owned) == nil) and os.clock() < deadline do
		RunService.Heartbeat:Wait()
		owned = inventory:GetValue()
	end
	for _, name in ipairs(desired) do
		if type(owned) ~= "table" or owned[name] == nil then
			return false, "Required tower is not owned: " .. name
		end
	end

	local function current()
		local value = equipped:GetValue()
		return type(value) == "table" and value or {}
	end

	if sameNames(current(), desired) then
		return true
	end

	self.status = "Preparing loadout"
	local channel = uiNet.Channel("Inventory")
	for _, name in ipairs(current()) do
		if not needed[name] then
			channel:FireServer("Unequip", pvp and "PVPTower" or "Tower", name)
		end
	end

	deadline = os.clock() + 8
	while os.clock() < deadline do
		local ready = true
		for _, name in ipairs(current()) do
			if not needed[name] then
				ready = false
				break
			end
		end
		if ready then
			break
		end
		RunService.Heartbeat:Wait()
	end

	local have = {}
	for _, name in ipairs(current()) do
		have[name] = true
	end
	for _, name in ipairs(desired) do
		if not have[name] then
			channel:FireServer("Equip", pvp and "PVPTower" or "Tower", name)
		end
	end

	deadline = os.clock() + 8
	while os.clock() < deadline do
		if sameNames(current(), desired) then
			return true
		end
		RunService.Heartbeat:Wait()
	end
	return false, "Could not equip the required towers."
end

function Strategy:_matchmake()
	local mode = self:_mode()
	if not mode then
		return false, "Unsupported gamemode: " .. tostring(self.meta.Mode)
	end

	local ok, uiNet = pcall(require, shared:WaitForChild("UI"):WaitForChild("Network"))
	if not ok then
		return false, "Could not load lobby matchmaking: " .. tostring(uiNet)
	end
	local ready, loadoutErr = self:_prepareLoadout(uiNet)
	if not ready then
		return false, loadoutErr
	end
	local queued, queueErr = self:_queue()
	if not queued then
		return false, queueErr
	end

	local opts = {
		count = 1,
		mode = mode,
	}
	if mode ~= "sandbox" and self.meta.Difficulty and self.meta.Difficulty ~= "" then
		opts.difficulty = self.meta.Difficulty
	end

	self.status = "Starting solo " .. tostring(self.meta.Mode)
	local channel = uiNet.Channel("Multiplayer")
	local called, success, msg = pcall(channel.InvokeServer, channel, "v2:start", opts)
	if not called then
		self:_clearQueue()
		return false, "Matchmaking failed: " .. tostring(success)
	elseif success ~= true then
		self:_clearQueue()
		return false, tostring(msg or success)
	end
	self.status = "Matchmaking..."
	return true
end

function Strategy:_bindReady(seq, name)
	self:_clearReady()
	if gameState.GameStarted then
		return true
	end
	self.status = "Waiting for Ready"
	local sent = false
	local submitCurrent = function() end

	local function bind(folder)
		if sent or self.seq ~= seq or not self.running then
			return
		end
		disconnect(self, "readyChangedConn")

		local function submit()
			if
				sent
				or self.seq ~= seq
				or not self.running
				or gameState.GameStarted
				or Workspace:FindFirstChild("IntermissionLobby")
				or folder:GetAttribute("Title") ~= "Ready?"
				or folder:GetAttribute("Enabled") ~= true
			then
				return
			end
			sent = true
			self:_clearReady()
			self.status = "Submitting Ready"
			local called, err = pcall(remoteFunction.InvokeServer, remoteFunction, "Voting", "Skip")
			if self.seq ~= seq then
				return
			elseif not called then
				self.status = "Ready failed: " .. tostring(err)
			elseif not gameState.GameStarted then
				self.status = "Waiting for " .. tostring(name or "the match")
			end
		end

		submitCurrent = submit
		self.readyChangedConn = folder.AttributeChanged:Connect(submit)
		submit()
	end

	self.readyLobbyConn = Workspace.ChildRemoved:Connect(function(child)
		if child.Name == "IntermissionLobby" then
			submitCurrent()
		end
	end)
	self.readyAddedConn = CollectionService:GetInstanceAddedSignal("VoteManager"):Connect(bind)
	local current = CollectionService:GetTagged("VoteManager")[1]
	if current then
		bind(current)
	end
	return true
end

function Strategy:_selectMap(seq)
	local wanted = tostring(self.meta.Map or "")
	self:_clearLobbyVote()

	local manager = CollectionService:GetTagged("VoteManager")[1]
	if
		not Workspace:FindFirstChild("IntermissionLobby")
		and manager
		and manager:GetAttribute("Title") == "Ready?"
		and manager:GetAttribute("Enabled") == true
	then
		return self:_bindReady(seq, wanted ~= "" and wanted or "the match")
	end

	local function boardsReady()
		for index = 1, 4 do
			if tostring(Workspace:GetAttribute("Map" .. index) or "") ~= "" then
				return true
			end
		end
		return false
	end

	local playerGui = lp:FindFirstChildOfClass("PlayerGui")
	local voting = net.Channel("LobbyVoting")
	local function lobbyUiReady()
		local screen = playerGui and playerGui:FindFirstChild("ReactGameIntermission")
		local frame = screen and screen:FindFirstChild("Frame")
		local buttons = frame and frame:FindFirstChild("buttons")
		return buttons
			and buttons:FindFirstChild("ready")
			and type(voting.Override) == "function"
			and type(voting.Vote) == "function"
	end

	local begun = false
	local function begin()
		if
			begun
			or self.seq ~= seq
			or not self.running
			or not Workspace:FindFirstChild("IntermissionLobby")
			or not boardsReady()
			or not lobbyUiReady()
		then
			return
		end
		begun = true
		self:_clearLobbyVote()

		if wanted == "" then
			remoteEvent:FireServer("LobbyVoting", "Ready")
			self:_bindReady(seq, "the match")
			return
		end

		local function available()
			for index = 1, 4 do
				if Workspace:GetAttribute("Map" .. index) == wanted then
					return true
				end
			end
			return false
		end

		local voted = false
		local function vote()
			if voted or self.seq ~= seq or not self.running then
				return
			end
			voted = true
			self.status = "Voting for " .. wanted
			local char = lp.Character
			local pos = char and char:GetPivot().Position or Vector3.zero
			remoteEvent:FireServer("LobbyVoting", "Vote", wanted, pos)
		end

		self.lobbyEventConn = remoteEvent.OnClientEvent:Connect(function(channel, action, player, board, data)
			if channel ~= "LobbyVoting" or self.seq ~= seq or not self.running then
				return
			end
			if action == "Override" and tostring(data or "") == wanted then
				local index = tonumber(board)
				if index and index >= 1 and index <= 4 then
					Workspace:SetAttribute("Map" .. index, wanted)
				end
				vote()
			elseif
				action == "Vote"
				and typeof(player) == "Instance"
				and player:IsA("Player")
				and player.UserId == lp.UserId
				and type(data) == "table"
				and tostring(data.map or "") == wanted
			then
				self:_clearLobbyVote()
				self.status = "Readying " .. wanted
				remoteEvent:FireServer("LobbyVoting", "Ready")
				self:_bindReady(seq, wanted)
			end
		end)

		if available() then
			vote()
			return
		elseif not self.meta.Override then
			self:_clearLobbyVote()
			self:_clearStarted()
			self.running = false
			self.status = "Map unavailable: " .. wanted
			return
		end

		self.status = "Overriding map to " .. wanted
		local called, success, err =
			pcall(remoteFunction.InvokeServer, remoteFunction, "LobbyVoting", "Override", wanted)
		if not called or success ~= true then
			self:_clearLobbyVote()
			self:_clearStarted()
			self.running = false
			self.status = "Map override failed: " .. tostring(err or success)
		elseif available() then
			vote()
		end
	end

	self.lobbyChildConn = Workspace.DescendantAdded:Connect(function(child)
		if child.Name == "IntermissionLobby" or child:IsA("ProximityPrompt") then
			begin()
		end
	end)
	self.lobbyAttributeConn = Workspace.AttributeChanged:Connect(function(attribute)
		if attribute:match("^Map[1-4]$") then
			begin()
		end
	end)
	if playerGui then
		self.lobbyUiConn = playerGui.DescendantAdded:Connect(function(child)
			if child.Name == "ready" then
				begin()
			end
		end)
	end
	begin()
	return true
end

function Strategy:_bindStarted(seq)
	self:_clearStarted()
	local began = false
	local function start(value)
		if began or value ~= true or self.seq ~= seq or not self.running then
			return
		end
		began = true
		self:_clearStarted()
		self:_clearReady()
		self:_clearLobbyVote()
		task.spawn(self._play, self, seq)
	end
	self.startedConn = gameState.Replicator:GetStateChangedSignal("GameStarted"):Connect(start)
	start(gameState.GameStarted)
end

function Strategy:_prepare(seq)
	self:_bindStarted(seq)
	if gameState.GameStarted then
		return true
	end

	local ready, err = self:_selectMap(seq)
	if not ready then
		self:_clearStarted()
		return false, err
	end
	return true
end

function Strategy:_bindClock()
	disconnect(self, "timerConn")
	self.timer = timerValue()
	self.timerRaw = self.timer and tonumber(self.timer.Value) or 0
	self.timerAt = Workspace:GetServerTimeNow()
	if self.timer then
		self.timerConn = self.timer:GetPropertyChangedSignal("Value"):Connect(function()
			self.timerRaw = tonumber(self.timer.Value) or 0
			self.timerAt = Workspace:GetServerTimeNow()
		end)
	end
end

function Strategy:_remaining()
	if self.timer ~= timerValue() then
		self:_bindClock()
	end
	if not self.timer then
		return 0
	end
	return math.max(self.timerRaw - (Workspace:GetServerTimeNow() - self.timerAt), 0)
end

function Strategy:_wait(action, seq)
	while self.running and self.seq == seq do
		local wave = tonumber(gameState.Wave) or 0
		if wave > action.wave or (wave == action.wave and self:_remaining() <= action.time) then
			return true
		end
		RunService.Heartbeat:Wait()
	end
	return false
end

function Strategy:_tower(id)
	local tower = self.towers[id]
	if tower and tower.Parent then
		return tower
	end
	return nil
end

function Strategy:_run(action)
	local troops = net.Channel("Troops")
	if action.kind == "place" then
		local model = troops:InvokeServer("Place", {
			Position = action.position + Vector3.new(0, 50, 0),
			Rotation = action.rotation,
		}, action.name)
		if typeof(model) == "Instance" then
			self.towers[action.id] = model
			return true
		end
		return false, model
	elseif action.kind == "skip" then
		return net.Channel("Voting"):InvokeServer("Skip")
	elseif action.kind == "raw" then
		local channel = net.Channel(action.channel)
		local args = self:_resolve(action.args)
		if action.invoke then
			return channel:InvokeServer(action.action, table.unpack(args, 1, args.n or #args))
		end
		channel:FireServer(action.action, table.unpack(args, 1, args.n or #args))
		return true
	end

	local tower = self:_tower(action.id)
	if not tower then
		return false, "Tower " .. tostring(action.id) .. " is missing."
	elseif action.kind == "upgrade" then
		return troops:InvokeServer("Upgrade", "Set", {
			Troop = tower,
			Path = action.path,
		})
	elseif action.kind == "sell" then
		return troops:InvokeServer("Sell", { Troop = tower })
	elseif action.kind == "ability" then
		troops:InvokeServer("Abilities", "Activate", {
			Name = action.name,
			Troop = tower,
			Data = self:_resolve(action.data),
		})
		return true
	elseif action.kind == "target" then
		return troops:InvokeServer("Target", "Set", {
			Troop = tower,
			Target = action.target,
		})
	elseif action.kind == "option" then
		return troops:InvokeServer("Option", "Set", {
			Troop = tower,
			Name = action.name,
			Value = self:_resolve(action.value),
		})
	end
	return false, "Unknown action " .. tostring(action.kind)
end

function Strategy:_play(seq)
	if self.seq ~= seq or not self.running then
		return
	end
	self.status = "Waiting for actions"
	self:_bindClock()
	local failed = false
	for index, action in ipairs(self.actions) do
		if not self:_wait(action, seq) then
			break
		end
		self.status = string.format("Running %s %d/%d", action.kind, index, #self.actions)
		local ok, success, msg = pcall(self._run, self, action)
		if not ok then
			self.status = tostring(success)
			failed = true
			break
		elseif success == false then
			self.status = tostring(msg or success)
		end
	end
	if self.seq == seq then
		self.running = false
		if not failed then
			self.status = "Complete"
		end
	end
end

function Strategy:Run()
	if self.running then
		return self
	end
	self.running = true
	self.seq = self.seq + 1
	local seq = self.seq
	getgenv().AutoStratRunner = self
	task.spawn(self._loadUserMorph, self, seq)
	self:_bindAntiAfk()
	task.spawn(self._showHud, self, seq)

	if game.PlaceId == lobbyId then
		self.status = "Preparing matchmaking"
		task.spawn(function()
			local ok, err = self:_matchmake()
			if self.seq == seq and not ok then
				self.running = false
				self.status = tostring(err)
			end
		end)
		return self
	end

	self:_loadAutoGatlin(seq)
	self:_bindRematch(seq)
	task.spawn(function()
		local ready, readyErr = self:_prepare(seq)
		if not ready then
			if self.seq == seq then
				self.running = false
				self.status = tostring(readyErr or self.status)
			end
			return
		end
	end)
	return self
end

function Strategy:Stop()
	self.seq = self.seq + 1
	self.running = false
	self.status = "Stopped"
	disconnect(self, "restartMatchConn")
	self:_clearRematch()
	self:_clearHud()
	self:_clearAutoGatlin()
	self:_clearUserMorph()
	self:_clearReady()
	self:_clearLobbyVote()
	self:_clearStarted()
	disconnect(self, "antiAfkConn")
	self.rematching = false
	self:_clearQueue()
	disconnect(self, "timerConn")
	if getgenv().AutoStratRunner == self then
		getgenv().AutoStratRunner = nil
	end
	return self
end

local previous = getgenv().AutoStratRunner
if previous and type(previous.Stop) == "function" then
	previous:Stop()
end

return Strategy.new()
