#ifndef CMONITR_H
#define CMONITR_H

#include <sys/types.h>

/// Opens the HID sensor client once. Returns 0 on success.
int monitr_temp_open(void);

/// Hottest CPU die sensor in degrees Celsius, or -1 when unavailable.
double monitr_cpu_temp(void);

/// Pid macOS holds responsible for `pid` (the app that launched a helper), or -1.
pid_t monitr_responsible_pid(pid_t pid);

#endif
