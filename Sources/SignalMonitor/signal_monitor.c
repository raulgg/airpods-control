#include "SignalMonitor.h"

#include <errno.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <sys/event.h>
#include <time.h>
#include <unistd.h>

_Static_assert(
    ATOMIC_INT_LOCK_FREE == 2,
    "support-report signal handling requires lock-free int atomics");

enum {
  monitor_open = 0,
  monitor_closing = -1,
  monitor_closed_signal_accounted = -2,
  monitor_closed_without_signal = -3,
};

static _Atomic int signal_state;
static struct sigaction previous_sigint_action;
static struct sigaction previous_sigterm_action;
static bool monitor_installed;
static int signal_event_queue = -1;

#if defined(AIRPODS_CONTROL_SIGNAL_MONITOR_TESTING)
static _Atomic int pause_before_latch;
static _Atomic int handler_entered;

void airpods_control_signal_monitor_test_pause_handler(int should_pause) {
  atomic_store_explicit(
      &handler_entered, 0, memory_order_relaxed);
  atomic_store_explicit(
      &pause_before_latch, should_pause, memory_order_relaxed);
}

int airpods_control_signal_monitor_test_handler_entered(void) {
  return atomic_load_explicit(&handler_entered, memory_order_relaxed);
}
#endif

static int publish_termination_signal(int signal_number) {
  int expected = monitor_open;
  if (atomic_compare_exchange_strong_explicit(
      &signal_state,
      &expected,
      signal_number,
      memory_order_relaxed,
      memory_order_relaxed)) {
    return signal_number;
  }

  if (expected == monitor_closing) {
    if (atomic_compare_exchange_strong_explicit(
        &signal_state,
        &expected,
        signal_number,
        memory_order_relaxed,
        memory_order_relaxed)) {
      return signal_number;
    }
  }
  return expected;
}

static void record_termination_signal(int signal_number) {
#if defined(AIRPODS_CONTROL_SIGNAL_MONITOR_TESTING)
  if (atomic_load_explicit(&pause_before_latch, memory_order_relaxed) != 0) {
    atomic_store_explicit(&handler_entered, 1, memory_order_relaxed);
    while (atomic_load_explicit(&pause_before_latch, memory_order_relaxed) != 0) {
    }
  }
#endif

  // If teardown is still running, publish the signal for its final atomic
  // read. Once teardown has closed without a process-directed kqueue event,
  // the handler is necessarily a late thread-directed delivery; returning
  // would let the caller continue after missing it.
  if (publish_termination_signal(signal_number)
      == monitor_closed_without_signal) {
    _exit(128 + signal_number);
  }
}

static int register_signal_event_queue(void) {
  int event_queue = kqueue();
  if (event_queue < 0) {
    return errno;
  }

  struct kevent changes[2];
  EV_SET(
      &changes[0],
      SIGINT,
      EVFILT_SIGNAL,
      EV_ADD | EV_ENABLE,
      0,
      0,
      NULL);
  EV_SET(
      &changes[1],
      SIGTERM,
      EVFILT_SIGNAL,
      EV_ADD | EV_ENABLE,
      0,
      0,
      NULL);
  if (kevent(event_queue, changes, 2, NULL, 0, NULL) != 0) {
    int error = errno;
    (void)close(event_queue);
    return error;
  }

  signal_event_queue = event_queue;
  return 0;
}

static int drain_signal_event_queue(void) {
  if (signal_event_queue < 0) {
    return 0;
  }

  struct kevent events[2];
  struct timespec timeout = {0};
  int event_count;
  do {
    event_count = kevent(
        signal_event_queue,
        NULL,
        0,
        events,
        2,
        &timeout);
  } while (event_count < 0 && errno == EINTR);

  if (event_count <= 0) {
    return 0;
  }
  for (int index = 0; index < event_count; index++) {
    int signal_number = (int)events[index].ident;
    if (signal_number == SIGINT || signal_number == SIGTERM) {
      return signal_number;
    }
  }
  return 0;
}

static void close_signal_event_queue(void) {
  if (signal_event_queue >= 0) {
    (void)close(signal_event_queue);
    signal_event_queue = -1;
  }
}

static int finalize_signal_state(int caught) {
  int closed_state = caught > monitor_open
      ? monitor_closed_signal_accounted
      : monitor_closed_without_signal;
  int state = atomic_exchange_explicit(
      &signal_state, closed_state, memory_order_relaxed);
  if (state > monitor_open) {
    if (caught <= monitor_open) {
      caught = state;
    }
    atomic_store_explicit(
        &signal_state,
        monitor_closed_signal_accounted,
        memory_order_relaxed);
  }
  return caught;
}

int airpods_control_signal_monitor_install(void) {
  if (monitor_installed) {
    return EBUSY;
  }

  int queue_error = register_signal_event_queue();
  if (queue_error != 0) {
    return queue_error;
  }
  atomic_store_explicit(&signal_state, monitor_open, memory_order_relaxed);

  struct sigaction action = {0};
  action.sa_handler = record_termination_signal;
  sigemptyset(&action.sa_mask);
  sigaddset(&action.sa_mask, SIGINT);
  sigaddset(&action.sa_mask, SIGTERM);

  if (sigaction(SIGINT, &action, &previous_sigint_action) != 0) {
    int error = errno;
    close_signal_event_queue();
    return error;
  }
  if (sigaction(SIGTERM, &action, &previous_sigterm_action) != 0) {
    int error = errno;
    int caught = atomic_exchange_explicit(
        &signal_state, monitor_closing, memory_order_relaxed);
    (void)sigaction(SIGINT, &previous_sigint_action, NULL);
    if (caught <= monitor_open) {
      caught = drain_signal_event_queue();
    }
    caught = finalize_signal_state(caught);
    close_signal_event_queue();
    if (caught > monitor_open) {
      _exit(128 + caught);
    }
    return error;
  }

  monitor_installed = true;
  return 0;
}

int airpods_control_signal_monitor_caught_signal(void) {
  int state = atomic_load_explicit(&signal_state, memory_order_relaxed);
  if (state > monitor_open) {
    return state;
  }

  int caught = drain_signal_event_queue();
  if (caught <= monitor_open) {
    return 0;
  }
  state = publish_termination_signal(caught);
  return state > monitor_open ? state : caught;
}

int airpods_control_signal_monitor_disarm(void) {
  int caught = 0;
  if (monitor_installed) {
    int state = atomic_exchange_explicit(
        &signal_state, monitor_closing, memory_order_relaxed);
    if (state > monitor_open) {
      caught = state;
    }
    // Restore each complete action while the other signal is still captured.
    // A newly selected signal uses its prior disposition. EVFILT_SIGNAL records
    // process-directed delivery before handler selection, so the final drain
    // also accounts for a monitor handler already selected on another thread.
    (void)sigaction(SIGTERM, &previous_sigterm_action, NULL);
    (void)sigaction(SIGINT, &previous_sigint_action, NULL);
    if (caught == 0) {
      caught = drain_signal_event_queue();
    }
    caught = finalize_signal_state(caught);
    close_signal_event_queue();
    monitor_installed = false;
  }
  return caught;
}
