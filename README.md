# Luau Parser Foundation

A foundational Luau parser (`Parser.luau`) and test suite (`ParserTests.luau`) focused on expression precedence and associativity, assignment-target validation, contextual `continue` disambiguation and block termination, diagnostics, error recovery, and bounded nesting depth protection.

## Repository Contents

* `Parser.luau` — Core parser module exposing `Parser.parse(tokens, config, diagnosticsSink, trivia)` and Luau AST/diagnostic/token type definitions (`--!strict`).
* `ParserTests.luau` — Test harness exposing `ParserTests.runAll()` across 4 test groups:
  1. `precedence_and_associativity_local_decl_ast`
  2. `assignment_target_validation`
  3. `continue_disambiguation_and_block_termination`
  4. `recovery_immediate_invalid_tokens_depth_and_closers`

## Running `ParserTests.runAll()`

`ParserTests.luau` resolves `Parser` via `require(script.Parent.Parser)`. In a Roblox Studio hierarchy where `Parser` and `ParserTests` sit as siblings under a common parent:

```lua
local ParserTests = require(path.to.ParserTests)
local results = ParserTests.runAll()

for groupName, passed in pairs(results) do
	print(groupName, passed)
end
