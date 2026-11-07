/*
 * main.m - InstaDock: the desktop picture and the dock of PureDarwin's Argon desktop.
 *
 * The crash report is taken over from PureDarwin's own Dock.
 *
 * Copyright (c) 2026 The PureDarwin Project
 * Copyright (c) 2026 The pd-instadock authors
 *
 * SPDX-License-Identifier: MPL-2.0 OR BSD-2-Clause
 */

#import "IDDock.h"
#include <dlfcn.h>
#include <execinfo.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ucontext.h>
#include <unistd.h>

// a crash prints where it happened, the kernel alone only reports the signal
static void crashed(int sig, siginfo_t *info, void *context)
{
    void *frames[48];
    int count = backtrace(frames, 48);
    ucontext_t *uc = context;
    void *pc = (void *)uc->uc_mcontext->__ss.__rip;
    void **fp = (void **)uc->uc_mcontext->__ss.__rbp;
    Dl_info at;

    fprintf(stderr, "Dock: signal %d at %p\n", sig, info->si_addr);
    if (dladdr(pc, &at) && at.dli_sname != NULL)
        fprintf(stderr, "  pc %s + %ld (%s)\n", at.dli_sname, (long)((char *)pc - (char *)at.dli_saddr), at.dli_fname);
    else
        fprintf(stderr, "  pc %p\n", pc);
    for (int i = 0; i < 16 && fp != NULL && ((uintptr_t)fp & 7) == 0; i++) {
        void *ret = fp[1];

        if (dladdr(ret, &at) && at.dli_sname != NULL)
            fprintf(stderr, "  fp%-2d %s + %ld\n", i, at.dli_sname, (long)((char *)ret - (char *)at.dli_saddr));
        else
            fprintf(stderr, "  fp%-2d %p\n", i, ret);
        if ((void **)fp[0] <= fp)
            break;
        fp = (void **)fp[0];
    }
    fflush(stderr);
    for (int i = 0; i < count; i++) {
        Dl_info where;

        if (dladdr(frames[i], &where) && where.dli_sname != NULL)
            fprintf(stderr, "  %2d %s + %ld\n", i, where.dli_sname, (long)((char *)frames[i] - (char *)where.dli_saddr));
        else
            fprintf(stderr, "  %2d %p\n", i, frames[i]);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

int main(int argc, const char *argv[])
{
    struct sigaction action = { 0 };
    stack_t altstack = { .ss_sp = malloc(1 << 16), .ss_size = 1 << 16 };
    NSAutoreleasePool *pool;
    IDController *controller;

    sigaltstack(&altstack, NULL);
    action.sa_sigaction = crashed;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(SIGSEGV, &action, NULL);
    sigaction(SIGBUS, &action, NULL);
    sigaction(SIGABRT, &action, NULL);
    // the apps the dock launches are its children, ignoring SIGCHLD lets the kernel reap them as they quit
    signal(SIGCHLD, SIG_IGN);

    pool = [[NSAutoreleasePool alloc] init];
    [NSApplication sharedApplication];
    controller = [[IDController alloc] init];
    [NSApp setDelegate:controller];
    [NSApp run];
    [pool release];
    return 0;
}
