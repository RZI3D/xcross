// SysV <-> Microsoft x64 calling-convention trampolines for loading
// Android/bionic ELF libraries on Windows.
//
// Android .so code uses the SysV ABI (args in rdi,rsi,rdx,rcx,r8,r9).
// Dart FFI / NativeCallable on Windows use the Microsoft x64 ABI
// (rcx,rdx,r8,r9 + 32-byte shadow space). These trampolines rearrange
// integer/pointer arguments for arities 0..8 (enough for ADI).
//
// On non-Windows builds the hook emits identity stubs instead.

#include <stdint.h>
#include <string.h>

#if defined(_WIN32) && (defined(_M_X64) || defined(__x86_64__))

#include <windows.h>

typedef struct {
  uint8_t code[128];
  void* target;
} TrampolineSlot;

enum { kPoolCapacity = 256 };

static TrampolineSlot g_pool[kPoolCapacity];
static size_t g_pool_used = 0;
static int g_pool_executable = 0;

static int ensure_pool_executable(void) {
  if (g_pool_executable) return 1;
  DWORD old = 0;
  if (!VirtualProtect(g_pool, sizeof(g_pool), PAGE_EXECUTE_READWRITE, &old)) {
    return 0;
  }
  g_pool_executable = 1;
  return 1;
}

static TrampolineSlot* alloc_slot(void* target) {
  if (!ensure_pool_executable()) return NULL;
  if (g_pool_used >= kPoolCapacity) return NULL;
  TrampolineSlot* slot = &g_pool[g_pool_used++];
  memset(slot, 0, sizeof(*slot));
  slot->target = target;
  return slot;
}

static size_t emit_load_target(uint8_t* code, size_t at, const TrampolineSlot* slot) {
  const intptr_t rip_after = (intptr_t)(code + at + 7);
  const intptr_t target_addr = (intptr_t)&slot->target;
  const int32_t disp = (int32_t)(target_addr - rip_after);
  code[at++] = 0x48;
  code[at++] = 0x8B;
  code[at++] = 0x05;
  memcpy(code + at, &disp, 4);
  return at + 4;
}

// SysV -> MS (export): Android calls us (SysV), we call Dart/MSVC (MS).
static void emit_export(TrampolineSlot* slot, int argc) {
  uint8_t* code = slot->code;
  size_t at = 0;

  if (argc <= 4) {
    if (argc >= 3) {
      code[at++] = 0x49; code[at++] = 0x89; code[at++] = 0xD2; // r10 = rdx
    }
    if (argc >= 4) {
      code[at++] = 0x49; code[at++] = 0x89; code[at++] = 0xCB; // r11 = rcx
    }
    if (argc >= 1) {
      code[at++] = 0x48; code[at++] = 0x89; code[at++] = 0xF9; // rcx = rdi
    }
    if (argc >= 2) {
      code[at++] = 0x48; code[at++] = 0x89; code[at++] = 0xF2; // rdx = rsi
    }
    if (argc >= 3) {
      code[at++] = 0x4D; code[at++] = 0x89; code[at++] = 0xD0; // r8 = r10
    }
    if (argc >= 4) {
      code[at++] = 0x4D; code[at++] = 0x89; code[at++] = 0xD9; // r9 = r11
    }
    at = emit_load_target(code, at, slot);
    code[at++] = 0xFF; code[at++] = 0xE0; // jmp *rax
    return;
  }

  // argc 5..8
  code[at++] = 0x41; code[at++] = 0x54; // push r12
  code[at++] = 0x41; code[at++] = 0x55; // push r13
  code[at++] = 0x4D; code[at++] = 0x89; code[at++] = 0xC4; // r12 = r8 (SysV arg5)
  if (argc >= 6) {
    code[at++] = 0x4D; code[at++] = 0x89; code[at++] = 0xCD; // r13 = r9
  }
  if (argc >= 3) {
    code[at++] = 0x49; code[at++] = 0x89; code[at++] = 0xD2; // r10 = rdx
  }
  if (argc >= 4) {
    code[at++] = 0x49; code[at++] = 0x89; code[at++] = 0xCB; // r11 = rcx
  }
  code[at++] = 0x48; code[at++] = 0x89; code[at++] = 0xF9; // rcx = rdi
  code[at++] = 0x48; code[at++] = 0x89; code[at++] = 0xF2; // rdx = rsi
  if (argc >= 3) {
    code[at++] = 0x4D; code[at++] = 0x89; code[at++] = 0xD0; // r8 = r10
  }
  if (argc >= 4) {
    code[at++] = 0x4D; code[at++] = 0x89; code[at++] = 0xD9; // r9 = r11
  }

  const int extra = argc - 4;
  const int frame = 0x28 + 8 * extra;
  code[at++] = 0x48; code[at++] = 0x81; code[at++] = 0xEC;
  memcpy(code + at, &frame, 4); at += 4;

  // mov [rsp+0x20], r12
  code[at++] = 0x4C; code[at++] = 0x89; code[at++] = 0x64; code[at++] = 0x24;
  code[at++] = 0x20;
  if (argc >= 6) {
    code[at++] = 0x4C; code[at++] = 0x89; code[at++] = 0x6C; code[at++] = 0x24;
    code[at++] = 0x28;
  }
  if (argc >= 7) {
    // After 2 pushes + frame: original SysV [rsp+8] (arg7) at rsp+frame+0x18
    const int off = frame + 0x18;
    code[at++] = 0x48; code[at++] = 0x8B; code[at++] = 0x84; code[at++] = 0x24;
    memcpy(code + at, &off, 4); at += 4;
    code[at++] = 0x48; code[at++] = 0x89; code[at++] = 0x44; code[at++] = 0x24;
    code[at++] = 0x30;
  }
  if (argc >= 8) {
    const int off = frame + 0x20;
    code[at++] = 0x48; code[at++] = 0x8B; code[at++] = 0x84; code[at++] = 0x24;
    memcpy(code + at, &off, 4); at += 4;
    code[at++] = 0x48; code[at++] = 0x89; code[at++] = 0x44; code[at++] = 0x24;
    code[at++] = 0x38;
  }

  at = emit_load_target(code, at, slot);
  code[at++] = 0xFF; code[at++] = 0xD0; // call *rax
  code[at++] = 0x48; code[at++] = 0x81; code[at++] = 0xC4;
  memcpy(code + at, &frame, 4); at += 4;
  code[at++] = 0x41; code[at++] = 0x5D; // pop r13
  code[at++] = 0x41; code[at++] = 0x5C; // pop r12
  code[at++] = 0xC3; // ret
  (void)at;
}

// MS -> SysV (import): Dart calls us (MS), we call Android ADI (SysV).
static void emit_import(TrampolineSlot* slot, int argc) {
  uint8_t* code = slot->code;
  size_t at = 0;

  if (argc <= 4) {
    if (argc >= 4) {
      code[at++] = 0x4D; code[at++] = 0x89; code[at++] = 0xCB; // r11 = r9
    }
    if (argc >= 3) {
      code[at++] = 0x4D; code[at++] = 0x89; code[at++] = 0xC2; // r10 = r8
    }
    if (argc >= 1) {
      code[at++] = 0x48; code[at++] = 0x89; code[at++] = 0xCF; // rdi = rcx
    }
    if (argc >= 2) {
      code[at++] = 0x48; code[at++] = 0x89; code[at++] = 0xD6; // rsi = rdx
    }
    if (argc >= 3) {
      code[at++] = 0x4C; code[at++] = 0x89; code[at++] = 0xD2; // rdx = r10
    }
    if (argc >= 4) {
      code[at++] = 0x4C; code[at++] = 0x89; code[at++] = 0xD9; // rcx = r11
    }
    at = emit_load_target(code, at, slot);
    code[at++] = 0xFF; code[at++] = 0xE0;
    return;
  }

  code[at++] = 0x41; code[at++] = 0x54; // push r12
  code[at++] = 0x41; code[at++] = 0x55; // push r13
  // MS arg5 at [rsp+0x28] on entry; after 2 pushes -> [rsp+0x38]
  code[at++] = 0x4C; code[at++] = 0x8B; code[at++] = 0x64; code[at++] = 0x24;
  code[at++] = 0x38;
  if (argc >= 6) {
    code[at++] = 0x4C; code[at++] = 0x8B; code[at++] = 0x6C; code[at++] = 0x24;
    code[at++] = 0x40;
  }

  code[at++] = 0x4D; code[at++] = 0x89; code[at++] = 0xCB; // r11 = r9
  code[at++] = 0x4D; code[at++] = 0x89; code[at++] = 0xC2; // r10 = r8
  code[at++] = 0x48; code[at++] = 0x89; code[at++] = 0xCF; // rdi = rcx
  code[at++] = 0x48; code[at++] = 0x89; code[at++] = 0xD6; // rsi = rdx
  code[at++] = 0x4C; code[at++] = 0x89; code[at++] = 0xD2; // rdx = r10
  code[at++] = 0x4C; code[at++] = 0x89; code[at++] = 0xD9; // rcx = r11
  code[at++] = 0x4D; code[at++] = 0x89; code[at++] = 0xE0; // r8 = r12
  if (argc >= 6) {
    code[at++] = 0x4D; code[at++] = 0x89; code[at++] = 0xE9; // r9 = r13
  }

  int aligned = 0x20;
  if (argc >= 7) aligned = 0x20;
  if (argc >= 8) aligned = 0x20;
  aligned = (argc > 6) ? (((argc - 6) * 8 + 15) & ~15) : 0x10;
  if (aligned < 0x10) aligned = 0x10;

  code[at++] = 0x48; code[at++] = 0x83; code[at++] = 0xEC;
  code[at++] = (uint8_t)aligned;

  if (argc >= 7) {
    const int off = 0x48 + aligned; // 0x38+0x10 from pushes was arg5; arg7 is +0x10 more = 0x48 before sub... 
    // Before sub rsp: arg7 at [rsp+0x48] (entry 0x38 + 2 pushes 0x10 + 0x10 for arg6->arg7)
    // MS: arg5@[rsp+28h], arg6@[rsp+30h], arg7@[rsp+38h], arg8@[rsp+40h] on entry
    // After 2 pushes: +10h → arg5@38h, arg6@40h, arg7@48h, arg8@50h
    // After sub aligned: add aligned to those.
    const int arg7_off = 0x48 + aligned;
    code[at++] = 0x48; code[at++] = 0x8B; code[at++] = 0x84; code[at++] = 0x24;
    memcpy(code + at, &arg7_off, 4); at += 4;
    code[at++] = 0x48; code[at++] = 0x89; code[at++] = 0x04; code[at++] = 0x24;
  }
  if (argc >= 8) {
    const int arg8_off = 0x50 + aligned;
    code[at++] = 0x48; code[at++] = 0x8B; code[at++] = 0x84; code[at++] = 0x24;
    memcpy(code + at, &arg8_off, 4); at += 4;
    code[at++] = 0x48; code[at++] = 0x89; code[at++] = 0x44; code[at++] = 0x24;
    code[at++] = 0x08;
  }

  at = emit_load_target(code, at, slot);
  code[at++] = 0xFF; code[at++] = 0xD0;
  code[at++] = 0x48; code[at++] = 0x83; code[at++] = 0xC4;
  code[at++] = (uint8_t)aligned;
  code[at++] = 0x41; code[at++] = 0x5D;
  code[at++] = 0x41; code[at++] = 0x5C;
  code[at++] = 0xC3;
  (void)at;
}

__declspec(dllexport) void* provision_sysv_wrap_export(void* ms_fn, int argc) {
  if (ms_fn == NULL || argc < 0 || argc > 8) return NULL;
  TrampolineSlot* slot = alloc_slot(ms_fn);
  if (slot == NULL) return NULL;
  emit_export(slot, argc);
  FlushInstructionCache(GetCurrentProcess(), slot->code, sizeof(slot->code));
  return slot->code;
}

__declspec(dllexport) void* provision_sysv_wrap_import(void* sysv_fn, int argc) {
  if (sysv_fn == NULL || argc < 0 || argc > 8) return NULL;
  TrampolineSlot* slot = alloc_slot(sysv_fn);
  if (slot == NULL) return NULL;
  emit_import(slot, argc);
  FlushInstructionCache(GetCurrentProcess(), slot->code, sizeof(slot->code));
  return slot->code;
}

#else

#if defined(_WIN32)
__declspec(dllexport)
#endif
void* provision_sysv_wrap_export(void* fn, int argc) {
  (void)argc;
  return fn;
}

#if defined(_WIN32)
__declspec(dllexport)
#endif
void* provision_sysv_wrap_import(void* fn, int argc) {
  (void)argc;
  return fn;
}

#endif
