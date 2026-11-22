--!strict

local Parser = require(script.Parent.Parser)

local ScopeAnalysis = {}

export type SymbolRecord = {
	id: number,
	name: string,
	scopeId: number,
	span: Parser.Span,
}

export type ScopeKind = "Chunk" | "Block" | "While" | "Repeat"

export type ScopeNode = {
	id: number,
	kind: ScopeKind,
	parentId: number?,
	childrenIds: { number },
	symbolsByName: { [string]: SymbolRecord },
	declaredSymbolIds: { number },
	span: Parser.Span,
}

export type ScopeAnalysisResult = {
	rootScopeId: number,
	scopes: { [number]: ScopeNode },
	symbols: { [number]: SymbolRecord },
}

type AnalyzerState = {
	nextScopeId: number,
	scopes: { [number]: ScopeNode },
	symbols: { [number]: SymbolRecord },
}

local function createScope(
	state: AnalyzerState,
	kind: ScopeKind,
	parentId: number?,
	span: Parser.Span
): ScopeNode
	local id = state.nextScopeId
	state.nextScopeId += 1

	local node: ScopeNode = {
		id = id,
		kind = kind,
		parentId = parentId,
		childrenIds = {},
		symbolsByName = {},
		declaredSymbolIds = {},
		span = span,
	}

	state.scopes[id] = node

	if parentId ~= nil then
		local parent = state.scopes[parentId]
		if parent ~= nil then
			table.insert(parent.childrenIds, id)
		end
	end

	return node
end

local function visitBlock(state: AnalyzerState, block: Parser.BlockNode, scopeId: number): ()
	for _, stmt in ipairs(block.statements) do
		if stmt.kind == "DoStmt" then
			local childScope = createScope(state, "Block", scopeId, stmt.span)
			visitBlock(state, stmt.body, childScope.id)
		elseif stmt.kind == "WhileStmt" then
			local childScope = createScope(state, "While", scopeId, stmt.span)
			visitBlock(state, stmt.body, childScope.id)
		elseif stmt.kind == "RepeatStmt" then
			local childScope = createScope(state, "Repeat", scopeId, stmt.span)
			visitBlock(state, stmt.body, childScope.id)
		end
	end
end

function ScopeAnalysis.analyze(ast: Parser.ChunkNode): ScopeAnalysisResult
	local state: AnalyzerState = {
		nextScopeId = 1,
		scopes = {},
		symbols = {},
	}

	local rootScope = createScope(state, "Chunk", nil, ast.span)
	visitBlock(state, ast.body, rootScope.id)

	return {
		rootScopeId = rootScope.id,
		scopes = state.scopes,
		symbols = state.symbols,
	}
end

function ScopeAnalysis.getScopeChain(result: ScopeAnalysisResult, startScopeId: number): { ScopeNode }
	local chain: { ScopeNode } = {}
	local visited: { [number]: boolean } = {}
	local currentId: number? = startScopeId

	while currentId ~= nil do
		if visited[currentId] then
			break
		end

		local scope = result.scopes[currentId]
		if scope == nil then
			break
		end

		visited[currentId] = true
		table.insert(chain, scope)
		currentId = scope.parentId
	end

	return chain
end

function ScopeAnalysis.resolveName(
	result: ScopeAnalysisResult,
	name: string,
	scopeId: number
): SymbolRecord?
	local chain = ScopeAnalysis.getScopeChain(result, scopeId)
	for _, scope in ipairs(chain) do
		local sym = scope.symbolsByName[name]
		if sym ~= nil then
			return sym
		end
	end

	return nil
end

return ScopeAnalysis
