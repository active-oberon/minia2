/*	The bodies for oberon.h. Everything here is POSIX and libc; there is no collector.

	The one thing worth reading twice is the monitor. Active Oberon's EXCLUSIVE is a monitor and
	AWAIT re-checks its condition whenever somebody leaves it, so UnlockObject broadcasts. The lock
	is not recursive on purpose: an EXCLUSIVE method calling another EXCLUSIVE method of the same
	object is an error in A2 as well, and a recursive mutex would turn that error into a condition
	variable used on a lock held twice, which is undefined.
*/

#include "oberon.h"

struct OberonDescriptor BaseObject_descriptor = { NULL };

Boolean IsBase (void* descriptor, void* base)
{
	while (descriptor != NULL) {
		if (descriptor == base) return true;
		descriptor = ((struct OberonDescriptor*) descriptor)->base;
	}
	return false;
}

/* A static object's monitor is zeroed by the loader and initialised by the module body; another
   thread can reach it first, so the first use initialises it under one global lock. */
static pthread_mutex_t oberon_once = PTHREAD_MUTEX_INITIALIZER;

static void Ready (BaseObject* object)
{
	pthread_mutex_lock (&oberon_once);
	if (!object->ready) InitObject (object);
	pthread_mutex_unlock (&oberon_once);
}

void InitObject (BaseObject* object)
{
	pthread_mutex_init (&object->lock, NULL);
	pthread_cond_init (&object->changed, NULL);
	object->ready = 1;
}

void LockObject (BaseObject* object)
{
	if (!object->ready) Ready (object);
	pthread_mutex_lock (&object->lock);
}

void UnlockObject (BaseObject* object)
{
	pthread_cond_broadcast (&object->changed);
	pthread_mutex_unlock (&object->lock);
}

void AwaitCondition (BaseObject* object)
{
	pthread_cond_wait (&object->changed, &object->lock);
}

struct Activation {
	ObjectType object;
	void (*body) (ObjectType);
};

static void* Run (void* argument)
{
	struct Activation* activation = argument;
	ObjectType object = activation->object;
	void (*body) (ObjectType) = activation->body;

	free (activation);
	body (object);
	return NULL;
}

void Activate (ObjectType object, int priority, void (*body) (ObjectType))
{
	pthread_t thread;
	struct Activation* activation = malloc (sizeof (struct Activation));

	(void) priority;
	activation->object = object;
	activation->body = body;
	if (pthread_create (&thread, NULL, Run, activation) != 0) {
		free (activation);
		return;
	}
	pthread_detach (thread);
}

void Objects_Terminate (void)
{
	pthread_exit (NULL);
}

void Dispose (void* pointer)
{
	void** target = pointer;

	free (*target);
	*target = NULL;
}

Char Capitalize (Char c)
{
	return (c >= 'a' && c <= 'z') ? (Char) (c - 'a' + 'A') : c;
}

void Trace_String (const char* text, size_t length)
{
	/* the length is the declared size of the array, not the string in it */
	fwrite (text, 1, strnlen (text, length), stdout);
}

void Trace_Int (HugeInt value, size_t width)
{
	printf ("%*lld", (int) width, (long long) value);
}

void Trace_Boolean (Boolean value)
{
	fputs (value ? "TRUE" : "FALSE", stdout);
}

void Trace_Bits (Set value, size_t offset, size_t bits)
{
	size_t i;

	for (i = bits; i > 0; i--) fputc ((value >> (offset + i - 1)) & 1 ? '1' : '0', stdout);
}

void Trace_Char (Char c)
{
	fputc (c, stdout);
}

void Trace_Address (void* address)
{
	printf ("%p", address);
}

void Trace_Ln (void)
{
	fputc ('\n', stdout);
	fflush (stdout);
}
