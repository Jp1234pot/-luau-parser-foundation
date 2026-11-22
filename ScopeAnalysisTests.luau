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

type DiagnosticSnapshot = {
code: string,
severity: Parser.DiagnosticSeverity,
stage: string,
message: string,
span: ScalarSpan,
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

local function collectStatementSnapshots(
block: Parser.BlockNode,
prefix: string,
out: { StatementSnapshot }
): ()
for i, stmt in ipairs(block.statements) do
local entryPath = string.format("%s[%d]", prefix, i)
table.insert(out, {
path = entryPath,
node = stmt,
kind = stmt.kind,
span = captureScalarSpan(stmt.span),
})

if stmt.kind == "DoStmt" then  
		collectStatementSnapshots(stmt.body, entryPath .. ".body", out)  
	elseif stmt.kind == "WhileStmt" then  
		collectStatementSnapshots(stmt.body, entryPath .. ".body", out)  
	elseif stmt.kind == "RepeatStmt" then  
		collectStatementSnapshots(stmt.body, entryPath .. ".body", out)  
	end  
end

end

local function verifyStatementSnapshots(
block: Parser.BlockNode,
prefix: string,
snapshots: { StatementSnapshot },
cursorRef: { index: number }
): ()
for i, stmt in ipairs(block.statements) do
local entryPath = string.format("%s[%d]", prefix, i)
cursorRef.index += 1
local snap = snapshots[cursorRef.index]
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

if stmt.kind == "DoStmt" then  
		verifyStatementSnapshots(stmt.body, entryPath .. ".body", snapshots, cursorRef)  
	elseif stmt.kind == "WhileStmt" then  
		verifyStatementSnapshots(stmt.body, entryPath .. ".body", snapshots, cursorRef)  
	elseif stmt.kind == "RepeatStmt" then  
		verifyStatementSnapshots(stmt.body, entryPath .. ".body", snapshots, cursorRef)  
	end  
end

end

function ScopeAnalysisTests.runAll(): { [string]: boolean }
local results: { [string]: boolean } = {}

-- 1. Root chunk scope & nested DoStmt block hierarchy + getScopeChain (starting scope up to root)  
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

-- 2. WhileStmt and RepeatStmt scope ownership  
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

-- 3. Lexical lookup & shadowing test using manually populated scope tables  
-- (actual declaration registration and shadowing analysis belong to Milestone 2)  
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
	}  
	local innerSym: ScopeAnalysis.SymbolRecord = {  
		id = 2,  
		name = "v",  
		scopeId = childId,  
		span = mkSpan(2, 2),  
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

-- 4. Invalid scope IDs and cyclic hierarchy handling for getScopeChain and resolveName  
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

	-- Cyclic parentId chain test on isolated test scope map  
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
	}  

	local cyclicChain = ScopeAnalysis.getScopeChain(cyclicResult, 10)  
	assertTrue(#cyclicChain == 2, "Expected cyclic getScopeChain to terminate after visiting each scope once")  
	assertTrue(ScopeAnalysis.resolveName(cyclicResult, "absent", 10) == nil, "Expected cyclic resolveName to terminate and return nil")  

	results["invalid_scope_id_and_cycle_handling"] = true  
end  

-- 5. AST immutability: analyze must not alter AST structure, nested statements, scalar spans, or diagnostics  
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
		tok("Keyword", "end", 52, 54, nil, nil), -- extra 'end' produces a parser diagnostic  
		eof(55),  
	})  

	local ast = parsed.ast  
	local origBody = ast.body  
	local origChunkKind = ast.kind  
	local origChunkSpan = captureScalarSpan(ast.span)  
	local origBodyKind = origBody.kind  
	local origBodyTerminated = origBody.terminatedByControlFlow  
	local origBodySpan = captureScalarSpan(origBody.span)  

	local stmtSnapshots: { StatementSnapshot } = {}  
	collectStatementSnapshots(origBody, "body.statements", stmtSnapshots)  

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

	local cursorRef = { index = 0 }  
	verifyStatementSnapshots(origBody, "body.statements", stmtSnapshots, cursorRef)  
	assertTrue(cursorRef.index == #stmtSnapshots, "Expected all statement snapshots to be verified")  

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

return results

end

return ScopeAnalysisTests
