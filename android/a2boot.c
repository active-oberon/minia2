/*	a2boot -- start an A2 image on Android, where its own ELF cannot be started.
 *
 *	Bionic refuses ET_EXEC outright ("Android only supports position-independent executables"), and
 *	an A2 image cannot be position independent: the backend emits absolute addresses and the image
 *	is linked for a fixed displacement. Rather than teach the backend PIC -- weeks -- this loads the
 *	image itself, which turns out to be small work, because an A2 image asks the dynamic linker for
 *	remarkably little: one library and one symbol, `dlsym`, through which the system then resolves
 *	everything else for itself (see the dynamic section Linux.Glue.Mod writes by hand).
 *
 *	So: map the one loadable segment at the address it was linked for, apply the handful of
 *	relocations by looking their names up with dlsym, build the stack the entry point expects, and
 *	branch to it. Nothing of Bionic's loader is involved; the image is data as far as it is
 *	concerned.
 *
 *	The same code serves the window later on: a NativeActivity is a shared object with an entry
 *	point of its own, and what it has to do to bring A2 up is exactly this.
 *
 *	Which image to start, in this order: $A2_IMAGE, then <the name this was invoked as>.img, then
 *	the first argument. The middle one is what makes the bundle work unchanged on Android: the shim
 *	is installed AS `oberon` with the image beside it as `oberon.img`, so `ob`, the test harness and
 *	everything else go on starting `oberon` and know nothing about any of this.
 *
 *	Two architectures and two C libraries. The four places where either of them shows through are
 *	marked below; everything else is the same file. AArch64 on Bionic is what this exists for; x86-64
 *	is here because the only Android machine other than a phone is the emulator, which is x86-64, and
 *	because it can be built against glibc, where booting an AMD64 image this way is a way of checking
 *	the loading itself with none of Android in the picture. That last one is what has been run; the
 *	emulator has not been needed yet.
 *
 *	Build (NDK):
 *	  $NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android28-clang \
 *	      -O2 -o a2boot android/a2boot.c
 *	  $NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android28-clang \
 *	      -O2 -o a2boot android/a2boot.c        (the emulator)
 *	  cc -O2 -o a2boot android/a2boot.c         (glibc, to check the loading)
 *	Run:
 *	  ./a2boot ./oberon [arguments for A2 ...]      or, installed as above, just ./oberon [...]
 */

#include <alloca.h>
#include <elf.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <malloc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

/*	Declared here rather than relied on from a header: Bionic puts it in unistd.h unconditionally and
	glibc hides it behind _GNU_SOURCE. The declaration is the same either way. */
extern char **environ;

/*	The machine, in the two forms the ELF file names it and one for the message when they disagree. */
#if defined(__aarch64__)
#	define A2_MACHINE EM_AARCH64
#	define A2_MACHINE_NAME "AArch64"
#	define A2_ABS64 R_AARCH64_ABS64
#elif defined(__x86_64__)
#	define A2_MACHINE EM_X86_64
#	define A2_MACHINE_NAME "x86-64"
#	define A2_ABS64 R_X86_64_64
#else
#	error a2boot has no idea what an image for this machine looks like
#endif

static void Fail(const char *what) {
	fprintf(stderr, "a2boot: %s: %s\n", what, strerror(errno));
	exit(1);
}

static void Refuse(const char *what) {
	fprintf(stderr, "a2boot: %s\n", what);
	exit(1);
}

/*	Read the whole file: it is under two megabytes, and having it in memory keeps the parsing free
 *	of second thoughts about what is mapped and what is not. */
static unsigned char *ReadFile(const char *path, size_t *size) {
	int fd = open(path, O_RDONLY);
	struct stat st;
	unsigned char *buffer;
	if (fd < 0) Fail(path);
	if (fstat(fd, &st) < 0) Fail(path);
	buffer = malloc((size_t)st.st_size);
	if (buffer == NULL) Refuse("out of memory reading the image");
	if (read(fd, buffer, (size_t)st.st_size) != (ssize_t)st.st_size) Fail(path);
	close(fd);
	*size = (size_t)st.st_size;
	return buffer;
}

/*	Bionic decides which namespace a `dlopen` refers to by looking at the address of whoever called
 *	it, and the image is in an anonymous mapping that the linker knows nothing about: asked from
 *	there, even `libc.so` is not found. So every dl* call is routed back through this file, where the
 *	return address is inside a real executable and the question has an answer. The image asks for
 *	`dlopen`, `dlclose` and `exit` through `dlsym`, and `dlsym` is the one symbol it is given -- so
 *	handing it this one is enough to catch all of them. */
static void *BootDlopen(const char *path, int mode) { return dlopen(path, mode); }
static void BootDlclose(void *handle) { dlclose(handle); }

static void *BootDlsym(void *handle, const char *name) {
	if (strcmp(name, "dlopen") == 0) return (void *)BootDlopen;
	if (strcmp(name, "dlclose") == 0) return (void *)BootDlclose;
	if (strcmp(name, "dlsym") == 0) return (void *)BootDlsym;
	return dlsym(handle, name);
}

/*	One entry of the dynamic section, by tag. */
static Elf64_Xword Dynamic(const Elf64_Dyn *dynamic, Elf64_Sxword tag) {
	for (; dynamic->d_tag != DT_NULL; dynamic++)
		if (dynamic->d_tag == tag) return dynamic->d_un.d_val;
	return 0;
}

int main(int argc, char **argv) {
	size_t size, span;
	unsigned char *file;
	Elf64_Ehdr *header;
	Elf64_Phdr *segments, *load = NULL, *dynamicSegment = NULL;
	void *mapped;
	unsigned long long *block;
	char **arguments;
	char beside[4096];
	const char *image;
	int i, passed;

	/*	Installed as `oberon` with `oberon.img` beside it, everything that starts A2 goes on working
	 *	untouched, which is the point: the harness and `ob` need not know that Android takes a
	 *	different road into the same image. */
	image = getenv("A2_IMAGE");
	arguments = argv; passed = argc;
	if (image == NULL) {
		ssize_t length = readlink("/proc/self/exe", beside, sizeof(beside) - 5);
		if (length > 0) {
			memcpy(beside + length, ".img", 5);
			if (access(beside, R_OK) == 0) image = beside;
		}
	}
	if (image == NULL) {
		if (argc < 2) Refuse("usage: a2boot <image> [arguments ...] (or install as <name> with <name>.img beside it)");
		image = argv[1]; arguments = argv + 1; passed = argc - 1;
	}
	/*	Android hands out heap memory with a tag in the top byte of the pointer, and the A2 collector
	 *	is not written for that: it takes the address of a block as a number, derives the bounds of
	 *	the heap from it and decides what is a pointer into the heap by comparison, so a tag that
	 *	differs between the block and what is compared against it makes live objects invisible. What
	 *	that looks like is a collection that quietly frees something still in use -- a line printed
	 *	twice, a byte of rubbish, and then a fault somewhere else entirely.
	 *
	 *	Turned off for this process rather than worked around in the collector: masking the top byte
	 *	everywhere an address is compared would be a change spread over the heap, the barriers and the
	 *	loader, all to give up a check that costs us nothing to keep switched off. Tagging is a
	 *	debugging aid for C, and this process has no C to debug.
	 *
	 *	Only Bionic has the call, and only on AArch64 is there anything for it to switch off; the
	 *	glibc and x86-64 builds simply have no tagging to begin with. */
#if defined(__BIONIC__) && defined(M_BIONIC_SET_HEAP_TAGGING_LEVEL)
	if (mallopt(M_BIONIC_SET_HEAP_TAGGING_LEVEL, M_HEAP_TAGGING_LEVEL_NONE) == 0)
		fprintf(stderr, "a2boot: could not turn off heap pointer tagging; the collector may lose objects\n");
#endif

	file = ReadFile(image, &size);
	if (size < sizeof(Elf64_Ehdr) || memcmp(file, ELFMAG, SELFMAG) != 0) Refuse("the image is not an ELF file");
	header = (Elf64_Ehdr *)file;
	if (header->e_machine != A2_MACHINE) Refuse("not an " A2_MACHINE_NAME " image");
	segments = (Elf64_Phdr *)(file + header->e_phoff);
	for (i = 0; i < header->e_phnum; i++) {
		if (segments[i].p_type == PT_LOAD && load == NULL) load = &segments[i];
		if (segments[i].p_type == PT_DYNAMIC) dynamicSegment = &segments[i];
	}
	if (load == NULL) Refuse("the image has no loadable segment");

	/*	Mapped anonymous and copied into rather than mapped from the file: the segment is writable
	 *	and executable at once, which is what the image was linked as, and an anonymous mapping is
	 *	the one form of that Android's policy allows an ordinary process -- the same permission its
	 *	own module loader needs, since that writes code into the heap and calls it. MAP_FIXED and not
	 *	MAP_FIXED_NOREPLACE would be a way to lose whatever else lives there, so the address is asked
	 *	for and then checked. */
	span = (size_t)(load->p_vaddr + load->p_memsz);
	span = (span + 0xFFF) & ~(size_t)0xFFF;
	span -= (size_t)(load->p_vaddr & ~(Elf64_Addr)0xFFF);
	mapped = mmap((void *)(load->p_vaddr & ~(Elf64_Addr)0xFFF), span,
		PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
	if (mapped == MAP_FAILED) Fail("mapping the image where it was linked for");
	if (mapped != (void *)(load->p_vaddr & ~(Elf64_Addr)0xFFF))
		Refuse("the address the image was linked for is taken");
	memcpy((void *)load->p_vaddr, file + load->p_offset, (size_t)load->p_filesz);

	/*	The relocations. An A2 image carries one -- `dlsym` -- but the loop is general, because a
	 *	general loop is no longer than a special case and says what it does. */
	if (dynamicSegment != NULL) {
		const Elf64_Dyn *dynamic = (const Elf64_Dyn *)dynamicSegment->p_vaddr;
		const Elf64_Rela *relocations = (const Elf64_Rela *)Dynamic(dynamic, DT_RELA);
		Elf64_Xword bytes = Dynamic(dynamic, DT_RELASZ);
		const Elf64_Sym *symbols = (const Elf64_Sym *)Dynamic(dynamic, DT_SYMTAB);
		const char *strings = (const char *)Dynamic(dynamic, DT_STRTAB);
		Elf64_Xword at;
		for (at = 0; relocations != NULL && at + sizeof(Elf64_Rela) <= bytes; at += sizeof(Elf64_Rela)) {
			const Elf64_Rela *relocation = (const Elf64_Rela *)((const char *)relocations + at);
			const char *name = strings + symbols[ELF64_R_SYM(relocation->r_info)].st_name;
			void *value;
			if (ELF64_R_TYPE(relocation->r_info) != A2_ABS64) {
				fprintf(stderr, "a2boot: relocation type %lu for %s is not one this understands\n",
					(unsigned long)ELF64_R_TYPE(relocation->r_info), name);
				exit(1);
			}
			value = strcmp(name, "dlsym") == 0 ? (void *)BootDlsym : dlsym(RTLD_DEFAULT, name);
			if (value == NULL) {
				fprintf(stderr, "a2boot: the image wants %s and nothing here has it\n", name);
				exit(1);
			}
			*(void **)relocation->r_offset = (char *)value + relocation->r_addend;
		}
	}

	/*	The stack the entry point reads: argc, the arguments, a null, the environment, a null --
	 *	the layout the kernel leaves behind, which is what Linux.Glue.Mod's {OPENING} procedure walks
	 *	(it takes argc from sp and the environment from sp + 16 + argc * 8). It sits at the top of a
	 *	region of its own, because the system goes on using the stack below it for its main thread.
	 *	The image's own name is argument zero, so what A2 sees is what it would see if Bionic had
	 *	started it. */
	{
		unsigned long long *slot;
		int environmentCount = 0;
		while (environ[environmentCount] != NULL) environmentCount++;
		/*	argc, the arguments, a null, the environment, a null -- built on the stack this process
		 *	already has rather than on one of our own.
		 *
		 *	A stack of our own was the first thing tried and it is wrong, quietly: the system asks the
		 *	C library where the main thread's stack lies -- the collector has to know, it walks it --
		 *	and the answer describes the real one, whatever we happen to be running on. Anything below
		 *	that answer is then scanned as if it held stack, and the first collection walks into
		 *	nothing. On the real stack the two agree by construction. Nothing here returns, so the
		 *	frame this sits in is free to be overwritten. */
		block = (unsigned long long *)alloca((size_t)(passed + environmentCount + 3) * 8 + 16);
		block = (unsigned long long *)((unsigned long long)block & ~15ull);
		slot = block;
		*slot++ = (unsigned long long)passed;
		for (i = 0; i < passed; i++) *slot++ = (unsigned long long)arguments[i];
		*slot++ = 0;
		for (i = 0; i < environmentCount; i++) *slot++ = (unsigned long long)environ[i];
		*slot++ = 0;
	}

	/*	Into the image: the stack pointer at the block just built and a branch that does not return. */
#if defined(__aarch64__)
	__asm__ volatile(
		"mov sp, %0\n\t"
		"br %1\n\t"
		:: "r"(block), "r"(header->e_entry) : "memory");
#else
	__asm__ volatile(
		"movq %0, %%rsp\n\t"
		"jmpq *%1\n\t"
		:: "r"(block), "r"((unsigned long long)header->e_entry) : "memory");
#endif
	return 0;										/* not reached */
}
