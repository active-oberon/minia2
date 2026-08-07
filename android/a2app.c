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
 *	What it draws is deliberately not A2's doing yet. Filling the window from C answers "does this
 *	process hold a surface at the same time as it holds A2", which is the question this spike is for;
 *	drawing A2's own display into it is a Displays backend, and that is the work this measures rather
 *	than the work it does.
 *
 *	Build: see android/build-apk.sh.
 */

#include <android/asset_manager.h>
#include <android/log.h>
#include <android/native_activity.h>
#include <android/input.h>
#include <android/keycodes.h>
#include <android/looper.h>
#include <android/native_window.h>
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
	if (pthread_create(&systemThread, NULL, RunTheSystem, NULL) != 0) {
		Complain("cannot start the thread to run A2 on: %s", strerror(errno));
		return;
	}
	pthread_detach(systemThread);
	systemStarted = 1;
}

/*	The window. Filled from here, in one colour, so that a picture on the screen means the process
 *	holds a surface while A2 runs in it -- and nothing more than that is claimed. */
static void Fill(ANativeWindow *window) {
	ANativeWindow_Buffer buffer;
	int y, x;
	if (window == NULL) return;
	if (ANativeWindow_setBuffersGeometry(window, 0, 0, WINDOW_FORMAT_RGBX_8888) != 0)
		Complain("the window would not take the format asked for");
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

static void OnWindowCreated(ANativeActivity *activity, ANativeWindow *window) {
	(void)activity;
	Log("window created");
	Fill(window);
}

static void OnWindowDestroyed(ANativeActivity *activity, ANativeWindow *window) {
	(void)activity; (void)window;
	Log("window destroyed");
}

static void OnWindowRedraw(ANativeActivity *activity, ANativeWindow *window) {
	(void)activity;
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
static ANativeActivity *theActivity;

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
			}
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
	activity->callbacks->onInputQueueCreated = OnInputQueueCreated;
	activity->callbacks->onInputQueueDestroyed = OnInputQueueDestroyed;
	theActivity = activity;

	StartTheSystem(activity);
	Log("onCreate returning, which is the whole point of the thread");
}
