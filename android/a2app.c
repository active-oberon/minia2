/*	a2app -- A2 as an Android application: a NativeActivity that brings the system up and owns a
 *	window.
 *
 *	This is the spike for the second half of the Android port. The first half -- A2 running natively
 *	on Bionic -- is done and its way into the image is android/a2boot.c, which this shares. What is
 *	new here is everything an application has that a command does not, and the questions worth
 *	answering are about the entry rather than about the pixels:
 *
 *	  - A command is entered from main. An application is entered from ANativeActivity_onCreate,
 *	    which the framework calls on a thread it owns and expects back: that thread runs the looper
 *	    delivering the window and the input. A2 takes the stack it is entered on and never returns.
 *	    So the system goes on a thread of our own -- EnterOnOwnThread -- and onCreate returns
 *	    promptly, which is the arrangement this file exists to test.
 *	  - The collector walks stacks, and the bottom of the one it starts on comes from the address of
 *	    a local in the image's own entry procedure. On a thread of our own that describes that
 *	    thread, which is right by construction; the same arrangement passes the collector stress and
 *	    the whole check set from a terminal, so this file is not where that is first tried.
 *	  - An application has no standard output. A2 writes its transcript to file descriptor 1, which
 *	    in an application goes nowhere at all, so the two descriptors are turned into a pipe and
 *	    pumped into the log -- otherwise the first failure here is a process that dies in silence.
 *	  - The payload has to be somewhere the application can read. /data/local/tmp, where the command
 *	    lives, belongs to the shell user and an application cannot read it; so the image travels in
 *	    the package as an asset and is unpacked once into the application's own directory.
 *
 *	What is on the screen is A2's own doing now, and so is what it does when touched:
 *	source/AndroidDisplay.Mod registers a display over this window, source/AndroidInput.Mod turns the
 *	touches below into A2's mouse, and source/DisplayDemo.Mod draws through the one and reacts to the
 *	other. None of the three is in the image -- they travel as object files and are loaded when the
 *	window arrives, which is also the first thing in this port to need dynamic loading for something
 *	other than testing it. The window stays here, behind the four procedures further down, and so do the
 *	touches, in a ring: both for the same reason, which is that the framework's threads are not A2's.
 *
 *	Build: see android/build-apk.sh.
 */

#include <android/asset_manager.h>
#include <android/configuration.h>
#include <android/log.h>
#include <android/native_activity.h>
#include <android/input.h>
#include <android/keycodes.h>
#include <android/looper.h>
#include <android/native_window.h>
#include <jni.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "a2boot.h"

#define TAG "A2"
#define Log(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define Complain(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

/*	A2's transcript, which would otherwise be written to a descriptor going nowhere, pumped line by
 *	line into the log. Both descriptors, because traps come out on the second one. */
static void *Pump(void *readEnd) {
	char line[512];
	size_t filled = 0;
	int fd = (int)(long)readEnd;
	for (;;) {
		char c;
		ssize_t got = read(fd, &c, 1);
		if (got <= 0) break;
		if (c == '\n' || filled == sizeof(line) - 1) {
			line[filled] = 0;
			if (filled > 0) Log("%s", line);
			filled = 0;
		} else if (c != '\r') {
			line[filled++] = c;
		}
	}
	return NULL;
}

static void LogTheTranscript(void) {
	int ends[2];
	pthread_t pump;
	if (pipe(ends) != 0) { Complain("no pipe for the transcript: %s", strerror(errno)); return; }
	dup2(ends[1], 1);
	dup2(ends[1], 2);
	close(ends[1]);
	setvbuf(stdout, NULL, _IOLBF, 0);
	pthread_create(&pump, NULL, Pump, (void *)(long)ends[0]);
	pthread_detach(pump);
}

/*	One asset out of the package and into a file, if it is not there already. The image is a couple
 *	of megabytes and the copy costs a moment; doing it once and answering the path afterwards keeps
 *	starting the application quick. */
static int Unpack(AAssetManager *assets, const char *name, const char *directory, char *path, size_t room) {
	AAsset *asset;
	FILE *out;
	char buffer[64 * 1024];
	int read;
	struct stat existing;

	snprintf(path, room, "%s/%s", directory, name);
	asset = AAssetManager_open(assets, name, AASSET_MODE_STREAMING);
	if (asset == NULL) { Complain("the package has no asset %s", name); return 0; }
	if (stat(path, &existing) == 0 && existing.st_size == AAsset_getLength(asset)) {
		AAsset_close(asset);
		return 1;										/* unpacked by an earlier run */
	}
	out = fopen(path, "wb");
	if (out == NULL) { Complain("cannot write %s: %s", path, strerror(errno)); AAsset_close(asset); return 0; }
	while ((read = AAsset_read(asset, buffer, sizeof(buffer))) > 0) {
		if (fwrite(buffer, 1, (size_t)read, out) != (size_t)read) {
			Complain("cannot write %s: %s", path, strerror(errno));
			fclose(out); AAsset_close(asset); return 0;
		}
	}
	fclose(out);
	AAsset_close(asset);
	Log("unpacked %s", path);
	return 1;
}

/*	Everything else in the package, beside the image: the object files of the display driver and of
 *	what draws through it. They are not in the image -- the image is the same one the command line
 *	bundle uses, 32 modules and nothing graphical -- so they are loaded at run time, which is a thing
 *	this port only gained a few days ago and is worth exercising in the application too. */
static int UnpackTheRest(AAssetManager *assets, const char *directory) {
	AAssetDir *listing = AAssetManager_openDir(assets, "");
	const char *name;
	char path[4096];
	int unpacked = 0;
	if (listing == NULL) { Complain("the package has no assets to list"); return 0; }
	while ((name = AAssetDir_getNextFileName(listing)) != NULL) {
		/*	Object files and nothing else: an application's asset manager lists more than the package
			put in it, and the first run of this unpacked a megabyte of somebody's machine learning
			model for no reason at all. */
		const char *dot = strrchr(name, '.');
		if (dot == NULL || strcmp(dot, ".GofU8") != 0) continue;
		if (Unpack(assets, name, directory, path, sizeof(path))) unpacked++;
	}
	AAssetDir_close(listing);
	return unpacked;
}

/*	Who owns which signal, before and after A2 comes up.
 *
 *	An application is not a bare process. The Android runtime is in it whether or not the application
 *	has a line of Java -- the activity being started here is one of its classes -- and that runtime
 *	uses signals for its own work: SIGSEGV, because it turns null dereferences into exceptions by
 *	catching the fault; SIGQUIT for its thread dumps; SIGUSR1 and the first real-time signals for its
 *	collector and its profiler. A2 uses signals too: SIGSEGV and the rest to report a trap, SIGUSR1
 *	and SIGUSR2 to stop and start its own threads while it collects. Both install their handlers with
 *	sigaction, and the second one to do it wins for the whole process, including threads belonging to
 *	the first.
 *
 *	So this prints the table twice, and the difference is the answer. */
static void Handlers(const char *when) {
	static const int signals[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGQUIT, SIGUSR1, SIGUSR2, SIGTRAP };
	static const char *const names[] = { "SEGV", "BUS", "ILL", "FPE", "QUIT", "USR1", "USR2", "TRAP" };
	size_t i;
	for (i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
		struct sigaction current;
		if (sigaction(signals[i], NULL, &current) != 0) continue;
		Log("%s: SIG%-4s handler %p flags 0x%x", when, names[i],
			(current.sa_flags & SA_SIGINFO) ? (void *)current.sa_sigaction : (void *)current.sa_handler,
			(unsigned)current.sa_flags);
	}
}

static void Tell(const char *command);

/*	Two seconds in: the same table again, and then a few things asked of the system, so that the log
 *	says whether it is alive rather than merely started. The collector is asked for five times over,
 *	because repeated collections with nothing else going on is the shape that failed on Bionic before
 *	the wait in Objects.Await was fixed, and a new kind of process deserves the same question. */
static void *LookAgain(void *unused) {
	(void)unused;
	sleep(2);
	Handlers("after A2");
	Tell("System.Time");
	Tell("Kernel.GC"); Tell("Kernel.GC"); Tell("Kernel.GC"); Tell("Kernel.GC"); Tell("Kernel.GC");
	Tell("System.Time");
	return NULL;
}

/*	The system, started once and left running for as long as the process lives. Deliberately not tied
 *	to the activity's lifetime: A2 has no notion of being destroyed and recreated, and an Android
 *	activity is destroyed and recreated for something as ordinary as a rotation. What the window
 *	backend will have to survive is exactly that, which is why the window is kept separately below. */
static char imagePath[4096];
static char searchPath[4096];					/* the command that puts the unpacked objects on A2's path */
static pthread_t systemThread;
static int systemStarted = 0;

/*	A2 is started as the shell, with a pipe for its standard input which this end keeps open.
 *
 *	Not as `oberon do <commands>`, which was the first thing tried: that runs the commands and then
 *	ends the process, and in an application ending the process takes the window and the activity with
 *	it -- the application vanishes from the screen a fraction of a second after it appears, which
 *	looks like a crash and is not one. The shell, on the other hand, wants a standard input, and an
 *	application has none: given end-of-file it spins rather than stopping.
 *
 *	A pipe answers both. The shell blocks on it instead of spinning, the system stays up for as long
 *	as the application does, and the write end is a handle to drive it with -- which is what Tell
 *	below is, and what the window will eventually replace. */
static int toTheShell = -1;

static void Tell(const char *command) {
	if (toTheShell < 0) return;
	write(toTheShell, command, strlen(command));
	write(toTheShell, "\n", 1);
}

static void *RunTheSystem(void *unused) {
	static char name[] = "oberon";
	char *arguments[1];
	Elf64_Addr entry;
	int ends[2];
	(void)unused;
	arguments[0] = name;
	if (pipe(ends) == 0) {
		dup2(ends[0], 0);
		close(ends[0]);
		toTheShell = ends[1];
	} else {
		Complain("no pipe for the shell's input: %s", strerror(errno));
	}
	Log("loading %s", imagePath);
	entry = A2Load(imagePath);
	Log("entering the image at %p", (void *)(long)entry);
	Enter(1, arguments, entry);						/* this thread is now A2's, and does not return */
	return NULL;
}

static void StartTheSystem(ANativeActivity *activity) {
	char directory[3072];
	if (systemStarted) return;
	snprintf(directory, sizeof(directory), "%s", activity->internalDataPath);
	mkdir(directory, 0700);
	if (!Unpack(activity->assetManager, "oberon.img", directory, imagePath, sizeof(imagePath))) return;
	Log("unpacked %d more file(s) beside it", UnpackTheRest(activity->assetManager, directory));
	snprintf(searchPath, sizeof(searchPath), "Files.AddSearchPath %s", directory);
	if (pthread_create(&systemThread, NULL, RunTheSystem, NULL) != 0) {
		Complain("cannot start the thread to run A2 on: %s", strerror(errno));
		return;
	}
	pthread_detach(systemThread);
	systemStarted = 1;
}

/*	The window, and the three procedures A2 sees it through.
 *
 *	The window belongs to this file and its lifetime stays here. A2's display driver
 *	(source/AndroidDisplay.Mod) finds these by name with dlsym and knows nothing about
 *	ANativeWindow -- deliberately, and not to save it the trouble: the framework destroys a window on
 *	a thread of its own, so any arrangement where A2 held the pointer itself would be a race between
 *	its next frame and onNativeWindowDestroyed. Here the mutex that a lock takes is the one the
 *	destroy waits on, and a frame is over in milliseconds.
 *
 *	Everything is out-parameters and plain integers, so that nothing on the A2 side has to agree with
 *	a struct layout of the NDK's -- the shape of struct sigaction has already cost this port a day.
 *	The stride is in pixels, as the surface reports it. */
static ANativeWindow *theWindow;
static pthread_mutex_t windowMutex = PTHREAD_MUTEX_INITIALIZER;
static int windowLocked;

/*	Which window this is, counted up whenever a new one arrives.
 *
 *	A driver that sends only what changed needs to know when nothing it has sent is there any more,
 *	and the buffers alone do not say so: the surface of a window this process has drawn into before
 *	carries that content over into the buffer it hands out, so a new window comes back with a small
 *	region to write and the last thing painted still in it -- which is how the gradient below reappeared
 *	under A2's picture, with only the path of a moving box patched over it. So A2 reads this, and repaints
 *	the lot when it changes. */
static int windowGeneration;

int A2WindowGeneration(void) {
	return windowGeneration;
}

int A2WindowSize(int32_t *width, int32_t *height) {
	int answered = 0;
	pthread_mutex_lock(&windowMutex);
	if (theWindow != NULL) {
		if (width != NULL) *width = ANativeWindow_getWidth(theWindow);
		if (height != NULL) *height = ANativeWindow_getHeight(theWindow);
		answered = 1;
	}
	pthread_mutex_unlock(&windowMutex);
	return answered;
}

/*	Holds the mutex when it answers 1, until A2WindowUnlockAndPost releases it.
 *
 *	The rectangle goes in and comes back out, because that is how the surface works: given a region a
 *	caller means to write, it copies the rest from what was posted before -- and if it cannot, it says
 *	so by widening the region it hands back. So the answer is the region that MUST be written, and A2
 *	writes exactly that. Passing the whole buffer every time is the same call with the region set to
 *	the whole buffer, which is what the first frame does.
 *
 *	Named ...Region rather than keeping the old name for a shorter diff: an application built before
 *	this change has the four-argument version, and a dlsym for a name that is not there answers NIL
 *	and reports no window -- where the same name with a different shape would read four words of the
 *	stack as a rectangle and paint an arbitrary part of the screen. */
int A2WindowLockRegion(void **bits, int32_t *width, int32_t *height, int32_t *stride, int32_t *format,
		int32_t *left, int32_t *top, int32_t *right, int32_t *bottom) {
	ANativeWindow_Buffer buffer;
	ARect region;
	region.left = *left; region.top = *top; region.right = *right; region.bottom = *bottom;
	pthread_mutex_lock(&windowMutex);
	if (theWindow == NULL || ANativeWindow_lock(theWindow, &buffer, &region) != 0) {
		pthread_mutex_unlock(&windowMutex);
		return 0;
	}
	windowLocked = 1;
	*bits = buffer.bits;
	*width = buffer.width; *height = buffer.height; *stride = buffer.stride;
	/*	The format is answered rather than assumed, because a window does not have to give what it was
		asked for: the second window of this application came back as RGB_565 -- half the bytes per
		pixel -- and writing four bytes each ran off the end of it at exactly half the height. It is
		asked for RGBX_8888 in Configure below; this is so that A2 can refuse instead of trusting. */
	*format = buffer.format;
	*left = region.left; *top = region.top; *right = region.right; *bottom = region.bottom;
	return 1;
}

void A2WindowUnlockAndPost(void) {
	if (!windowLocked) return;							/* only ever called by the thread that locked */
	ANativeWindow_unlockAndPost(theWindow);
	windowLocked = 0;
	pthread_mutex_unlock(&windowMutex);
}

static ANativeActivity *theActivity;		/* set in onCreate; the density needs it, and so does input */

/*	How dense the screen is, in dots to the inch, or 0 if the platform will not say.
 *
 *	A2's display driver has always had a field for the size of a pixel and the phone has always had to
 *	make one up -- a constant standing for "a dense screen". That was affordable while nothing read it.
 *	It is not affordable now: WindowManager zooms the whole view by that number (see ZoomForUnit), so
 *	what used to be a comment is the difference between a system laid out for this screen and one laid
 *	out for a screen nobody has.
 *
 *	This is the density Android itself lays out by -- the one behind dp, which is why a title bar in an
 *	ordinary application is the size it is -- and taking it from here rather than measuring the glass is
 *	deliberate: it is a bucket, near enough the truth and rounded the way every other application on the
 *	phone rounds it, and the NDK has no way to ask for the physical size at all (DisplayMetrics.xdpi is
 *	Java's, and reaching it means JNI on a thread that would have to be attached).
 *
 *	The configuration is read fresh each time rather than kept: it is asked once, when the display is
 *	installed, and a copy held across a configuration change would be the stale one. */
int A2WindowDensityDpi(void) {
	AConfiguration *configuration;
	int32_t density;
	if (theActivity == NULL) return 0;
	configuration = AConfiguration_new();
	if (configuration == NULL) return 0;
	AConfiguration_fromAssetManager(configuration, theActivity->assetManager);
	density = AConfiguration_getDensity(configuration);
	AConfiguration_delete(configuration);
	/*	The two values that are not a density and the one that means "not stated". Anything outside what a
		screen can be is refused here rather than turned into a zoom on the other side of dlsym. */
	if (density == ACONFIGURATION_DENSITY_DEFAULT || density == ACONFIGURATION_DENSITY_ANY
			|| density == ACONFIGURATION_DENSITY_NONE || density < 60 || density > 1200)
		return 0;
	return (int)density;
}

/*	Filled from here once, in a gradient, before A2 is told about the window: a picture on the screen
 *	then means the process holds a surface, which is what it meant when this file was a spike, and it
 *	is also what tells the two apart -- what A2 draws is the Mandelbrot set. */
/*	What every window is asked for, whether or not anything here draws in it: four bytes a pixel, and
 *	the size the window already has. Asking belongs to the window arriving and not to the first paint --
 *	which is where it was, inside Fill, until Fill stopped being called for every window and the next
 *	window quietly came back as RGB_565 with A2 writing 32 bit pixels into it. */
static void Configure(ANativeWindow *window) {
	if (window == NULL) return;
	if (ANativeWindow_setBuffersGeometry(window, 0, 0, WINDOW_FORMAT_RGBX_8888) != 0)
		Complain("the window would not take the format asked for");
}

static void Fill(ANativeWindow *window) {
	ANativeWindow_Buffer buffer;
	int y, x;
	if (window == NULL) return;
	if (ANativeWindow_lock(window, &buffer, NULL) != 0) {
		Complain("cannot lock the window");
		return;
	}
	for (y = 0; y < buffer.height; y++) {
		uint32_t *row = (uint32_t *)buffer.bits + (size_t)y * buffer.stride;
		for (x = 0; x < buffer.width; x++) {
			/*	A gradient rather than a flat colour: a flat one is what a failed lock leaves behind
				too, and the two should not look alike. */
			unsigned r = (unsigned)(255 * x / (buffer.width ? buffer.width : 1));
			unsigned g = (unsigned)(255 * y / (buffer.height ? buffer.height : 1));
			row[x] = 0xFF000000u | (r << 16) | (g << 8) | 0x40u;
		}
	}
	ANativeWindow_unlockAndPost(window);
	Log("window filled: %d x %d, stride %d, format %d",
		buffer.width, buffer.height, buffer.stride, buffer.format);
}

/*	The system is told about the window once, and from then on it owns the picture. The commands go
 *	down the same pipe everything else does: the objects were unpacked beside the image, so naming a
 *	module is enough to have it loaded -- there is nothing of the display in the image itself.
 *
 *	What comes up is A2's own window manager and not the demo that came before it. The difference is
 *	the whole point of this step: DisplayDemo owns the frame buffer and draws on it, which proves a
 *	display driver and nothing else, while WindowManager brings a background, a window with
 *	decoration, an event loop and a hit-testing chain -- so a finger dragging the window by its title
 *	bar is A2 doing it, through the same Inputs messages a mouse would send. Both are in the package;
 *	the demo is a command away for anyone with the pipe, and this is what the screen shows.
 *
 *	Order matters and is not arbitrary: the manager waits for a display (Displays.registry.Await) and
 *	reads its size once, so the driver has to be registered first. Which also says what rotation does
 *	to it -- the driver follows the window round, the manager does not know the display can change
 *	shape, and there is no event in Displays for it to hear. That is the next thing here. */
static int displayTold;

static void TellAboutTheWindow(void) {
	if (!displayTold) {
		displayTold = 1;
		Tell(searchPath);
		Tell("AndroidDisplay.Install");
		Tell("AndroidInput.Install");
		Tell("WindowManager.Install");
	}
	/*	Every window, not only the first. The display and the manager are installed once and go on
		living across windows, but the demo window can be closed -- it has a close button, and a finger
		finds it -- and then there is a desktop with nothing on it and no way back short of stopping the
		process. Open answers "already open" and does nothing when it is still there, so this costs a
		line in the log and nothing else. */
	Tell("WMDemo.Open");
	/*	And the keyboard, because nothing in A2 knows to ask for one: on every machine A2 has ever run
		on, the keyboard was simply there. Raised from A2's side rather than from here, so that it is a
		command the system owns and can send away again. */
	Tell("AndroidInput.ShowKeyboard");
}

static void OnWindowCreated(ANativeActivity *activity, ANativeWindow *window) {
	(void)activity;
	Log("window created");
	Configure(window);
	/*	The gradient only until A2 has a picture of its own. Painting it into every window would put it
		back underneath A2's next frame, which is what happened the first time this was tried. */
	if (!displayTold) Fill(window);					/* before A2 can see it, so the two never race */
	pthread_mutex_lock(&windowMutex);
	theWindow = window;
	windowGeneration++;
	pthread_mutex_unlock(&windowMutex);
	TellAboutTheWindow();
}

static void OnWindowDestroyed(ANativeActivity *activity, ANativeWindow *window) {
	(void)activity; (void)window;
	/*	Taken away under the mutex, which is what makes this safe: a frame in flight on A2's thread
		holds it, so this waits for that frame instead of pulling the buffer out from under it. */
	pthread_mutex_lock(&windowMutex);
	theWindow = NULL;
	pthread_mutex_unlock(&windowMutex);
	Log("window destroyed");
}

static void OnWindowRedraw(ANativeActivity *activity, ANativeWindow *window) {
	(void)activity;
	/*	Once A2 has the window, redrawing is its business: its next frame is the answer, and filling
		from here would fight it for the surface. */
	if (displayTold) return;
	Fill(window);
}

/*	Input, which is here for one reason before it is here for any other: without it there is no way
 *	out of the application.
 *
 *	A NativeActivity is handed its events through a queue, and a queue nobody attaches to a looper
 *	delivers nothing -- including the back key, so the first version of this file could be started
 *	and then only killed, which is how it was found. Attached to the looper of the thread the
 *	framework calls us on, so the callback below runs there and may touch the activity.
 *
 *	Every event is finished, whether or not it was understood: an event left unfinished stops the
 *	queue. Back ends the activity, which is what a person expects of it; the system in this process
 *	goes on running, having no notion of an activity at all. */

/*	Touches, on their way to A2.
 *
 *	They arrive on the looper's thread, which is the framework's and not one of A2's, and that settles
 *	the shape of this: nothing here calls into A2. A2 has a collector that walks its own threads' stacks
 *	and monitors that only its own processes may hold, so an event delivered by calling an A2 procedure
 *	from this thread would be the same class of mistake as letting A2 report ART's faults. So the events
 *	are put in a ring here and A2 takes them out on a thread of its own (source/AndroidInput.Mod).
 *
 *	Three kinds and one finger. A mouse has one position, and A2's Inputs has no notion of a second
 *	pointer, so the first finger down is the one that counts and the rest are ignored -- honest for a
 *	system whose input model is a mouse, and a place to grow when there is something that wants gestures.
 *
 *	A ring rather than a queue that grows: input that cannot be kept up with has to be dropped
 *	somewhere, and dropping the oldest position of a finger that has since moved is the least harmful
 *	thing to drop. It is counted and reported once, because a silent drop would show up as a system that
 *	feels stiff and gives no reason. */
#define TouchRoom 64
#define TouchDown 0
#define TouchMove 1
#define TouchUp 2
#define KeyStroke 3

/*	Three numbers beside the kind, because a key needs three and a touch needs two: for a touch they
	are x and y, for a key the character, the keysym and the modifiers. One ring for both, in order,
	which is not tidiness -- a key that overtook the tap that put the caret where it goes would be
	typed in the wrong place. */
static struct { int32_t what, a, b, c; } touches[TouchRoom];
static int touchIn, touchOut, touchDropped;
static pthread_mutex_t touchMutex = PTHREAD_MUTEX_INITIALIZER;

static void Remember(int32_t what, int32_t a, int32_t b, int32_t c) {
	pthread_mutex_lock(&touchMutex);
	if ((touchIn + 1) % TouchRoom == touchOut) {
		touchOut = (touchOut + 1) % TouchRoom;			/* the oldest goes */
		if (touchDropped++ == 0) Log("input: the ring was full, dropping the oldest event");
	}
	touches[touchIn].what = what;
	touches[touchIn].a = a; touches[touchIn].b = b; touches[touchIn].c = c;
	touchIn = (touchIn + 1) % TouchRoom;
	pthread_mutex_unlock(&touchMutex);
}

/*	The next event, or 0 when there is none. Called by A2, from a thread of its own. */
int A2InputNext(int32_t *what, int32_t *a, int32_t *b, int32_t *c) {
	int answered = 0;
	pthread_mutex_lock(&touchMutex);
	if (touchIn != touchOut) {
		*what = touches[touchOut].what;
		*a = touches[touchOut].a; *b = touches[touchOut].b; *c = touches[touchOut].c;
		touchOut = (touchOut + 1) % TouchRoom;
		answered = 1;
	}
	pthread_mutex_unlock(&touchMutex);
	return answered;
}

static void TakeMotion(AInputEvent *event) {
	int32_t action = AMotionEvent_getAction(event);
	int32_t x = (int32_t)AMotionEvent_getX(event, 0);
	int32_t y = (int32_t)AMotionEvent_getY(event, 0);
	switch (action & AMOTION_EVENT_ACTION_MASK) {
		case AMOTION_EVENT_ACTION_DOWN: Remember(TouchDown, x, y, 0); break;
		case AMOTION_EVENT_ACTION_MOVE: Remember(TouchMove, x, y, 0); break;
		case AMOTION_EVENT_ACTION_UP:
		case AMOTION_EVENT_ACTION_CANCEL: Remember(TouchUp, x, y, 0); break;
		default: break;									/* the other fingers, and what they do */
	}
}

/*	Keys, and the one place where Android's vocabulary has to be translated rather than passed on.
 *
 *	A key event from the NDK carries a key CODE and a meta state -- not a character. The character is
 *	the business of a KeyCharacterMap, which lives in Java, and this application has no Java in it. So
 *	the table below is that map, for the keys a program is written with: letters, digits, punctuation,
 *	and the dozen keys that move a caret. It is deliberately here and not in A2 -- what a key means is
 *	Android's question, and the answer A2 gets is the one it already understands from X11: a character,
 *	an X11 keysym, and modifiers.
 *
 *	Which is why the keysym of a printable key is the character itself: X11 numbers Latin-1 that way,
 *	and Unix.KbdMouse.Mod hands A2 exactly the same thing.
 *
 *	What this does not do is international text. A soft keyboard that composes -- accents, any script
 *	that is not Latin, a prediction bar that commits a whole word -- talks to an InputConnection, which
 *	is Java, and none of it arrives here. For writing Active Oberon, whose source is ASCII, this is the
 *	whole of what is needed; for writing prose in Ukrainian it is not, and that is the day somebody
 *	writes the Java half. */
#define KsBackSpace 0xFF08
#define KsTab       0xFF09
#define KsReturn    0xFF0D
#define KsEscape    0xFF1B
#define KsDelete    0xFFFF
#define KsHome      0xFF50
#define KsLeft      0xFF51
#define KsUp        0xFF52
#define KsRight     0xFF53
#define KsDown      0xFF54
#define KsPageUp    0xFF55
#define KsPageDown  0xFF56
#define KsEnd       0xFF57
#define KsInsert    0xFF63
#define KsShiftL    0xFFE1
#define KsControlL  0xFFE3
#define KsAltL      0xFFE9

/*	Our own four bits for the modifiers, in place of Android's twenty: A2 knows shift, control, alt and
	meta, and the fifth bit says the key came up rather than went down. */
#define ModShift   0x01
#define ModCtrl    0x02
#define ModAlt     0x04
#define ModMeta    0x08
#define ModRelease 0x10

static const struct { int32_t code; int32_t plain, shifted; } printable[] = {
	{AKEYCODE_A,'a','A'}, {AKEYCODE_B,'b','B'}, {AKEYCODE_C,'c','C'}, {AKEYCODE_D,'d','D'},
	{AKEYCODE_E,'e','E'}, {AKEYCODE_F,'f','F'}, {AKEYCODE_G,'g','G'}, {AKEYCODE_H,'h','H'},
	{AKEYCODE_I,'i','I'}, {AKEYCODE_J,'j','J'}, {AKEYCODE_K,'k','K'}, {AKEYCODE_L,'l','L'},
	{AKEYCODE_M,'m','M'}, {AKEYCODE_N,'n','N'}, {AKEYCODE_O,'o','O'}, {AKEYCODE_P,'p','P'},
	{AKEYCODE_Q,'q','Q'}, {AKEYCODE_R,'r','R'}, {AKEYCODE_S,'s','S'}, {AKEYCODE_T,'t','T'},
	{AKEYCODE_U,'u','U'}, {AKEYCODE_V,'v','V'}, {AKEYCODE_W,'w','W'}, {AKEYCODE_X,'x','X'},
	{AKEYCODE_Y,'y','Y'}, {AKEYCODE_Z,'z','Z'},
	{AKEYCODE_0,'0',')'}, {AKEYCODE_1,'1','!'}, {AKEYCODE_2,'2','@'}, {AKEYCODE_3,'3','#'},
	{AKEYCODE_4,'4','$'}, {AKEYCODE_5,'5','%'}, {AKEYCODE_6,'6','^'}, {AKEYCODE_7,'7','&'},
	{AKEYCODE_8,'8','*'}, {AKEYCODE_9,'9','('},
	{AKEYCODE_SPACE,' ',' '}, {AKEYCODE_COMMA,',','<'}, {AKEYCODE_PERIOD,'.','>'},
	{AKEYCODE_MINUS,'-','_'}, {AKEYCODE_EQUALS,'=','+'}, {AKEYCODE_GRAVE,'`','~'},
	{AKEYCODE_LEFT_BRACKET,'[','{'}, {AKEYCODE_RIGHT_BRACKET,']','}'},
	{AKEYCODE_BACKSLASH,'\\','|'}, {AKEYCODE_SEMICOLON,';',':'},
	{AKEYCODE_APOSTROPHE,'\'','"'}, {AKEYCODE_SLASH,'/','?'},
	{AKEYCODE_AT,'@','@'}, {AKEYCODE_PLUS,'+','+'}, {AKEYCODE_STAR,'*','*'},
	{AKEYCODE_POUND,'#','#'},
	{AKEYCODE_NUMPAD_0,'0','0'}, {AKEYCODE_NUMPAD_1,'1','1'}, {AKEYCODE_NUMPAD_2,'2','2'},
	{AKEYCODE_NUMPAD_3,'3','3'}, {AKEYCODE_NUMPAD_4,'4','4'}, {AKEYCODE_NUMPAD_5,'5','5'},
	{AKEYCODE_NUMPAD_6,'6','6'}, {AKEYCODE_NUMPAD_7,'7','7'}, {AKEYCODE_NUMPAD_8,'8','8'},
	{AKEYCODE_NUMPAD_9,'9','9'},
};

static const struct { int32_t code; int32_t ch, keysym; } special[] = {
	{AKEYCODE_ENTER,          '\r', KsReturn},   {AKEYCODE_NUMPAD_ENTER, '\r', KsReturn},
	{AKEYCODE_TAB,            '\t', KsTab},
	{AKEYCODE_DEL,            '\b', KsBackSpace},
	{AKEYCODE_FORWARD_DEL,    0x7F, KsDelete},
	{AKEYCODE_ESCAPE,         0x1B, KsEscape},
	{AKEYCODE_DPAD_LEFT,      0, KsLeft},        {AKEYCODE_DPAD_RIGHT, 0, KsRight},
	{AKEYCODE_DPAD_UP,        0, KsUp},          {AKEYCODE_DPAD_DOWN,  0, KsDown},
	{AKEYCODE_MOVE_HOME,      0, KsHome},        {AKEYCODE_MOVE_END,   0, KsEnd},
	{AKEYCODE_PAGE_UP,        0, KsPageUp},      {AKEYCODE_PAGE_DOWN,  0, KsPageDown},
	{AKEYCODE_INSERT,         0, KsInsert},
	{AKEYCODE_SHIFT_LEFT,     0, KsShiftL},      {AKEYCODE_SHIFT_RIGHT, 0, KsShiftL},
	{AKEYCODE_CTRL_LEFT,      0, KsControlL},    {AKEYCODE_CTRL_RIGHT,  0, KsControlL},
	{AKEYCODE_ALT_LEFT,       0, KsAltL},        {AKEYCODE_ALT_RIGHT,   0, KsAltL},
};

static int32_t Modifiers(int32_t meta) {
	int32_t flags = 0;
	if (meta & (AMETA_SHIFT_ON | AMETA_CAPS_LOCK_ON)) flags |= ModShift;
	if (meta & AMETA_CTRL_ON) flags |= ModCtrl;
	if (meta & AMETA_ALT_ON) flags |= ModAlt;
	if (meta & AMETA_META_ON) flags |= ModMeta;
	return flags;
}

/*	Answers whether the key was one this knows; an unknown key is left to the framework, which is how
	volume and the rest go on working. */
static int TakeKey(AInputEvent *event) {
	int32_t code = AKeyEvent_getKeyCode(event);
	int32_t action = AKeyEvent_getAction(event);
	int32_t flags = Modifiers(AKeyEvent_getMetaState(event));
	int32_t ch = 0, keysym = 0;
	size_t i;
	if (action != AKEY_EVENT_ACTION_DOWN && action != AKEY_EVENT_ACTION_UP) return 0;
	for (i = 0; i < sizeof(printable) / sizeof(printable[0]); i++) {
		if (printable[i].code == code) {
			ch = (flags & ModShift) ? printable[i].shifted : printable[i].plain;
			keysym = ch;								/* X11 numbers Latin-1 as itself */
			break;
		}
	}
	if (keysym == 0) {
		for (i = 0; i < sizeof(special) / sizeof(special[0]); i++) {
			if (special[i].code == code) { ch = special[i].ch; keysym = special[i].keysym; break; }
		}
	}
	if (keysym == 0) return 0;
	/*	Control turns a letter into its control character, as every terminal has since teletypes: this
		is what makes Ctrl-C reach a program rather than typing a c. */
	if ((flags & ModCtrl) && ch >= 'a' && ch <= 'z') ch = ch - 'a' + 1;
	else if ((flags & ModCtrl) && ch >= 'A' && ch <= 'Z') ch = ch - 'A' + 1;
	if (action == AKEY_EVENT_ACTION_UP) flags |= ModRelease;
	Remember(KeyStroke, ch, keysym, flags);
	return 1;
}

/*	The soft keyboard, and the one place where "no Java" had to be read carefully.
 *
 *	`ANativeActivity_showSoftInput` is the NDK's answer and it does not work here. Asked implicitly,
 *	forced, from the window-created callback, from the focus callback, and with
 *	`stateAlwaysVisible` in the manifest -- `dumpsys input_method` said `mInputShown=false` every time,
 *	and nothing anywhere complained. The reason is not a bug: an input method opens for a view that can
 *	receive text, which means a view with an InputConnection, and a NativeActivity's view is a surface
 *	with no notion of text at all. The NDK call goes through the same path and is dropped by the same
 *	rule.
 *
 *	What works is asking InputMethodManager directly, which is a Java object -- reached from here
 *	through JNI, without a line of Java in the package. The distinction is worth keeping straight: this
 *	application has no classes of its own and no classes.dex, and calling the framework's own classes
 *	from C does not change that. `activity->vm` and `activity->clazz` are handed to us for exactly this.
 *
 *	The decor view is made focusable and asked for focus first, because showSoftInput opens for the
 *	view it is given and a view that cannot hold focus is not one of those. */
static int Keyboard(int show) {
	JavaVM *vm;
	JNIEnv *env = NULL;
	int attached = 0, answered = 0;
	jclass activityClass, windowClass, viewClass, immClass;
	jobject imm = NULL, window = NULL, decor = NULL;
	jmethodID method;
	jstring service;

	if (theActivity == NULL) return 0;
	vm = theActivity->vm;
	if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
		if ((*vm)->AttachCurrentThread(vm, &env, NULL) != 0) {
			Complain("keyboard: cannot reach the virtual machine from this thread");
			return 0;
		}
		attached = 1;
	}

	activityClass = (*env)->GetObjectClass(env, theActivity->clazz);

	/*	getSystemService("input_method") */
	method = (*env)->GetMethodID(env, activityClass, "getSystemService",
			"(Ljava/lang/String;)Ljava/lang/Object;");
	service = (*env)->NewStringUTF(env, "input_method");
	imm = (*env)->CallObjectMethod(env, theActivity->clazz, method, service);
	(*env)->DeleteLocalRef(env, service);

	/*	getWindow().getDecorView() */
	method = (*env)->GetMethodID(env, activityClass, "getWindow", "()Landroid/view/Window;");
	window = (*env)->CallObjectMethod(env, theActivity->clazz, method);
	windowClass = (*env)->GetObjectClass(env, window);
	method = (*env)->GetMethodID(env, windowClass, "getDecorView", "()Landroid/view/View;");
	decor = (*env)->CallObjectMethod(env, window, method);
	viewClass = (*env)->GetObjectClass(env, decor);

	if (imm != NULL && decor != NULL) {
		immClass = (*env)->GetObjectClass(env, imm);
		if (show) {
			method = (*env)->GetMethodID(env, viewClass, "setFocusable", "(Z)V");
			(*env)->CallVoidMethod(env, decor, method, JNI_TRUE);
			method = (*env)->GetMethodID(env, viewClass, "setFocusableInTouchMode", "(Z)V");
			(*env)->CallVoidMethod(env, decor, method, JNI_TRUE);
			method = (*env)->GetMethodID(env, viewClass, "requestFocus", "()Z");
			(*env)->CallBooleanMethod(env, decor, method);
			method = (*env)->GetMethodID(env, immClass, "showSoftInput", "(Landroid/view/View;I)Z");
			answered = (*env)->CallBooleanMethod(env, imm, method, decor, 2 /* SHOW_FORCED */);
		} else {
			jobject token;
			method = (*env)->GetMethodID(env, viewClass, "getWindowToken", "()Landroid/os/IBinder;");
			token = (*env)->CallObjectMethod(env, decor, method);
			method = (*env)->GetMethodID(env, immClass, "hideSoftInputFromWindow",
					"(Landroid/os/IBinder;I)Z");
			answered = (*env)->CallBooleanMethod(env, imm, method, token, 0);
		}
	}
	if ((*env)->ExceptionCheck(env)) {
		(*env)->ExceptionDescribe(env);
		(*env)->ExceptionClear(env);
		answered = 0;
	}
	if (attached) (*vm)->DetachCurrentThread(vm);
	return answered ? 1 : 0;
}

/*	And the reason A2 cannot simply call the above: a view belongs to the thread that made it.
 *
 *	`setFocusable` on the decor view from A2's thread aborts the process outright -- ART checks, and
 *	says so: `Only the original thread that created a view hierarchy can touch its views. Expected:
 *	main Calling: Thread-2`. Not a crash in our code and not something a return value would have told
 *	us; the whole process was gone a second after it started.
 *
 *	So the request crosses to the main thread the way everything else in this file crosses a thread
 *	boundary -- through a pipe the looper watches. It is the same shape as the touches, and for the
 *	same reason turned round: there, the framework's thread must not call into A2; here, A2's thread
 *	must not call into the framework. */
static int keyboardWanted[2] = { -1, -1 };

static int OnKeyboardWanted(int fd, int events, void *data) {
	char want = 0, byte;
	(void)events; (void)data;
	while (read(fd, &byte, 1) == 1) want = byte;			/* the last word wins */
	if (want != 0) Log("keyboard: %s", Keyboard(want == 1) ? "up" : "the input method said no");
	return 1;											/* keep the callback registered */
}

int A2Keyboard(int show) {
	char want = show ? 1 : 2;
	if (keyboardWanted[1] < 0) return 0;
	return write(keyboardWanted[1], &want, 1) == 1;
}

/*	And when the window has focus, because that is the earliest the request can succeed: a window that
 *	does not have focus is not a window an input method will open for, and the window is created some
 *	way before it is focused. Once per focus gained; asking twice is harmless but says nothing. */
static void OnWindowFocusChanged(ANativeActivity *activity, int hasFocus) {
	(void)activity;
	Log("window focus %s", hasFocus ? "gained" : "lost");
	if (hasFocus && displayTold) Tell("AndroidInput.ShowKeyboard");
}

static int OnInput(int fd, int events, void *data) {
	AInputQueue *queue = (AInputQueue *)data;
	AInputEvent *event = NULL;
	(void)fd; (void)events;
	while (AInputQueue_getEvent(queue, &event) >= 0) {
		int handled = 0;
		if (AInputQueue_preDispatchEvent(queue, event)) continue;
		if (AInputEvent_getType(event) == AINPUT_EVENT_TYPE_KEY) {
			int32_t code = AKeyEvent_getKeyCode(event);
			if (code == AKEYCODE_BACK) {
				if (AKeyEvent_getAction(event) == AKEY_EVENT_ACTION_UP) {
					Log("back: finishing the activity");
					ANativeActivity_finish(theActivity);
				}
				handled = 1;
			} else {
				/*	Everything else is offered to A2, and what it does not know stays unhandled so that
					the framework goes on doing what it did with it -- volume, the home key, the rest. */
				handled = TakeKey(event);
			}
		} else if (AInputEvent_getType(event) == AINPUT_EVENT_TYPE_MOTION) {
			TakeMotion(event);
			handled = 1;
		}
		AInputQueue_finishEvent(queue, event, handled);
	}
	return 1;											/* keep the callback registered */
}

static void OnInputQueueCreated(ANativeActivity *activity, AInputQueue *queue) {
	(void)activity;
	Log("input queue attached");
	AInputQueue_attachLooper(queue, ALooper_forThread(), 1, OnInput, queue);
}

static void OnInputQueueDestroyed(ANativeActivity *activity, AInputQueue *queue) {
	(void)activity;
	Log("input queue detached");
	AInputQueue_detachLooper(queue);
}

static void OnStart(ANativeActivity *activity) { (void)activity; Log("start"); }
static void OnResume(ANativeActivity *activity) { (void)activity; Log("resume"); }
static void OnPause(ANativeActivity *activity) { (void)activity; Log("pause"); }
static void OnStop(ANativeActivity *activity) { (void)activity; Log("stop"); }
static void OnDestroy(ANativeActivity *activity) { (void)activity; Log("destroy (A2 goes on running)"); }
static void OnLowMemory(ANativeActivity *activity) { (void)activity; Log("low memory"); }
static void OnConfigurationChanged(ANativeActivity *activity) { (void)activity; Log("configuration changed"); }

/*	The window is now a different shape -- a rotation, and the manifest says this activity survives one
 *	rather than being destroyed and built again. Nothing is done to the window here beyond asking for
 *	the format once more; the size is A2's business, and it learns it from the next lock. Counted as a
 *	new window, because that is exactly what it is as far as the picture in it is concerned: nothing A2
 *	has drawn belongs anywhere it was. */
static void OnWindowResized(ANativeActivity *activity, ANativeWindow *window) {
	(void)activity;
	Log("window resized to %d x %d", ANativeWindow_getWidth(window), ANativeWindow_getHeight(window));
	Configure(window);
	pthread_mutex_lock(&windowMutex);
	windowGeneration++;
	pthread_mutex_unlock(&windowMutex);
}

void ANativeActivity_onCreate(ANativeActivity *activity, void *savedState, size_t savedStateSize) {
	(void)savedState; (void)savedStateSize;
	LogTheTranscript();
	Log("onCreate on thread %d", (int)gettid());
	Handlers("before A2");
	{ pthread_t later; pthread_create(&later, NULL, LookAgain, NULL); pthread_detach(later); }

	activity->callbacks->onStart = OnStart;
	activity->callbacks->onResume = OnResume;
	activity->callbacks->onPause = OnPause;
	activity->callbacks->onStop = OnStop;
	activity->callbacks->onDestroy = OnDestroy;
	activity->callbacks->onLowMemory = OnLowMemory;
	activity->callbacks->onConfigurationChanged = OnConfigurationChanged;
	activity->callbacks->onNativeWindowCreated = OnWindowCreated;
	activity->callbacks->onNativeWindowDestroyed = OnWindowDestroyed;
	activity->callbacks->onNativeWindowRedrawNeeded = OnWindowRedraw;
	activity->callbacks->onNativeWindowResized = OnWindowResized;
	/*	The channel A2 asks for the keyboard through, watched here on the thread that owns the view.
		Made before anything can ask, and never closed: the activity outlives every asker. */
	if (pipe(keyboardWanted) == 0) {
		fcntl(keyboardWanted[0], F_SETFL, O_NONBLOCK);
		ALooper_addFd(ALooper_forThread(), keyboardWanted[0], 2, ALOOPER_EVENT_INPUT,
				OnKeyboardWanted, NULL);
	} else {
		Complain("no pipe for the keyboard: %s", strerror(errno));
	}
	activity->callbacks->onWindowFocusChanged = OnWindowFocusChanged;
	activity->callbacks->onInputQueueCreated = OnInputQueueCreated;
	activity->callbacks->onInputQueueDestroyed = OnInputQueueDestroyed;
	theActivity = activity;

	StartTheSystem(activity);
	Log("onCreate returning, which is the whole point of the thread");
}
