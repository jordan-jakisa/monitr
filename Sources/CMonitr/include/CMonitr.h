#ifndef CMONITR_H
#define CMONITR_H

#include <sys/types.h>

/// Opens the HID sensor client once. Returns 0 on success.
int monitr_temp_open(void);

/// Hottest CPU die sensor in degrees Celsius, or -1 when unavailable.
double monitr_cpu_temp(void);

/// Number of temperature sensors found by monitr_temp_open.
int monitr_temp_count(void);
/// Name of sensor `i` (for example "PMU tdie3"), valid for the life of the process.
const char *monitr_temp_name(int i);
/// Current reading of sensor `i` in °C, or -1 when it reports nothing sensible.
/// Costs one IOKit call, so read the full list only while it is on screen.
double monitr_temp_value(int i);

/// Pid macOS holds responsible for `pid` (the app that launched a helper), or -1.
pid_t monitr_responsible_pid(pid_t pid);

#endif
