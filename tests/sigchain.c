/*	A process that is not A2's alone, in the smallest shape that shows what that costs.
 *
 *	Installing a signal handler is a process wide act. An Android application is ART's process before
 *	it is ours, and ART catches SIGSEGV to check for nil itself; once A2 comes up and installs its trap
 *	handler, every fault in the process arrives at A2 instead -- including faults on threads A2 has
 *	never heard of, whose stacks it cannot walk and whose owner is waiting for them. The runtime
 *	therefore remembers what it displaced and hands such a signal back.
 *
 *	This is that arrangement without Android: a C program that installs its own SIGSEGV handler, starts
 *	an A2 image on a thread of its own, and then faults on the thread that stayed behind -- which is
 *	foreign to A2 by construction, because A2 never entered it. The handler below must be the one that
 *	runs. With A2_SIGCHAIN_QUIET set nothing faults here and the image is left to fault on a thread of
 *	its own, where the opposite must happen: A2 reports it and this handler is not called.
 *
 *	Build (needs no Android and no cross compiler):
 *		cc -O2 -DA2BOOT_NO_MAIN -o sigchain tests/sigchain.c android/a2boot.c -lpthread
 *	Run: tests/sigchain-check.sh
 */
#define _GNU_SOURCE
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "../android/a2boot.h"

static const char marker[] = "sigchain: the handler installed before A2 was given the signal\n";

/*	write, not printf: this runs in a signal handler and the process ends inside it. */
static void Foreign(int signal, siginfo_t *info, void *context) {
	(void)info; (void)context;
	if (write(1, marker, sizeof marker - 1) < 0) _exit(4);
	_exit(signal == SIGSEGV ? 0 : 3);
}

static struct { int passed; char **arguments; Elf64_Addr entry; } handover;

static void *Started(void *unused) {
	(void)unused;
	Enter(handover.passed, handover.arguments, handover.entry);
	return NULL;										/* not reached */
}

int main(int argc, char **argv) {
	struct sigaction action;
	pthread_attr_t attributes;
	pthread_t thread;
	struct timespec wait;
	const char *image, *delay;
	int error;

	image = getenv("A2_IMAGE");
	if (image == NULL) { fprintf(stderr, "sigchain: set A2_IMAGE to the image to start\n"); return 2; }

	memset(&action, 0, sizeof action);
	action.sa_sigaction = Foreign;
	action.sa_flags = SA_SIGINFO;
	sigemptyset(&action.sa_mask);
	if (sigaction(SIGSEGV, &action, NULL) != 0) { perror("sigchain: sigaction"); return 2; }

	handover.entry = A2Load(image);
	handover.arguments = argv; handover.passed = argc;
	pthread_attr_init(&attributes);
	pthread_attr_setstacksize(&attributes, 8u * 1024u * 1024u);	/* the compiler in there is recursive */
	error = pthread_create(&thread, &attributes, Started, NULL);
	pthread_attr_destroy(&attributes);
	if (error != 0) { fprintf(stderr, "sigchain: starting the image's thread: %s\n", strerror(error)); return 2; }

	if (getenv("A2_SIGCHAIN_QUIET") != NULL) {
		pthread_join(thread, NULL);						/* the image faults on its own and reports it */
		return 0;
	}

	/*	Long enough for the image to have reached its shell, which the check confirms in the output
		rather than trusting: the shell's banner is printed after the trap handler is installed, so a
		banner followed by the marker is the whole proof. */
	delay = getenv("A2_SIGCHAIN_DELAY");
	wait.tv_sec = delay != NULL ? atoi(delay) : 3;
	wait.tv_nsec = 0;
	nanosleep(&wait, NULL);

	*(volatile int *)0x1000 = 1;						/* a page no one maps, on a thread A2 does not know */

	fprintf(stderr, "sigchain: the store to an unmapped page did not fault\n");
	return 3;
}
