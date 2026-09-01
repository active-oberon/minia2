; Active Oberon highlighting. Which local is a parameter and which name is a type
; are things the language server already knows from the symbol table and sends as
; semantic tokens (docs/IDE.md §2); this file colours what the syntax alone decides.
; Later patterns win, so the file goes from the general to the specific.

; ---- identifiers, before anything narrows them ----

(identifier) @variable

; ---- keywords ----

[
  "MODULE" "CELLNET" "CELL" "END" "BEGIN" "CODE" "IN" "OUT" "PORT"
  "CONST" "TYPE" "VAR" "ANY" "ARRAY" "RECORD" "POINTER" "OBJECT" "ENUM" "EXTERN"
] @keyword

"IMPORT" @keyword.import

["PROCEDURE" "OPERATOR"] @keyword.function

["IF" "THEN" "ELSIF" "ELSE" "CASE" "OF" "WITH"] @keyword.conditional

["WHILE" "REPEAT" "UNTIL" "FOR" "TO" "BY" "LOOP" "DO"] @keyword.repeat
(exit_statement) @keyword.repeat

"RETURN" @keyword.return

"AWAIT" @keyword.coroutine

["FINALLY" "IGNORE"] @keyword.exception

["DIV" "MOD" "OR" "IN" "IS" "NEW" "ALIAS" "SIZE" "ADDRESS"] @keyword.operator

(conditional_directive) @keyword.directive

; ---- literals ----

(number) @number
(character) @character
[(string) (escaped_string) (string_concatenation)] @string
["TRUE" "FALSE"] @boolean
"NIL" @constant.builtin
["SELF" "RESULT" "IMAG"] @variable.builtin

(comment) @comment @spell
(note) @comment
(code_body) @string.special

; inactive_branch is deliberately not captured. The grammar has to pick one branch of a
; conditional to parse and picks the first, but that is NOT the branch the compiler takes:
; with no -D definitions every condition is false, so the compiler -- and the language
; server, which resolves symbols in it and marks the SYSTEM calls dangerous -- takes the
; #ELSE. Colouring the skipped text like a comment would therefore claim the wrong half is
; dead. Left plain, the grammar says nothing about it and the server's semantic tokens are
; the only thing that speaks.

; ---- types ----

; Anywhere a type is expected the name is a type; in a qualified one the first
; half is the module it comes from.
(qualified_identifier (identifier) @type)
(qualified_identifier (identifier) @module . (identifier))

(type_declaration name: (identifier_definition (identifier) @type))

((identifier) @type.builtin
  (#any-of? @type.builtin
    "BOOLEAN" "CHAR" "INTEGER" "LONGINTEGER" "RANGE" "INTEGERSET"
    "SIGNED8" "SIGNED16" "SIGNED32" "SIGNED64"
    "UNSIGNED8" "UNSIGNED16" "UNSIGNED32" "UNSIGNED64"
    "FLOAT32" "FLOAT64" "REAL" "COMPLEX32" "COMPLEX64" "COMPLEX"
    "SET" "SET8" "SET16" "SET32" "SET64" "BYTE"))

; ---- declarations ----

(module name: (identifier) @module)
(module end_name: (identifier) @module)
(module context: (identifier) @module)
(import name: (identifier) @module)
(import module: (identifier) @module)
(import context: (identifier) @module)

(const_declaration name: (identifier_definition (identifier) @constant))
(enumeration_constant (identifier_definition (identifier) @constant))

(template_parameter (identifier) @variable.parameter)
(parameter_name (identifier) @variable.parameter)
(receiver (identifier) @variable.parameter)
(port_name (identifier) @variable.parameter)

(flag (identifier) @attribute)

; ---- uses ----

(member_expression field: (identifier) @variable.member)

(procedure_declaration name: (identifier_definition (identifier) @function))
(procedure_declaration name: (string) @function)
(operator_declaration name: (string) @function)

(call_expression function: (identifier) @function.call)
(call_expression function: (member_expression field: (identifier) @function.call))

((identifier) @function.builtin
  (#any-of? @function.builtin
    "ABS" "ASH" "CAP" "CHR" "ENTIER" "FLOOR" "ENTIERH" "ORD" "ORD32" "LEN" "LONG"
    "SHORT" "MAX" "MIN" "ODD" "LSH" "ROT" "ROL" "ROR" "SHL" "SHR" "INCR" "SUM"
    "DIM" "CAS" "FIRST" "LAST" "STEP" "RE" "IM" "ADDRESSOF" "SIZEOF"
    "ASSERT" "COPY" "DEC" "INC" "EXCL" "INCL" "DISPOSE" "HALT" "GETPROCEDURE"
    "TRACE" "RESHAPE" "ALL" "INCMUL" "DECMUL" "WAIT" "CONNECT" "RECEIVE" "SEND"
    "DELEGATE"))

((identifier) @module.builtin
  (#eq? @module.builtin "SYSTEM"))

; ---- operators and punctuation ----

[
  ":=" "=" "#" "<" "<=" ">" ">=" ".=" ".#" ".<" ".<=" ".>" ".>="
  "??" "!!" "<<?" ">>?" "+" "-" "*" "/" "&" "~" "\\" "**" "+*" ".*" "./"
  "^" "`" ".." "!" "?" "<<" ">>"
] @operator

["(" ")" "[" "]" "{" "}"] @punctuation.bracket
[";" "," ":" "." "|"] @punctuation.delimiter
