/*	The C side of tests/transpiler-check.sh: it calls what TranspilerCases.Mod exports and checks
	the answers, so the check proves the generated C runs and not only that it was written.

	Nothing here is generated -- it is the hand-written counterpart, and it is deliberately in C:
	the point is that a C program can use a transpiled Active Oberon module directly. */

#include "TranspilerCases.h"

int main (void)
{
	Char c = 0;
	Char s[8] = {0};
	TranspilerCases_Box box;

	TranspilerCases_Escapes (&c, s, 8);
	assert (c == '\n');
	assert (strcmp (s, "a\\b\"c") == 0);

	assert (TranspilerCases_Declared () == 42);
	assert (TranspilerCases_Widths () == sizeof (size_t) * 8);
	assert (TranspilerCases_Bounds (3, 9) == 12);
	assert (TranspilerCases_Narrow ((size_t) 5) == 5);

	/* a rotate by zero is the value itself -- the shift by a whole word it used to do is undefined */
	assert (TranspilerCases_Rotates (1, 0) == 1u + 1u + 1u + 1u + 'a');

	box = TranspilerCases_Result ();
	assert (box != NULL);
	assert (box->record.value == 7);
	assert (IsBase (box->_descriptor, &TranspilerCases_Box_descriptor));
	assert (!IsBase (box->_descriptor, (void*) 1));

	TranspilerCases_Say ();
	return 0;
}
