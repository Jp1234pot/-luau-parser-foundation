--!strict

export type Position = {
	line: number,
	column: number,
	offset: number,
}

export type Span = {
	start: Position,
	["end"]: Position,
}

export type StringDelimiter =
	| "SingleQuote"
	| "DoubleQuote"
	| "LongBracket"
	| "Backtick"

export type TriviaKind =
	| "Whitespace"
	| "SingleLineComment"
	| "MultiLineComment"

export type Trivia = {
	kind: TriviaKind,
	lexeme: string,
	span: Span,
}

export type TokenKind =
	| "Eof"
	| "Identifier"
	| "Number"
	| "String"
	| "InterpStart"
	| "InterpMid"
	| "InterpEnd"
	| "Keyword"
	| "Symbol"
	| "Invalid"

export type Token = {
	kind: TokenKind,
	lexeme: string,
	value: (string | number | boolean)?,
	delimiter: StringDelimiter?,
	span: Span,
	leadingTrivia: { Trivia }?,
}

export type DiagnosticSeverity = "Error" | "Warning" | "Info"

export type Diagnostic = {
	code: string,
	severity: DiagnosticSeverity,
	stage: "Parser",
	message: string,
	span: Span,
}

export type ParserConfig = {
	maxDepth: number?,
	allowConst: boolean?,
	allowIfExpr: boolean?,
	allowTypeFunctions: boolean?,
}

-- AST node definitions

export type IdentNode = {
	kind: "Identifier",
	name: string,
	span: Span,
}

export type LiteralNode =
	| { kind: "NilLiteral", span: Span }
	| { kind: "BooleanLiteral", value: boolean, span: Span }
	| { kind: "NumberLiteral", value: number, raw: string, span: Span }
	| { kind: "StringLiteral", value: string?, raw: string, delimiter: StringDelimiter, span: Span }
	| { kind: "LiteralTable", entries: { LiteralTableEntry }, raw: string, span: Span }

export type LiteralTableEntry =
	| { kind: "FieldEntry", key: IdentNode | LiteralNode, value: LiteralNode, span: Span }
	| { kind: "ArrayEntry", value: LiteralNode, span: Span }

export type AttributeNode = {
	kind: "Attribute",
	name: string,
	arguments: { LiteralNode }?,
	rawSyntax: string,
	span: Span,
}

export type AttributeGroupNode = {
	kind: "AttributeGroup",
	attributes: { AttributeNode },
	rawSyntax: string,
	span: Span,
}

export type TypeNode =
	| { kind: "TypeReference", name: string, span: Span }
	| { kind: "TypeOptional", inner: TypeNode, span: Span }
	| { kind: "TypeUnion", types: { TypeNode }, span: Span }
	| { kind: "TypeIntersection", types: { TypeNode }, span: Span }
	| { kind: "TypeError", span: Span }

export type BindingNode = {
	kind: "Binding",
	name: IdentNode,
	typeAnnotation: TypeNode?,
	span: Span,
}

export type ExprNode =
	| { kind: "NilLiteral", span: Span }
	| { kind: "BooleanLiteral", value: boolean, span: Span }
	| { kind: "NumberLiteral", value: number, raw: string, span: Span }
	| { kind: "StringLiteral", value: string?, raw: string, delimiter: StringDelimiter, span: Span }
	| { kind: "VarargLiteral", span: Span }
	| { kind: "IdentifierExpr", name: string, span: Span }
	| { kind: "UnaryExpr", operator: "not" | "#" | "-", operand: ExprNode, span: Span }
	| { kind: "BinaryExpr", operator: string, left: ExprNode, right: ExprNode, span: Span }
	| { kind: "GroupedExpr", inner: ExprNode, span: Span }
	| { kind: "ErrorExpr", rawLexemes: { string }, span: Span }

export type StmtNode =
	| { kind: "LocalDecl", bindings: { BindingNode }, values: { ExprNode }, span: Span }
	| { kind: "Assignment", targets: { ExprNode }, values: { ExprNode }, span: Span }
	| { kind: "CompoundAssignment", operator: string, target: ExprNode, value: ExprNode, span: Span }
	| { kind: "ReturnStmt", values: { ExprNode }, span: Span }
	| { kind: "BreakStmt", span: Span }
	| { kind: "ContinueStmt", span: Span }
	| { kind: "DoStmt", body: BlockNode, span: Span }
	| { kind: "WhileStmt", condition: ExprNode, body: BlockNode, span: Span }
	| { kind: "RepeatStmt", body: BlockNode, condition: ExprNode, span: Span }
	| { kind: "ErrorStmt", span: Span }

export type BlockNode = {
	kind: "Block",
	statements: { StmtNode },
	terminatedByControlFlow: boolean,
	span: Span,
}

export type ChunkNode = {
	kind: "Chunk",
	body: BlockNode,
	span: Span,
}

export type ParseResult = {
	ast: ChunkNode,
	tokens: { Token },
	trivia: { Trivia }?,
	diagnostics: { Diagnostic },
}

local Parser = {}

local COMPOUND_OPS: { [string]: boolean } = {
	["+="] = true,
	["-="] = true,
	["*="] = true,
	["/="] = true,
	["//="] = true,
	["%="] = true,
	["^="] = true,
	["..="] = true,
}

local RELATIONAL_OPS: { [string]: boolean } = {
	["<"] = true,
	[">"] = true,
	["<="] = true,
	[">="] = true,
	["~="] = true,
	["=="] = true,
}

local ADDITIVE_OPS: { [string]: boolean } = {
	["+"] = true,
	["-"] = true,
}

local MULTIPLICATIVE_OPS: { [string]: boolean } = {
	["*"] = true,
	["/"] = true,
	["//"] = true,
	["%"] = true,
}

local BLOCK_CLOSERS: { [string]: boolean } = {
	["end"] = true,
	["else"] = true,
	["elseif"] = true,
	["until"] = true,
}

-- Statement starters recognized as recovery boundaries; `if`, `for`, and `function`
-- are not implemented as statement parsers in this foundation stage.
local STATEMENT_STARTERS: { [string]: boolean } = {
	["local"] = true,
	["if"] = true,
	["while"] = true,
	["repeat"] = true,
	["for"] = true,
	["function"] = true,
	["return"] = true,
	["break"] = true,
	["do"] = true,
}

local DEFERRED_STATEMENT_STARTERS: { [string]: boolean } = {
	["if"] = true,
	["for"] = true,
	["function"] = true,
}

local DEFAULT_EOF_SPAN: Span = {
	start = { line = 1, column = 1, offset = 1 },
	["end"] = { line = 1, column = 1, offset = 1 },
}

local function mergeSpan(startSpan: Span, endSpan: Span): Span
	return {
		start = startSpan.start,
		["end"] = endSpan["end"],
	}
end

local function addDiagnostic(
	diagnostics: { Diagnostic },
	code: string,
	severity: DiagnosticSeverity,
	message: string,
	span: Span
): ()
	table.insert(diagnostics, {
		code = code,
		severity = severity,
		stage = "Parser",
		message = message,
		span = span,
	})
end

function Parser.parse(
	tokens: { Token },
	config: ParserConfig?,
	diagnosticsSink: { Diagnostic }?,
	trivia: { Trivia }?
): ParseResult
	local diagnostics: { Diagnostic } = diagnosticsSink or {}
	local maxDepth = if config and config.maxDepth then math.max(1, config.maxDepth) else 128

	local fallbackSpan: Span = DEFAULT_EOF_SPAN
	if #tokens > 0 then
		local last = tokens[#tokens]
		fallbackSpan = {
			start = last.span["end"],
			["end"] = last.span["end"],
		}
	end

	local syntheticEof: Token = {
		kind = "Eof",
		lexeme = "",
		value = nil,
		delimiter = nil,
		span = fallbackSpan,
		leadingTrivia = nil,
	}

	local cursor = 1
	local depth = 0

	local function peek(offset: number?): Token
		if #tokens == 0 then
			return syntheticEof
		end
		local idx = cursor + (offset or 0)
		if idx < 1 then
			return tokens[1]
		end
		if idx > #tokens then
			return syntheticEof
		end
		return tokens[idx]
	end

	local function advance(): Token
		local tok = peek(0)
		if tok.kind ~= "Eof" and cursor <= #tokens then
			cursor += 1
		end
		return tok
	end

	local function consumeInvalidToken(tok: Token): ()
		addDiagnostic(
			diagnostics,
			"PAR007",
			"Error",
			string.format("Unexpected invalid token '%s'.", tok.lexeme),
			tok.span
		)
		advance()
	end

	local function isAtEnd(): boolean
		return peek(0).kind == "Eof"
	end

	local function matchSymbol(lexeme: string): Token?
		local t = peek(0)
		if t.kind == "Symbol" and t.lexeme == lexeme then
			return advance()
		end
		return nil
	end

	local function matchKeyword(word: string): Token?
		local t = peek(0)
		if t.kind == "Keyword" and t.lexeme == word then
			return advance()
		end
		return nil
	end

	local function expectIdentifier(contextMsg: string): IdentNode?
		local t = peek(0)
		if t.kind == "Identifier" then
			advance()
			return {
				kind = "Identifier",
				name = t.lexeme,
				span = t.span,
			}
		end
		addDiagnostic(
			diagnostics,
			"PAR001",
			"Error",
			string.format("Expected identifier %s, got '%s'.", contextMsg, t.lexeme),
			t.span
		)
		return nil
	end

	local function enterDepth(span: Span): boolean
		depth += 1
		if depth > maxDepth then
			depth -= 1
			addDiagnostic(
				diagnostics,
				"PAR002",
				"Error",
				string.format("Maximum parser nesting depth (%d) exceeded.", maxDepth),
				span
			)
			return false
		end
		return true
	end

	local function exitDepth(): ()
		if depth > 0 then
			depth -= 1
		end
	end

	local function validateAssignmentTarget(target: ExprNode): boolean
		if target.kind == "IdentifierExpr" then
			return true
		end
		addDiagnostic(
			diagnostics,
			"PAR008",
			"Error",
			string.format("Invalid assignment target of kind '%s'; expected identifier.", target.kind),
			target.span
		)
		return false
	end

	-- Block recovery

	-- Iteratively tracks nested `do` / `while ... do` (`end`) and `repeat` (`until`) blocks so a
	-- `while` header and its required `do` contribute a single `end`-terminated block, skipping inner
	-- closers while preserving enclosing block delimiters.
	local function synchronize(stopSet: { [string]: boolean }?): number
		local startCursor = cursor
		local parenBalance = 0
		local bracketBalance = 0
		local braceBalance = 0
		local endBlockDepth = 0
		local untilBlockDepth = 0
		local pendingWhileHeader = false

		while not isAtEnd() do
			local tok = peek(0)
			local lex = tok.lexeme

			if tok.kind == "Symbol" then
				if lex == "(" then
					parenBalance += 1
				elseif lex == ")" and parenBalance > 0 then
					parenBalance -= 1
				elseif lex == "[" then
					bracketBalance += 1
				elseif lex == "]" and bracketBalance > 0 then
					bracketBalance -= 1
				elseif lex == "{" then
					braceBalance += 1
				elseif lex == "}" and braceBalance > 0 then
					braceBalance -= 1
				elseif lex == ";" and parenBalance == 0 and bracketBalance == 0 and braceBalance == 0 then
					advance()
					return cursor - startCursor
				end
			end

			if parenBalance == 0 and bracketBalance == 0 and braceBalance == 0 and tok.kind == "Keyword" then
				if lex == "while" then
					endBlockDepth += 1
					pendingWhileHeader = true
				elseif lex == "do" then
					if pendingWhileHeader then
						pendingWhileHeader = false
					else
						endBlockDepth += 1
					end
				elseif lex == "repeat" then
					untilBlockDepth += 1
				elseif lex == "end" then
					if endBlockDepth > 0 then
						endBlockDepth -= 1
						if endBlockDepth == 0 then
							pendingWhileHeader = false
							advance()
							continue
						end
					else
						return cursor - startCursor
					end
				elseif lex == "until" then
					if untilBlockDepth > 0 then
						untilBlockDepth -= 1
					else
						return cursor - startCursor
					end
				elseif (lex == "else" or lex == "elseif") and endBlockDepth == 0 and untilBlockDepth == 0 then
					return cursor - startCursor
				elseif STATEMENT_STARTERS[lex] and endBlockDepth == 0 and untilBlockDepth == 0 then
					return cursor - startCursor
				end
			end

			if parenBalance == 0 and bracketBalance == 0 and braceBalance == 0 and endBlockDepth == 0 and untilBlockDepth == 0 then
				if stopSet and stopSet[lex] and cursor > startCursor then
					return cursor - startCursor
				end
			end

			if tok.kind == "Invalid" then
				consumeInvalidToken(tok)
			else
				advance()
			end
		end

		return cursor - startCursor
	end

	local parseBlock: (stopWords: { [string]: boolean }?) -> BlockNode
	local parseExpression: () -> ExprNode
	local parsePrecOr: () -> ExprNode
	local parsePrecAnd: () -> ExprNode
	local parsePrecRelational: () -> ExprNode
	local parsePrecConcat: () -> ExprNode
	local parsePrecAdditive: () -> ExprNode
	local parsePrecMultiplicative: () -> ExprNode
	local parsePrecUnary: () -> ExprNode
	local parsePrecExponent: () -> ExprNode
	local parsePrimary: () -> ExprNode

	-- Type annotations

	local function parseTypeAtom(): TypeNode
		local t = peek(0)
		if t.kind == "Identifier" then
			advance()
			return {
				kind = "TypeReference",
				name = t.lexeme,
				span = t.span,
			}
		end
		addDiagnostic(diagnostics, "PAR003", "Error", string.format("Expected type name, got '%s'.", t.lexeme), t.span)
		return { kind = "TypeError", span = t.span }
	end

	local function parseTypePostfix(): TypeNode
		local node = parseTypeAtom()
		while matchSymbol("?") ~= nil do
			local qTok = peek(-1)
			node = {
				kind = "TypeOptional",
				inner = node,
				span = mergeSpan(node.span, qTok.span),
			}
		end
		return node
	end

	local function parseTypeIntersection(): TypeNode
		local first = parseTypePostfix()
		if peek(0).kind ~= "Symbol" or peek(0).lexeme ~= "&" then
			return first
		end
		local items: { TypeNode } = { first }
		while matchSymbol("&") ~= nil do
			table.insert(items, parseTypePostfix())
		end
		return {
			kind = "TypeIntersection",
			types = items,
			span = mergeSpan(first.span, items[#items].span),
		}
	end

	local function parseTypeUnion(): TypeNode
		local first = parseTypeIntersection()
		if peek(0).kind ~= "Symbol" or peek(0).lexeme ~= "|" then
			return first
		end
		local items: { TypeNode } = { first }
		while matchSymbol("|") ~= nil do
			table.insert(items, parseTypeIntersection())
		end
		return {
			kind = "TypeUnion",
			types = items,
			span = mergeSpan(first.span, items[#items].span),
		}
	end

	local function parseBinding(): BindingNode?
		local nameTok = peek(0)
		local ident = expectIdentifier("in variable binding")
		if not ident then
			return nil
		end
		local endSpan = nameTok.span
		local ann: TypeNode? = nil
		if matchSymbol(":") ~= nil then
			ann = parseTypeUnion()
			endSpan = ann.span
		end
		return {
			kind = "Binding",
			name = ident,
			typeAnnotation = ann,
			span = mergeSpan(nameTok.span, endSpan),
		}
	end

	-- Expression precedence

	-- Bounded non-recursive operand consumption on depth overflow so trailing tokens cannot leak
	-- as unrelated statements or expressions without recursing deeper into the precedence ladder.
	local function consumeOverflowOperand(fallbackSpan: Span): ExprNode
		local startTok = peek(0)
		if startTok.kind == "Eof" then
			return { kind = "ErrorExpr", rawLexemes = {}, span = fallbackSpan }
		end
		local raw: { string } = {}
		local lastSpan = fallbackSpan
		local parenBalance = 0
		local bracketBalance = 0
		local braceBalance = 0

		while not isAtEnd() do
			local tok = peek(0)
			local lex = tok.lexeme

			if tok.kind == "Symbol" then
				if lex == "(" then
					parenBalance += 1
				elseif lex == ")" then
					if parenBalance > 0 then
						parenBalance -= 1
					else
						break
					end
				elseif lex == "[" then
					bracketBalance += 1
				elseif lex == "]" then
					if bracketBalance > 0 then
						bracketBalance -= 1
					else
						break
					end
				elseif lex == "{" then
					braceBalance += 1
				elseif lex == "}" then
					if braceBalance > 0 then
						braceBalance -= 1
					else
						break
					end
				elseif lex == "," or lex == ";" then
					if parenBalance == 0 and bracketBalance == 0 and braceBalance == 0 then
						break
					end
				end
			elseif parenBalance == 0 and bracketBalance == 0 and braceBalance == 0 then
				if STATEMENT_STARTERS[lex] or BLOCK_CLOSERS[lex] then
					break
				end
			end

			table.insert(raw, lex)
			lastSpan = tok.span
			if tok.kind == "Invalid" then
				consumeInvalidToken(tok)
			else
				advance()
			end
		end

		return {
			kind = "ErrorExpr",
			rawLexemes = raw,
			span = mergeSpan(startTok.span, lastSpan),
		}
	end

	parsePrimary = function(): ExprNode
		local t = peek(0)

		if t.kind == "Keyword" and t.lexeme == "nil" then
			advance()
			return { kind = "NilLiteral", span = t.span }
		elseif t.kind == "Keyword" and (t.lexeme == "true" or t.lexeme == "false") then
			advance()
			return { kind = "BooleanLiteral", value = (t.lexeme == "true"), span = t.span }
		elseif t.kind == "Number" then
			advance()
			local numVal = if type(t.value) == "number" then t.value else (tonumber(t.lexeme) or 0)
			return { kind = "NumberLiteral", value = numVal, raw = t.lexeme, span = t.span }
		elseif t.kind == "String" then
			advance()
			local delim: StringDelimiter = t.delimiter or "DoubleQuote"
			local strVal = if type(t.value) == "string" then t.value else nil
			return { kind = "StringLiteral", value = strVal, raw = t.lexeme, delimiter = delim, span = t.span }
		elseif t.kind == "Symbol" and t.lexeme == "..." then
			advance()
			return { kind = "VarargLiteral", span = t.span }
		elseif t.kind == "Identifier" then
			advance()
			return { kind = "IdentifierExpr", name = t.lexeme, span = t.span }
		elseif t.kind == "Symbol" and t.lexeme == "(" then
			local openTok = advance()
			if not enterDepth(openTok.span) then
				local recoveredInner = consumeOverflowOperand(openTok.span)
				matchSymbol(")")
				return recoveredInner
			end
			local inner = parseExpression()
			local closeTok = matchSymbol(")")
			exitDepth()
			if not closeTok then
				addDiagnostic(diagnostics, "PAR001", "Error", "Expected ')' to close parenthesized expression.", peek(0).span)
				return {
					kind = "ErrorExpr",
					rawLexemes = { openTok.lexeme },
					span = mergeSpan(openTok.span, peek(0).span),
				}
			end
			return {
				kind = "GroupedExpr",
				inner = inner,
				span = mergeSpan(openTok.span, closeTok.span),
			}
		end

		if t.kind == "Keyword" and (STATEMENT_STARTERS[t.lexeme] or BLOCK_CLOSERS[t.lexeme]) then
			addDiagnostic(diagnostics, "PAR001", "Error", string.format("Expected expression before '%s'.", t.lexeme), t.span)
			return { kind = "ErrorExpr", rawLexemes = {}, span = t.span }
		end

		if t.kind == "Invalid" then
			consumeInvalidToken(t)
			return { kind = "ErrorExpr", rawLexemes = { t.lexeme }, span = t.span }
		end

		addDiagnostic(diagnostics, "PAR001", "Error", string.format("Unexpected token '%s' in expression.", t.lexeme), t.span)
		advance()
		return { kind = "ErrorExpr", rawLexemes = { t.lexeme }, span = t.span }
	end

	parsePrecExponent = function(): ExprNode
		local left = parsePrimary()
		if peek(0).kind == "Symbol" and peek(0).lexeme == "^" then
			local opTok = advance()
			if not enterDepth(opTok.span) then
				local overflowRight = consumeOverflowOperand(opTok.span)
				return {
					kind = "BinaryExpr",
					operator = "^",
					left = left,
					right = overflowRight,
					span = mergeSpan(left.span, overflowRight.span),
				}
			end
			local right = parsePrecUnary()
			exitDepth()
			return {
				kind = "BinaryExpr",
				operator = "^",
				left = left,
				right = right,
				span = mergeSpan(left.span, right.span),
			}
		end
		return left
	end

	parsePrecUnary = function(): ExprNode
		local t = peek(0)
		if (t.kind == "Keyword" and t.lexeme == "not")
			or (t.kind == "Symbol" and (t.lexeme == "#" or t.lexeme == "-"))
		then
			local opTok = advance()
			local opLex: "not" | "#" | "-" = if opTok.lexeme == "not"
				then "not"
				elseif opTok.kind == "Symbol" and opTok.lexeme == "#" then "#"
				else "-"
			if not enterDepth(opTok.span) then
				local overflowOperand = consumeOverflowOperand(opTok.span)
				return {
					kind = "UnaryExpr",
					operator = opLex,
					operand = overflowOperand,
					span = mergeSpan(opTok.span, overflowOperand.span),
				}
			end
			local operand = parsePrecUnary()
			exitDepth()
			return {
				kind = "UnaryExpr",
				operator = opLex,
				operand = operand,
				span = mergeSpan(opTok.span, operand.span),
			}
		end
		return parsePrecExponent()
	end

	parsePrecMultiplicative = function(): ExprNode
		local expr = parsePrecUnary()
		while peek(0).kind == "Symbol" and MULTIPLICATIVE_OPS[peek(0).lexeme] do
			local opTok = advance()
			local right = parsePrecUnary()
			expr = {
				kind = "BinaryExpr",
				operator = opTok.lexeme,
				left = expr,
				right = right,
				span = mergeSpan(expr.span, right.span),
			}
		end
		return expr
	end

	parsePrecAdditive = function(): ExprNode
		local expr = parsePrecMultiplicative()
		while peek(0).kind == "Symbol" and ADDITIVE_OPS[peek(0).lexeme] do
			local opTok = advance()
			local right = parsePrecMultiplicative()
			expr = {
				kind = "BinaryExpr",
				operator = opTok.lexeme,
				left = expr,
				right = right,
				span = mergeSpan(expr.span, right.span),
			}
		end
		return expr
	end

	parsePrecConcat = function(): ExprNode
		local left = parsePrecAdditive()
		if peek(0).kind == "Symbol" and peek(0).lexeme == ".." then
			local opTok = advance()
			if not enterDepth(opTok.span) then
				local overflowRight = consumeOverflowOperand(opTok.span)
				return {
					kind = "BinaryExpr",
					operator = "..",
					left = left,
					right = overflowRight,
					span = mergeSpan(left.span, overflowRight.span),
				}
			end
			local right = parsePrecConcat()
			exitDepth()
			return {
				kind = "BinaryExpr",
				operator = "..",
				left = left,
				right = right,
				span = mergeSpan(left.span, right.span),
			}
		end
		return left
	end

	parsePrecRelational = function(): ExprNode
		local expr = parsePrecConcat()
		while peek(0).kind == "Symbol" and RELATIONAL_OPS[peek(0).lexeme] do
			local opTok = advance()
			local right = parsePrecConcat()
			expr = {
				kind = "BinaryExpr",
				operator = opTok.lexeme,
				left = expr,
				right = right,
				span = mergeSpan(expr.span, right.span),
			}
		end
		return expr
	end

	parsePrecAnd = function(): ExprNode
		local expr = parsePrecRelational()
		while peek(0).kind == "Keyword" and peek(0).lexeme == "and" do
			advance()
			local right = parsePrecRelational()
			expr = {
				kind = "BinaryExpr",
				operator = "and",
				left = expr,
				right = right,
				span = mergeSpan(expr.span, right.span),
			}
		end
		return expr
	end

	parsePrecOr = function(): ExprNode
		local expr = parsePrecAnd()
		while peek(0).kind == "Keyword" and peek(0).lexeme == "or" do
			advance()
			local right = parsePrecAnd()
			expr = {
				kind = "BinaryExpr",
				operator = "or",
				left = expr,
				right = right,
				span = mergeSpan(expr.span, right.span),
			}
		end
		return expr
	end

	parseExpression = function(): ExprNode
		return parsePrecOr()
	end

	-- Statement parsing

	local function isStandaloneContinueStatement(): boolean
		local t = peek(0)
		if t.kind ~= "Identifier" or t.lexeme ~= "continue" then
			return false
		end
		local nxt = peek(1)
		if nxt.kind == "String" then
			return false
		end
		if nxt.kind == "Symbol" then
			local s = nxt.lexeme
			if s == "." or s == "[" or s == ":" or s == "{" or s == "(" or s == "=" or s == "," then
				return false
			end
			if COMPOUND_OPS[s] then
				return false
			end
		end
		return true
	end

	local function parseStatement(stopWords: { [string]: boolean }?): (StmtNode?, boolean)
		local t = peek(0)

		if t.kind == "Keyword" and BLOCK_CLOSERS[t.lexeme] then
			if stopWords and stopWords[t.lexeme] then
				return nil, false
			end
			local badCloser = advance()
			addDiagnostic(
				diagnostics,
				"PAR001",
				"Error",
				string.format("Unexpected block delimiter '%s'.", badCloser.lexeme),
				badCloser.span
			)
			return { kind = "ErrorStmt", span = badCloser.span }, false
		end

		-- Minimal deferred-starter handling: consumes only the starter keyword (`if`, `for`, `function`)
		-- and emits PAR009; subsequent tokens in the unsupported construct are not skipped.
		if t.kind == "Keyword" and DEFERRED_STATEMENT_STARTERS[t.lexeme] then
			local deferredTok = advance()
			addDiagnostic(
				diagnostics,
				"PAR009",
				"Error",
				string.format("Statement construct '%s' is not yet implemented in this parser stage.", deferredTok.lexeme),
				deferredTok.span
			)
			return { kind = "ErrorStmt", span = deferredTok.span }, false
		end

		if isStandaloneContinueStatement() then
			local contTok = advance()
			matchSymbol(";")
			return {
				kind = "ContinueStmt",
				span = contTok.span,
			}, true
		end

		if matchKeyword("break") ~= nil then
			local brkTok = peek(-1)
			matchSymbol(";")
			return {
				kind = "BreakStmt",
				span = brkTok.span,
			}, true
		end

		if matchKeyword("return") ~= nil then
			local retTok = peek(-1)
			local values: { ExprNode } = {}
			local endSpan = retTok.span
			local nextTok = peek(0)
			local canHaveExpr = not (
				nextTok.kind == "Eof"
				or (nextTok.kind == "Symbol" and nextTok.lexeme == ";")
				or (nextTok.kind == "Keyword" and BLOCK_CLOSERS[nextTok.lexeme])
			)
			if canHaveExpr then
				repeat
					local val = parseExpression()
					table.insert(values, val)
					endSpan = val.span
				until matchSymbol(",") == nil
			end
			matchSymbol(";")
			return {
				kind = "ReturnStmt",
				values = values,
				span = mergeSpan(retTok.span, endSpan),
			}, true
		end

		if matchKeyword("do") ~= nil then
			local doTok = peek(-1)
			if not enterDepth(doTok.span) then
				synchronize({ ["end"] = true })
				return { kind = "ErrorStmt", span = doTok.span }, false
			end
			local body = parseBlock({ ["end"] = true })
			local endTok = matchKeyword("end")
			exitDepth()
			if not endTok then
				addDiagnostic(diagnostics, "PAR001", "Error", "Expected 'end' to close 'do' block.", peek(0).span)
				return {
					kind = "DoStmt",
					body = body,
					span = mergeSpan(doTok.span, body.span),
				}, false
			end
			return {
				kind = "DoStmt",
				body = body,
				span = mergeSpan(doTok.span, endTok.span),
			}, false
		end

		if matchKeyword("while") ~= nil then
			local whileTok = peek(-1)
			if not enterDepth(whileTok.span) then
				synchronize({ ["end"] = true })
				return { kind = "ErrorStmt", span = whileTok.span }, false
			end
			local cond = parseExpression()
			if matchKeyword("do") == nil then
				addDiagnostic(diagnostics, "PAR001", "Error", "Expected 'do' after 'while' condition.", peek(0).span)
			end
			local body = parseBlock({ ["end"] = true })
			local endTok = matchKeyword("end")
			exitDepth()
			if not endTok then
				addDiagnostic(diagnostics, "PAR001", "Error", "Expected 'end' to close 'while' loop.", peek(0).span)
			end
			local lastSpan = if endTok then endTok.span else body.span
			return {
				kind = "WhileStmt",
				condition = cond,
				body = body,
				span = mergeSpan(whileTok.span, lastSpan),
			}, false
		end

		if matchKeyword("repeat") ~= nil then
			local repTok = peek(-1)
			if not enterDepth(repTok.span) then
				synchronize({ ["until"] = true })
				return { kind = "ErrorStmt", span = repTok.span }, false
			end
			local body = parseBlock({ ["until"] = true })
			local untilTok = matchKeyword("until")
			if not untilTok then
				addDiagnostic(diagnostics, "PAR001", "Error", "Expected 'until' to close 'repeat' loop.", peek(0).span)
				exitDepth()
				return {
					kind = "RepeatStmt",
					body = body,
					condition = { kind = "ErrorExpr", rawLexemes = {}, span = peek(0).span },
					span = mergeSpan(repTok.span, body.span),
				}, false
			end
			local cond = parseExpression()
			exitDepth()
			return {
				kind = "RepeatStmt",
				body = body,
				condition = cond,
				span = mergeSpan(repTok.span, cond.span),
			}, false
		end

		if matchKeyword("local") ~= nil then
			local localTok = peek(-1)
			local bindings: { BindingNode } = {}
			repeat
				local b = parseBinding()
				if not b then
					synchronize()
					return { kind = "ErrorStmt", span = mergeSpan(localTok.span, peek(0).span) }, false
				end
				table.insert(bindings, b)
			until matchSymbol(",") == nil

			local values: { ExprNode } = {}
			local endSpan = bindings[#bindings].span
			if matchSymbol("=") ~= nil then
				repeat
					local v = parseExpression()
					table.insert(values, v)
					endSpan = v.span
				until matchSymbol(",") == nil
			end
			matchSymbol(";")
			return {
				kind = "LocalDecl",
				bindings = bindings,
				values = values,
				span = mergeSpan(localTok.span, endSpan),
			}, false
		end

		local firstTarget = parsePrimary()
		local allTargetsValid = validateAssignmentTarget(firstTarget)

		if peek(0).kind == "Symbol" and COMPOUND_OPS[peek(0).lexeme] then
			local opTok = advance()
			local rhs = parseExpression()
			matchSymbol(";")
			if not allTargetsValid then
				synchronize(stopWords)
				return { kind = "ErrorStmt", span = mergeSpan(firstTarget.span, rhs.span) }, false
			end
			return {
				kind = "CompoundAssignment",
				operator = opTok.lexeme,
				target = firstTarget,
				value = rhs,
				span = mergeSpan(firstTarget.span, rhs.span),
			}, false
		end

		local targets: { ExprNode } = { firstTarget }
		while matchSymbol(",") ~= nil do
			local nextTarget = parsePrimary()
			if not validateAssignmentTarget(nextTarget) then
				allTargetsValid = false
			end
			table.insert(targets, nextTarget)
		end

		if matchSymbol("=") ~= nil then
			local values: { ExprNode } = {}
			repeat
				table.insert(values, parseExpression())
			until matchSymbol(",") == nil
			matchSymbol(";")
			if not allTargetsValid then
				return { kind = "ErrorStmt", span = mergeSpan(firstTarget.span, values[#values].span) }, false
			end
			return {
				kind = "Assignment",
				targets = targets,
				values = values,
				span = mergeSpan(firstTarget.span, values[#values].span),
			}, false
		end

		addDiagnostic(
			diagnostics,
			"PAR001",
			"Error",
			string.format("Expected '=' in assignment, got '%s'.", peek(0).lexeme),
			peek(0).span
		)
		synchronize(stopWords)
		return { kind = "ErrorStmt", span = mergeSpan(firstTarget.span, peek(0).span) }, false
	end

	parseBlock = function(stopWords: { [string]: boolean }?): BlockNode
		local startTok = peek(0)
		local statements: { StmtNode } = {}
		local terminated = false
		local lastSpan = startTok.span

		while not isAtEnd() do
			local cur = peek(0)
			if stopWords and stopWords[cur.lexeme] then
				break
			end
			if stopWords ~= nil and BLOCK_CLOSERS[cur.lexeme] then
				break
			end

			local beforeCursor = cursor
			local stmt, isTerminator = parseStatement(stopWords)
			if stmt then
				table.insert(statements, stmt)
				lastSpan = stmt.span
			end

			if isTerminator then
				terminated = true
				while not isAtEnd() do
					local after = peek(0)
					if stopWords and stopWords[after.lexeme] then
						break
					end
					if stopWords ~= nil and BLOCK_CLOSERS[after.lexeme] then
						break
					end
					if after.kind == "Symbol" and after.lexeme == ";" then
						advance()
						continue
					end
					addDiagnostic(
						diagnostics,
						"PAR006",
						"Warning",
						"Unreachable statement after block-terminating statement.",
						after.span
					)
					local innerBefore = cursor
					local skippedStmt = parseStatement(stopWords)
					if skippedStmt then
						lastSpan = skippedStmt.span
					end
					if cursor <= innerBefore and not isAtEnd() then
						local stuckAfter = peek(0)
						if not (stuckAfter.kind == "Keyword" and BLOCK_CLOSERS[stuckAfter.lexeme]) then
							if stuckAfter.kind == "Invalid" then
								consumeInvalidToken(stuckAfter)
							else
								advance()
							end
						else
							break
						end
					end
				end
				break
			end

			if cursor <= beforeCursor and not isAtEnd() then
				local afterTok = peek(0)
				if stopWords and stopWords[afterTok.lexeme] then
					break
				end
				if stopWords ~= nil and BLOCK_CLOSERS[afterTok.lexeme] then
					break
				end
				if afterTok.kind == "Invalid" then
					consumeInvalidToken(afterTok)
				else
					advance()
				end
			end
		end

		if #statements > 0 then
			startTok = {
				kind = "Symbol",
				lexeme = "",
				value = nil,
				delimiter = nil,
				span = statements[1].span,
				leadingTrivia = nil,
			}
		end

		return {
			kind = "Block",
			statements = statements,
			terminatedByControlFlow = terminated,
			span = mergeSpan(startTok.span, lastSpan),
		}
	end

	local body = parseBlock(nil)
	local eofTok = peek(0)
	local chunkSpan = if #body.statements > 0
		then mergeSpan(body.statements[1].span, eofTok.span)
		else body.span

	return {
		ast = {
			kind = "Chunk",
			body = body,
			span = chunkSpan,
		},
		tokens = tokens,
		trivia = trivia,
		diagnostics = diagnostics,
	}
end

return Parser
