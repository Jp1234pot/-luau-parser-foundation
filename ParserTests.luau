--!strict

local Parser = require(script.Parent.Parser)

local ParserTests = {}

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

function ParserTests.runAll(): { [string]: boolean }
	local results: { [string]: boolean } = {}

	-- 1. Precedence & associativity in LocalDecl initializers
	do
		local r1 = Parser.parse({
			tok("Keyword", "local", 1, 5, nil, nil),
			tok("Identifier", "x", 7, 7, "x", nil),
			tok("Symbol", "=", 9, 9, nil, nil),
			tok("Symbol", "-", 11, 11, nil, nil),
			tok("Number", "2", 12, 12, 2, nil),
			tok("Symbol", "^", 14, 14, nil, nil),
			tok("Number", "2", 16, 16, 2, nil),
			eof(17),
		})
		local d1 = r1.ast.body.statements[1] :: any
		assertTrue(
			#r1.diagnostics == 0
				and d1.kind == "LocalDecl"
				and d1.values[1].kind == "UnaryExpr"
				and d1.values[1].operator == "-"
				and d1.values[1].operand.kind == "BinaryExpr"
				and d1.values[1].operand.operator == "^",
			"Expected local x = -2 ^ 2 -> UnaryExpr('-', BinaryExpr('^', ...))"
		)

		local r1b = Parser.parse({
			tok("Keyword", "local", 1, 5, nil, nil),
			tok("Identifier", "x", 7, 7, "x", nil),
			tok("Symbol", "=", 9, 9, nil, nil),
			tok("Number", "2", 11, 11, 2, nil),
			tok("Symbol", "^", 13, 13, nil, nil),
			tok("Symbol", "-", 15, 15, nil, nil),
			tok("Number", "2", 16, 16, 2, nil),
			eof(17),
		})
		local d1b = r1b.ast.body.statements[1] :: any
		assertTrue(
			#r1b.diagnostics == 0
				and d1b.kind == "LocalDecl"
				and d1b.values[1].kind == "BinaryExpr"
				and d1b.values[1].operator == "^"
				and d1b.values[1].right.kind == "UnaryExpr"
				and d1b.values[1].right.operator == "-",
			"Expected local x = 2 ^ -2 -> BinaryExpr('^', 2, UnaryExpr('-', 2))"
		)

		local r2 = Parser.parse({
			tok("Keyword", "local", 1, 5, nil, nil),
			tok("Identifier", "x", 7, 7, "x", nil),
			tok("Symbol", "=", 9, 9, nil, nil),
			tok("Keyword", "not", 11, 13, nil, nil),
			tok("Identifier", "a", 15, 15, "a", nil),
			tok("Symbol", "==", 17, 18, nil, nil),
			tok("Identifier", "b", 20, 20, "b", nil),
			eof(21),
		})
		local e2 = (r2.ast.body.statements[1] :: any).values[1]
		assertTrue(
			#r2.diagnostics == 0
				and e2.kind == "BinaryExpr"
				and e2.operator == "=="
				and e2.left.kind == "UnaryExpr"
				and e2.left.operator == "not",
			"Expected local x = not a == b -> BinaryExpr('==', UnaryExpr('not', a), b)"
		)

		local r3 = Parser.parse({
			tok("Keyword", "local", 1, 5, nil, nil),
			tok("Identifier", "x", 7, 7, "x", nil),
			tok("Symbol", "=", 9, 9, nil, nil),
			tok("Identifier", "a", 11, 11, "a", nil),
			tok("Symbol", "^", 13, 13, nil, nil),
			tok("Identifier", "b", 15, 15, "b", nil),
			tok("Symbol", "^", 17, 17, nil, nil),
			tok("Identifier", "c", 19, 19, "c", nil),
			eof(20),
		})
		local e3 = (r3.ast.body.statements[1] :: any).values[1]
		assertTrue(
			#r3.diagnostics == 0
				and e3.kind == "BinaryExpr"
				and e3.operator == "^"
				and e3.right.kind == "BinaryExpr"
				and e3.right.operator == "^",
			"Expected right-associative a ^ (b ^ c)"
		)

		local r4 = Parser.parse({
			tok("Keyword", "local", 1, 5, nil, nil),
			tok("Identifier", "x", 7, 7, "x", nil),
			tok("Symbol", "=", 9, 9, nil, nil),
			tok("Identifier", "a", 11, 11, "a", nil),
			tok("Symbol", "..", 13, 14, nil, nil),
			tok("Identifier", "b", 16, 16, "b", nil),
			tok("Symbol", "..", 18, 19, nil, nil),
			tok("Identifier", "c", 21, 21, "c", nil),
			eof(22),
		})
		local e4 = (r4.ast.body.statements[1] :: any).values[1]
		assertTrue(
			#r4.diagnostics == 0
				and e4.kind == "BinaryExpr"
				and e4.operator == ".."
				and e4.right.kind == "BinaryExpr"
				and e4.right.operator == "..",
			"Expected right-associative a .. (b .. c)"
		)

		results["precedence_and_associativity_local_decl_ast"] = true
	end

	-- 2. Assignment target validation
	do
		local rMulti = Parser.parse({
			tok("Identifier", "a", 1, 1, "a", nil),
			tok("Symbol", ",", 2, 2, nil, nil),
			tok("Identifier", "b", 4, 4, "b", nil),
			tok("Symbol", "=", 6, 6, nil, nil),
			tok("Number", "1", 8, 8, 1, nil),
			tok("Symbol", ",", 9, 9, nil, nil),
			tok("Number", "2", 11, 11, 2, nil),
			eof(12),
		})
		local mStmt = rMulti.ast.body.statements[1] :: any
		assertTrue(
			#rMulti.diagnostics == 0
				and mStmt.kind == "Assignment"
				and #mStmt.targets == 2
				and mStmt.targets[1].name == "a"
				and mStmt.targets[2].name == "b",
			"Expected valid multi-target assignment a, b = 1, 2"
		)

		local rBadFirst = Parser.parse({
			tok("Number", "1", 1, 1, 1, nil),
			tok("Symbol", "=", 3, 3, nil, nil),
			tok("Number", "2", 5, 5, 2, nil),
			eof(6),
		})
		assertTrue(#rBadFirst.diagnostics >= 1, "Expected diagnostic for invalid first target '1 = 2'")

		local rBadSecond = Parser.parse({
			tok("Identifier", "a", 1, 1, "a", nil),
			tok("Symbol", ",", 2, 2, nil, nil),
			tok("Number", "1", 4, 4, 1, nil),
			tok("Symbol", "=", 6, 6, nil, nil),
			tok("Number", "10", 8, 9, 10, nil),
			tok("Symbol", ",", 10, 10, nil, nil),
			tok("Number", "20", 12, 13, 20, nil),
			eof(14),
		})
		assertTrue(#rBadSecond.diagnostics >= 1, "Expected diagnostic for invalid second target in 'a, 1 = 10, 20'")

		local rBadCompound = Parser.parse({
			tok("Number", "1", 1, 1, 1, nil),
			tok("Symbol", "+=", 3, 4, nil, nil),
			tok("Number", "2", 6, 6, 2, nil),
			eof(7),
		})
		assertTrue(#rBadCompound.diagnostics >= 1, "Expected diagnostic for invalid compound target '1 += 2'")

		results["assignment_target_validation"] = true
	end

	-- 3. Contextual `continue` disambiguation & block termination
	do
		local rAssign = Parser.parse({
			tok("Identifier", "continue", 1, 8, "continue", nil),
			tok("Symbol", "=", 10, 10, nil, nil),
			tok("Number", "10", 12, 13, 10, nil),
			eof(14),
		})
		assertTrue(rAssign.ast.body.statements[1].kind == "Assignment", "Expected continue = 10 to parse as Assignment")

		local rLoop = Parser.parse({
			tok("Keyword", "while", 1, 5, nil, nil),
			tok("Keyword", "true", 7, 10, true, nil),
			tok("Keyword", "do", 12, 13, nil, nil),
			tok("Identifier", "continue", 15, 22, "continue", nil),
			tok("Keyword", "local", 24, 28, nil, nil),
			tok("Identifier", "x", 30, 30, "x", nil),
			tok("Symbol", "=", 32, 32, nil, nil),
			tok("Number", "1", 34, 34, 1, nil),
			tok("Keyword", "end", 36, 38, nil, nil),
			eof(39),
		})
		local whileStmt = rLoop.ast.body.statements[1] :: any
		assertTrue(
			whileStmt.kind == "WhileStmt"
				and whileStmt.body.terminatedByControlFlow == true
				and whileStmt.body.statements[1].kind == "ContinueStmt",
			"Expected ContinueStmt with block termination inside while body"
		)

		results["continue_disambiguation_and_block_termination"] = true
	end

	-- 4. Recovery: immediate recovery, repeated invalid tokens, overflow recovery, nesting-aware blocks & closers
	do
		local rImmediate = Parser.parse({
			tok("Number", "1", 1, 1, 1, nil),
			tok("Symbol", "=", 3, 3, nil, nil),
			tok("Number", "2", 5, 5, 2, nil),
			tok("Keyword", "local", 7, 11, nil, nil),
			tok("Identifier", "recovered", 13, 21, "recovered", nil),
			tok("Symbol", "=", 23, 23, nil, nil),
			tok("Number", "10", 25, 26, 10, nil),
			eof(27),
		})
		assertTrue(#rImmediate.diagnostics >= 1, "Expected diagnostic for malformed assignment before local recovered = 10")
		local foundRecovered = false
		for _, st in ipairs(rImmediate.ast.body.statements) do
			if st.kind == "LocalDecl" and (st :: any).bindings[1].name.name == "recovered" then
				foundRecovered = true
				break
			end
		end
		assertTrue(foundRecovered, "Expected LocalDecl 'recovered' immediately following malformed assignment")

		local rRepeatedBad = Parser.parse({
			tok("Invalid", "?", 1, 1, nil, nil),
			tok("Invalid", "?", 2, 2, nil, nil),
			tok("Invalid", "?", 3, 3, nil, nil),
			tok("Keyword", "local", 5, 9, nil, nil),
			tok("Identifier", "ok", 11, 12, "ok", nil),
			tok("Symbol", "=", 14, 14, nil, nil),
			tok("Number", "7", 16, 16, 7, nil),
			eof(17),
		})
		local invalidDiagCount = 0
		for _, diag in ipairs(rRepeatedBad.diagnostics) do
			if diag.code == "PAR007" then
				invalidDiagCount += 1
			end
		end
		local foundOk = false
		for _, st in ipairs(rRepeatedBad.ast.body.statements) do
			if st.kind == "LocalDecl" and (st :: any).bindings[1].name.name == "ok" then
				foundOk = true
				break
			end
		end
		assertTrue(invalidDiagCount == 3 and foundOk, "Expected 3 PAR007 diagnostics for '? ? ?' and recovery to 'local ok = 7'")

		local rDeferredFor = Parser.parse({
			tok("Keyword", "for", 1, 3, nil, nil),
			tok("Identifier", "i", 5, 5, "i", nil),
			tok("Symbol", "=", 7, 7, nil, nil),
			tok("Number", "1", 9, 9, 1, nil),
			tok("Keyword", "local", 11, 15, nil, nil),
			tok("Identifier", "afterFor", 17, 24, "afterFor", nil),
			tok("Symbol", "=", 26, 26, nil, nil),
			tok("Number", "8", 28, 28, 8, nil),
			eof(29),
		})
		local foundDeferredDiag = false
		for _, diag in ipairs(rDeferredFor.diagnostics) do
			if diag.code == "PAR009" then
				foundDeferredDiag = true
				break
			end
		end
		local foundAfterFor = false
		for _, st in ipairs(rDeferredFor.ast.body.statements) do
			if st.kind == "LocalDecl" and (st :: any).bindings[1].name.name == "afterFor" then
				foundAfterFor = true
				break
			end
		end
		assertTrue(foundDeferredDiag and foundAfterFor, "Expected PAR009 for unimplemented 'for' starter and recovery to 'local afterFor = 8'")

		local rConcatDeep = Parser.parse({
			tok("Keyword", "local", 1, 5, nil, nil),
			tok("Identifier", "s", 7, 7, "s", nil),
			tok("Symbol", "=", 9, 9, nil, nil),
			tok("Identifier", "a", 11, 11, "a", nil),
			tok("Symbol", "..", 13, 14, nil, nil),
			tok("Identifier", "b", 16, 16, "b", nil),
			tok("Symbol", "..", 18, 19, nil, nil),
			tok("Identifier", "c", 21, 21, "c", nil),
			tok("Symbol", "..", 23, 24, nil, nil),
			tok("Identifier", "d", 26, 26, "d", nil),
			tok("Keyword", "local", 28, 32, nil, nil),
			tok("Identifier", "afterConcat", 34, 44, "afterConcat", nil),
			tok("Symbol", "=", 46, 46, nil, nil),
			tok("Number", "42", 48, 49, 42, nil),
			eof(50),
		}, { maxDepth = 2 })
		local hitConcatDepth = false
		for _, diag in ipairs(rConcatDeep.diagnostics) do
			if diag.code == "PAR002" then
				hitConcatDepth = true
				break
			end
		end
		local foundAfterConcat = false
		for _, st in ipairs(rConcatDeep.ast.body.statements) do
			if st.kind == "LocalDecl" and (st :: any).bindings[1].name.name == "afterConcat" then
				foundAfterConcat = true
				break
			end
		end
		assertTrue(
			hitConcatDepth and foundAfterConcat,
			"Expected PAR002 on concatenation depth overflow and recovery to 'local afterConcat = 42'"
		)

		local rExpDeep = Parser.parse({
			tok("Keyword", "local", 1, 5, nil, nil),
			tok("Identifier", "e", 7, 7, "e", nil),
			tok("Symbol", "=", 9, 9, nil, nil),
			tok("Identifier", "a", 11, 11, "a", nil),
			tok("Symbol", "^", 13, 13, nil, nil),
			tok("Identifier", "b", 15, 15, "b", nil),
			tok("Symbol", "^", 17, 17, nil, nil),
			tok("Identifier", "c", 19, 19, "c", nil),
			tok("Keyword", "local", 21, 25, nil, nil),
			tok("Identifier", "afterExp", 27, 34, "afterExp", nil),
			tok("Symbol", "=", 36, 36, nil, nil),
			tok("Number", "11", 38, 39, 11, nil),
			eof(40),
		}, { maxDepth = 1 })
		local hitExpDepth = false
		for _, diag in ipairs(rExpDeep.diagnostics) do
			if diag.code == "PAR002" then
				hitExpDepth = true
				break
			end
		end
		local foundAfterExp = false
		for _, st in ipairs(rExpDeep.ast.body.statements) do
			if st.kind == "LocalDecl" and (st :: any).bindings[1].name.name == "afterExp" then
				foundAfterExp = true
				break
			end
		end
		assertTrue(
			hitExpDepth and foundAfterExp,
			"Expected PAR002 on exponent depth overflow and recovery to 'local afterExp = 11'"
		)

		local rUnaryDeep = Parser.parse({
			tok("Keyword", "local", 1, 5, nil, nil),
			tok("Identifier", "u", 7, 7, "u", nil),
			tok("Symbol", "=", 9, 9, nil, nil),
			tok("Symbol", "-", 11, 11, nil, nil),
			tok("Symbol", "-", 12, 12, nil, nil),
			tok("Number", "5", 13, 13, 5, nil),
			tok("Keyword", "local", 15, 19, nil, nil),
			tok("Identifier", "afterUnary", 21, 30, "afterUnary", nil),
			tok("Symbol", "=", 32, 32, nil, nil),
			tok("Number", "12", 34, 35, 12, nil),
			eof(36),
		}, { maxDepth = 1 })
		local hitUnaryDepth = false
		for _, diag in ipairs(rUnaryDeep.diagnostics) do
			if diag.code == "PAR002" then
				hitUnaryDepth = true
				break
			end
		end
		local foundAfterUnary = false
		for _, st in ipairs(rUnaryDeep.ast.body.statements) do
			if st.kind == "LocalDecl" and (st :: any).bindings[1].name.name == "afterUnary" then
				foundAfterUnary = true
				break
			end
		end
		assertTrue(
			hitUnaryDepth and foundAfterUnary,
			"Expected PAR002 on unary depth overflow and recovery to 'local afterUnary = 12'"
		)

		-- Entry point A: synchronize starts before a nested `while ... do` inside an outer `do`
		-- (`do <malformed> while true do local x = 1 end end local afterWhileBefore = 51`)
		local rSyncBeforeWhile = Parser.parse({
			tok("Keyword", "do", 1, 2, nil, nil),
			tok("Number", "1", 4, 4, 1, nil), -- malformed statement triggers synchronize before `while`
			tok("Keyword", "while", 6, 10, nil, nil),
			tok("Keyword", "true", 12, 15, true, nil),
			tok("Keyword", "do", 17, 18, nil, nil),
			tok("Keyword", "local", 20, 24, nil, nil),
			tok("Identifier", "x", 26, 26, "x", nil),
			tok("Symbol", "=", 28, 28, nil, nil),
			tok("Number", "1", 30, 30, 1, nil),
			tok("Keyword", "end", 32, 34, nil, nil), -- inner `end` consumed as nested while's closer
			tok("Keyword", "end", 36, 38, nil, nil), -- enclosing `end` preserved for outer `do`
			tok("Keyword", "local", 40, 44, nil, nil),
			tok("Identifier", "afterWhileBefore", 46, 61, "afterWhileBefore", nil),
			tok("Symbol", "=", 63, 63, nil, nil),
			tok("Number", "51", 65, 66, 51, nil),
			eof(67),
		})
		local unexpectedCloserCountBefore = 0
		for _, diag in ipairs(rSyncBeforeWhile.diagnostics) do
			if diag.message == "Unexpected block delimiter 'end'." then
				unexpectedCloserCountBefore += 1
			end
		end
		local outerDoBefore = rSyncBeforeWhile.ast.body.statements[1] :: any
		local foundAfterWhileBefore = false
		for _, st in ipairs(rSyncBeforeWhile.ast.body.statements) do
			if st.kind == "LocalDecl" and (st :: any).bindings[1].name.name == "afterWhileBefore" then
				foundAfterWhileBefore = true
				break
			end
		end
		assertTrue(
			outerDoBefore ~= nil
				and outerDoBefore.kind == "DoStmt"
				and unexpectedCloserCountBefore == 0
				and foundAfterWhileBefore,
			"Expected synchronize before nested while to consume inner end, preserve enclosing end, and recover 'afterWhileBefore = 51'"
		)

		-- Entry point B: synchronize starts after `while` has already been consumed (`maxDepth = 1`
		-- enters `while`, consumes `while`, then synchronizes across `true do ... end` while outer `do` owns outer `end`)
		local rSyncAfterWhile = Parser.parse({
			tok("Keyword", "do", 1, 2, nil, nil),
			tok("Keyword", "while", 4, 8, nil, nil),
			tok("Keyword", "true", 10, 13, true, nil),
			tok("Keyword", "do", 15, 16, nil, nil),
			tok("Keyword", "local", 18, 22, nil, nil),
			tok("Identifier", "y", 24, 24, "y", nil),
			tok("Symbol", "=", 26, 26, nil, nil),
			tok("Number", "2", 28, 28, 2, nil),
			tok("Keyword", "end", 30, 32, nil, nil), -- inner `end` consumed as nested while's closer
			tok("Keyword", "end", 34, 36, nil, nil), -- enclosing `end` preserved for outer `do`
			tok("Keyword", "local", 38, 42, nil, nil),
			tok("Identifier", "afterWhileAfter", 44, 58, "afterWhileAfter", nil),
			tok("Symbol", "=", 60, 60, nil, nil),
			tok("Number", "52", 62, 63, 52, nil),
			eof(64),
		}, { maxDepth = 1 })
		local unexpectedCloserCountAfter = 0
		for _, diag in ipairs(rSyncAfterWhile.diagnostics) do
			if diag.message == "Unexpected block delimiter 'end'." then
				unexpectedCloserCountAfter += 1
			end
		end
		local outerDoAfter = rSyncAfterWhile.ast.body.statements[1] :: any
		local foundAfterWhileAfter = false
		for _, st in ipairs(rSyncAfterWhile.ast.body.statements) do
			if st.kind == "LocalDecl" and (st :: any).bindings[1].name.name == "afterWhileAfter" then
				foundAfterWhileAfter = true
				break
			end
		end
		assertTrue(
			outerDoAfter ~= nil
				and outerDoAfter.kind == "DoStmt"
				and unexpectedCloserCountAfter == 0
				and foundAfterWhileAfter,
			"Expected synchronize after consumed while to consume inner end, preserve enclosing end, and recover 'afterWhileAfter = 52'"
		)

		-- Retained nested `repeat` and `do` overflow tests
		local rNestedDoWhileRepeat = Parser.parse({
			tok("Keyword", "do", 1, 2, nil, nil),
			tok("Keyword", "while", 4, 8, nil, nil),
			tok("Keyword", "true", 10, 13, true, nil),
			tok("Keyword", "do", 15, 16, nil, nil),
			tok("Keyword", "repeat", 18, 23, nil, nil),
			tok("Keyword", "until", 25, 29, nil, nil),
			tok("Keyword", "true", 31, 34, true, nil),
			tok("Keyword", "end", 36, 38, nil, nil),
			tok("Keyword", "end", 40, 42, nil, nil),
			tok("Keyword", "local", 44, 48, nil, nil),
			tok("Identifier", "afterNested", 50, 60, "afterNested", nil),
			tok("Symbol", "=", 62, 62, nil, nil),
			tok("Number", "99", 64, 65, 99, nil),
			eof(66),
		}, { maxDepth = 1 })
		local hitNestedBlockDepth = false
		for _, diag in ipairs(rNestedDoWhileRepeat.diagnostics) do
			if diag.code == "PAR002" then
				hitNestedBlockDepth = true
				break
			end
		end
		local outerDo = rNestedDoWhileRepeat.ast.body.statements[1] :: any
		local foundAfterNested = false
		for _, st in ipairs(rNestedDoWhileRepeat.ast.body.statements) do
			if st.kind == "LocalDecl" and (st :: any).bindings[1].name.name == "afterNested" then
				foundAfterNested = true
				break
			end
		end
		assertTrue(
			hitNestedBlockDepth
				and outerDo ~= nil
				and outerDo.kind == "DoStmt"
				and foundAfterNested,
			"Expected PAR002 on nested while/repeat depth overflow, preserved outer DoStmt, and recovery to 'local afterNested = 99'"
		)

		local rNestedRepeatUntil = Parser.parse({
			tok("Keyword", "do", 1, 2, nil, nil),
			tok("Keyword", "repeat", 4, 9, nil, nil),
			tok("Keyword", "do", 11, 12, nil, nil),
			tok("Keyword", "end", 14, 16, nil, nil),
			tok("Keyword", "until", 18, 22, nil, nil),
			tok("Keyword", "false", 24, 28, false, nil),
			tok("Keyword", "end", 30, 32, nil, nil),
			tok("Keyword", "local", 34, 38, nil, nil),
			tok("Identifier", "afterRepeat", 40, 50, "afterRepeat", nil),
			tok("Symbol", "=", 52, 52, nil, nil),
			tok("Number", "77", 54, 55, 77, nil),
			eof(56),
		}, { maxDepth = 1 })
		local hitRepeatDepth = false
		for _, diag in ipairs(rNestedRepeatUntil.diagnostics) do
			if diag.code == "PAR002" then
				hitRepeatDepth = true
				break
			end
		end
		local outerDo2 = rNestedRepeatUntil.ast.body.statements[1] :: any
		local foundAfterRepeat = false
		for _, st in ipairs(rNestedRepeatUntil.ast.body.statements) do
			if st.kind == "LocalDecl" and (st :: any).bindings[1].name.name == "afterRepeat" then
				foundAfterRepeat = true
				break
			end
		end
		assertTrue(
			hitRepeatDepth
				and outerDo2 ~= nil
				and outerDo2.kind == "DoStmt"
				and foundAfterRepeat,
			"Expected PAR002 on nested repeat depth overflow, preserved outer DoStmt, and recovery to 'local afterRepeat = 77'"
		)

		local rMissingNestedEnd = Parser.parse({
			tok("Keyword", "do", 1, 2, nil, nil),
			tok("Keyword", "do", 4, 5, nil, nil),
			tok("Keyword", "local", 7, 11, nil, nil),
			tok("Identifier", "inner", 13, 17, "inner", nil),
			tok("Symbol", "=", 19, 19, nil, nil),
			tok("Number", "1", 21, 21, 1, nil),
			tok("Keyword", "end", 23, 25, nil, nil),
			tok("Keyword", "local", 27, 31, nil, nil),
			tok("Identifier", "outerAfter", 33, 42, "outerAfter", nil),
			tok("Symbol", "=", 44, 44, nil, nil),
			tok("Number", "2", 46, 46, 2, nil),
			eof(47),
		})
		assertTrue(#rMissingNestedEnd.diagnostics >= 1, "Expected diagnostic for missing nested 'end'")

		for _, closerLex in ipairs({ "else", "elseif", "until", "end" }) do
			local rCloser = Parser.parse({
				tok("Keyword", closerLex, 1, #closerLex, nil, nil),
				eof(#closerLex + 1),
			})
			assertTrue(#rCloser.diagnostics >= 1, "Expected diagnostic for unexpected closer: " .. closerLex)
		end

		local rEmpty = Parser.parse({})
		assertTrue(
			rEmpty.ast.kind == "Chunk"
				and #rEmpty.ast.body.statements == 0
				and #rEmpty.diagnostics == 0,
			"Expected empty token input to yield empty Chunk with 0 diagnostics"
		)

		local rNoEof = Parser.parse({
			tok("Keyword", "local", 1, 5, nil, nil),
			tok("Identifier", "a", 7, 7, "a", nil),
		})
		local noEofStmt = rNoEof.ast.body.statements[1] :: any
		assertTrue(
			#rNoEof.diagnostics == 0
				and noEofStmt.kind == "LocalDecl"
				and noEofStmt.bindings[1].name.name == "a",
			"Expected input without explicit EOF token to parse cleanly"
		)

		results["recovery_immediate_invalid_tokens_depth_and_closers"] = true
	end

	return results
end

return ParserTests
