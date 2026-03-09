--[[
    How to use:

    -- Instance (Part, UI, Light, etc.)
    TweenPlus.play(workspace.Part, TweenInfo.new(1), { Transparency = 1 })

    -- Model (animates via PivotTo)
    TweenPlus.play(workspace.PortaoModel, TweenInfo.new(2), { CFrame = CFrame.new(0, 10, 0) })

    -- Await completion (yields)
    TweenPlus.play(workspace.Part, TweenInfo.new(1), { Transparency = 1 }):await()

    -- Stop mid-tween
    TweenPlus.stop(workspace.Part)

    -- Check if tweening
    TweenPlus.isPlaying(workspace.Part) --> boolean
]]

local TweenService = game:GetService("TweenService")
local RunService   = game:GetService("RunService")

type TweenHandle = {
	await:     (self: TweenHandle) -> (),
	cancel:    (self: TweenHandle) -> (),
	isPlaying: (self: TweenHandle) -> boolean,
}

type ActiveEntry = {
	kind:       "tween" | "heartbeat",
	tween:      Tween?,
	connection: RBXScriptConnection?,
	completed:  BindableEvent,
	done:       boolean,
}

local _active: { [Instance]: ActiveEntry } = {}

local function cancelEntry(entry: ActiveEntry)
	if entry.kind == "tween" and entry.tween then
		entry.tween:Cancel()
	elseif entry.kind == "heartbeat" and entry.connection then
		entry.connection:Disconnect()
	end
end

local function finishEntry(target: Instance, entry: ActiveEntry)
	if entry.done then return end
	entry.done = true
	entry.completed:Fire()
	entry.completed:Destroy()
	if _active[target] == entry then
		_active[target] = nil
	end
end

local function stopTarget(target: Instance)
	local entry = _active[target]
	if not entry then return end
	cancelEntry(entry)
	finishEntry(target, entry)
end

local function makeHandle(target: Instance, entry: ActiveEntry): TweenHandle
	local handle = {}

	function handle:await()
		if entry.done then return end
		entry.completed.Event:Wait()
	end

	function handle:cancel()
		stopTarget(target)
	end

	function handle:isPlaying(): boolean
		return not entry.done
	end

	return handle
end

local function tweenModel(target: Model, info: TweenInfo, goalCFrame: CFrame): TweenHandle
	local entry: ActiveEntry = {
		kind      = "heartbeat",
		completed = Instance.new("BindableEvent"),
		done      = false,
	}

	local startCFrame = target:GetPivot()
	local elapsed     = 0
	local duration    = math.max(info.Time, 1e-4) -- guard against zero-duration

	entry.connection = RunService.Heartbeat:Connect(function(dt)
		if not target.Parent then
			finishEntry(target, entry)
			return
		end

		elapsed += dt
		local alpha = math.clamp(elapsed / duration, 0, 1)
		local ratio = TweenService:GetValue(alpha, info.EasingStyle, info.EasingDirection)
		target:PivotTo(startCFrame:Lerp(goalCFrame, ratio))

		if alpha >= 1 then
			if entry.connection then entry.connection:Disconnect() end
			finishEntry(target, entry)
		end
	end)

	_active[target] = entry
	return makeHandle(target, entry)
end

local function tweenInstance(target: Instance, info: TweenInfo, properties: { [string]: any }): TweenHandle?
	local ok, tween = pcall(TweenService.Create, TweenService, target, info, properties)
	if not ok or not tween then
		warn(`[TweenPlus] Invalid property for '{target.ClassName}' — {tween}`)
		return nil
	end

	local entry: ActiveEntry = {
		kind      = "tween",
		tween     = tween,
		completed = Instance.new("BindableEvent"),
		done      = false,
	}

	_active[target] = entry
	tween:Play()

	tween.Completed:Once(function()
		finishEntry(target, entry)
	end)

	return makeHandle(target, entry)
end

local TweenPlus = {}

--- Plays a tween on any Instance or Model. Returns a TweenHandle.
function TweenPlus.play(target: Instance, info: TweenInfo, properties: { [string]: any }): TweenHandle?
	assert(typeof(target) == "Instance",    "[TweenPlus] target must be an Instance")
	assert(typeof(info) == "TweenInfo",     "[TweenPlus] info must be a TweenInfo")
	assert(typeof(properties) == "table",   "[TweenPlus] properties must be a table")

	stopTarget(target) -- cancel any in-flight tween on this target

	if target:IsA("Model") then
		local goalCFrame = properties.CFrame or properties.Pivot
		if not goalCFrame then
			warn("[TweenPlus] Model tweens require a 'CFrame' property.")
			return nil
		end
		return tweenModel(target, info, goalCFrame)
	else
		return tweenInstance(target, info, properties)
	end
end

--- Cancels an active tween on the target.
function TweenPlus.stop(target: Instance)
	assert(typeof(target) == "Instance", "[TweenPlus] target must be an Instance")
	stopTarget(target)
end

--- Returns true if the target is currently being tweened.
function TweenPlus.isPlaying(target: Instance): boolean
	return _active[target] ~= nil
end

return TweenPlus
