/*	oberon.h -- what the C the transpiler writes needs underneath it.

	`Compiler.Compile -b=Transpiler X.Mod` writes X.c and X.h, and every X.h opens with
	#include "oberon.h". Until now that file did not exist anywhere in the tree, so nothing the
	backend produced had ever been through a C compiler. This is the smallest thing that makes it
	compile and run: the type names the backend prints, the object header it lays out, the four
	monitor calls behind EXCLUSIVE and AWAIT, and the handful of helpers it calls by name.

	What it deliberately is not: a garbage collector. NEW is calloc and nothing is ever freed
	unless the program says DISPOSE. That is enough for a program that runs and exits -- a demo, a
	test, a page in a browser -- and not enough for a system that stays up. The collector is the
	rest of the work, and it is the part that is measured in weeks.

	Compile the generated C with -I this directory and link with -pthread.
*/

#ifndef OBERON_H_INCLUDED
#define OBERON_H_INCLUDED

#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ASSERT (cond) is both ASSERT and HALT: the backend writes ASSERT (false) for the latter. */
#define ASSERT(condition) assert (condition)

/* The names PrintBasicType writes in the default style. Staila style prints the C names directly
   and needs none of these. */
typedef char		Char;
typedef uint16_t	Char16;
typedef uint32_t	Char32;
typedef bool		Boolean;
typedef uint8_t		Byte;
typedef int8_t		ShortInt;
typedef int16_t		Integer;
typedef int32_t		LongInt;
typedef int64_t		HugeInt;
typedef uint8_t		Unsigned8;
typedef uint16_t	Unsigned16;
typedef uint32_t	Unsigned32;
typedef uint64_t	Unsigned64;
typedef float		Real;
typedef double		LongReal;
typedef size_t		Set;
typedef uint8_t		Set8;
typedef uint16_t	Set16;
typedef uint32_t	Set32;
typedef uint64_t	Set64;

/* An open array: the lengths first, the elements behind them. PrintNew allocates
   sizeof (struct Array_pointer) + n * sizeof (element), so `array` has to be the flexible tail. */
#define OBERON_DIMENSIONS 8

struct Array_pointer {
	size_t length[OBERON_DIMENSIONS];
	char array[];
};

/* Every object carries this: EXCLUSIVE takes the lock, AWAIT waits on the condition, and leaving
   the monitor wakes everyone because that is when an AWAIT condition can have become true.
   `ready` is not paranoia: a module's own monitor is a static, and InitObject on it runs in the
   module body -- which is not necessarily before another thread reaches it. */
typedef struct BaseObject_struct {
	pthread_mutex_t lock;
	pthread_cond_t changed;
	int ready;
} BaseObject;

/* The generic object pointer Activate is given. */
typedef void* ObjectType;

/* A type descriptor is a struct whose first field is a void* to the descriptor of its base type;
   the backend generates one per type and initialises that field with &BaseObject_descriptor at the
   root. IsBase walks that chain, which is what IS and type guards reduce to. */
struct OberonDescriptor {
	void* base;
};

extern struct OberonDescriptor BaseObject_descriptor;

Boolean IsBase (void* descriptor, void* base);

void InitObject (BaseObject* object);
void LockObject (BaseObject* object);
void UnlockObject (BaseObject* object);
void AwaitCondition (BaseObject* object);

/* An active body: NEW writes Activate (obj, priority, body), and the body ends in
   Objects_Terminate. Priorities are accepted and ignored -- POSIX has no equivalent worth faking. */
void Activate (ObjectType object, int priority, void (*body) (ObjectType));
void Objects_Terminate (void);

void Dispose (void* pointer);
Char Capitalize (Char c);

/* TRACE, which the backend routes through the module named by --traceModule -- and every Unix
   platform in Compiler.Mod names Trace, so these are the symbols the generated C actually calls.
   The signatures are source/Trace.Mod's, so transpiling that module instead of linking these would
   collide; pick one. Trace_Char has no counterpart there, and the backend calls it anyway. */
void Trace_String (const char* text, size_t length);
void Trace_Int (HugeInt value, size_t width);
void Trace_Boolean (Boolean value);
void Trace_Bits (Set value, size_t offset, size_t bits);
void Trace_Char (Char c);
void Trace_Address (void* address);
void Trace_Ln (void);

#endif /* OBERON_H_INCLUDED */
