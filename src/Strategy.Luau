repeat
	task.wait()
until game:IsLoaded() and game.PlaceId ~= 0

local clone = cloneref or function(value)
	return value
end

local ReplicatedStorage = clone(game:GetService("ReplicatedStorage"))
local RunService = clone(game:GetService("RunService"))
local Workspace = clone(game:GetService("Workspace"))

local gameState = require(ReplicatedStorage.Shared.Modules.GameState)
local net = require(ReplicatedStorage.Shared.Modules.Network)

local Strategy = {}
Strategy.__index = Strategy

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

function Strategy.new()
	return setmetatable({
		actions = {},
		loadout = {},
		meta = {},
		name = "Strategy",
		nextTower = 0,
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

function Strategy:_bindClock()
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
			Position = action.position,
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

function Strategy:Run()
	if self.running then
		return self
	end
	self.running = true
	self.seq = self.seq + 1
	local seq = self.seq
	self.status = "Waiting for actions"
	self:_bindClock()
	getgenv().AutoStratRunner = self

	task.spawn(function()
		local failed = false
		for index, action in ipairs(self.actions) do
			if not self:_wait(action, seq) then
				break
			end
			self.status = string.format("Running %s %d/%d", action.kind, index, #self.actions)
			local ok, success, msg = pcall(self._run, self, action)
			if not ok or success == false then
				self.status = tostring(msg or success)
				failed = true
				break
			end
		end
		if self.seq == seq then
			self.running = false
			if not failed then
				self.status = "Complete"
			end
		end
	end)
	return self
end

function Strategy:Stop()
	self.seq = self.seq + 1
	self.running = false
	self.status = "Stopped"
	if self.timerConn then
		self.timerConn:Disconnect()
		self.timerConn = nil
	end
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
