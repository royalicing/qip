#ifndef QIP_AVIF_SETJMP_H
#define QIP_AVIF_SETJMP_H

typedef struct qip_avif_jmp_buf {
  int unused;
} jmp_buf[1];

int setjmp(jmp_buf env);
void longjmp(jmp_buf env, int value) __attribute__((noreturn));

#endif
