/* What ob bind is pointed at: a union, a run of bit fields, a variadic function, and a macro over
   macros -- the four things the generator has to do rather than copy. See tests/bind-thing.c. */
#ifndef BIND_THING_H
#define BIND_THING_H
#include <stddef.h>

#define THING_A 0x1
#define THING_B 0x2
#define THING_BOTH (THING_A|THING_B)

union either { int i; double d; char text[8]; };

struct thing {
	int kind;
	union either payload;
	unsigned flag_a : 1;
	unsigned flag_b : 1;
	unsigned wide : 12;
	int tail;
};

struct signs { signed level : 6; signed slope : 6; };

/* Refused on purpose, and the check reads the reason: Windows starts a new word when the type of a
   bit field changes and Unix goes on packing, so one generated file cannot serve both. */
struct mixed { unsigned a : 4; signed b : 4; };

size_t thing_sizeof(void);
size_t thing_offset_payload(void);
size_t thing_offset_tail(void);
size_t either_sizeof(void);
size_t signs_sizeof(void);
int thing_sum(const char *fmt, ...);
int thing_read_flags(const struct thing *t);
int thing_read_wide(const struct thing *t);
void thing_set(struct thing *t, int a, int b, int wide);
int thing_payload_i(const struct thing *t);
void thing_payload_set(struct thing *t, int value);
void signs_set(struct signs *s, int level, int slope);
int signs_read_level(const struct signs *s);
#endif
