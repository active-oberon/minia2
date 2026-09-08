/*
 * The header ob bind reads, the library it binds to, and C's own answers about both.
 *
 * Everything here exists to be said twice: once by C about its own types, once by the module
 * `ob bind` writes out of this header. tests/bind-check.sh diffs the two, so no size, offset or
 * value is written down in the check itself -- which is what makes it true on a host whose ABI
 * differs (a C `long`, a bit field crossing a word, the alignment of a union).
 *
 * Built twice: as a shared library (no BIND_THING_MAIN) and as the reference program.
 */
#include "bind-thing.h"
#include <stdarg.h>

size_t thing_sizeof(void) { return sizeof(struct thing); }
size_t thing_offset_payload(void) { return offsetof(struct thing, payload); }
size_t thing_offset_tail(void) { return offsetof(struct thing, tail); }
size_t either_sizeof(void) { return sizeof(union either); }
size_t signs_sizeof(void) { return sizeof(struct signs); }

/* A variadic function, so that the generated fixed-arity wrappers have something to be right about. */
int thing_sum(const char *fmt, ...) {
	va_list ap; int n = 0, i;
	va_start(ap, fmt);
	for (i = 0; fmt[i]; i++) n += va_arg(ap, int);
	va_end(ap);
	return n;
}

int thing_read_flags(const struct thing *t) { return (t->flag_a ? 1 : 0) + (t->flag_b ? 2 : 0); }
int thing_read_wide(const struct thing *t) { return t->wide; }
void thing_set(struct thing *t, int a, int b, int wide) { t->flag_a = a; t->flag_b = b; t->wide = wide; }
int thing_payload_i(const struct thing *t) { return t->payload.i; }
void thing_payload_set(struct thing *t, int value) { t->payload.i = value; }
void signs_set(struct signs *s, int level, int slope) { s->level = level; s->slope = slope; }
int signs_read_level(const struct signs *s) { return s->level; }

#ifdef BIND_THING_MAIN
#include <stdio.h>
int main(void) {
	struct thing t; struct signs s;
	printf("sizeof_thing=%zu\n", thing_sizeof());
	printf("offset_payload=%zu\n", thing_offset_payload());
	printf("offset_tail=%zu\n", thing_offset_tail());
	printf("sizeof_union=%zu\n", either_sizeof());
	printf("sizeof_signs=%zu\n", signs_sizeof());
	printf("THING_BOTH=%d\n", THING_BOTH);
	t.payload.i = 4242;
	printf("reads_union=%d\n", thing_payload_i(&t));
	thing_payload_set(&t, 1234);
	printf("reads_union_back=%d\n", t.payload.i);
	thing_set(&t, 1, 0, 4000);
	printf("reads_flags=%d\n", thing_read_flags(&t));
	printf("reads_wide=%d\n", thing_read_wide(&t));
	thing_set(&t, 1, 1, 777);
	printf("reads_flags_again=%d\n", thing_read_flags(&t));
	printf("reads_wide_again=%d\n", thing_read_wide(&t));
	signs_set(&s, -5, 7);
	printf("reads_level=%d\n", signs_read_level(&s));
	printf("reads_level_back=%d\n", s.level);
	printf("reads_slope_back=%d\n", s.slope);
	printf("sum1=%d\n", thing_sum("i", 7));
	printf("sum2=%d\n", thing_sum("ii", 10, 20));
	printf("sum3=%d\n", thing_sum("iii", 100, 200, 300));
	return 0;
}
#endif
