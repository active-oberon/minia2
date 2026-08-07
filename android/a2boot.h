/*	The two halves of starting an A2 image, shared by the command (android/a2boot.c, its own main)
 *	and by the application (android/a2app.c, a NativeActivity). Everything up to the entry point is
 *	the same for both; what differs is which thread enters and what else that process has to do. */
#ifndef A2BOOT_H
#define A2BOOT_H

#include <elf.h>

/*	Map the image where it was linked for, apply its relocations, and answer its entry point. */
Elf64_Addr A2Load(const char *image);

/*	Enter the image on the calling stack, never returning. */
void Enter(int argc, char **argv, Elf64_Addr entry);

/*	Enter it on a thread of our own and wait there. The thread does not return, so neither does
 *	this -- but the caller's stack is left alone, which is what an application needs. */
void EnterOnOwnThread(int argc, char **argv, Elf64_Addr entry);

#endif
