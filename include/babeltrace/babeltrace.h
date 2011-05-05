#ifndef _BABELTRACE_H
#define _BABELTRACE_H

#define BABELTRACE_VERSION_MAJOR	0
#define BABELTRACE_VERSION_MINOR	1

extern int babeltrace_verbose, babeltrace_debug;

#define printf_verbose(fmt, args...)				\
	do {							\
		if (babeltrace_verbose)				\
			printf("[verbose] " fmt, ## args);	\
	} while (0)

#define printf_debug(fmt, args...)				\
	do {							\
		if (babeltrace_debug)				\
			printf("[debug] " fmt, ## args);	\
	} while (0)

#endif