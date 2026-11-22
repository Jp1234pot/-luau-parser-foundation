--!strict

local Parser = require(script.Parent.Parser)

local ScopeAnalysis = {}

export type AccessKind = "Read" | "Write" | "ReadWrite"

export type SymbolRecord = {
	id: number,
	name: string,
	scopeId: number,
	span: Parser.Span,
	readCount: number,
	writeCount: number,
}

export type ReferenceRecord = {
	id: number,
	symbolId: number?,
	name: string,
	access: AccessKind,
	span: Parser.Span,
	scopeId: number,
	resolved: boolean,
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
	references: { ReferenceRecord },
}

type AnalyzerState = {
	nextScopeId: number,
	nextSymbolId: number,
	nextReferenceId: number,
	scopes: { [number]: ScopeNode },
	symbols: { [number]: SymbolRecord },
	references: { ReferenceRecord },
}

local function collectScopeChain(scopes: { [number]: ScopeNode }, startScopeId: number): { ScopeNode }
	local chain: { ScopeNode } = {}
	local visited: { [number]: boolean } = {}
	local currentId: number? = startScopeId

	while currentId ~= nil do
		if visited[currentId] then
			break
		end

		local scope = scopes[currentId]
		if scope == nil then
			break
		end

		visited[currentId] = true
		table.insert(chain, scope)
		currentId = scope.parentId
	end

	return chain
end

local function resolveNameInScopes(
	scopes: { [number]: ScopeNode },
	name: string,
	scopeId: number
): SymbolRecord?
	local chain = collectScopeChain(scopes, scopeId)
	for _, scope in ipairs(chain) do
		local sym = scope.symbolsByName[name]
		if sym ~= nil then
			return sym
		end
	end

	return nil
end

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

local function applyAccessCounts(sym: SymbolRecord, access: AccessKind): ()
	if access == "Read" then
		sym.readCount += 1
	elseif access == "Write" then
		sym.writeCount += 1
	elseif access == "ReadWrite" then
		sym.readCount += 1
		sym.writeCount += 1
	end
end

local function recordIdentifierReference(
	state: AnalyzerState,
	name: string,
	access: AccessKind,
	span: Parser.Span,
	scopeId: number
): ()
	local resolvedSym = resolveNameInScopes(state.scopes, name, scopeId)
	local refId = state.nextReferenceId
	state.nextReferenceId += 1

	local symbolId: number? = if resolvedSym ~= nil then resolvedSym.id else nil
	local refRecord: ReferenceRecord = {
		id = refId,
		symbolId = symbolId,
		name = name,
		access = access,
		span = span,
		scopeId = scopeId,
		resolved = resolvedSym ~= nil,
	}

	table.insert(state.references, refRecord)

	if resolvedSym ~= nil then
		applyAccessCounts(resolvedSym, access)
	end
end

local function visitExpr(
	state: AnalyzerState,
	expr: Parser.ExprNode,
	scopeId: number,
	access: AccessKind
): ()
	if expr.kind == "IdentifierExpr" then
		recordIdentifierReference(state, expr.name, access, expr.span, scopeId)
	elseif expr.kind == "UnaryExpr" then
		visitExpr(state, expr.operand, scopeId, "Read")
	elseif expr.kind == "BinaryExpr" then
		visitExpr(state, expr.left, scopeId, "Read")
		visitExpr(state, expr.right, scopeId, "Read")
	elseif expr.kind == "GroupedExpr" then
		visitExpr(state, expr.inner, scopeId, access)
	end
end

local function registerLocalBinding(
	state: AnalyzerState,
	scope: ScopeNode,
	binding: Parser.BindingNode
): SymbolRecord
	local symId = state.nextSymbolId
	state.nextSymbolId += 1

	local sym: SymbolRecord = {
		id = symId,
		name = binding.name.name,
		scopeId = scope.id,
		span = binding.span,
		readCount = 0,
		writeCount = 0,
	}

	state.symbols[symId] = sym
	table.insert(scope.declaredSymbolIds, symId)
	scope.symbolsByName[binding.name.name] = sym

	return sym
end

local function visitBlock(state: AnalyzerState, block: Parser.BlockNode, scopeId: number): ()
	for _, stmt in ipairs(block.statements) do
		if stmt.kind == "LocalDecl" then
			for _, valExpr in ipairs(stmt.values) do
				visitExpr(state, valExpr, scopeId, "Read")
			end
			local currentScope = state.scopes[scopeId]
			if currentScope ~= nil then
				for _, binding in ipairs(stmt.bindings) do
					registerLocalBinding(state, currentScope, binding)
				end
			end
		elseif stmt.kind == "Assignment" then
			for _, valExpr in ipairs(stmt.values) do
				visitExpr(state, valExpr, scopeId, "Read")
			end
			for _, targetExpr in ipairs(stmt.targets) do
				visitExpr(state, targetExpr, scopeId, "Write")
			end
		elseif stmt.kind == "CompoundAssignment" then
			visitExpr(state, stmt.value, scopeId, "Read")
			visitExpr(state, stmt.target, scopeId, "ReadWrite")
		elseif stmt.kind == "ReturnStmt" then
			for _, valExpr in ipairs(stmt.values) do
				visitExpr(state, valExpr, scopeId, "Read")
			end
		elseif stmt.kind == "DoStmt" then
			local childScope = createScope(state, "Block", scopeId, stmt.span)
			visitBlock(state, stmt.body, childScope.id)
		elseif stmt.kind == "WhileStmt" then
			visitExpr(state, stmt.condition, scopeId, "Read")
			local childScope = createScope(state, "While", scopeId, stmt.span)
			visitBlock(state, stmt.body, childScope.id)
		elseif stmt.kind == "RepeatStmt" then
			local childScope = createScope(state, "Repeat", scopeId, stmt.span)
			visitBlock(state, stmt.body, childScope.id)
			visitExpr(state, stmt.condition, childScope.id, "Read")
		end
	end
end

function ScopeAnalysis.analyze(ast: Parser.ChunkNode): ScopeAnalysisResult
	local state: AnalyzerState = {
		nextScopeId = 1,
		nextSymbolId = 1,
		nextReferenceId = 1,
		scopes = {},
		symbols = {},
		references = {},
	}

	local rootScope = createScope(state, "Chunk", nil, ast.span)
	visitBlock(state, ast.body, rootScope.id)

	return {
		rootScopeId = rootScope.id,
		scopes = state.scopes,
		symbols = state.symbols,
		references = state.references,
	}
end

function ScopeAnalysis.getScopeChain(result: ScopeAnalysisResult, startScopeId: number): { ScopeNode }
	return collectScopeChain(result.scopes, startScopeId)
end

function ScopeAnalysis.resolveName(
	result: ScopeAnalysisResult,
	name: string,
	scopeId: number
): SymbolRecord?
	return resolveNameInScopes(result.scopes, name, scopeId)
end

return ScopeAnalysis
