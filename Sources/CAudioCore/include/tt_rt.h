#ifndef TT_RT_H
#define TT_RT_H

/* Real-time annotations (ARCHITECTURE.md §2.2). CAudioCore is compiled with
 * -Wfunction-effects -Werror=function-effects, so a function marked TT_NONBLOCKING that calls
 * anything not known to be nonblocking (malloc, locks, ObjC, logging) fails the build.
 * Clang requires the attribute on the declaration and on the definition. */
#if defined(__has_attribute)
#  if __has_attribute(nonblocking)
#    define TT_NONBLOCKING __attribute__((nonblocking))
#  endif
#endif
#ifndef TT_NONBLOCKING
#  define TT_NONBLOCKING
#endif

#endif
