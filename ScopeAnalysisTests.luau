--!strict

local Parser = require(script.Parent.Parser)
local ScopeAnalysis = require(script.Parent.ScopeAnalysis)

local ScopeAnalysisTests = {}

type ScalarSpan = {
	startLine: number,
	startCol: number,
	startOffset: number,
	endLine: number,
	endCol: number,
	endOffset: number,
}

type StatementSnapshot = {
	path: string,
	node: Parser.StmtNode,
	kind: string,
	span: ScalarSpan,
}

type TypeAnnotationSummary = {
	kind: string,
	span: ScalarSpan,
	refName: string?,
}

type BindingSnapshot = {
	path: string,
	node: Parser.BindingNode,
	nameNode: Parser.IdentNode,
	identName: string,
	span: ScalarSpan,
	nameSpan: ScalarSpan,
	typeAnnotationNode: Parser.TypeNode?,
	typeAnnotationSummary: TypeAnnotationSummary?,
}

type ExprSnapshot = {
	path: string,
	node: Parser.ExprNode,
	kind: string,
	span: ScalarSpan,
	identName: string?,
	propNode: Parser.IdentNode?,
	propKind: string?,
	propName: string?,
	propSpan: ScalarSpan?,
	operator: string?,
	boolValue: boolean?,
	numValue: number?,
	strValue: string?,
	delimiter: Parser.StringDelimiter?,
	rawText: string?,
	rawLexemes: { string }?,
}

type ArrayIdentitySnapshot = {
	path: string,
	ref: any,
	length: number,
}

type DiagnosticSnapshot = {
	code: string,
	severity: Parser.DiagnosticSeverity,
	stage: string,
	message: string,
	span: ScalarSpan,
}

type AstSnapshots = {
	statements: { StatementSnapshot },
	bindings: { BindingSnapshot },
	expressions: { ExprSnapshot },
	arrays: { ArrayIdentitySnapshot },
}

local function mkPos(offset: number, col: number?): Parser.Position
	return { line = 1, column = col or offset, offset = offset }
end

local function mkSpan(sOff: number, eOff: number): Parser.Span
	return { start = mkPos(sOff), ["end"] = mkPos(eOff) }
end

local function tok(
	kind: Parser.TokenKind,
	lexeme: string,
	sOff: number,
	eOff: number,
	value: (string | number | boolean)?,
	delimiter: Parser.StringDelimiter?
): Parser.Token
	return {
		kind = kind,
		lexeme = lexeme,
		value = value,
		delimiter = delimiter,
		span = mkSpan(sOff, eOff),
		leadingTrivia = nil,
	}
end

local function eof(off: number): Parser.Token
	return tok("Eof", "", off, off, nil, nil)
end

local function assertTrue(cond: boolean, message: string): ()
	if not cond then
		error("FAIL: " .. message, 2)
	end
end

local function captureScalarSpan(span: Parser.Span): ScalarSpan
	return {
		startLine = span.start.line,
		startCol = span.start.column,
		startOffset = span.start.offset,
		endLine = span["end"].line,
		endCol = span["end"].column,
		endOffset = span["end"].offset,
	}
end

local function matchesScalarSpan(span: Parser.Span, expected: ScalarSpan): boolean
	return span.start.line == expected.startLine
		and span.start.column == expected.startCol
		and span.start.offset == expected.startOffset
		and span["end"].line == expected.endLine
		and span["end"].column == expected.endCol
		and span["end"].offset == expected.endOffset
end

local function summarizeTypeAnnotation(ann: Parser.TypeNode?): TypeAnnotationSummary?
	if ann == nil then
		return nil
	end
	local refName: string? = if ann.kind == "TypeReference" then ann.name else nil
	return {
		kind = ann.kind,
		span = captureScalarSpan(ann.span),
		refName = refName,
	}
end

local function matchesTypeAnnotationSummary(ann: Parser.TypeNode?, expected: TypeAnnotationSummary?): boolean
	if expected == nil then
		return ann == nil
	end
	if ann == nil then
		return false
	end
	if ann.kind ~= expected.kind or not matchesScalarSpan(ann.span, expected.span) then
		return false
	end
	if ann.kind == "TypeReference" then
		return ann.name == expected.refName
	end
	return expected.refName == nil
end

local function cloneStringArray(items: { string }): { string }
	local copy: { string } = {}
	for i, v in ipairs(items) do
		copy[i] = v
	end
	return copy
end

local function matchesStringArray(actual: { string }, expected: { string }): boolean
	if #actual ~= #expected then
		return false
	end
	for i, v in ipairs(expected) do
		if actual[i] ~= v then
			return false
		end
	end
	return true
end

local function recordArraySnapshot(out: { ArrayIdentitySnapshot }, path: string, arr: { any }): ()
	table.insert(out, {
		path = path,
		ref = arr,
		length = #arr,
	})
end

local function checkArraySnapshot(
	arr: { any },
	path: string,
	snapshots: { ArrayIdentitySnapshot },
	cursorRef: { index: number }
): ()
	cursorRef.index += 1
	local snap = snapshots[cursorRef.index]
	if snap == nil then
		error(string.format("Missing array snapshot for %s", path), 2)
	end
	assertTrue(snap.path == path, string.format("Expected array snapshot path %s, got %s", path, tostring(snap.path)))
	assertTrue(arr == snap.ref, string.format("Expected array identity at %s to remain unchanged", path))
	assertTrue(#arr == snap.length, string.format("Expected array length at %s to remain unchanged", path))
end

local function collectExprSnapshot(expr: Parser.ExprNode, path: string, out: { ExprSnapshot }): ()
	local snap: ExprSnapshot = {
		path = path,
		node = expr,
		kind = expr.kind,
		span = captureScalarSpan(expr.span),
		identName = nil,
		propNode = nil,
		propKind = nil,
		propName = nil,
		propSpan = nil,
		operator = nil,
		boolValue = nil,
		numValue = nil,
		strValue = nil,
		delimiter = nil,
		rawText = nil,
		rawLexemes = nil,
	}

	if expr.kind == "IdentifierExpr" then
		snap.identName = expr.name
	elseif expr.kind == "MemberExpr" then
		snap.propNode = expr.property
		snap.propKind = expr.property.kind
		snap.propName = expr.property.name
		snap.propSpan = captureScalarSpan(expr.property.span)
		table.insert(out, snap)
		collectExprSnapshot(expr.object, path .. ".object", out)
		return
	elseif expr.kind == "IndexExpr" then
		table.insert(out, snap)
		collectExprSnapshot(expr.base, path .. ".base", out)
		collectExprSnapshot(expr.index, path .. ".index", out)
		return
	elseif expr.kind == "BooleanLiteral" then
		snap.boolValue = expr.value
	elseif expr.kind == "NumberLiteral" then
		snap.numValue = expr.value
		snap.rawText = expr.raw
	elseif expr.kind == "StringLiteral" then
		snap.strValue = expr.value
		snap.delimiter = expr.delimiter
		snap.rawText = expr.raw
	elseif expr.kind == "ErrorExpr" then
		snap.rawLexemes = cloneStringArray(expr.rawLexemes)
	elseif expr.kind == "UnaryExpr" then
		snap.operator = expr.operator
		table.insert(out, snap)
		collectExprSnapshot(expr.operand, path .. ".operand", out)
		return
	elseif expr.kind == "BinaryExpr" then
		snap.operator = expr.operator
		table.insert(out, snap)
		collectExprSnapshot(expr.left, path .. ".left", out)
		collectExprSnapshot(expr.right, path .. ".right", out)
		return
	elseif expr.kind == "GroupedExpr" then
		table.insert(out, snap)
		collectExprSnapshot(expr.inner, path .. ".inner", out)
		return
	end

	table.insert(out, snap)
end

local function checkExprSnapshot(
	expr: Parser.ExprNode,
	path: string,
	snapshots: { ExprSnapshot },
	cursorRef: { index: number }
): ()
	cursorRef.index += 1
	local snap = snapshots[cursorRef.index]
	if snap == nil then
		error(string.format("Missing expression snapshot for %s", path), 2)
	end
	assertTrue(snap.path == path, string.format("Expected expression snapshot path %s, got %s", path, tostring(snap.path)))
	assertTrue(expr == snap.node, string.format("Expected expression node reference at %s to remain unchanged", path))
	assertTrue(expr.kind == snap.kind, string.format("Expected expression kind at %s to remain unchanged", path))
	assertTrue(matchesScalarSpan(expr.span, snap.span), string.format("Expected expression span at %s to remain unchanged", path))

	if expr.kind == "IdentifierExpr" then
		assertTrue(expr.name == snap.identName, string.format("Expected IdentifierExpr name at %s to remain unchanged", path))
	elseif expr.kind == "MemberExpr" then
		assertTrue(expr.property == snap.propNode, string.format("Expected MemberExpr.property node identity at %s to remain unchanged", path))
		assertTrue(expr.property.kind == snap.propKind, string.format("Expected MemberExpr.property kind at %s to remain unchanged", path))
		assertTrue(expr.property.name == snap.propName, string.format("Expected MemberExpr.property name at %s to remain unchanged", path))
		assertTrue(
			snap.propSpan ~= nil and matchesScalarSpan(expr.property.span, snap.propSpan),
			string.format("Expected MemberExpr.property span at %s to remain unchanged", path)
		)
		checkExprSnapshot(expr.object, path .. ".object", snapshots, cursorRef)
	elseif expr.kind == "IndexExpr" then
		checkExprSnapshot(expr.base, path .. ".base", snapshots, cursorRef)
		checkExprSnapshot(expr.index, path .. ".index", snapshots, cursorRef)
	elseif expr.kind == "BooleanLiteral" then
		assertTrue(expr.value == snap.boolValue, string.format("Expected BooleanLiteral value at %s to remain unchanged", path))
	elseif expr.kind == "NumberLiteral" then
		assertTrue(expr.value == snap.numValue, string.format("Expected NumberLiteral value at %s to remain unchanged", path))
		assertTrue(expr.raw == snap.rawText, string.format("Expected NumberLiteral raw at %s to remain unchanged", path))
	elseif expr.kind == "StringLiteral" then
		assertTrue(expr.value == snap.strValue, string.format("Expected StringLiteral value at %s to remain unchanged", path))
		assertTrue(expr.delimiter == snap.delimiter, string.format("Expected StringLiteral delimiter at %s to remain unchanged", path))
		assertTrue(expr.raw == snap.rawText, string.format("Expected StringLiteral raw at %s to remain unchanged", path))
	elseif expr.kind == "ErrorExpr" then
		assertTrue(
			snap.rawLexemes ~= nil and matchesStringArray(expr.rawLexemes, snap.rawLexemes),
			string.format("Expected ErrorExpr rawLexemes at %s to remain unchanged", path)
		)
	elseif expr.kind == "UnaryExpr" then
		assertTrue(expr.operator == snap.operator, string.format("Expected UnaryExpr operator at %s to remain unchanged", path))
		checkExprSnapshot(expr.operand, path .. ".operand", snapshots, cursorRef)
	elseif expr.kind == "BinaryExpr" then
		assertTrue(expr.operator == snap.operator, string.format("Expected BinaryExpr operator at %s to remain unchanged", path))
		checkExprSnapshot(expr.left, path .. ".left", snapshots, cursorRef)
		checkExprSnapshot(expr.right, path .. ".right", snapshots, cursorRef)
	elseif expr.kind == "GroupedExpr" then
		checkExprSnapshot(expr.inner, path .. ".inner", snapshots, cursorRef)
	end
end

local function collectBlockSnapshots(
	block: Parser.BlockNode,
	prefix: string,
	snaps: AstSnapshots
): ()
	recordArraySnapshot(snaps.arrays, prefix, block.statements)

	for i, stmt in ipairs(block.statements) do
		local entryPath = string.format("%s[%d]", prefix, i)
		table.insert(snaps.statements, {
			path = entryPath,
			node = stmt,
			kind = stmt.kind,
			span = captureScalarSpan(stmt.span),
		})

		if stmt.kind == "LocalDecl" then
			recordArraySnapshot(snaps.arrays, entryPath .. ".bindings", stmt.bindings)
			recordArraySnapshot(snaps.arrays, entryPath .. ".values", stmt.values)
			for bIdx, binding in ipairs(stmt.bindings) do
				table.insert(snaps.bindings, {
					path = string.format("%s.bindings[%d]", entryPath, bIdx),
					node = binding,
					nameNode = binding.name,
					identName = binding.name.name,
					span = captureScalarSpan(binding.span),
					nameSpan = captureScalarSpan(binding.name.span),
					typeAnnotationNode = binding.typeAnnotation,
					typeAnnotationSummary = summarizeTypeAnnotation(binding.typeAnnotation),
				})
			end
			for vIdx, valExpr in ipairs(stmt.values) do
				collectExprSnapshot(valExpr, string.format("%s.values[%d]", entryPath, vIdx), snaps.expressions)
			end
		elseif stmt.kind == "Assignment" then
			recordArraySnapshot(snaps.arrays, entryPath .. ".targets", stmt.targets)
			recordArraySnapshot(snaps.arrays, entryPath .. ".values", stmt.values)
			for tIdx, targetExpr in ipairs(stmt.targets) do
				collectExprSnapshot(targetExpr, string.format("%s.targets[%d]", entryPath, tIdx), snaps.expressions)
			end
			for vIdx, valExpr in ipairs(stmt.values) do
				collectExprSnapshot(valExpr, string.format("%s.values[%d]", entryPath, vIdx), snaps.expressions)
			end
		elseif stmt.kind == "CompoundAssignment" then
			collectExprSnapshot(stmt.target, entryPath .. ".target", snaps.expressions)
			collectExprSnapshot(stmt.value, entryPath .. ".value", snaps.expressions)
		elseif stmt.kind == "ReturnStmt" then
			recordArraySnapshot(snaps.arrays, entryPath .. ".values", stmt.values)
			for vIdx, valExpr in ipairs(stmt.values) do
				collectExprSnapshot(valExpr, string.format("%s.values[%d]", entryPath, vIdx), snaps.expressions)
			end
		elseif stmt.kind == "DoStmt" then
			collectBlockSnapshots(stmt.body, entryPath .. ".body", snaps)
		elseif stmt.kind == "WhileStmt" then
			collectExprSnapshot(stmt.condition, entryPath .. ".condition", snaps.expressions)
			collectBlockSnapshots(stmt.body, entryPath .. ".body", snaps)
		elseif stmt.kind == "RepeatStmt" then
			collectBlockSnapshots(stmt.body, entryPath .. ".body", snaps)
			collectExprSnapshot(stmt.condition, entryPath .. ".condition", snaps.expressions)
		end
	end
end

local function verifyBlockSnapshots(
	block: Parser.BlockNode,
	prefix: string,
	snaps: AstSnapshots,
	stmtCursor: { index: number },
	bindCursor: { index: number },
	exprCursor: { index: number },
	arrCursor: { index: number }
): ()
	checkArraySnapshot(block.statements, prefix, snaps.arrays, arrCursor)

	for i, stmt in ipairs(block.statements) do
		local entryPath = string.format("%s[%d]", prefix, i)
		stmtCursor.index += 1
		local snap = snaps.statements[stmtCursor.index]
		if snap == nil then
			error(string.format("Missing statement snapshot for %s", entryPath), 2)
		end
		assertTrue(snap.path == entryPath, string.format("Expected snapshot path %s, got %s", entryPath, tostring(snap.path)))
		assertTrue(stmt == snap.node, string.format("Expected statement node reference at %s to remain unchanged", entryPath))
		assertTrue(stmt.kind == snap.kind, string.format("Expected statement kind at %s to remain unchanged", entryPath))
		assertTrue(
			matchesScalarSpan(stmt.span, snap.span),
			string.format("Expected statement span coordinates at %s to remain unchanged", entryPath)
		)

		if stmt.kind == "LocalDecl" then
			checkArraySnapshot(stmt.bindings, entryPath .. ".bindings", snaps.arrays, arrCursor)
			checkArraySnapshot(stmt.values, entryPath .. ".values", snaps.arrays, arrCursor)
			for bIdx, binding in ipairs(stmt.bindings) do
				bindCursor.index += 1
				local bSnap = snaps.bindings[bindCursor.index]
				if bSnap == nil then
					error(string.format("Missing binding snapshot for %s.bindings[%d]", entryPath, bIdx), 2)
				end
				local bPath = string.format("%s.bindings[%d]", entryPath, bIdx)
				assertTrue(bSnap.path == bPath, string.format("Expected binding path %s, got %s", bPath, tostring(bSnap.path)))
				assertTrue(binding == bSnap.node, string.format("Expected binding node reference at %s to remain unchanged", bPath))
				assertTrue(binding.name == bSnap.nameNode, string.format("Expected binding.name reference at %s to remain unchanged", bPath))
				assertTrue(binding.name.name == bSnap.identName, string.format("Expected binding name at %s to remain unchanged", bPath))
				assertTrue(matchesScalarSpan(binding.span, bSnap.span), string.format("Expected binding span at %s to remain unchanged", bPath))
				assertTrue(matchesScalarSpan(binding.name.span, bSnap.nameSpan), string.format("Expected binding name span at %s to remain unchanged", bPath))
				assertTrue(
					binding.typeAnnotation == bSnap.typeAnnotationNode,
					string.format("Expected binding.typeAnnotation identity at %s to remain unchanged", bPath)
				)
				assertTrue(
					matchesTypeAnnotationSummary(binding.typeAnnotation, bSnap.typeAnnotationSummary),
					string.format("Expected binding.typeAnnotation details at %s to remain unchanged", bPath)
				)
			end
			for vIdx, valExpr in ipairs(stmt.values) do
				checkExprSnapshot(valExpr, string.format("%s.values[%d]", entryPath, vIdx), snaps.expressions, exprCursor)
			end
		elseif stmt.kind == "Assignment" then
			checkArraySnapshot(stmt.targets, entryPath .. ".targets", snaps.arrays, arrCursor)
			checkArraySnapshot(stmt.values, entryPath .. ".values", snaps.arrays, arrCursor)
			for tIdx, targetExpr in ipairs(stmt.targets) do
				checkExprSnapshot(targetExpr, string.format("%s.targets[%d]", entryPath, tIdx), snaps.expressions, exprCursor)
			end
			for vIdx, valExpr in ipairs(stmt.values) do
				checkExprSnapshot(valExpr, string.format("%s.values[%d]", entryPath, vIdx), snaps.expressions, exprCursor)
			end
		elseif stmt.kind == "CompoundAssignment" then
			checkExprSnapshot(stmt.target, entryPath .. ".target", snaps.expressions, exprCursor)
			checkExprSnapshot(stmt.value, entryPath .. ".value", snaps.expressions, exprCursor)
		elseif stmt.kind == "ReturnStmt" then
			checkArraySnapshot(stmt.values, entryPath .. ".values", snaps.arrays, arrCursor)
			for vIdx, valExpr in ipairs(stmt.values) do
				checkExprSnapshot(valExpr, string.format("%s.values[%d]", entryPath, vIdx), snaps.expressions, exprCursor)
			end
		elseif stmt.kind == "DoStmt" then
			verifyBlockSnapshots(stmt.body, entryPath .. ".body", snaps, stmtCursor, bindCursor, exprCursor, arrCursor)
		elseif stmt.kind == "WhileStmt" then
			checkExprSnapshot(stmt.condition, entryPath .. ".condition", snaps.expressions, exprCursor)
			verifyBlockSnapshots(stmt.body, entryPath .. ".body", snaps, stmtCursor, bindCursor, exprCursor, arrCursor)
		elseif stmt.kind == "RepeatStmt" then
			verifyBlockSnapshots(stmt.body, entryPath .. ".body", snaps, stmtCursor, bindCursor, exprCursor, arrCursor)
			checkExprSnapshot(stmt.condition, entryPath .. ".condition", snaps.expressions, exprCursor)
		end
	end
end

function ScopeAnalysisTests.runAll(): { [string]: boolean }
	local results: { [string]: boolean } = {}

	do
		local parsed = Parser.parse({
			tok("Keyword", "do", 1, 2, nil, nil),
			tok("Keyword", "do", 4, 5, nil, nil),
			tok("Keyword", "end", 7, 9, nil, nil),
			tok("Keyword", "end", 11, 13, nil, nil),
			eof(14),
		})

		local res = ScopeAnalysis.analyze(parsed.ast)
		local root = res.scopes[res.rootScopeId]
		assertTrue(root ~= nil and root.kind == "Chunk" and root.parentId == nil, "Expected root Chunk scope")
		assertTrue(#root.childrenIds == 1, "Expected 1 child scope under root Chunk")

		local outerBlockId = root.childrenIds[1]
		local outerBlock = res.scopes[outerBlockId]
		assertTrue(outerBlock ~= nil and outerBlock.kind == "Block" and outerBlock.parentId == root.id, "Expected outer Block child")
		assertTrue(#outerBlock.childrenIds == 1, "Expected 1 nested Block child")

		local innerBlockId = outerBlock.childrenIds[1]
		local innerBlock = res.scopes[innerBlockId]
		assertTrue(innerBlock ~= nil and innerBlock.kind == "Block" and innerBlock.parentId == outerBlock.id, "Expected inner Block child")

		local chain = ScopeAnalysis.getScopeChain(res, innerBlock.id)
		assertTrue(
			#chain == 3
				and chain[1].id == innerBlock.id
				and chain[2].id == outerBlock.id
				and chain[3].id == root.id,
			"Expected getScopeChain from starting inner scope upward to root"
		)

		results["root_chunk_and_block_hierarchy"] = true
	end

	do
		local parsed = Parser.parse({
			tok("Keyword", "while", 1, 5, nil, nil),
			tok("Keyword", "true", 7, 10, true, nil),
			tok("Keyword", "do", 12, 13, nil, nil),
			tok("Keyword", "repeat", 15, 20, nil, nil),
			tok("Keyword", "until", 22, 26, nil, nil),
			tok("Keyword", "false", 28, 32, false, nil),
			tok("Keyword", "end", 34, 36, nil, nil),
			eof(37),
		})

		local res = ScopeAnalysis.analyze(parsed.ast)
		local root = res.scopes[res.rootScopeId]
		assertTrue(#root.childrenIds == 1, "Expected single While scope under root")

		local whileScope = res.scopes[root.childrenIds[1]]
		assertTrue(whileScope.kind == "While" and whileScope.parentId == root.id, "Expected While scope owned by WhileStmt")
		assertTrue(#whileScope.childrenIds == 1, "Expected single Repeat scope inside While body")

		local repeatScope = res.scopes[whileScope.childrenIds[1]]
		assertTrue(repeatScope.kind == "Repeat" and repeatScope.parentId == whileScope.id, "Expected Repeat scope owned by RepeatStmt")

		results["while_and_repeat_scope_ownership"] = true
	end

	do
		local parsed = Parser.parse({
			tok("Keyword", "do", 1, 2, nil, nil),
			tok("Keyword", "end", 4, 6, nil, nil),
			eof(7),
		})
		local res = ScopeAnalysis.analyze(parsed.ast)
		local rootId = res.rootScopeId
		local childId = res.scopes[rootId].childrenIds[1]

		local outerSym: ScopeAnalysis.SymbolRecord = {
			id = 1,
			name = "v",
			scopeId = rootId,
			span = mkSpan(1, 1),
			readCount = 0,
			writeCount = 0,
		}
		local innerSym: ScopeAnalysis.SymbolRecord = {
			id = 2,
			name = "v",
			scopeId = childId,
			span = mkSpan(2, 2),
			readCount = 0,
			writeCount = 0,
		}

		res.symbols[outerSym.id] = outerSym
		res.symbols[innerSym.id] = innerSym
		res.scopes[rootId].symbolsByName["v"] = outerSym
		res.scopes[childId].symbolsByName["v"] = innerSym

		assertTrue(ScopeAnalysis.resolveName(res, "v", childId) == innerSym, "Expected inner scope symbol to shadow outer symbol in manual fixture")
		assertTrue(ScopeAnalysis.resolveName(res, "v", rootId) == outerSym, "Expected root scope to resolve outer symbol in manual fixture")
		assertTrue(ScopeAnalysis.resolveName(res, "missing", childId) == nil, "Expected nil for unknown identifier")

		results["resolve_name_chain_and_shadowing"] = true
	end

	do
		local parsed = Parser.parse({
			tok("Keyword", "do", 1, 2, nil, nil),
			tok("Keyword", "end", 4, 6, nil, nil),
			eof(7),
		})
		local res = ScopeAnalysis.analyze(parsed.ast)
		local invalidId = 999999

		local emptyChain = ScopeAnalysis.getScopeChain(res, invalidId)
		assertTrue(#emptyChain == 0, "Expected empty scope chain for non-existent scopeId")

		local zeroChain = ScopeAnalysis.getScopeChain(res, 0)
		assertTrue(#zeroChain == 0, "Expected empty scope chain for scopeId 0")

		local resolvedInvalid = ScopeAnalysis.resolveName(res, "anything", invalidId)
		assertTrue(resolvedInvalid == nil, "Expected nil from resolveName for non-existent scopeId")

		local resolvedNegative = ScopeAnalysis.resolveName(res, "anything", -1)
		assertTrue(resolvedNegative == nil, "Expected nil from resolveName for negative scopeId")

		local cyclicScopeA: ScopeAnalysis.ScopeNode = {
			id = 10,
			kind = "Block",
			parentId = 20,
			childrenIds = {},
			symbolsByName = {},
			declaredSymbolIds = {},
			span = mkSpan(1, 2),
		}
		local cyclicScopeB: ScopeAnalysis.ScopeNode = {
			id = 20,
			kind = "Block",
			parentId = 10,
			childrenIds = {},
			symbolsByName = {},
			declaredSymbolIds = {},
			span = mkSpan(3, 4),
		}
		local cyclicResult: ScopeAnalysis.ScopeAnalysisResult = {
			rootScopeId = 10,
			scopes = {
				[10] = cyclicScopeA,
				[20] = cyclicScopeB,
			},
			symbols = {},
			references = {},
		}

		local cyclicChain = ScopeAnalysis.getScopeChain(cyclicResult, 10)
		assertTrue(#cyclicChain == 2, "Expected cyclic getScopeChain to terminate after visiting each scope once")
		assertTrue(ScopeAnalysis.resolveName(cyclicResult, "absent", 10) == nil, "Expected cyclic resolveName to terminate and return nil")

		results["invalid_scope_id_and_cycle_handling"] = true
	end

	do
		local parsed = Parser.parse({
			tok("Keyword", "do", 1, 2, nil, nil),
			tok("Keyword", "do", 4, 5, nil, nil),
			tok("Keyword", "end", 7, 9, nil, nil),
			tok("Keyword", "end", 11, 13, nil, nil),
			tok("Keyword", "while", 15, 19, nil, nil),
			tok("Keyword", "true", 21, 24, true, nil),
			tok("Keyword", "do", 26, 27, nil, nil),
			tok("Keyword", "repeat", 29, 34, nil, nil),
			tok("Keyword", "until", 36, 40, nil, nil),
			tok("Keyword", "false", 42, 46, false, nil),
			tok("Keyword", "end", 48, 50, nil, nil),
			tok("Keyword", "end", 52, 54, nil, nil),
			eof(55),
		})

		local ast = parsed.ast
		local origBody = ast.body
		local origChunkKind = ast.kind
		local origChunkSpan = captureScalarSpan(ast.span)
		local origBodyKind = origBody.kind
		local origBodyTerminated = origBody.terminatedByControlFlow
		local origBodySpan = captureScalarSpan(origBody.span)
		local origStmtCount = #origBody.statements
		local origDiagArrayRef = parsed.diagnostics

		local snaps: AstSnapshots = {
			statements = {},
			bindings = {},
			expressions = {},
			arrays = {},
		}
		collectBlockSnapshots(origBody, "body.statements", snaps)

		local diagSnapshots: { DiagnosticSnapshot } = {}
		for i, diag in ipairs(parsed.diagnostics) do
			diagSnapshots[i] = {
				code = diag.code,
				severity = diag.severity,
				stage = diag.stage,
				message = diag.message,
				span = captureScalarSpan(diag.span),
			}
		end

		assertTrue(
			#diagSnapshots > 0,
			"Expected parser fixture to produce at least one diagnostic"
		)

		local _res = ScopeAnalysis.analyze(ast)

		assertTrue(ast.kind == origChunkKind, "Expected ChunkNode kind to remain unchanged")
		assertTrue(matchesScalarSpan(ast.span, origChunkSpan), "Expected ChunkNode span coordinates to remain unchanged")
		assertTrue(ast.body == origBody, "Expected ChunkNode.body reference to remain unchanged")
		assertTrue(origBody.kind == origBodyKind, "Expected BlockNode kind to remain unchanged")
		assertTrue(origBody.terminatedByControlFlow == origBodyTerminated, "Expected BlockNode.terminatedByControlFlow to remain unchanged")
		assertTrue(matchesScalarSpan(origBody.span, origBodySpan), "Expected BlockNode span coordinates to remain unchanged")
		assertTrue(#origBody.statements == origStmtCount, "Expected root block statement array length to remain unchanged")
		assertTrue(parsed.diagnostics == origDiagArrayRef, "Expected diagnostics array identity to remain unchanged")

		local stmtCursor = { index = 0 }
		local bindCursor = { index = 0 }
		local exprCursor = { index = 0 }
		local arrCursor = { index = 0 }
		verifyBlockSnapshots(origBody, "body.statements", snaps, stmtCursor, bindCursor, exprCursor, arrCursor)
		assertTrue(stmtCursor.index == #snaps.statements, "Expected all statement snapshots to be verified")
		assertTrue(bindCursor.index == #snaps.bindings, "Expected all binding snapshots to be verified")
		assertTrue(exprCursor.index == #snaps.expressions, "Expected all expression snapshots to be verified")
		assertTrue(arrCursor.index == #snaps.arrays, "Expected all array snapshots to be verified")

		assertTrue(#parsed.diagnostics == #diagSnapshots, "Expected parser diagnostics count to remain unchanged")
		for i, dSnap in ipairs(diagSnapshots) do
			local curDiag = parsed.diagnostics[i]
			assertTrue(curDiag.code == dSnap.code, string.format("Expected diagnostic #%d code to remain unchanged", i))
			assertTrue(curDiag.severity == dSnap.severity, string.format("Expected diagnostic #%d severity to remain unchanged", i))
			assertTrue(curDiag.stage == dSnap.stage, string.format("Expected diagnostic #%d stage to remain unchanged", i))
			assertTrue(curDiag.message == dSnap.message, string.format("Expected diagnostic #%d message to remain unchanged", i))
			assertTrue(matchesScalarSpan(curDiag.span, dSnap.span), string.format("Expected diagnostic #%d span coordinates to remain unchanged", i))
		end

		results["ast_immutability"] = true
	end

	do
		local parsed = Parser.parse({
			tok("Keyword", "local", 1, 5, nil, nil),
			tok("Identifier", "x", 7, 7, "x", nil),
			tok("Symbol", "=", 9, 9, nil, nil),
			tok("Number", "1", 11, 11, 1, nil),
			tok("Keyword", "do", 13, 14, nil, nil),
			tok("Keyword", "local", 16, 20, nil, nil),
			tok("Identifier", "x", 22, 22, "x", nil),
			tok("Symbol", "=", 24, 24, nil, nil),
			tok("Number", "2", 26, 26, 2, nil),
			tok("Keyword", "local", 28, 32, nil, nil),
			tok("Identifier", "x", 34, 34, "x", nil),
			tok("Symbol", "=", 36, 36, nil, nil),
			tok("Number", "3", 38, 38, 3, nil),
			tok("Keyword", "end", 40, 42, nil, nil),
			eof(43),
		})
		assertTrue(#parsed.diagnostics == 0, "Expected zero parser diagnostics in local declaration fixture")

		local res = ScopeAnalysis.analyze(parsed.ast)
		local rootScope = res.scopes[res.rootScopeId]
		local blockId = rootScope.childrenIds[1]
		local blockScope = res.scopes[blockId]

		assertTrue(#rootScope.declaredSymbolIds == 1, "Expected 1 declaration in root scope")
		assertTrue(#blockScope.declaredSymbolIds == 2, "Expected 2 declarations (including redeclaration) in inner Block scope")

		local sym1 = res.symbols[rootScope.declaredSymbolIds[1]]
		local sym2 = res.symbols[blockScope.declaredSymbolIds[1]]
		local sym3 = res.symbols[blockScope.declaredSymbolIds[2]]

		assertTrue(sym1 ~= nil and sym2 ~= nil and sym3 ~= nil, "Expected all 3 symbols to exist in symbol table")
		assertTrue(
			sym1.id ~= sym2.id and sym2.id ~= sym3.id and sym1.id ~= sym3.id,
			"Expected distinct symbol IDs for outer, inner, and redeclared inner symbols"
		)

		assertTrue(
			matchesScalarSpan(sym2.span, captureScalarSpan(mkSpan(22, 22))),
			"Expected inner declaration span to match binding span (22..22)"
		)
		assertTrue(sym1.readCount == 0 and sym1.writeCount == 0, "Expected initial read/write counts to be 0")
		assertTrue(ScopeAnalysis.resolveName(res, "x", res.rootScopeId) == sym1, "Expected root scope to resolve outer 'x'")
		assertTrue(ScopeAnalysis.resolveName(res, "x", blockId) == sym3, "Expected inner scope to resolve latest redeclared 'x'")

		results["m2_local_declaration_shadowing_and_redeclaration"] = true
	end

	do
		local parsedOuter = Parser.parse({
			tok("Keyword", "local", 1, 5, nil, nil),
			tok("Identifier", "x", 7, 7, "x", nil),
			tok("Symbol", "=", 9, 9, nil, nil),
			tok("Number", "10", 11, 12, 10, nil),
			tok("Keyword", "local", 14, 18, nil, nil),
			tok("Identifier", "x", 20, 20, "x", nil),
			tok("Symbol", "=", 22, 22, nil, nil),
			tok("Identifier", "x", 24, 24, "x", nil),
			eof(25),
		})
		local resOuter = ScopeAnalysis.analyze(parsedOuter.ast)
		local rootId = resOuter.rootScopeId
		local firstSym = resOuter.symbols[1]
		local secondSym = resOuter.symbols[2]
		assertTrue(firstSym ~= nil and secondSym ~= nil, "Expected two sequential 'x' symbols")
		assertTrue(#resOuter.references == 1, "Expected 1 identifier reference in second local x = x")
		assertTrue(
			resOuter.references[1].symbolId == firstSym.id and resOuter.references[1].resolved == true,
			"Expected RHS 'x' in 'local x = x' to bind to outer prior declaration"
		)
		assertTrue(firstSym.readCount == 1, "Expected outer 'x' readCount to increment once from RHS read")
		assertTrue(secondSym.readCount == 0, "Expected newly declared 'x' readCount to remain 0")
		assertTrue(
			ScopeAnalysis.resolveName(resOuter, "x", rootId) == secondSym,
			"Expected subsequent lookups in scope to resolve to newly registered 'x'"
		)

		local parsedMulti = Parser.parse({
			tok("Keyword", "local", 1, 5, nil, nil),
			tok("Identifier", "a", 7, 7, "a", nil),
			tok("Symbol", ",", 8, 8, nil, nil),
			tok("Identifier", "b", 10, 10, "b", nil),
			tok("Symbol", "=", 12, 12, nil, nil),
			tok("Identifier", "a", 14, 14, "a", nil),
			tok("Symbol", ",", 15, 15, nil, nil),
			tok("Identifier", "b", 17, 17, "b", nil),
			eof(18),
		})
		local resMulti = ScopeAnalysis.analyze(parsedMulti.ast)
		assertTrue(#resMulti.references == 2, "Expected 2 references ('a' then 'b') in initializer list")
		assertTrue(
			resMulti.references[1].name == "a" and resMulti.references[1].resolved == false and resMulti.references[1].symbolId == nil,
			"Expected 'a' in first initializer to be unresolved when not yet declared"
		)
		assertTrue(
			resMulti.references[2].name == "b" and resMulti.references[2].resolved == false and resMulti.references[2].symbolId == nil,
			"Expected 'b' in second initializer to be unresolved despite 'a' preceding it"
		)
		assertTrue(resMulti.symbols[1].readCount == 0 and resMulti.symbols[2].readCount == 0, "Expected neither binding read during its own declaration")

		results["m2_initializer_visibility_and_multi_binding_ordering"] = true
	end

	do
		local parsed = Parser.parse({
			tok("Keyword", "local", 1, 5, nil, nil),
			tok("Identifier", "x", 7, 7, "x", nil),
			tok("Symbol", "=", 9, 9, nil, nil),
			tok("Number", "1", 11, 11, 1, nil),
			tok("Identifier", "x", 13, 13, "x", nil),
			tok("Symbol", "=", 15, 15, nil, nil),
			tok("Identifier", "x", 17, 17, "x", nil),
			tok("Symbol", "+", 19, 19, nil, nil),
			tok("Identifier", "ext1", 21, 24, "ext1", nil),
			tok("Identifier", "x", 26, 26, "x", nil),
			tok("Symbol", "+=", 28, 29, nil, nil),
			tok("Identifier", "ext2", 31, 34, "ext2", nil),
			tok("Keyword", "return", 36, 41, nil, nil),
			tok("Identifier", "x", 43, 43, "x", nil),
			eof(44),
		})
		assertTrue(#parsed.diagnostics == 0, "Expected zero parser diagnostics in access classification fixture")

		local res = ScopeAnalysis.analyze(parsed.ast)
		local symX = res.symbols[1]
		assertTrue(symX ~= nil, "Expected symbol 'x'")

		-- Assignment and CompoundAssignment both visit RHS value expressions before target expressions, and LocalDecl bindings are not references.
		assertTrue(#res.references == 6, "Expected 6 identifier references in sequence")
		assertTrue(res.references[1].name == "x" and res.references[1].access == "Read" and res.references[1].resolved == true, "Expected ref #1 (RHS x) to be Read")
		assertTrue(res.references[2].name == "ext1" and res.references[2].access == "Read" and res.references[2].resolved == false and res.references[2].symbolId == nil, "Expected ref #2 'ext1' to be unresolved Read")
		assertTrue(res.references[3].name == "x" and res.references[3].access == "Write" and res.references[3].resolved == true, "Expected ref #3 (LHS x) to be Write")
		assertTrue(res.references[4].name == "ext2" and res.references[4].access == "Read" and res.references[4].resolved == false and res.references[4].symbolId == nil, "Expected ref #4 'ext2' to be unresolved Read")
		assertTrue(res.references[5].name == "x" and res.references[5].access == "ReadWrite" and res.references[5].resolved == true, "Expected ref #5 (compound target x) to be ReadWrite")
		assertTrue(res.references[6].name == "x" and res.references[6].access == "Read" and res.references[6].resolved == true, "Expected ref #6 to be Read")

		assertTrue(symX.readCount == 3, string.format("Expected symX.readCount == 3, got %d", symX.readCount))
		assertTrue(symX.writeCount == 2, string.format("Expected symX.writeCount == 2, got %d", symX.writeCount))

		results["m2_read_write_readwrite_and_unresolved_identifiers"] = true
	end

	do
		local parsed = Parser.parse({
			tok("Keyword", "local", 1, 5, nil, nil),
			tok("Identifier", "flag", 7, 10, "flag", nil),
			tok("Symbol", "=", 12, 12, nil, nil),
			tok("Keyword", "false", 14, 18, false, nil),
			tok("Keyword", "while", 20, 24, nil, nil),
			tok("Keyword", "not", 26, 28, nil, nil),
			tok("Identifier", "flag", 30, 33, "flag", nil),
			tok("Keyword", "do", 35, 36, nil, nil),
			tok("Keyword", "repeat", 38, 43, nil, nil),
			tok("Keyword", "local", 45, 49, nil, nil),
			tok("Identifier", "innerFlag", 51, 59, "innerFlag", nil),
			tok("Symbol", "=", 61, 61, nil, nil),
			tok("Keyword", "true", 63, 66, true, nil),
			tok("Identifier", "flag", 68, 71, "flag", nil),
			tok("Symbol", "=", 73, 73, nil, nil),
			tok("Identifier", "innerFlag", 75, 83, "innerFlag", nil),
			tok("Keyword", "until", 85, 89, nil, nil),
			tok("Identifier", "innerFlag", 91, 99, "innerFlag", nil),
			tok("Keyword", "end", 101, 103, nil, nil),
			eof(104),
		})
		assertTrue(#parsed.diagnostics == 0, "Expected zero parser diagnostics in while/repeat scope test")

		local res = ScopeAnalysis.analyze(parsed.ast)
		local rootScope = res.scopes[res.rootScopeId]
		local whileScope = res.scopes[rootScope.childrenIds[1]]
		local repeatScope = res.scopes[whileScope.childrenIds[1]]

		local flagSym = res.symbols[1]
		local innerFlagSym = res.symbols[2]
		assertTrue(flagSym ~= nil and flagSym.scopeId == rootScope.id, "Expected 'flag' declared in root scope")
		assertTrue(innerFlagSym ~= nil and innerFlagSym.scopeId == repeatScope.id, "Expected 'innerFlag' declared in Repeat scope")

		-- Assignment visits RHS value ('innerFlag') before target ('flag').
		assertTrue(#res.references == 4, "Expected 4 references across while and repeat constructs")
		assertTrue(
			res.references[1].scopeId == rootScope.id and res.references[1].symbolId == flagSym.id,
			"Expected while condition 'flag' to be analyzed in parent scope"
		)
		assertTrue(
			res.references[2].scopeId == repeatScope.id and res.references[2].symbolId == innerFlagSym.id and res.references[2].access == "Read",
			"Expected 'innerFlag' RHS read inside repeat body to resolve repeat-scoped 'innerFlag'"
		)
		assertTrue(
			res.references[3].scopeId == repeatScope.id and res.references[3].symbolId == flagSym.id and res.references[3].access == "Write",
			"Expected 'flag' write inside repeat body to resolve outer 'flag'"
		)
		assertTrue(
			res.references[4].scopeId == repeatScope.id and res.references[4].symbolId == innerFlagSym.id and res.references[4].access == "Read",
			"Expected 'until innerFlag' condition to see local declared in repeat body within same Repeat scope"
		)

		results["m2_while_condition_scope_and_repeat_condition_visibility"] = true
	end

	do
		local parsed = Parser.parse({
			tok("Keyword", "local", 1, 5, nil, nil),
			tok("Identifier", "s", 7, 7, "s", nil),
			tok("Symbol", ":", 8, 8, nil, nil),
			tok("Identifier", "string", 10, 15, "string", nil),
			tok("Symbol", "=", 17, 17, nil, nil),
			tok("String", "'hi'", 19, 22, "hi", "SingleQuote"),
			tok("Keyword", "local", 24, 28, nil, nil),
			tok("Identifier", "a", 30, 30, "a", nil),
			tok("Symbol", ",", 31, 31, nil, nil),
			tok("Identifier", "b", 33, 33, "b", nil),
			tok("Symbol", "=", 35, 35, nil, nil),
			tok("Number", "1", 37, 37, 1, nil),
			tok("Symbol", ",", 38, 38, nil, nil),
			tok("Number", "2", 40, 40, 2, nil),
			tok("Identifier", "a", 42, 42, "a", nil),
			tok("Symbol", ",", 43, 43, nil, nil),
			tok("Identifier", "b", 45, 45, "b", nil),
			tok("Symbol", "=", 47, 47, nil, nil),
			tok("Number", "3", 49, 49, 3, nil),
			tok("Symbol", ",", 50, 50, nil, nil),
			tok("Number", "4", 52, 52, 4, nil),
			tok("Identifier", "a", 54, 54, "a", nil),
			tok("Symbol", "+=", 56, 57, nil, nil),
			tok("Number", "2", 59, 59, 2, nil),
			tok("Keyword", "while", 61, 65, nil, nil),
			tok("Identifier", "a", 67, 67, "a", nil),
			tok("Symbol", "<", 69, 69, nil, nil),
			tok("Number", "5", 71, 71, 5, nil),
			tok("Keyword", "do", 73, 74, nil, nil),
			tok("Symbol", ")", 76, 76, nil, nil),
			tok("Keyword", "end", 78, 80, nil, nil),
			tok("Keyword", "repeat", 82, 87, nil, nil),
			tok("Identifier", "a", 89, 89, "a", nil),
			tok("Symbol", "-=", 91, 92, nil, nil),
			tok("Number", "1", 94, 94, 1, nil),
			tok("Keyword", "until", 96, 100, nil, nil),
			tok("Identifier", "a", 102, 102, "a", nil),
			tok("Symbol", "<=", 104, 105, nil, nil),
			tok("Number", "1", 107, 107, 1, nil),
			tok("Keyword", "return", 109, 114, nil, nil),
			tok("Identifier", "a", 116, 116, "a", nil),
			tok("Symbol", ",", 117, 117, nil, nil),
			tok("Identifier", "b", 119, 119, "b", nil),
			tok("Keyword", "end", 121, 123, nil, nil),
			eof(124),
		})

		local ast = parsed.ast
		local origBody = ast.body
		local origChunkSpan = captureScalarSpan(ast.span)
		local origBodySpan = captureScalarSpan(origBody.span)
		local origStmtCount = #origBody.statements
		local origDiagArrayRef = parsed.diagnostics

		local snaps: AstSnapshots = {
			statements = {},
			bindings = {},
			expressions = {},
			arrays = {},
		}
		collectBlockSnapshots(origBody, "body.statements", snaps)

		local diagSnapshots: { DiagnosticSnapshot } = {}
		for i, diag in ipairs(parsed.diagnostics) do
			diagSnapshots[i] = {
				code = diag.code,
				severity = diag.severity,
				stage = diag.stage,
				message = diag.message,
				span = captureScalarSpan(diag.span),
			}
		end
		assertTrue(#diagSnapshots > 0, "Expected at least one parser diagnostic in immutability fixture")

		local _res = ScopeAnalysis.analyze(ast)

		assertTrue(ast.body == origBody, "Expected ChunkNode.body reference unchanged")
		assertTrue(matchesScalarSpan(ast.span, origChunkSpan), "Expected ChunkNode span unchanged")
		assertTrue(matchesScalarSpan(origBody.span, origBodySpan), "Expected BlockNode span unchanged")
		assertTrue(#origBody.statements == origStmtCount, "Expected root statement count unchanged")
		assertTrue(parsed.diagnostics == origDiagArrayRef, "Expected diagnostics array identity unchanged")

		local stmtCursor = { index = 0 }
		local bindCursor = { index = 0 }
		local exprCursor = { index = 0 }
		local arrCursor = { index = 0 }
		verifyBlockSnapshots(origBody, "body.statements", snaps, stmtCursor, bindCursor, exprCursor, arrCursor)
		assertTrue(stmtCursor.index == #snaps.statements, "Expected all statement snapshots verified")
		assertTrue(bindCursor.index == #snaps.bindings, "Expected all binding snapshots verified")
		assertTrue(exprCursor.index == #snaps.expressions, "Expected all expression snapshots verified")
		assertTrue(arrCursor.index == #snaps.arrays, "Expected all array snapshots verified")

		assertTrue(#parsed.diagnostics == #diagSnapshots, "Expected parser diagnostics count unchanged")
		for i, dSnap in ipairs(diagSnapshots) do
			local curDiag = parsed.diagnostics[i]
			assertTrue(curDiag.code == dSnap.code, string.format("Expected diagnostic #%d code unchanged", i))
			assertTrue(curDiag.severity == dSnap.severity, string.format("Expected diagnostic #%d severity unchanged", i))
			assertTrue(curDiag.stage == dSnap.stage, string.format("Expected diagnostic #%d stage unchanged", i))
			assertTrue(curDiag.message == dSnap.message, string.format("Expected diagnostic #%d message unchanged", i))
			assertTrue(matchesScalarSpan(curDiag.span, dSnap.span), string.format("Expected diagnostic #%d span unchanged", i))
		end

		results["m2_ast_immutability_full_statements"] = true
	end

	-- Step 1: MemberExpr & IndexExpr AST immutability (including MemberExpr.property identity and scalar span)
	do
		local parsed = Parser.parse({
			tok("Keyword", "local", 1, 5, nil, nil),
			tok("Identifier", "t", 7, 7, "t", nil),
			tok("Symbol", "=", 9, 9, nil, nil),
			tok("Identifier", "extObj", 11, 16, "extObj", nil),
			tok("Symbol", ".", 17, 17, nil, nil),
			tok("Identifier", "field", 18, 22, "field", nil),
			tok("Symbol", "[", 23, 23, nil, nil),
			tok("Identifier", "idxKey", 24, 29, "idxKey", nil),
			tok("Symbol", "]", 30, 30, nil, nil),
			tok("Identifier", "t", 32, 32, "t", nil),
			tok("Symbol", ".", 33, 33, nil, nil),
			tok("Identifier", "nestedProp", 34, 43, "nestedProp", nil),
			tok("Symbol", "[", 44, 44, nil, nil),
			tok("Identifier", "innerIdx", 45, 52, "innerIdx", nil),
			tok("Symbol", "]", 53, 53, nil, nil),
			tok("Symbol", "=", 55, 55, nil, nil),
			tok("Number", "9", 57, 57, 9, nil),
			tok("Identifier", "t", 59, 59, "t", nil),
			tok("Symbol", ".", 60, 60, nil, nil),
			tok("Identifier", "nestedProp", 61, 70, "nestedProp", nil),
			tok("Symbol", "+=", 72, 73, nil, nil),
			tok("Number", "1", 75, 75, 1, nil),
			eof(76),
		})
		assertTrue(#parsed.diagnostics == 0, "Expected zero parser diagnostics in Step 1 immutability fixture")

		local ast = parsed.ast
		local origBody = ast.body
		local snaps: AstSnapshots = {
			statements = {},
			bindings = {},
			expressions = {},
			arrays = {},
		}
		collectBlockSnapshots(origBody, "body.statements", snaps)

		local _res = ScopeAnalysis.analyze(ast)

		local stmtCursor = { index = 0 }
		local bindCursor = { index = 0 }
		local exprCursor = { index = 0 }
		local arrCursor = { index = 0 }
		verifyBlockSnapshots(origBody, "body.statements", snaps, stmtCursor, bindCursor, exprCursor, arrCursor)
		assertTrue(stmtCursor.index == #snaps.statements, "Expected all Step 1 statement snapshots verified")
		assertTrue(bindCursor.index == #snaps.bindings, "Expected all Step 1 binding snapshots verified")
		assertTrue(exprCursor.index == #snaps.expressions, "Expected all Step 1 expression snapshots verified")
		assertTrue(arrCursor.index == #snaps.arrays, "Expected all Step 1 array snapshots verified")

		-- Statement 1 (`local t = extObj.field[idxKey]`) expressions in snaps.expressions:
		--   [1] body.statements[1].values[1] (IndexExpr)
		--   [2] body.statements[1].values[1].base (MemberExpr: extObj.field)
		--   [3] body.statements[1].values[1].base.object (IdentifierExpr: extObj)
		--   [4] body.statements[1].values[1].index (IdentifierExpr: idxKey)
		-- Statement 2 (`t.nestedProp[innerIdx] = 9`) expressions start at [5]:
		--   [5] body.statements[2].targets[1] (IndexExpr: t.nestedProp[innerIdx])
		--   [6] body.statements[2].targets[1].base (MemberExpr: t.nestedProp)
		--   [7] body.statements[2].targets[1].base.object (IdentifierExpr: t)
		--   [8] body.statements[2].targets[1].index (IdentifierExpr: innerIdx)
		local assignStmt = origBody.statements[2] :: any
		local targetIndexExpr = assignStmt.targets[1] :: any
		local memberNode = targetIndexExpr.base :: any
		assertTrue(memberNode.kind == "MemberExpr", "Expected target base to be MemberExpr")
		assertTrue(
			snaps.expressions[5].path == "body.statements[2].targets[1]"
				and snaps.expressions[6].path == "body.statements[2].targets[1].base"
				and snaps.expressions[7].path == "body.statements[2].targets[1].base.object"
				and snaps.expressions[8].path == "body.statements[2].targets[1].index",
			"Expected snaps.expressions[5..8] to match body.statements[2].targets[1] subtree"
		)

		local targetSlice: { ExprSnapshot } = {
			snaps.expressions[5],
			snaps.expressions[6],
			snaps.expressions[7],
			snaps.expressions[8],
		}
		local origPropNode = memberNode.property
		local origPropSpan = captureScalarSpan(origPropNode.span)

		memberNode.property = {
			kind = "Identifier",
			name = origPropNode.name,
			span = mkSpan(origPropNode.span.start.offset, origPropNode.span["end"].offset),
		}
		local caughtIdentityChange = false
		do
			local ok = pcall(function()
				local c = { index = 0 }
				checkExprSnapshot(targetIndexExpr, "body.statements[2].targets[1]", targetSlice, c)
				assertTrue(c.index == #targetSlice, "Expected all targetSlice snapshots to be consumed")
			end)
			caughtIdentityChange = not ok
		end
		assertTrue(caughtIdentityChange, "Expected checkExprSnapshot to detect MemberExpr.property node identity replacement")
		memberNode.property = origPropNode

		origPropNode.span.start.column += 1
		local caughtSpanChange = false
		do
			local ok = pcall(function()
				local c = { index = 0 }
				checkExprSnapshot(targetIndexExpr, "body.statements[2].targets[1]", targetSlice, c)
				assertTrue(c.index == #targetSlice, "Expected all targetSlice snapshots to be consumed")
			end)
			caughtSpanChange = not ok
		end
		assertTrue(caughtSpanChange, "Expected checkExprSnapshot to detect MemberExpr.property scalar span mutation")
		origPropNode.span.start.column = origPropSpan.startCol

		results["m3_step1_member_and_index_ast_immutability"] = true
	end

	-- Step 1: Exact reference ordering, access kinds, resolution, symbol IDs, read/write counts,
	-- non-registration of member properties, and nested member/index + compound assignment targets
	do
		local parsed = Parser.parse({
			tok("Keyword", "local", 1, 5, nil, nil),
			tok("Identifier", "obj", 7, 9, "obj", nil),
			tok("Symbol", "=", 11, 11, nil, nil),
			tok("Number", "0", 13, 13, 0, nil),
			tok("Keyword", "local", 15, 19, nil, nil),
			tok("Identifier", "k", 21, 21, "k", nil),
			tok("Symbol", "=", 23, 23, nil, nil),
			tok("Number", "1", 25, 25, 1, nil),
			-- Stmt 3: obj.prop = k  => RHS reads k; target MemberExpr reads obj
			tok("Identifier", "obj", 27, 29, "obj", nil),
			tok("Symbol", ".", 30, 30, nil, nil),
			tok("Identifier", "prop", 31, 34, "prop", nil),
			tok("Symbol", "=", 36, 36, nil, nil),
			tok("Identifier", "k", 38, 38, "k", nil),
			-- Stmt 4: obj.sub[k].leaf = unresBase.field[unresKey]
			-- RHS visits unresBase (Read), unresKey (Read); target visits obj (Read), k (Read)
			tok("Identifier", "obj", 40, 42, "obj", nil),
			tok("Symbol", ".", 43, 43, nil, nil),
			tok("Identifier", "sub", 44, 46, "sub", nil),
			tok("Symbol", "[", 47, 47, nil, nil),
			tok("Identifier", "k", 48, 48, "k", nil),
			tok("Symbol", "]", 49, 49, nil, nil),
			tok("Symbol", ".", 50, 50, nil, nil),
			tok("Identifier", "leaf", 51, 54, "leaf", nil),
			tok("Symbol", "=", 56, 56, nil, nil),
			tok("Identifier", "unresBase", 58, 66, "unresBase", nil),
			tok("Symbol", ".", 67, 67, nil, nil),
			tok("Identifier", "field", 68, 72, "field", nil),
			tok("Symbol", "[", 73, 73, nil, nil),
			tok("Identifier", "unresKey", 74, 81, "unresKey", nil),
			tok("Symbol", "]", 82, 82, nil, nil),
			-- Stmt 5: obj.sub[k] += k  => RHS reads k; target IndexExpr reads obj (Read), k (Read)
			tok("Identifier", "obj", 84, 86, "obj", nil),
			tok("Symbol", ".", 87, 87, nil, nil),
			tok("Identifier", "sub", 88, 90, "sub", nil),
			tok("Symbol", "[", 91, 91, nil, nil),
			tok("Identifier", "k", 92, 92, "k", nil),
			tok("Symbol", "]", 93, 93, nil, nil),
			tok("Symbol", "+=", 95, 96, nil, nil),
			tok("Identifier", "k", 98, 98, "k", nil),
			-- Stmt 6: k += 2  => RHS has no identifier; direct target k receives ReadWrite
			tok("Identifier", "k", 100, 100, "k", nil),
			tok("Symbol", "+=", 102, 103, nil, nil),
			tok("Number", "2", 105, 105, 2, nil),
			eof(106),
		})
		assertTrue(#parsed.diagnostics == 0, "Expected zero parser diagnostics in Step 1 scope precision test")

		local res = ScopeAnalysis.analyze(parsed.ast)
		local rootScope = res.scopes[res.rootScopeId]
		local symObj = rootScope.symbolsByName["obj"]
		local symK = rootScope.symbolsByName["k"]
		assertTrue(symObj ~= nil and symK ~= nil, "Expected symbols 'obj' and 'k' in root scope")

		local forbiddenNames: { [string]: boolean } = {
			["prop"] = true,
			["sub"] = true,
			["leaf"] = true,
			["field"] = true,
		}
		for propName in pairs(forbiddenNames) do
			assertTrue(rootScope.symbolsByName[propName] == nil, string.format("Expected member property '%s' not to be a symbol", propName))
		end

		-- Exact reference sequence (10 references):
		-- [1] k (Read, resolved, symK.id)      from RHS of `obj.prop = k`
		-- [2] obj (Read, resolved, symObj.id)  from target `obj.prop`
		-- [3] unresBase (Read, unresolved, nil) from RHS `unresBase.field[unresKey]`
		-- [4] unresKey (Read, unresolved, nil)  from RHS index `unresKey`
		-- [5] obj (Read, resolved, symObj.id)  from target `obj.sub[k].leaf`
		-- [6] k (Read, resolved, symK.id)      from target index `k` in `obj.sub[k].leaf`
		-- [7] k (Read, resolved, symK.id)      from RHS of `obj.sub[k] += k`
		-- [8] obj (Read, resolved, symObj.id)  from target `obj.sub[k]`
		-- [9] k (Read, resolved, symK.id)      from target index `k` in `obj.sub[k]`
		-- [10] k (ReadWrite, resolved, symK.id) from direct compound target `k += 2`
		assertTrue(#res.references == 10, string.format("Expected 10 references, got %d", #res.references))

		local expectedRefs: { { name: string, access: ScopeAnalysis.AccessKind, resolved: boolean, symbolId: number? } } = {
			{ name = "k", access = "Read", resolved = true, symbolId = symK.id },
			{ name = "obj", access = "Read", resolved = true, symbolId = symObj.id },
			{ name = "unresBase", access = "Read", resolved = false, symbolId = nil },
			{ name = "unresKey", access = "Read", resolved = false, symbolId = nil },
			{ name = "obj", access = "Read", resolved = true, symbolId = symObj.id },
			{ name = "k", access = "Read", resolved = true, symbolId = symK.id },
			{ name = "k", access = "Read", resolved = true, symbolId = symK.id },
			{ name = "obj", access = "Read", resolved = true, symbolId = symObj.id },
			{ name = "k", access = "Read", resolved = true, symbolId = symK.id },
			{ name = "k", access = "ReadWrite", resolved = true, symbolId = symK.id },
		}

		for i, exp in ipairs(expectedRefs) do
			local actual = res.references[i]
			assertTrue(not forbiddenNames[actual.name], string.format("Member property '%s' must never appear as a lexical reference", actual.name))
			assertTrue(actual.name == exp.name, string.format("Ref #%d expected name '%s', got '%s'", i, exp.name, actual.name))
			assertTrue(actual.access == exp.access, string.format("Ref #%d (%s) expected access '%s', got '%s'", i, exp.name, exp.access, actual.access))
			assertTrue(actual.resolved == exp.resolved, string.format("Ref #%d (%s) expected resolved=%s", i, exp.name, tostring(exp.resolved)))
			assertTrue(actual.symbolId == exp.symbolId, string.format("Ref #%d (%s) expected symbolId=%s, got %s", i, exp.name, tostring(exp.symbolId), tostring(actual.symbolId)))
		end

		assertTrue(symObj.readCount == 3 and symObj.writeCount == 0, string.format("Expected 'obj' counts (3, 0), got (%d, %d)", symObj.readCount, symObj.writeCount))
		assertTrue(symK.readCount == 5 and symK.writeCount == 1, string.format("Expected 'k' counts (5, 1), got (%d, %d)", symK.readCount, symK.writeCount))

		results["m3_step1_member_and_index_scope_accounting"] = true
	end

	return results
end

return ScopeAnalysisTests
