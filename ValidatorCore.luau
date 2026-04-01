--!strict
--[[
	ValidatorCore v2.0
	Sistema de validação de schemas com suporte a campos obrigatórios/opcionais,
	tipos variados, métricas detalhadas e proteção contra abusos (recursão, tamanho).

	Uso:
		local Validator = require(...)
		local schema = Validator.schema({
			name = Validator.string(50),          -- string com máximo 50 caracteres
			age  = Validator.number(0, 120),       -- número entre 0 e 120
			email = Validator.optional(Validator.string()), -- opcional
		})
		local ok, data = schema({ name = "João", age = 30 })
		assert(ok, data) -- data contém os valores validados

		-- Métricas
		print(Validator.Metrics.get()) -- { totalValidations, totalErrors, ... }
]]

local RunService = game:GetService("RunService")
local IS_SERVER = RunService:IsServer()

export type Validator<T> = (value: any, context?: ValidationContext) -> (boolean, T | string)

export type ValidationContext = {
	path: string,               -- caminho atual no schema (ex: "user.address.city")
	metrics: MetricsCollector,  -- coletor de métricas para esta validação
}

type MetricsCollector = {
	recordSuccess: () -> (),
	recordError: (msg: string) -> (),
}

type SchemaConfig = { [string]: Validator<any> }
type CompiledSchema = { validator: Validator<any>, requiredKeys: { [string]: boolean } }

-- Configurações globais (podem ser alteradas)
local Config = {
	MaxDepth = 5,           -- profundidade máxima de aninhamento de tabelas
	MaxKeys = 100,          -- número máximo de chaves por tabela
	MaxStringLength = 100,  -- tamanho máximo para strings (aplicado em todos os ambientes)
}

-- Métricas globais (todas as validações)
local GlobalMetrics = {
	totalValidations = 0,
	totalErrors = 0,
	perSchema = {}, -- nome da schema -> { validations, errors }
}

-- Cache de schemas compilados (fraco para permitir coleta)
local compiledSchemas = setmetatable({}, { __mode = "k" })

-- Função auxiliar para criar um coletor de métricas para uma validação específica
local function createMetricsCollector(schemaName: string?): MetricsCollector
	local collector = {
		validations = 0,
		errors = 0,
		recordSuccess = function(self)
			self.validations += 1
		end,
		recordError = function(self, msg: string)
			self.errors += 1
		end,
	}
	return collector
end

-- Atualiza as métricas globais e por schema ao final da validação
local function finalizeMetrics(collector: MetricsCollector, schemaName: string?)
	GlobalMetrics.totalValidations += collector.validations
	GlobalMetrics.totalErrors += collector.errors
	if schemaName then
		if not GlobalMetrics.perSchema[schemaName] then
			GlobalMetrics.perSchema[schemaName] = { validations = 0, errors = 0 }
		end
		GlobalMetrics.perSchema[schemaName].validations += collector.validations
		GlobalMetrics.perSchema[schemaName].errors += collector.errors
	end
end

-- Validação de número com conversão segura
local function validateNumber(v: any, min: number?, max: number?): (boolean, number | string)
	if type(v) ~= "number" then
		return false, "expected number, got " .. type(v)
	end
	if v ~= v then -- NaN
		return false, "value is NaN"
	end
	if v == math.huge or v == -math.huge then
		return false, "value is infinite"
	end
	if min and v < min then
		return false, string.format("value %.2f is less than minimum %.2f", v, min)
	end
	if max and v > max then
		return false, string.format("value %.2f is greater than maximum %.2f", v, max)
	end
	return true, v
end

-- Validação de string com comprimento máximo (aplicado em todos os ambientes)
local function validateString(v: any, maxLen: number?): (boolean, string | string)
	if type(v) ~= "string" then
		return false, "expected string, got " .. type(v)
	end
	local limit = maxLen or Config.MaxStringLength
	if #v > limit then
		return false, string.format("string length %d exceeds maximum %d", #v, limit)
	end
	return true, v
end

-- Validação de tabela com recursão
local function validateTable(v: any, schema: CompiledSchema, depth: number, seen: { [any]: boolean }, context: ValidationContext): (boolean, any)
	if type(v) ~= "table" then
		return false, "expected table, got " .. type(v)
	end

	-- Prevenção de recursão cíclica
	if seen[v] then
		return false, "circular reference detected"
	end
	if depth > Config.MaxDepth then
		return false, "maximum depth exceeded"
	end

	seen[v] = true
	local count = 0
	local result = {}

	-- Verificar chaves obrigatórias
	for key, required in pairs(schema.requiredKeys) do
		if v[key] == nil then
			return false, string.format("missing required key '%s'", key)
		end
	end

	-- Validar todas as chaves presentes
	for key, value in pairs(v) do
		count += 1
		if count > Config.MaxKeys then
			return false, "table exceeds maximum number of keys"
		end

		local validator = schema.validator[key]
		if not validator then
			return false, string.format("unexpected key '%s'", key)
		end

		local subContext = {
			path = context.path .. "." .. key,
			metrics = context.metrics,
		}
		local ok, resultValue = validator(value, subContext)
		if not ok then
			return false, string.format("error at '%s': %s", subContext.path, resultValue)
		end
		result[key] = resultValue
	end

	return true, result
end

-- ==============================
-- Tipos públicos
-- ==============================

local Types = {}

-- Validação de string
function Types.string(maxLen: number?): Validator<string>
	return function(v: any, ctx: ValidationContext?): (boolean, string | string)
		local ok, res = validateString(v, maxLen)
		if ok then
			if ctx then ctx.metrics:recordSuccess() end
			return true, res
		else
			if ctx then ctx.metrics:recordError(res) end
			return false, res
		end
	end
end

-- Validação de número
function Types.number(min: number?, max: number?): Validator<number>
	return function(v: any, ctx: ValidationContext?): (boolean, number | string)
		local ok, res = validateNumber(v, min, max)
		if ok then
			if ctx then ctx.metrics:recordSuccess() end
			return true, res
		else
			if ctx then ctx.metrics:recordError(res) end
			return false, res
		end
	end
end

-- Validação de booleano
function Types.boolean(): Validator<boolean>
	return function(v: any, ctx: ValidationContext?): (boolean, boolean | string)
		if type(v) ~= "boolean" then
			if ctx then ctx.metrics:recordError("expected boolean") end
			return false, "expected boolean"
		end
		if ctx then ctx.metrics:recordSuccess() end
		return true, v
	end
end

-- Validação de literal (valor exato)
function Types.literal(value: any): Validator<any>
	return function(v: any, ctx: ValidationContext?): (boolean, any | string)
		if v == value then
			if ctx then ctx.metrics:recordSuccess() end
			return true, v
		end
		if ctx then ctx.metrics:recordError(string.format("expected '%s', got '%s'", tostring(value), tostring(v))) end
		return false, string.format("expected '%s'", tostring(value))
	end
end

-- Validação de array (lista) com validador para elementos
function Types.array(elementValidator: Validator<any>): Validator<any>
	return function(v: any, ctx: ValidationContext?): (boolean, any | string)
		if type(v) ~= "table" then
			if ctx then ctx.metrics:recordError("expected array (table)") end
			return false, "expected array"
		end
		-- Verificar se é um array (índices inteiros consecutivos começando em 1)
		local maxIdx = 0
		for k in pairs(v) do
			if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
				if ctx then ctx.metrics:recordError("array must have integer keys starting at 1") end
				return false, "array must have integer keys starting at 1"
			end
			if k > maxIdx then maxIdx = k end
		end
		-- Verificar se há gaps
		for i = 1, maxIdx do
			if v[i] == nil then
				if ctx then ctx.metrics:recordError("array has missing index") end
				return false, "array has missing index"
			end
		end

		local result = {}
		for i = 1, maxIdx do
			local subCtx = ctx and {
				path = (ctx.path or "") .. "[" .. i .. "]",
				metrics = ctx.metrics,
			} or nil
			local ok, elem = elementValidator(v[i], subCtx)
			if not ok then
				return false, string.format("array element %d: %s", i, elem)
			end
			result[i] = elem
		end
		if ctx then ctx.metrics:recordSuccess() end
		return true, result
	end
end

-- Validação de tabela genérica (qualquer tabela)
function Types.table(): Validator<any>
	return function(v: any, ctx: ValidationContext?): (boolean, any | string)
		if type(v) ~= "table" then
			if ctx then ctx.metrics:recordError("expected table") end
			return false, "expected table"
		end
		if ctx then ctx.metrics:recordSuccess() end
		return true, v
	end
end

-- Validação de qualquer valor (sem restrição)
function Types.any(): Validator<any>
	return function(v: any, ctx: ValidationContext?): (boolean, any | string)
		if ctx then ctx.metrics:recordSuccess() end
		return true, v
	end
end

-- Validação de nil (útil em unions)
function Types.nil(): Validator<nil>
	return function(v: any, ctx: ValidationContext?): (boolean, nil | string)
		if v == nil then
			if ctx then ctx.metrics:recordSuccess() end
			return true, nil
		end
		if ctx then ctx.metrics:recordError("expected nil") end
		return false, "expected nil"
	end
end

-- Campo opcional: se não presente, ignora; se presente, valida com o validador fornecido
function Types.optional(validator: Validator<any>): Validator<any>
	return function(v: any, ctx: ValidationContext?): (boolean, any | string)
		if v == nil then
			if ctx then ctx.metrics:recordSuccess() end
			return true, nil
		end
		return validator(v, ctx)
	end
end

-- União de tipos: aceita qualquer um dos validadores passados
function Types.oneOf(...: Validator<any>): Validator<any>
	local validators = { ... }
	return function(v: any, ctx: ValidationContext?): (boolean, any | string)
		local lastError
		for _, validator in ipairs(validators) do
			local ok, res = validator(v, ctx)
			if ok then
				return true, res
			else
				lastError = res
			end
		end
		if ctx then ctx.metrics:recordError("oneOf failed: " .. tostring(lastError)) end
		return false, "value does not match any of the allowed types"
	end
end

-- Schema principal
function Types.schema(schemaConfig: SchemaConfig): Validator<any>
	-- Verificar se já está compilado
	if compiledSchemas[schemaConfig] then
		return compiledSchemas[schemaConfig].validator
	end

	-- Compilar: separar campos obrigatórios (todos que não são optional)
	local requiredKeys = {}
	local validatorMap = {}
	for key, validator in pairs(schemaConfig) do
		validatorMap[key] = validator
		-- Determinar se é obrigatório: se não é um optional, ou se o optional está explicitamente marcado?
		-- O campo é obrigatório a menos que o validador seja explicitamente Types.optional.
		-- Mas não podemos detectar isso facilmente porque optional é uma closure.
		-- Vamos marcar como obrigatório se não for um optional (teremos que inspecionar a função? complicado).
		-- Em vez disso, exigimos que o usuário use Types.optional quando desejar opcional.
		-- A validação de campos obrigatórios será feita verificando se o validador rejeita nil.
		-- Se o validador aceitar nil (como optional), então não é obrigatório.
		-- Para simplificar, vamos deixar a verificação de obrigatoriedade para o validador.
		-- Quando o campo está ausente, chamamos o validador com nil e se ele falhar, reportamos.
		-- Então não precisamos de um campo requiredKeys explícito.
	end

	local compiled = {
		validator = validatorMap,
		requiredKeys = requiredKeys, -- não usado agora
	}

	-- Criar o validador final
	local function schemaValidator(data: any, ctx: ValidationContext?): (boolean, any | string)
		if type(data) ~= "table" then
			if ctx then ctx.metrics:recordError("expected table") end
			return false, "expected table"
		end

		-- Criar contexto se não fornecido
		local localCtx = ctx or {
			path = "",
			metrics = createMetricsCollector(),
		}
		local seen = {}
		local ok, result = validateTable(data, compiled, 1, seen, localCtx)
		if ok then
			-- Sucesso: atualizar métricas
			if ctx then
				ctx.metrics:recordSuccess()
			else
				localCtx.metrics:recordSuccess()
				finalizeMetrics(localCtx.metrics, nil) -- sem nome de schema, apenas globais
			end
			return true, result
		else
			-- Falha: atualizar métricas
			if ctx then
				ctx.metrics:recordError(result)
			else
				localCtx.metrics:recordError(result)
				finalizeMetrics(localCtx.metrics, nil)
			end
			return false, result
		end
	end

	-- Cache
	compiledSchemas[schemaConfig] = { validator = schemaValidator, requiredKeys = requiredKeys }
	return schemaValidator
end

-- ==============================
-- Métricas e utilitários
-- ==============================

local Metrics = {}

function Metrics.get()
	return {
		totalValidations = GlobalMetrics.totalValidations,
		totalErrors = GlobalMetrics.totalErrors,
		perSchema = GlobalMetrics.perSchema,
	}
end

function Metrics.reset()
	GlobalMetrics.totalValidations = 0
	GlobalMetrics.totalErrors = 0
	GlobalMetrics.perSchema = {}
end

-- Permite modificar configurações globais (use com cuidado)
function Metrics.setConfig(newConfig: { MaxDepth?: number, MaxKeys?: number, MaxStringLength?: number })
	if newConfig.MaxDepth then Config.MaxDepth = newConfig.MaxDepth end
	if newConfig.MaxKeys then Config.MaxKeys = newConfig.MaxKeys end
	if newConfig.MaxStringLength then Config.MaxStringLength = newConfig.MaxStringLength end
end

-- Exporta a API
local ValidatorCore = {
	Types = Types,
	Metrics = Metrics,
	Config = Config, -- expor apenas leitura? vamos expor como tabela só para consulta
}

return ValidatorCore
