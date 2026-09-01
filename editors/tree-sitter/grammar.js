/// <reference types="tree-sitter-cli/dsl" />
// Active Oberon, transcribed from the EBNF that source/FoxParser.Mod carries above
// each production, with the token forms from source/FoxScanner.Mod.

// ponytail: uppercase keywords only. FoxScanner keeps a lowercase table too, chosen by
// the case of the MODULE that opens the file; no source in the tree uses it. Add a second
// keyword set if one ever appears.
const PREC = { relation: 1, add: 2, mul: 3, unary: 4, postfix: 5 };

const sepBy1 = (sep, rule) => seq(rule, repeat(seq(sep, rule)));
const sepBy = (sep, rule) => optional(sepBy1(sep, rule));

module.exports = grammar({
  name: 'oberon',

  word: $ => $.identifier,

  externals: $ => [$.comment, $.code_body, $.note, $.inactive_branch, $.escaped_string],

  extras: $ => [/[\s\u001b﻿]/, $.comment, $.conditional_directive, $.inactive_branch],

  rules: {
    source_file: $ => repeat(choice($.module, $.note)),

    // Module = ('MODULE' | 'CELLNET' [Flags]) Identifier [TemplateParameters]
    //          ['IN' Identifier] ';' {ImportList} DeclarationSequence [Body] 'END' Identifier '.'.
    module: $ => seq(
      choice('MODULE', seq('CELLNET', optional($.flags))),
      field('name', $.identifier),
      optional($.template_parameters),
      optional(seq('IN', field('context', $.identifier))),
      ';',
      repeat($.import_list),
      optional($.declaration_sequence),
      optional($.body),
      'END', field('end_name', $.identifier), '.',
    ),

    template_parameters: $ => seq('(', sepBy(',', $.template_parameter), ')'),
    template_parameter: $ => seq(optional(choice('CONST', 'TYPE', 'IMPORT')), $.identifier),

    // ImportList = 'IMPORT' Import {',' Import} ';'.
    import_list: $ => seq('IMPORT', sepBy1(',', $.import), ';'),
    import: $ => seq(
      field('name', $.identifier),
      optional(seq(':=', field('module', $.identifier), optional($.instantiation))),
      optional(seq('IN', field('context', $.identifier))),
    ),
    instantiation: $ => seq('(', sepBy(',', $._type), ')'),

    // ---- declarations ----

    declaration_sequence: $ => repeat1(choice(
      $.const_section, $.type_section, $.var_section,
      $.procedure_declaration, $.operator_declaration,
    )),

    // Every declaration swallows the ';' that follows it, so the separator never
    // has to be told apart from the empty declaration the EBNF also allows.
    const_section: $ => seq('CONST', repeat(seq($.const_declaration, repeat(';')))),
    const_declaration: $ => seq(field('name', $.identifier_definition), '=', $._expression),

    type_section: $ => seq('TYPE', repeat(seq($.type_declaration, repeat(';')))),
    type_declaration: $ => seq(field('name', $.identifier_definition), '=', field('type', $._type)),

    var_section: $ => seq('VAR', repeat(seq($.variable_declaration, repeat(';')))),
    variable_declaration: $ => seq(sepBy1(',', $.variable_name), optional(seq(':', field('type', $._type)))),
    variable_name: $ => seq(
      field('name', $.identifier_definition),
      optional($.flags),
      optional(choice(seq(':=', $._expression), seq('EXTERN', $.string))),
    ),

    identifier_definition: $ => seq($.identifier, optional(choice('*', '-'))),

    // ProcedureDeclaration = 'PROCEDURE' ['^'] ['CONST'] ['&'|'~'|'-'|Flags ['-']] [Receiver]
    //   IdentifierDefinition [FormalParameters]
    //   (';' DeclarationSequence [Body] 'END' Identifier | 'EXTERN' ConstExpression).
    procedure_declaration: $ => prec.right(seq(
      'PROCEDURE',
      optional('^'),
      optional('CONST'),
      optional(choice('&', '~', '-', seq($.flags, optional('-')))),
      optional($.receiver),
      // A string name is the deprecated operator form: FoxParser diagnoses it and
      // then parses it as an OperatorDeclaration anyway.
      field('name', choice($.identifier_definition, $.string)),
      optional($.formal_parameters),
      optional(choice(
        seq('EXTERN', $._expression),
        seq(';', optional($.declaration_sequence), optional($.body), 'END',
          optional(choice($.identifier, $.string))),
      )),
      optional(';'),
    )),

    receiver: $ => seq('(', optional(choice('VAR', 'CONST')), $.identifier, ':', $.identifier, ')'),

    // OperatorDeclaration = 'OPERATOR' [Flags] ['-'] String ['*'|'-'] FormalParameters ';'
    //   DeclarationSequence [Body] 'END' String.
    operator_declaration: $ => prec.right(seq(
      'OPERATOR',
      optional($.flags),
      optional('-'),
      field('name', $.string),
      optional(choice('*', '-')),
      $.formal_parameters,
      ';',
      optional($.declaration_sequence),
      optional($.body),
      'END', optional($.string), optional(';'),
    )),

    formal_parameters: $ => seq(
      '(', sepBy(';', $.parameter_declaration), ')',
      optional(seq(':', optional($.flags), field('return_type', $._type))),
    ),
    parameter_declaration: $ => seq(
      optional(choice('VAR', 'CONST')),
      sepBy1(',', $.parameter_name),
      ':', field('type', $._type),
    ),
    parameter_name: $ => seq($.identifier, optional($.flags), optional(seq(choice(':=', '='), $._expression))),

    // Flags = '{' [Identifier ['(' Expression ')' | '=' Expression] {',' ...}] '}'.
    // Wins over a set literal: after BEGIN or a type keyword the braces are flags.
    flags: $ => prec(1, seq('{', sepBy(',', $.flag), '}')),
    flag: $ => prec(1, seq($.identifier, optional(choice(seq('(', $._expression, ')'), seq('=', $._expression))))),

    // Body = 'BEGIN' [Flags] StatementSequence ['FINALLY' StatementSequence] | 'CODE' Code.
    body: $ => choice(
      seq('BEGIN', optional($.flags), optional($.statement_sequence),
        optional(seq('FINALLY', optional($.statement_sequence)))),
      seq('CODE', optional($.code_body), optional($.code_with_clause)),
    ),

    code_with_clause: $ => seq('WITH', repeat(seq(choice('IN', 'OUT'), optional($.statement_sequence)))),

    // ---- types ----

    _type: $ => choice(
      $.array_type, $.record_type, $.pointer_type, $.object_type, $.cell_type,
      $.port_type, $.procedure_type, $.enumeration_type, $.any_type, $.qualified_identifier,
    ),

    any_type: $ => prec.right(seq('ANY', optional(choice('OBJECT', 'POINTER', 'RECORD')))),

    array_type: $ => choice(
      seq('ARRAY', optional($.flags), 'OF', field('element', $._type)),
      prec(1, seq('ARRAY', optional($.flags), '[', sepBy1(',', $.math_array_size), ']',
        optional(seq('OF', field('element', $._type))))),
      seq('ARRAY', optional($.flags), sepBy1(',', $._expression), 'OF', field('element', $._type)),
    ),
    // 'ARRAY [' is always a math array, never an array literal used as a dimension.
    math_array_size: $ => prec(2, choice($._expression, '*', '?')),

    record_type: $ => seq(
      'RECORD', optional($.flags),
      optional(seq('(', field('base', $.qualified_identifier), ')')),
      optional(';'),
      repeat(seq($.variable_declaration, repeat(';'))),
      repeat(choice($.procedure_declaration, $.operator_declaration)),
      'END',
    ),

    pointer_type: $ => seq('POINTER', optional($.flags), 'TO', field('target', $._type)),

    object_type: $ => prec.right(choice(
      'OBJECT',
      seq('OBJECT', $._object_head, optional(';'),
        optional($.declaration_sequence), optional($.body), 'END', optional($.identifier)),
      seq('OBJECT', optional($.declaration_sequence), optional($.body), 'END', optional($.identifier)),
    )),
    _object_head: $ => choice(
      seq($.flags, optional(seq('(', field('base', $.qualified_identifier), ')'))),
      seq('(', field('base', $.qualified_identifier), ')'),
    ),

    cell_type: $ => prec.right(seq(
      choice('CELL', 'CELLNET'), optional($.flags), optional($.port_list), optional(';'),
      repeat($.import_list), optional($.declaration_sequence), optional($.body),
      'END', optional($.identifier),
    )),
    port_list: $ => seq('(', sepBy(';', $.port_declaration), ')'),
    port_declaration: $ => seq(sepBy1(',', $.port_name), ':', field('type', $._type)),
    port_name: $ => seq($.identifier, optional($.flags)),

    port_type: $ => prec.right(seq('PORT', choice('IN', 'OUT'), optional(seq('(', $._expression, ')')))),

    procedure_type: $ => prec.right(seq('PROCEDURE', optional($.flags), optional($.formal_parameters))),

    enumeration_type: $ => seq(
      'ENUM', optional(seq('(', field('base', $.qualified_identifier), ')')),
      sepBy1(',', $.enumeration_constant), 'END',
    ),
    enumeration_constant: $ => seq($.identifier_definition, optional(seq('=', $._expression))),

    qualified_identifier: $ => choice(
      seq($.identifier, optional(seq('.', $.identifier))),
      'ADDRESS', 'SIZE',
    ),

    // ---- statements ----

    // ponytail: the ';' is a separator here rather than a required one, so two adjacent
    // statements with none between them parse. Highlighting does not care and the compiler
    // is the one that reports it; tighten only if the tree is ever used to diagnose.
    statement_sequence: $ => repeat1(choice($._statement, ';')),

    _statement: $ => choice(
      $.assignment, $.communication_statement, $.call_statement, $.local_declaration,
      $.if_statement, $.with_statement, $.case_statement, $.while_statement,
      $.repeat_statement, $.for_statement, $.loop_statement, $.exit_statement,
      $.return_statement, $.await_statement, $.ignore_statement,
      $.statement_block, $.code_statement,
    ),

    assignment: $ => seq(field('left', $._designator), ':=', field('right', $._expression)),
    communication_statement: $ => seq($._designator, choice('!', '?', '<<', '>>'), $._expression),
    call_statement: $ => $._designator,

    local_declaration: $ => seq('VAR', sepBy1(',', $.local_variable), optional(seq(':', $._type))),
    local_variable: $ => seq($.identifier, optional(seq(':=', $._expression))),

    if_statement: $ => seq(
      'IF', $._expression, 'THEN', optional($.statement_sequence),
      repeat($.elsif_clause), optional($.else_clause), 'END',
    ),
    elsif_clause: $ => seq('ELSIF', $._expression, 'THEN', optional($.statement_sequence)),
    else_clause: $ => seq('ELSE', optional($.statement_sequence)),

    with_statement: $ => seq(
      'WITH', $.identifier, ':', optional('|'), sepBy1('|', $.with_alternative),
      optional($.else_clause), 'END',
    ),
    with_alternative: $ => seq(
      field('type', $.qualified_identifier),
      optional(seq(':', field('type', $.qualified_identifier))),  // deprecated repeated variable
      'DO', optional($.statement_sequence),
    ),

    case_statement: $ => seq(
      'CASE', $._expression, 'OF', optional('|'), sepBy1('|', $.case_clause),
      optional($.else_clause), 'END',
    ),
    case_clause: $ => seq(sepBy1(',', $._range_expression), ':', optional($.statement_sequence)),

    while_statement: $ => seq('WHILE', $._expression, 'DO', optional($.statement_sequence), 'END'),
    repeat_statement: $ => seq('REPEAT', optional($.statement_sequence), 'UNTIL', $._expression),
    for_statement: $ => seq(
      'FOR', $.identifier, ':=', $._expression, 'TO', $._expression,
      optional(seq('BY', $._expression)), 'DO', optional($.statement_sequence), 'END',
    ),
    loop_statement: $ => seq('LOOP', optional($.statement_sequence), 'END'),
    exit_statement: _ => 'EXIT',
    return_statement: $ => prec.right(seq('RETURN', optional($._expression))),
    await_statement: $ => seq('AWAIT', $._expression),
    ignore_statement: $ => seq('IGNORE', $._expression),
    statement_block: $ => seq('BEGIN', optional($.flags), optional($.statement_sequence), 'END'),
    code_statement: $ => seq('CODE', optional($.code_body), optional($.code_with_clause), 'END'),

    // ---- expressions ----

    _expression: $ => choice($.conditional_expression, $._relational_expression),

    // Expression = RelationalExpression ['IF' RelationalExpression 'ELSE' Expression].
    conditional_expression: $ => prec.right(1, seq(
      $._relational_expression, 'IF', $._relational_expression, 'ELSE', $._expression)),

    _relational_expression: $ => choice($.relation_expression, $._range_expression),

    relation_expression: $ => prec.left(PREC.relation, seq(
      $._range_expression,
      field('operator', choice('=', '#', '<', '<=', '>', '>=', 'IN', 'IS',
        '.=', '.#', '.<', '.<=', '.>', '.>=', '??', '!!', '<<?', '>>?')),
      $._range_expression,
    )),

    _range_expression: $ => choice($.range, $._simple_expression),
    range: $ => prec.right(seq(
      optional($._simple_expression), '..', optional($._simple_expression),
      optional(seq('BY', $._simple_expression)),
    )),

    _simple_expression: $ => choice($.binary_expression, $._factor),
    binary_expression: $ => choice(
      prec.left(PREC.add, seq($._simple_expression,
        field('operator', choice('+', '-', 'OR')), $._simple_expression)),
      prec.left(PREC.mul, seq($._simple_expression,
        field('operator', choice('*', '/', 'DIV', 'MOD', '&', '.*', './', '\\', '**', '+*')),
        $._simple_expression)),
    ),

    _factor: $ => choice($.prefix_expression, $._designator),
    prefix_expression: $ => prec.right(PREC.unary, seq(
      field('operator', choice('~', '+', '-')), $._factor)),

    _designator: $ => choice(
      $._primary_expression,
      $.call_expression, $.member_expression, $.index_expression,
      $.dereference, $.transpose,
    ),
    call_expression: $ => prec.left(PREC.postfix, seq(
      field('function', $._designator), '(', optional($.expression_list), ')')),
    member_expression: $ => prec.left(PREC.postfix, seq(
      $._designator, '.', field('field', $.identifier))),
    index_expression: $ => prec.left(PREC.postfix, seq($._designator, '[', $.index_list, ']')),
    dereference: $ => prec.left(PREC.postfix, seq($._designator, '^')),
    transpose: $ => prec.left(PREC.postfix, seq($._designator, '`')),

    _primary_expression: $ => choice(
      $.number, $.character, $.string, $.escaped_string, $.string_concatenation,
      $.set, $.array_literal,
      'NIL', 'IMAG', 'TRUE', 'FALSE', 'SELF', 'RESULT', 'ADDRESS', 'SIZE', 'ANY', 'NEW',
      $.size_of, $.address_of, $.alias_of,
      $.new_expression, $.parenthesized_expression,
      $.identifier,
    ),

    // 'OF' after ADDRESS/SIZE always starts the operator, never the OF of a CASE.
    size_of: $ => prec(1, seq('SIZE', 'OF', $._factor)),
    address_of: $ => prec(1, seq('ADDRESS', 'OF', $._factor)),
    alias_of: $ => prec(1, seq('ALIAS', 'OF', $._factor)),
    // NEW followed by '(' is the builtin call — FoxParser reads the parenthesis as an
    // argument list, so only the paren-less 'NEW Type' form is a new_expression.
    new_expression: $ => prec.right(-1, seq('NEW', $._designator)),
    parenthesized_expression: $ => seq('(', $._expression, ')'),

    string_concatenation: $ => prec.left(1, seq(
      choice($.string, $.escaped_string, $.character),
      repeat1(choice($.string, $.escaped_string, $.character)))),

    set: $ => seq('{', sepBy(',', $._range_expression), '}'),
    array_literal: $ => seq('[', sepBy1(',', $._expression), ']'),
    expression_list: $ => sepBy1(',', $._expression),
    index_list: $ => sepBy1(',', choice($._range_expression, '?', '*')),

    // ---- tokens ----

    identifier: _ => /[A-Za-z_][A-Za-z0-9_]*/,

    // Integer = Digit {["'"]Digit} | Digit {["'"]HexDigit} 'H' | '0x' … | '0b' …
    // Real = Digit {["'"]Digit} '.' {Digit} [('E'|'D') ['+'|'-'] Digit {Digit}].
    // Character = Digit {HexDigit} 'X'.
    // ponytail: a real literal needs a digit after the point -- '0.' is legal A2 but
    // '0..9' is the far more common range, and telling them apart needs a lexer with
    // lookahead. Three files in ocp write '0.'; write '0.0' there.
    number: _ => token(choice(
      /0x[0-9a-fA-F']+/,
      /0b[01']+/,
      /[0-9][0-9a-fA-F']*H/,
      /[0-9][0-9']*\.[0-9][0-9']*([ED][+-]?[0-9]+)?/,
      /[0-9][0-9']*\.[ED][+-]?[0-9]+/,
      /[0-9][0-9']*/,
    )),

    // Character = Digit {HexDigit} 'X' — concatenates with strings, so 09X is how
    // a tab reaches one.
    character: _ => /[0-9][0-9a-fA-F']*X/,

    string: _ => token(choice(
      /"[^"\n]*"/,
      /'[^'\n]*'/,
    )),

    // #IF … THEN and #END, skipped the way a comment is. The branch after #ELSE or #ELSIF is
    // swallowed by the scanner instead, so only one branch is parsed — see scanner.c for why
    // that is a parsing choice and not a claim about which branch the compiler takes.
    conditional_directive: _ => token(choice(
      /#IF[ \t][^\n]*/,
      /#END[ \t]*;?/,
    )),
  },
});
