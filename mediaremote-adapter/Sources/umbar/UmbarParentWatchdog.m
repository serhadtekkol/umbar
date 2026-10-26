// UmbarParentWatchdog.m
//
// umbar addition — NOT part of upstream ungive/mediaremote-adapter. Lives in
// its own directory so the vendored upstream files stay byte-identical (see
// VENDORED.txt).
//
// Why: the app runs `/usr/bin/perl mediaremote-adapter.pl … stream` as a child
// process. macOS has no PR_SET_PDEATHSIG, and the stream loop only writes to
// stdout when now-playing data changes, so after the app quits, is SIGTERMed
// or crashes the child is reparented to launchd and keeps running forever
// (card #57). The app-side willTerminate cleanup cannot cover SIGTERM, SIGKILL
// or a crash, so the child has to notice on its own.
//
// How: when perl's DynaLoader loads this framework, the constructor below
// reads UMBAR_ADAPTER_PARENT_PID (set only by umbar's NowPlayingAdapterProcess)
// and watches that pid with a kqueue-backed dispatch source (NOTE_EXIT). When
// the parent exits for any reason, the child calls _exit immediately. Without
// the variable (e.g. someone running the script by hand) nothing changes.

#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <stdlib.h>
#include <unistd.h>

static dispatch_source_t gUmbarParentWatch = NULL;

__attribute__((constructor)) static void umbar_watch_parent(void) {
    const char *value = getenv("UMBAR_ADAPTER_PARENT_PID");
    if (value == NULL || *value == '\0') {
        return;
    }
    char *end = NULL;
    long parsed = strtol(value, &end, 10);
    if (end == value || *end != '\0' || parsed <= 1) {
        return;
    }
    pid_t parent = (pid_t)parsed;

    gUmbarParentWatch = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)parent, DISPATCH_PROC_EXIT,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    if (gUmbarParentWatch == NULL) {
        // The pid cannot be watched (already gone): nobody will ever read our
        // output, so do not linger.
        _exit(0);
    }
    dispatch_source_set_event_handler(gUmbarParentWatch, ^{
        // _exit, not exit: skip atexit handlers and the CFRunLoop teardown of
        // the adapter; there is no state worth flushing for a dead reader.
        _exit(0);
    });
    dispatch_resume(gUmbarParentWatch);

    // Closes the window between spawn and the source being armed: if the
    // parent already died we were reparented and the source may never fire.
    if (getppid() != parent) {
        _exit(0);
    }
}
