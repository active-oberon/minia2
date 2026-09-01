#include "tree_sitter/parser.h"
#include <string.h>

// The tokens the regex lexer cannot express, each of them a rule FoxScanner.Mod
// implements by hand: nested (* … *) comments, the verbatim body of a CODE block,
// the free-form notes A2 modules carry after the closing period, the branch of a
// conditional the compiler skips, and the raw string with a chosen delimiter.

enum TokenType { COMMENT, CODE_BODY, NOTE, INACTIVE_BRANCH, ESCAPED_STRING };

void *tree_sitter_oberon_external_scanner_create(void) { return NULL; }
void tree_sitter_oberon_external_scanner_destroy(void *payload) { (void)payload; }
unsigned tree_sitter_oberon_external_scanner_serialize(void *payload, char *buffer) {
  (void)payload; (void)buffer; return 0;
}
void tree_sitter_oberon_external_scanner_deserialize(void *payload, const char *buffer, unsigned length) {
  (void)payload; (void)buffer; (void)length;
}

static bool is_word_char(int32_t c) {
  return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_';
}

// The upper-case word at the cursor, consumed. Never more than a keyword's worth.
static int read_word(TSLexer *lexer, char *word) {
  int n = 0;
  while (n < 7 && lexer->lookahead >= 'A' && lexer->lookahead <= 'Z') {
    word[n++] = (char)lexer->lookahead;
    lexer->advance(lexer, false);
  }
  word[n] = 0;
  if (is_word_char(lexer->lookahead)) return -1;  // MODULEX is not MODULE
  return n;
}

static bool word_is(const char *word, int n, const char *keyword, int length) {
  return n == length && memcmp(word, keyword, (size_t)length) == 0;
}

// FoxScanner.ReadComment: (* … *) nests, counted by level.
static bool scan_comment(TSLexer *lexer) {
  lexer->advance(lexer, false);            // '('
  if (lexer->lookahead != '*') return false;
  lexer->advance(lexer, false);

  int level = 1;
  while (level > 0 && !lexer->eof(lexer)) {
    if (lexer->lookahead == '(') {
      lexer->advance(lexer, false);
      if (lexer->lookahead == '*') { level++; lexer->advance(lexer, false); }
    } else if (lexer->lookahead == '*') {
      lexer->advance(lexer, false);
      if (lexer->lookahead == ')') { level--; lexer->advance(lexer, false); }
    } else {
      lexer->advance(lexer, false);
    }
  }
  lexer->result_symbol = COMMENT;
  return true;
}

// FoxScanner.SkipToEndOfCode: everything up to the END or WITH that closes the
// block. A '#' in front keeps the word out, so the #END of a conditional inside
// the assembler stays part of the text.
static bool scan_code_body(TSLexer *lexer) {
  bool any = false;
  bool after_hash = false;
  char word[8];

  for (;;) {
    if (lexer->eof(lexer)) break;
    lexer->mark_end(lexer);

    if (!after_hash && (lexer->lookahead == 'E' || lexer->lookahead == 'W')) {
      int n = read_word(lexer, word);
      if (word_is(word, n, "END", 3) || word_is(word, n, "WITH", 4)) {
        if (!any) return false;
        lexer->result_symbol = CODE_BODY;
        return true;
      }
      any = true;
      continue;
    }

    after_hash = lexer->lookahead == '#';
    lexer->advance(lexer, false);
    any = true;
  }

  if (!any) return false;
  lexer->mark_end(lexer);
  lexer->result_symbol = CODE_BODY;
  return true;
}

// Free-form text after 'END Module.', up to the next module or the end of file.
static bool scan_note(TSLexer *lexer) {
  char word[8];
  lexer->mark_end(lexer);
  int n = read_word(lexer, word);
  if (word_is(word, n, "MODULE", 6) || word_is(word, n, "CELLNET", 7)) return false;

  for (;;) {
    if (lexer->eof(lexer)) break;
    if (lexer->lookahead == '\n' || lexer->lookahead == '\r') {
      lexer->advance(lexer, false);
      lexer->mark_end(lexer);
      while (lexer->lookahead == ' ' || lexer->lookahead == '\t') lexer->advance(lexer, false);
      n = read_word(lexer, word);
      if (word_is(word, n, "MODULE", 6) || word_is(word, n, "CELLNET", 7)) {
        lexer->result_symbol = NOTE;
        return true;
      }
      continue;
    }
    lexer->advance(lexer, false);
  }
  lexer->mark_end(lexer);
  lexer->result_symbol = NOTE;
  return true;
}

// 0 = no directive, 1 = #IF, 2 = #END, 3 = #ELSE or #ELSIF. Consumed either way.
static int read_directive(TSLexer *lexer) {
  char word[8];
  lexer->advance(lexer, false);            // '#'
  int n = read_word(lexer, word);
  if (word_is(word, n, "IF", 2)) return 1;
  if (word_is(word, n, "END", 3)) return 2;
  if (word_is(word, n, "ELSE", 4) || word_is(word, n, "ELSIF", 5)) return 3;
  return 0;
}

// One branch of a conditional has to be the one that is parsed, and this takes the first:
// the later ones hold code for other targets and, in a few modules, text that is not code at
// all, which would put an ERROR node across the whole file. It is a parsing choice and NOT a
// claim about which branch is live — with no -D definitions every condition is false, so the
// compiler takes the #ELSE. Nothing colours the skipped text for that reason: the language
// server is what knows, and it resolves the branch it compiles.
static bool scan_inactive_branch(TSLexer *lexer) {
  if (read_directive(lexer) != 3) return false;

  int depth = 1;
  while (!lexer->eof(lexer)) {
    if (lexer->lookahead == '#') {
      int directive = read_directive(lexer);
      if (directive == 1) {
        depth++;
      } else if (directive == 2) {
        depth--;
        if (depth == 0) {
          while (lexer->lookahead == ' ' || lexer->lookahead == '\t') lexer->advance(lexer, false);
          if (lexer->lookahead == ';') lexer->advance(lexer, false);  // '#END;' is one line
          break;
        }
      }
      continue;
    }
    lexer->advance(lexer, false);
  }
  lexer->mark_end(lexer);
  lexer->result_symbol = INACTIVE_BRANCH;
  return true;
}

// FoxScanner.GetEscapedString: \"…"\ , or \X"…"X\ with X as the chosen escape.
static bool scan_escaped_string(TSLexer *lexer) {
  lexer->advance(lexer, false);            // '\'
  int32_t escape = 0;
  if (lexer->lookahead != '"' && lexer->lookahead != '\'') {
    if (lexer->lookahead <= ' ') return false;
    escape = lexer->lookahead;
    lexer->advance(lexer, false);
  }
  if (lexer->lookahead != '"' && lexer->lookahead != '\'') return false;
  int32_t quote = lexer->lookahead;
  lexer->advance(lexer, false);

  while (!lexer->eof(lexer)) {
    if (lexer->lookahead == quote) {
      lexer->advance(lexer, false);
      if (escape != 0) {
        if (lexer->lookahead != escape) continue;
        lexer->advance(lexer, false);
      }
      if (lexer->lookahead == '\\') {
        lexer->advance(lexer, false);
        lexer->result_symbol = ESCAPED_STRING;
        return true;
      }
      continue;
    }
    lexer->advance(lexer, false);
  }
  return false;
}

bool tree_sitter_oberon_external_scanner_scan(void *payload, TSLexer *lexer, const bool *valid_symbols) {
  (void)payload;

  // The code body starts at the cursor, leading whitespace included.
  if (valid_symbols[CODE_BODY]) return scan_code_body(lexer);

  while (lexer->lookahead == ' ' || lexer->lookahead == '\t' ||
         lexer->lookahead == '\n' || lexer->lookahead == '\r') {
    lexer->advance(lexer, true);
  }
  if (lexer->eof(lexer)) return false;

  // One token per first character, so a failed attempt never eats another's input.
  switch (lexer->lookahead) {
    case '(': return valid_symbols[COMMENT] && scan_comment(lexer);
    case '#': return valid_symbols[INACTIVE_BRANCH] && scan_inactive_branch(lexer);
    case '\\': return valid_symbols[ESCAPED_STRING] && scan_escaped_string(lexer);
    default: return valid_symbols[NOTE] && scan_note(lexer);
  }
}
