#include "SignalMonitor.h"

#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>

static void ignore_signal_for_test(int signal_number) {
  (void)signal_number;
}

static _Atomic int worker_ready;
static _Atomic int release_worker;

static void *wait_for_process_signal(void *unused) {
  (void)unused;
  sigset_t signal_set;
  sigemptyset(&signal_set);
  sigaddset(&signal_set, SIGINT);
  if (pthread_sigmask(SIG_UNBLOCK, &signal_set, NULL) != 0) {
    return (void *)1;
  }
  atomic_store_explicit(&worker_ready, 1, memory_order_relaxed);
  while (atomic_load_explicit(&release_worker, memory_order_relaxed) == 0) {
    sched_yield();
  }
  return NULL;
}

static void exercise_late_handler_in_child(int poll_before_disarm) {
  sigset_t signal_set;
  sigemptyset(&signal_set);
  sigaddset(&signal_set, SIGINT);
  if (pthread_sigmask(SIG_BLOCK, &signal_set, NULL) != 0) {
    _exit(10);
  }

  struct sigaction harmless_action = {0};
  harmless_action.sa_handler = ignore_signal_for_test;
  sigemptyset(&harmless_action.sa_mask);
  if (sigaction(SIGINT, &harmless_action, NULL) != 0) {
    _exit(11);
  }
  if (airpods_control_signal_monitor_install() != 0) {
    _exit(12);
  }

  airpods_control_signal_monitor_test_pause_handler(1);
  pthread_t worker;
  if (pthread_create(&worker, NULL, wait_for_process_signal, NULL) != 0) {
    _exit(13);
  }
  for (int attempts = 0;
       attempts < 100000
       && !atomic_load_explicit(&worker_ready, memory_order_relaxed);
       attempts++) {
    sched_yield();
  }
  if (!atomic_load_explicit(&worker_ready, memory_order_relaxed)) {
    _exit(14);
  }
  if (kill(getpid(), SIGINT) != 0) {
    _exit(15);
  }

  for (int attempts = 0;
       attempts < 100000
       && !airpods_control_signal_monitor_test_handler_entered();
       attempts++) {
    sched_yield();
  }
  if (!airpods_control_signal_monitor_test_handler_entered()) {
    _exit(16);
  }

  if (poll_before_disarm
      && airpods_control_signal_monitor_caught_signal() != SIGINT) {
    // A delayed process handler must not allow later device writes merely
    // because its first atomic instruction has not run yet.
    _exit(17);
  }
  if (airpods_control_signal_monitor_disarm() != SIGINT) {
    // Returning zero here would let the real caller display the issue prompt
    // while this already-selected handler is still paused.
    _exit(18);
  }
  atomic_store_explicit(&release_worker, 1, memory_order_relaxed);
  airpods_control_signal_monitor_test_pause_handler(0);
  void *worker_result = NULL;
  if (pthread_join(worker, &worker_result) != 0 || worker_result != NULL) {
    _exit(19);
  }
  _exit(0);
}

int main(void) {
  for (int poll_before_disarm = 0; poll_before_disarm <= 1; poll_before_disarm++) {
    pid_t child = fork();
    if (child < 0) {
      perror("fork");
      return 1;
    }
    if (child == 0) {
      exercise_late_handler_in_child(poll_before_disarm);
    }

    int status = 0;
    if (waitpid(child, &status, 0) != child) {
      perror("waitpid");
      return 1;
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
      fprintf(
          stderr,
          "process-directed late signal was lost "
          "(poll=%d, child status=%d)\n",
          poll_before_disarm,
          status);
      return 1;
    }
  }
  return 0;
}
