--[[ How to use

    local AnimationController = require(...AnimationController)

    -- Create controller (library is optional)
    local anim = AnimationController.new(character, workspace.AnimLibrary)

    -- Play by asset id, url, Animation instance, or library name
    local track = anim:Play("Run", { fade = 0.2, speed = 1.5, priority = Enum.AnimationPriority.Action })
    local track = anim:Play(1234567890)
    local track = anim:Play("rbxassetid://1234567890")

    -- Stop specific animation
    anim:Stop("Run")
    anim:Stop("Run", 0.3)  -- custom fade

    -- Stop last played
    anim:StopLast()
    anim:StopLast(0.3)

    -- Stop all
    anim:StopAll()
    anim:StopAll(0.5)

    -- Check if playing
    anim:IsPlaying("Run") --> boolean

    -- Directly from returned track
    track:Stop()
]]


-- Keyed by Animator instance (safer than Humanoid — survives R15 rigs)
local _trackCache: { [Animator]: { [any]: AnimationTrack } } = {}


type AnimSource = string | number | Animation

export type PlayOptions = {
	fade:     number?,
	weight:   number?,
	speed:    number?,
	priority: Enum.AnimationPriority?,
}


local AnimationController = {}
AnimationController.__index = AnimationController

function AnimationController.new(character: Model, library: Folder?)
	assert(typeof(character) == "Instance", "[AnimationController] character must be a Model")

	local self      = setmetatable({}, AnimationController)
	self.Character  = character
	self.Humanoid   = character:WaitForChild("Humanoid") :: Humanoid
	self.Animator   = self.Humanoid:FindFirstChildOfClass("Animator")
		or Instance.new("Animator", self.Humanoid) :: Animator
	self.Library    = library
	self._lastTrack = nil :: AnimationTrack?

	if not _trackCache[self.Animator] then
		_trackCache[self.Animator] = {}

		self.Humanoid.Died:Once(function()
			_trackCache[self.Animator] = nil
		end)
	end

	return self
end


-- Resolves a source (name / id / url / Animation) to a cached AnimationTrack
function AnimationController:_resolve(source: AnimSource): AnimationTrack?
	local tracks = _trackCache[self.Animator]
	if not tracks then return nil end

	if tracks[source] then return tracks[source] end

	local animObj: Animation

	if typeof(source) == "Instance" and source:IsA("Animation") then
		animObj = source
	else
		animObj            = Instance.new("Animation")
		animObj.AnimationId = typeof(source) == "number"
			and ("rbxassetid://" .. source)
			or  tostring(source)
	end

	local track       = self.Animator:LoadAnimation(animObj)
	tracks[source]    = track
	return track
end

-- Converts a user-supplied value into the canonical source key.
-- Library name → Animation instance; everything else passes through.
function AnimationController:_toSource(raw: AnimSource): AnimSource
	if
		typeof(raw) == "string"
		and self.Library
		and not raw:find("rbxassetid://", 1, true)
	then
		return (self.Library:FindFirstChild(raw, true) :: any) or raw
	end
	return raw
end

--- Plays an animation. Returns the AnimationTrack so callers can chain .Stopped etc.
function AnimationController:Play(animSource: AnimSource, opts: PlayOptions?): AnimationTrack?
	local source = self:_toSource(animSource)
	local track  = self:_resolve(source)
	if not track then return nil end

	local cfg = opts or {}
	track:Play(cfg.fade or 0.1, cfg.weight or 1, cfg.speed or 1)

	if cfg.priority then
		track.Priority = cfg.priority
	end

	self._lastTrack = track
	return track
end

--- Stops a specific animation by name, id, url, or Animation instance.
function AnimationController:Stop(animSource: AnimSource, fade: number?)
	local source = self:_toSource(animSource)
	local tracks = _trackCache[self.Animator]
	local track  = tracks and tracks[source]

	if track then
		track:Stop(fade or 0.1)
	end
end

--- Stops the most recently played animation.
function AnimationController:StopLast(fade: number?)
	if self._lastTrack then
		self._lastTrack:Stop(fade or 0.1)
	end
end

--- Stops every loaded animation on this controller.
function AnimationController:StopAll(fade: number?)
	local tracks = _trackCache[self.Animator]
	if not tracks then return end

	for _, track in tracks do
		track:Stop(fade or 0.1)
	end
end

--- Returns true if the animation is currently playing.
function AnimationController:IsPlaying(animSource: AnimSource): boolean
	local source = self:_toSource(animSource)
	local tracks = _trackCache[self.Animator]
	local track  = tracks and tracks[source]
	return track ~= nil and track.IsPlaying
end

return AnimationController
