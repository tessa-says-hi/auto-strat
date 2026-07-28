local clone = cloneref or function(value)
	return value
end

local env = type(getgenv) == "function" and getgenv() or shared or _G
local Players = clone(game:GetService("Players"))
local ReplicatedStorage = clone(game:GetService("ReplicatedStorage"))
local TeleportService = clone(game:GetService("TeleportService"))
local Workspace = clone(game:GetService("Workspace"))

local lp = clone(Players.LocalPlayer)
local net = require(ReplicatedStorage.Shared.Modules.Network)
local gameState = require(ReplicatedStorage.Shared.Modules.GameState)
local playerLib = require(ReplicatedStorage.Client.Modules.Replicators.PlayerReplicator)
local towerLib = require(ReplicatedStorage.Client.Modules.Replicators.TowerReplicator)

local Recorder = {}
Recorder.__index = Recorder

local watched = {
	LobbyVoting = true,
	Troops = true,
	Voting = true,
}

local names = {
	abilities = "ability",
	option = "option",
	place = "place",
	sell = "sell",
	target = "target",
	upgrade = "upgrade",
}

local function cleanName(value)
	local name = tostring(value or ""):gsub("[^%w%s_%-]", ""):match("^%s*(.-)%s*$")
	return name ~= "" and name or "MyStrategy"
end

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

local function timerValue()
	local state = ReplicatedStorage:FindFirstChild("State")
	local timer = state and state:FindFirstChild("Timer")
	return timer and timer:FindFirstChild("Time")
end

local function disconnect(owner, key)
	local connection = owner[key]
	if connection then
		connection:Disconnect()
		owner[key] = nil
	end
end

local function resetLibrary(library)
	local container = library.container
	local screen = container and container:FindFirstAncestorOfClass("ScreenGui")
	if screen then
		screen:Destroy()
	end
	library.container = nil
	library.count = 0
	library.toggled = true
	library.binding = false
	for _, key in ipairs({ "queue", "callbacks", "rainbowtable", "binds" }) do
		if type(library[key]) == "table" then
			table.clear(library[key])
		end
	end
end

local function loadUiLibrary()
	local library = env.AutoStratRecorderUILibrary
	if type(library) == "table" and type(library.CreateWindow) == "function" then
		return library
	end

	local path = "GUI/UI.Luau"
	local source = type(env.AutoStratSources) == "table" and env.AutoStratSources[path]
	if not source then
		local root = env.AutoStratRepo or "https://raw.githubusercontent.com/tessa-says-hi/auto-strat/main/"
		source = game:HttpGet(root .. path, true)
	end
	local chunk, err = loadstring(source)
	if not chunk then
		error("Could not load recorder UI: " .. tostring(err), 0)
	end
	library = chunk()
	env.AutoStratRecorderUILibrary = library
	return library
end

local function shortStatus(value)
	return tostring(value or ""):match("^[^\r\n]*") or ""
end

local function towerModel(value)
	if typeof(value) ~= "Instance" then
		return nil
	end
	local towers = Workspace:FindFirstChild("Towers")
	if not towers then
		return nil
	end
	local model = value
	while model and model.Parent ~= towers do
		model = model.Parent
	end
	return model
end

local function towerInfo(model)
	local tower = model and towerLib.getTowerByModel(model)
	if not tower then
		return nil
	end
	return tower, tower.TowerName, tower.GoldenPerks == true
end

local function loadout()
	local player = playerLib.GetLocalPlayerRaw()
	local equipped = player and player.EquippedTowers or {}
	local inventory = {}
	local ok, cache = pcall(require, ReplicatedStorage.Client.Modules.Cache)
	if ok then
		local item = cache("Inventory.Troops")
		inventory = item and item:GetValue() or {}
	end

	local out = {}
	for slot = 1, 6 do
		local name = equipped[slot]
		if name then
			local owned = inventory[name]
			out[#out + 1] = {
				Name = name,
				Golden = type(owned) == "table" and owned.GoldenPerks == true,
			}
		end
	end
	return out
end

local function metadata()
	local data = TeleportService:GetLocalPlayerTeleportData() or {}
	local function pick(...)
		for index = 1, select("#", ...) do
			local value = select(index, ...)
			if value ~= nil and value ~= "" then
				return value
			end
		end
		return ""
	end
	local map = pick(gameState.MapName, data.Map)
	local mode = pick(gameState.GameMode, data.Mode)
	local difficulty = pick(gameState.Difficulty, data.Difficulty)
	return {
		Map = map,
		Mode = mode,
		Difficulty = difficulty,
		Loadout = loadout(),
	}
end

function Recorder.new()
	return setmetatable({
		active = false,
		actions = {},
		autoSkip = false,
		autoSkipStatus = "Auto Skip is off.",
		installed = false,
		last = "Nothing recorded yet.",
		meta = metadata(),
		name = "MyStrategy",
		nextTower = 0,
		status = "Ready to record a strategy.",
		towerIds = setmetatable({}, { __mode = "k" }),
		uiSeq = 0,
		uiText = {},
	}, Recorder)
end

function Recorder:_bindClock()
	if self.timerConn then
		self.timerConn:Disconnect()
	end
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

function Recorder:_stamp()
	if self.timer ~= timerValue() then
		self:_bindClock()
	end
	local left = self.timerRaw or 0
	if self.timer then
		left = math.max(left - (Workspace:GetServerTimeNow() - self.timerAt), 0)
	end
	local total = math.floor(left * 1000 + 0.5)
	return {
		wave = math.max(tonumber(gameState.Wave) or 0, 0),
		minute = math.floor(total / 60000),
		second = math.floor(total / 1000) % 60,
		millisecond = total % 1000,
	}
end

function Recorder:_push(kind, value)
	value.kind = kind
	value.at = self:_stamp()
	value.seq = #self.actions + 1
	self.actions[value.seq] = value
	self.last = string.format("%s #%d", names[kind] or kind, value.seq)
	self.status = string.format("Recording %s", self.name)
	self:QueueAutosave()
end

function Recorder:_snapshot(value, seen)
	local kind = typeof(value)
	if kind == "Instance" then
		local model = self.towerIds[value] and value or towerModel(value)
		local id = model and self.towerIds[model]
		if id then
			return { __kind = "tower", id = id }
		end
		return { __kind = "instance", path = value:GetFullName() }
	elseif kind == "EnumItem" then
		return { __kind = "enum", path = tostring(value) }
	elseif kind ~= "table" then
		return value
	end

	seen = seen or {}
	if seen[value] then
		return "<cycle>"
	end
	seen[value] = true
	local out = {}
	for key, item in pairs(value) do
		out[self:_snapshot(key, seen)] = self:_snapshot(item, seen)
	end
	seen[value] = nil
	return out
end

function Recorder:_literal(value, seen)
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

	if value.__kind == "tower" then
		return string.format("TDS:Tower(%d)", value.id)
	elseif value.__kind == "instance" then
		return "TDS:Find(" .. quote(value.path) .. ")"
	elseif value.__kind == "enum" then
		return "TDS:Enum(" .. quote(value.path) .. ")"
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

function Recorder:_golden(name)
	for _, item in ipairs(self.meta.Loadout or {}) do
		if item.Name == name then
			return item.Golden == true
		end
	end
	local ok, cache = pcall(require, ReplicatedStorage.Client.Modules.Cache)
	if not ok then
		return false
	end
	local inventory = cache("Inventory.Troops"):GetValue()
	local item = type(inventory) == "table" and inventory[name]
	return type(item) == "table" and item.GoldenPerks == true
end

function Recorder:_id(model)
	local direct = self.towerIds[model]
	if direct then
		return direct
	end
	model = towerModel(model)
	if not model then
		return nil
	end
	local id = self.towerIds[model]
	if id then
		return id
	end

	local tower, name, golden = towerInfo(model)
	if not tower or tower.OwnerId ~= lp.UserId then
		return nil
	end
	self.nextTower = self.nextTower + 1
	id = self.nextTower
	self.towerIds[model] = id

	local pivot = model:GetPivot()
	self:_push("place", {
		id = id,
		name = name,
		position = pivot.Position,
		rotation = pivot - pivot.Position,
		golden = golden,
		existing = true,
	})
	return id
end

function Recorder:_placed(model, placement, name)
	model = towerModel(model)
	if not model then
		return
	end
	local id = self.towerIds[model]
	if not id then
		self.nextTower = self.nextTower + 1
		id = self.nextTower
		self.towerIds[model] = id
	end
	self:_push("place", {
		id = id,
		name = name,
		position = placement.Position,
		rotation = placement.Rotation,
		golden = self:_golden(name),
	})
end

function Recorder:_raw(channel, action, args, invoke)
	if not watched[channel] then
		return
	end
	self:_push("raw", {
		channel = channel,
		action = action,
		args = self:_snapshot(args),
		invoke = invoke,
	})
end

function Recorder:_captureInvoke(channel, action, args, result)
	if not self.active then
		return
	end

	if channel == "Troops" then
		local mode = args[1]
		local data = args[2]
		if action == "Place" then
			if typeof(result[1]) == "Instance" and type(mode) == "table" then
				self:_placed(result[1], mode, data)
			end
			return
		elseif action == "Upgrade" then
			if result[1] == true and type(data) == "table" then
				local id = self:_id(data.Troop)
				if id then
					self:_push("upgrade", { id = id, path = tonumber(data.Path) or 0 })
				end
			end
			return
		elseif action == "Sell" then
			if result[1] == true and type(mode) == "table" then
				local id = self:_id(mode.Troop)
				if id then
					self:_push("sell", { id = id })
				end
			end
			return
		elseif action == "Abilities" and mode == "Activate" and type(data) == "table" then
			local id = self:_id(data.Troop)
			if id then
				self:_push("ability", {
					id = id,
					name = data.Name,
					data = self:_snapshot(data.Data or {}),
				})
			end
			return
		elseif action == "Target" then
			if result[1] and type(data) == "table" then
				local id = self:_id(data.Troop)
				if id then
					self:_push("target", { id = id, target = data.Target })
				end
			end
			return
		elseif action == "Option" then
			if result[1] == true and type(data) == "table" then
				local id = self:_id(data.Troop)
				if id then
					self:_push("option", {
						id = id,
						name = data.Name,
						value = self:_snapshot(data.Value),
					})
				end
			end
			return
		end
	elseif channel == "Voting" and action == "Skip" then
		if gameState.GameStarted and (tonumber(gameState.Wave) or 0) > 0 and result[1] == true then
			self:_push("skip", {})
		end
		return
	end

	self:_raw(channel, action, args, true)
end

function Recorder:_captureFire(channel, action, args)
	if not self.active or (channel == "LobbyVoting" and action == "Ready") then
		return
	end
	self:_raw(channel, action, args, false)
end

function Recorder:Install()
	if self.installed then
		return true
	end
	if type(hookfunction) ~= "function" then
		self.status = "Recorder needs hookfunction."
		return false
	end

	local channel = net.Channel("Troops")
	local mt = getmetatable(channel)
	local methods = mt and mt.__index
	local invoke = type(methods) == "table" and methods.InvokeServer
	local fire = type(methods) == "table" and methods.FireServer
	if type(invoke) ~= "function" or type(fire) ~= "function" then
		self.status = "TDS network methods were not found."
		return false
	end

	local okInvoke, oldInvoke = pcall(hookfunction, invoke, function(ch, action, ...)
		local args = table.pack(...)
		local result = table.pack(self.oldInvoke(ch, action, ...))
		local ok, err = pcall(self._captureInvoke, self, ch.Channel, action, args, result)
		if not ok then
			self.status = "Recorder hook error: " .. tostring(err)
		end
		return table.unpack(result, 1, result.n)
	end)
	if not okInvoke or type(oldInvoke) ~= "function" then
		self.status = "Could not hook InvokeServer: " .. tostring(oldInvoke)
		return false
	end
	self.oldInvoke = oldInvoke
	self.invoke = invoke

	local okFire, oldFire = pcall(hookfunction, fire, function(ch, action, ...)
		local args = table.pack(...)
		self.oldFire(ch, action, ...)
		local ok, err = pcall(self._captureFire, self, ch.Channel, action, args)
		if not ok then
			self.status = "Recorder hook error: " .. tostring(err)
		end
	end)
	if not okFire or type(oldFire) ~= "function" then
		pcall(hookfunction, invoke, oldInvoke)
		self.invoke = nil
		self.oldInvoke = nil
		self.status = "Could not hook FireServer: " .. tostring(oldFire)
		return false
	end
	self.oldFire = oldFire
	self.fire = fire
	self.installed = true
	return true
end

function Recorder:_captureExisting()
	local towers = Workspace:FindFirstChild("Towers")
	if not towers then
		return 0
	end
	local found = {}
	for _, model in ipairs(towers:GetChildren()) do
		local tower = towerLib.getTowerByModel(model)
		if tower and tower.OwnerId == lp.UserId and tower:IsAlive() then
			found[#found + 1] = model
		end
	end
	table.sort(found, function(a, b)
		local left = towerLib.getTowerByModel(a)
		local right = towerLib.getTowerByModel(b)
		return tostring(left and left.Replicator:Get("UID") or a) < tostring(right and right.Replicator:Get("UID") or b)
	end)
	for _, model in ipairs(found) do
		self:_id(model)
	end
	return #found
end

function Recorder:Autosave()
	if #self.actions == 0 then
		return false
	end
	if type(writefile) ~= "function" then
		self.autosaveError = "writefile is not supported by this executor."
		return false
	end

	local folder = "auto-strat"
	local stem = cleanName(self.name):gsub("%s+", "_")
	local file = folder .. "/" .. stem .. ".luau"
	local backup = folder .. "/" .. stem .. "_autosave_backup.luau"
	local ready, folderErr = pcall(function()
		if type(isfolder) == "function" and type(makefolder) == "function" and not isfolder(folder) then
			makefolder(folder)
		end
	end)
	if not ready then
		self.autosaveError = "folder failed: " .. tostring(folderErr)
		return false
	end

	local built, source = pcall(self.Export, self)
	if not built then
		self.autosaveError = "export failed: " .. tostring(source)
		return false
	end
	local backedUp, backupErr = pcall(writefile, backup, source)
	if not backedUp then
		self.autosaveError = "backup failed: " .. tostring(backupErr)
		return false
	end

	self.autosaveBackup = backup
	self.autosaveCount = #self.actions
	self.autosaveName = self.name
	local saved, saveErr = pcall(writefile, file, source)
	if not saved then
		self.autosaveError = "primary failed; recovery saved to " .. backup .. ": " .. tostring(saveErr)
		return true, backup
	end

	self.autosaveFile = file
	self.autosaveError = nil
	return true, file
end

function Recorder:QueueAutosave()
	if self.autosaveQueued or #self.actions == 0 then
		return
	end
	self.autosaveQueued = true
	task.defer(function()
		if not self.autosaveQueued then
			return
		end
		self.autosaveQueued = false
		self:Autosave()
	end)
end

function Recorder:Start(name)
	if not self:Install() then
		return false
	end
	self.autosaveQueued = false
	self.autosaveCount = nil
	self.autosaveName = nil
	self.autosaveError = nil
	self.autosaveFile = nil
	self.autosaveBackup = nil
	self.name = cleanName(name or self.name)
	self.actions = {}
	self.nextTower = 0
	self.towerIds = setmetatable({}, { __mode = "k" })
	self.meta = metadata()
	self.active = true
	self.last = "Waiting for your first action."
	self:_bindClock()
	local existing = self:_captureExisting()
	self.status = existing > 0 and string.format("Recording %s; captured %d placed tower(s).", self.name, existing)
		or "Recording " .. self.name
	return true
end

function Recorder:Stop()
	self.active = false
	self.status = string.format("Stopped with %d action(s).", #self.actions)
	self.autosaveQueued = false
	if
		#self.actions > 0
		and (self.autosaveCount ~= #self.actions or self.autosaveName ~= self.name or self.autosaveError)
	then
		self:Autosave()
	end
	return self
end

function Recorder:Clear()
	self.autosaveQueued = false
	self.autosaveCount = nil
	self.autosaveName = nil
	self.autosaveError = nil
	self.autosaveFile = nil
	self.autosaveBackup = nil
	self.actions = {}
	self.nextTower = 0
	self.towerIds = setmetatable({}, { __mode = "k" })
	self.last = "Nothing recorded yet."
	self.status = self.active and "Recording " .. self.name or "Recorder cleared."
	return self
end

function Recorder:SetName(value)
	local before = self.name
	self.name = cleanName(value)
	if self.active and #self.actions > 0 and self.name ~= before then
		self:QueueAutosave()
	end
	return self
end

function Recorder:_bindSkipTimer()
	local timer = timerValue()
	if self.autoSkipTimer == timer then
		return
	end
	disconnect(self, "autoSkipTimerConn")
	self.autoSkipTimer = timer
	if timer then
		self.autoSkipTimerConn = timer:GetPropertyChangedSignal("Value"):Connect(function()
			self:_queueAutoSkip()
		end)
	end
end

function Recorder:_tryAutoSkip()
	if not self.autoSkip or self.skipInFlight then
		return
	end

	self:_bindSkipTimer()
	local wave = tonumber(gameState.Wave) or 0
	if not gameState.GameStarted or gameState.GameOver or wave <= 0 then
		self.autoSkipVotedWave = nil
		self.autoSkipStatus = "Waiting for a wave to start."
		return
	end
	if self.autoSkipVotedWave == wave then
		self.autoSkipStatus = string.format("Skip submitted for wave %d.", wave)
		return
	end

	local seq = self.autoSkipSeq
	self.skipInFlight = true
	task.spawn(function()
		local voting = net.Channel("Voting")
		local ok, accepted = pcall(voting.InvokeServer, voting, "Skip")
		self.skipInFlight = false
		if self.autoSkip and self.autoSkipSeq == seq then
			if ok and accepted == true then
				self.autoSkipVotedWave = wave
				self.autoSkipStatus = string.format("Skip submitted for wave %d.", wave)
			elseif ok then
				self.autoSkipStatus = string.format("Waiting for the wave %d skip vote.", wave)
			else
				self.autoSkipStatus = "Auto Skip error: " .. shortStatus(accepted)
			end
		end
		if self.autoSkip and self.skipPending then
			self.skipPending = false
			self:_queueAutoSkip()
		end
	end)
end

function Recorder:_queueAutoSkip()
	if not self.autoSkip then
		return
	end
	if self.skipInFlight then
		self.skipPending = true
		return
	end
	if self.skipQueued then
		return
	end
	self.skipQueued = true
	task.defer(function()
		self.skipQueued = false
		self:_tryAutoSkip()
	end)
end

function Recorder:SetAutoSkip(value)
	value = value == true
	if self.autoSkip == value and (not value or self.autoSkipGameConn) then
		return self
	end

	self.autoSkip = value
	self.autoSkipSeq = (self.autoSkipSeq or 0) + 1
	self.skipQueued = false
	self.skipPending = false
	self.autoSkipVotedWave = nil
	disconnect(self, "autoSkipGameConn")
	disconnect(self, "autoSkipTimerConn")
	self.autoSkipTimer = nil

	if not value then
		self.autoSkipStatus = "Auto Skip is off."
		return self
	end

	self.autoSkipStatus = "Watching for the next skip vote."
	local replicator = gameState.Replicator
	if replicator and replicator.Changed then
		local ok, connection = pcall(function()
			return replicator.Changed:Connect(function()
				self:_bindSkipTimer()
				self:_queueAutoSkip()
			end)
		end)
		if ok then
			self.autoSkipGameConn = connection
		end
	end
	self:_bindSkipTimer()
	self:_queueAutoSkip()
	return self
end

function Recorder:_at(action)
	local at = action.at
	return string.format("%d, %d, %d, %d", at.wave, at.minute, at.second, at.millisecond)
end

function Recorder:_line(action)
	local at = self:_at(action)
	if action.kind == "place" then
		return string.format(
			"TDS:Place(%s, %s, %s, %s, %s, %s, %s)",
			quote(action.name),
			number(action.position.X),
			number(action.position.Y),
			number(action.position.Z),
			at,
			self:_literal(action.rotation),
			tostring(action.golden == true)
		)
	elseif action.kind == "upgrade" then
		return string.format("TDS:Upgrade(%d, %s, %d)", action.id, at, action.path)
	elseif action.kind == "sell" then
		return string.format("TDS:Sell(%d, %s)", action.id, at)
	elseif action.kind == "ability" then
		return string.format(
			"TDS:Ability(%d, %s, %s, %s)",
			action.id,
			quote(action.name),
			at,
			self:_literal(action.data)
		)
	elseif action.kind == "skip" then
		return "TDS:Skip(" .. at .. ")"
	elseif action.kind == "target" then
		return string.format("TDS:Target(%d, %s, %s)", action.id, quote(action.target), at)
	elseif action.kind == "option" then
		return string.format(
			"TDS:Option(%d, %s, %s, %s)",
			action.id,
			quote(action.name),
			self:_literal(action.value),
			at
		)
	elseif action.kind == "raw" then
		return string.format(
			"TDS:Raw(%s, %s, %s, %s, %s)",
			quote(action.channel),
			quote(action.action),
			self:_literal(action.args),
			at,
			tostring(action.invoke)
		)
	end
end

function Recorder:Export()
	local latest = metadata()
	if latest.Map ~= "" then
		self.meta.Map = latest.Map
	end
	if latest.Mode ~= "" then
		self.meta.Mode = latest.Mode
	end
	if latest.Difficulty ~= "" then
		self.meta.Difficulty = latest.Difficulty
	end
	if #latest.Loadout > 0 then
		self.meta.Loadout = latest.Loadout
	end

	local lines = {
		'local TDS = loadstring(game:HttpGet("https://raw.githubusercontent.com/tessa-says-hi/auto-strat/main/src/Strategy.Luau", true))()',
	}
	local loadoutArgs = {}
	for _, item in ipairs(self.meta.Loadout or {}) do
		loadoutArgs[#loadoutArgs + 1] =
			string.format("{ Name = %s, Golden = %s }", quote(item.Name), tostring(item.Golden == true))
	end
	lines[#lines + 1] = "TDS:Loadout(" .. table.concat(loadoutArgs, ", ") .. ")"
	lines[#lines + 1] = string.format(
		"TDS:Map(%s, true, %s, %s)",
		quote(self.meta.Map),
		quote(self.meta.Mode),
		quote(self.meta.Difficulty)
	)
	for _, action in ipairs(self.actions) do
		local line = self:_line(action)
		if line then
			lines[#lines + 1] = line
		end
	end
	lines[#lines + 1] = "TDS:Run()"
	return table.concat(lines, "\n") .. "\n"
end

function Recorder:Copy()
	if type(setclipboard) ~= "function" then
		self.status = "This executor does not support setclipboard."
		return false
	end
	setclipboard(self:Export())
	self.status = string.format("Copied %d action(s) to clipboard.", #self.actions)
	return true
end

function Recorder:Save()
	if type(writefile) ~= "function" then
		self.status = "This executor does not support writefile."
		return false
	end
	local folder = "auto-strat"
	local file = folder .. "/" .. cleanName(self.name):gsub("%s+", "_") .. ".luau"
	local ok, err = pcall(function()
		if type(isfolder) == "function" and type(makefolder) == "function" and not isfolder(folder) then
			makefolder(folder)
		end
		writefile(file, self:Export())
	end)
	if not ok then
		self.status = "Save failed: " .. tostring(err)
		return false
	end
	self.status = "Saved " .. file
	return true, file
end

function Recorder:_setUiText(key, value)
	value = tostring(value or "")
	if self.uiText[key] == value then
		return
	end
	self.uiText[key] = value
	local row = self.uiRows and self.uiRows[key]
	if row then
		pcall(function()
			row.Text = value
		end)
	end
end

function Recorder:_refreshUi()
	self:_setUiText("state", "State: " .. shortStatus(self.status))
	self:_setUiText("actions", string.format("Actions: %d", #self.actions))
	self:_setUiText("last", "Last: " .. shortStatus(self.last))
	if self.autosaveError then
		self:_setUiText("autosave", "Autosave: " .. shortStatus(self.autosaveError))
	elseif self.autosaveFile then
		self:_setUiText("autosave", "Autosave: " .. self.autosaveFile)
	elseif type(writefile) == "function" then
		self:_setUiText("autosave", "Autosave: armed")
	else
		self:_setUiText("autosave", "Autosave: unavailable")
	end

	self:_setUiText("skip", "Auto Skip: " .. shortStatus(self.autoSkipStatus))
	local host = self.host
	if host then
		local chain = host.CommanderChainStatus
		if type(host.CommanderChainText) == "function" then
			local ok, value = pcall(host.CommanderChainText, host)
			chain = ok and value or chain
		end
		local stack = host.StackStatus
		if type(host.StackPriceText) == "function" then
			local ok, value = pcall(host.StackPriceText, host)
			stack = ok and value or stack
		end
		self:_setUiText("chain", "Commander: " .. shortStatus(chain))
		self:_setUiText("stack", "Auto Stack: " .. shortStatus(stack))
	else
		self:_setUiText("chain", "Commander: load Auto Gatlin to enable")
		self:_setUiText("stack", "Auto Stack: load Auto Gatlin to enable")
	end
end

function Recorder:_buildUi(library, seq)
	resetLibrary(library)
	self.uiRows = {}
	self.uiText = {}
	self.uiButtons = {}

	local recorder = library:CreateWindow("Strategy Recorder", {})
	local nameBox = recorder:Box("Strategy Name", {
		default = self.name,
		flag = "RecorderStrategyName",
	}, function(value)
		self:SetName(value)
	end)
	nameBox.Text = self.name

	self.uiButtons.Start = recorder:Button("Start Recorder", function()
		self:Start(nameBox.Text)
	end)
	self.uiButtons.Stop = recorder:Button("Stop Recorder", function()
		self:Stop()
	end)
	self.uiButtons.Copy = recorder:Button("Copy Strategy", function()
		self:Copy()
	end)
	self.uiButtons.Save = recorder:Button("Save Strategy", function()
		self:Save()
	end)
	self.uiButtons.Clear = recorder:Button("Clear Recording", function()
		self:Clear()
	end)
	recorder:Section("")
	self.uiRows.state = recorder:Section("")
	self.uiRows.actions = recorder:Section("")
	self.uiRows.last = recorder:Section("")
	self.uiRows.autosave = recorder:Section("")

	local tools = library:CreateWindow("Recorder Tools")
	tools:Toggle("Auto Skip", {
		default = self.autoSkip,
		flag = "RecorderAutoSkip",
	}, function(value)
		self:SetAutoSkip(value)
	end)

	local host = self.host
	tools:Toggle("Auto Chain Commander", {
		default = host and host.AutoCommanderChain == true or false,
		flag = "RecorderAutoCommanderChain",
	}, function(value)
		if host and type(host.SetAutoCommanderChain) == "function" then
			local ok, err = pcall(host.SetAutoCommanderChain, host, value)
			if not ok then
				self.status = "Auto Chain failed: " .. shortStatus(err)
			end
		end
	end)
	tools:Toggle("Auto Stack", {
		default = host and host.AutoStacker == true or false,
		flag = "RecorderAutoStacker",
	}, function(value)
		if host and type(host.SetAutoStacker) == "function" then
			local ok, err = pcall(host.SetAutoStacker, host, value)
			if not ok then
				self.status = "Auto Stack failed: " .. shortStatus(err)
			end
		end
	end)
	tools:Slider("Stack Amount", {
		default = math.clamp(tonumber(host and host.StackAmount) or 15, 1, 50),
		min = 1,
		max = 50,
		flag = "RecorderStackAmount",
	}, function(value)
		if host and type(host.SetStackAmount) == "function" then
			local ok, err = pcall(host.SetStackAmount, host, value)
			if not ok then
				self.status = "Stack Amount failed: " .. shortStatus(err)
			end
		end
	end)
	tools:Section("")
	self.uiRows.skip = tools:Section("")
	self.uiRows.chain = tools:Section("")
	self.uiRows.stack = tools:Section("")

	local screen = library.container and library.container.Parent
	if screen and screen:IsA("ScreenGui") then
		screen.Name = "AutoStratRecorderUI"
		screen.DisplayOrder = 2147483647
		screen.IgnoreGuiInset = true
		screen.ResetOnSpawn = false
		screen.ZIndexBehavior = Enum.ZIndexBehavior.Global
	end

	self.uiLibrary = library
	self.uiReady = true
	self.uiError = nil
	self:_refreshUi()
	task.spawn(function()
		while self.uiReady and self.uiSeq == seq do
			task.wait(0.25)
			self:_refreshUi()
		end
	end)
end

function Recorder:DestroyUI()
	self.uiSeq = self.uiSeq + 1
	self.uiReady = false
	self.uiLoading = false
	local library = self.uiLibrary or env.AutoStratRecorderUILibrary
	if type(library) == "table" then
		pcall(resetLibrary, library)
	end
	self.uiLibrary = nil
	self.uiRows = nil
	self.uiButtons = nil
	self.uiText = {}
	return self
end

function Recorder:LoadUI(host, rebuild)
	if host ~= nil then
		self.host = host
	end
	if rebuild then
		self:DestroyUI()
	elseif self.uiReady or self.uiLoading then
		return self
	end
	if env.AutoStratSkipRecorderUI then
		return self
	end

	self.uiSeq = self.uiSeq + 1
	local seq = self.uiSeq
	self.uiLoading = true
	self.uiError = nil
	task.spawn(function()
		local ok, err = pcall(function()
			local library = loadUiLibrary()
			if self.uiSeq ~= seq then
				return
			end
			self:_buildUi(library, seq)
		end)
		if self.uiSeq ~= seq then
			return
		end
		self.uiLoading = false
		if not ok then
			self.uiReady = false
			self.uiError = tostring(err)
			self.status = "Recorder UI failed: " .. shortStatus(err)
		end
	end)
	return self
end

function Recorder:AttachHost(host)
	if self.host == host and self.uiReady then
		return self
	end
	self.host = host
	return self:LoadUI(host, true)
end

function Recorder:Status()
	local status = string.format("%s\n%d action(s) | %s", self.status, #self.actions, self.last)
	if self.autosaveError then
		return status .. "\nAutosave: " .. self.autosaveError
	elseif self.autosaveFile then
		return status .. "\nAutosaved: " .. self.autosaveFile
	elseif type(writefile) ~= "function" then
		return status .. "\nAutosave unavailable: this executor has no writefile."
	end
	return status .. "\nAutosave armed; saves after each recorded action."
end

function Recorder:Destroy()
	if self.destroyed then
		return self
	end
	self.destroyed = true
	self.active = false
	self.autosaveQueued = false
	if
		#self.actions > 0
		and (self.autosaveCount ~= #self.actions or self.autosaveName ~= self.name or self.autosaveError)
	then
		self:Autosave()
	end
	self:SetAutoSkip(false)
	self:DestroyUI()
	disconnect(self, "timerConn")
	if self.invoke and self.oldInvoke and type(hookfunction) == "function" then
		pcall(hookfunction, self.invoke, self.oldInvoke)
	end
	if self.fire and self.oldFire and type(hookfunction) == "function" then
		pcall(hookfunction, self.fire, self.oldFire)
	end
	self.installed = false
	self.invoke = nil
	self.oldInvoke = nil
	self.fire = nil
	self.oldFire = nil
	if env.AutoStratRecorder == self then
		env.AutoStratRecorder = nil
	end
	return self
end

local previous = env.AutoStratRecorder
if previous and type(previous.Destroy) == "function" then
	pcall(previous.Destroy, previous)
end

local recorder = Recorder.new()
env.AutoStratRecorder = recorder
if not env.AutoStratSkipRecorderUI then
	recorder:LoadUI(env.AutoGatlin)
end
return recorder
