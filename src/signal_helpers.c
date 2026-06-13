#include <stdlib.h>
#include <signal.h>

// Extern Swift functions declared with @_cdecl.
extern void minttab_restore_native_hotkeys(void);
extern void minttab_sigterm_handler(int sig);
extern void minttab_sigint_handler(int sig);

void minttab_setup_signal_handlers(void) {
    atexit(minttab_restore_native_hotkeys);
    signal(SIGTERM, minttab_sigterm_handler);
    signal(SIGINT, minttab_sigint_handler);
}
