--!strict
local RunService = game:GetService("RunService")

local IS_SERVER = RunService:IsServer()

-- CONFIG
local MAX_DEPTH = 5
local MAX_KEYS = 100
local MAX_STRING_LENGTH = 100

-- TYPES
export type Validator<T> = (value: any) -> T

export type Schema = {
	[string]: any
}

export type Metrics = {
	validations: number,
	errors: number,
}

-- MODULE
local Arg = {}
Arg.__index = Arg

local metrics: Metrics = {
	validations = 0,
	errors = 0,
}

local function fail(msg: string)
	metrics.errors += 1
	error("[Arg] " .. msg, 3)
end

-- BASE TYPES
function Arg.string(v: any, maxLen: number?): string
	if type(v) ~= "string" or v == "" then
		fail("invalid string")
	end

	if IS_SERVER then
		local limit = maxLen or MAX_STRING_LENGTH
		if #v > limit then
			fail("string too long")
		end
	end

	metrics.validations += 1
	return v
end

function Arg.number(v: any, min: number?, max: number?): number
	if type(v) ~= "number" then
		fail("invalid number")
	end

	if min and v < min then fail("number too small") end
	if max and v > max then fail("number too big") end

	metrics.validations += 1
	return v
end

function Arg.boolean(v: any): boolean
	if type(v) ~= "boolean" then
		fail("invalid boolean")
	end

	metrics.validations += 1
	return v
end

function Arg.func(v: any): (...any) -> ()
	if type(v) ~= "function" then
		fail("invalid function")
	end

	metrics.validations += 1
	return v
end

-- ROBLOX TYPES
function Arg.vector3(v: any): Vector3
	if typeof(v) ~= "Vector3" then
		fail("invalid Vector3")
	end

	metrics.validations += 1
	return v
end

function Arg.cframe(v: any): CFrame
	if typeof(v) ~= "CFrame" then
		fail("invalid CFrame")
	end

	metrics.validations += 1
	return v
end

function Arg.instance(v: any, className: string?): Instance
	if typeof(v) ~= "Instance" then
		fail("invalid Instance")
	end

	if className and not v:IsA(className) then
		fail("Instance is not " .. className)
	end

	metrics.validations += 1
	return v
end

-- TABLE BASICS
function Arg.table(t: any): {[any]: any}
	if type(t) ~= "table" then
		fail("invalid table")
	end

	metrics.validations += 1
	return t
end

function Arg.array(t: any): {any}
	if type(t) ~= "table" then
		fail("invalid array")
	end

	for i = 1, #t do
		if t[i] == nil then
			fail("array has holes")
		end
	end

	metrics.validations += 1
	return t
end

-- UNION
function Arg.oneOf(v: any, ...: ((any) -> any))
	local validators = { ... }

	for _, check in ipairs(validators) do
		local ok = pcall(check, v)
		if ok then
			return v
		end
	end

	fail("invalid type (oneOf failed)")
end

-- SCHEMA SYSTEM
local compiledSchemas: {[any]: Validator<any>} = {}

local function validateTable(
	t: {[any]: any},
	schema: Schema,
	depth: number,
	seen: {[any]: boolean}
)
	if seen[t] then
		fail("circular table")
	end
	seen[t] = true

	if depth > MAX_DEPTH then
		fail("table too deep")
	end

	local count = 0

	for k, v in pairs(t) do
		count += 1

		if IS_SERVER and count > MAX_KEYS then
			fail("table too large")
		end

		local rule = schema[k]

		if not rule then
			fail("unexpected key: " .. tostring(k))
		end

		if type(rule) == "function" then
			rule(v)

		elseif type(rule) == "table" then
			if type(v) ~= "table" then
				fail("expected table at key: " .. tostring(k))
			end

			validateTable(v, rule, depth + 1, seen)
		else
			fail("invalid schema at key: " .. tostring(k))
		end
	end

	return t
end

function Arg.schema(schema: Schema): Validator<any>
	if compiledSchemas[schema] then
		return compiledSchemas[schema]
	end

	local fn = function(data: any)
		if type(data) ~= "table" then
			fail("expected table")
		end

		local result = validateTable(data, schema, 1, {})
		metrics.validations += 1
		return result
	end

	compiledSchemas[schema] = fn
	return fn
end

-- METRICS
function Arg.getMetrics(): Metrics
	return metrics
end

function Arg.resetMetrics()
	metrics.validations = 0
	metrics.errors = 0
end

return Arg
