#ifndef BATON_IOS_CRASH_CANARY_H
#define BATON_IOS_CRASH_CANARY_H

/// Deliberately crashes on a C source line so a release dSYM can prove exact
/// function, file, and line symbolication. Called only from the internal,
/// owner-confirmed diagnostics affordance.
__attribute__((noreturn)) void baton_ios_trigger_test_crash(void);

#endif
