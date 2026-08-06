# The VIG C ABI

How a C compiler targets VIG: what a type is, where a value lives, and what a call
looks like. [OPCODES.md](OPCODES.md) says what each instruction does; this document
says what a compiler must agree with itself about.

Every rule here is a convention between a compiler and the code it emits. The VM
enforces almost none of them — it enforces the frame protocol and nothing more — so
a compiler that breaks its own rules produces a program that runs and gives a wrong
answer. `vigasm --check-stack` catches the class of mistakes that shows up as an
unbalanced operand stack; the rest is on the compiler.

## Scope

The subset is **32-bit and integer-only**. This is a decision and not an oversight:

- No `long long` and no 64-bit arithmetic. A frame slot is four bytes and `ret_val`
  returns exactly one of them, so a 64-bit value would need slot pairs everywhere
  and a hidden pointer to come back from a function. VIG also has no carry flag, so
  the arithmetic would have to be synthesised from `add_wrap` and `lt_u`.
- No floating point. `float` is **reserved** as one four-byte slot holding IEEE-754
  bits, and no operation on it is defined. Reserving the slot now means that adding
  soft-float routines to the C runtime later, or float opcodes to the VM, changes
  what a compiler emits and not this ABI.

A compiler should reject `long long`, `double` and `float` arithmetic with a clear
message rather than silently narrowing them.

## Types

| C type | Size | Access | Notes |
| --- | ---: | --- | --- |
| `char` | 1 | `load8_s` / `store8` | **signed**, matching the `i8` data directive |
| `signed char` | 1 | `load8_s` / `store8` | |
| `unsigned char` | 1 | `load8_u` / `store8` | |
| `_Bool` | 1 | `load8_u` / `store8` | `0` or `1` |
| `short` | 2 | `load16_s` / `store16` | |
| `unsigned short` | 2 | `load16_u` / `store16` | |
| `int`, `long` | 4 | `load32` / `store32` | |
| `unsigned int`, `unsigned long` | 4 | `load32` / `store32` | |
| enum | 4 | `load32` / `store32` | an `int` |
| any pointer | 4 | `load32` / `store32` | a byte address in guest memory |
| `float` | 4 | `load32` / `store32` | reserved, no operations |

Everything is **little-endian**, which is what `load32` and the `i32` directive
write.

Signedness decides the instruction, not the type: a value on the operand stack is
thirty-two bits and nothing there says what they mean. `unsigned` selects `lt_u`,
`div_u`, `mod_u` and `shr_u`; signed selects `lt`, `div`, `mod` and `shr_s`. `eq`
and `ne` are the same either way.

Signed `+`, `-` and `*` may use `add`, `sub` and `mul`, which trap on overflow —
useful, because signed overflow is undefined in C and a trap is a better answer than
a wrong number. Unsigned arithmetic **must** use `add_wrap`, `sub_wrap` and
`mul_wrap`: wrapping is defined behaviour in C and a trap there would be wrong.

### Layout of a struct or a union

Fields sit at their natural offsets **in declaration order with no padding**, and
`sizeof` is the sum of the member sizes. The VM permits an unaligned `load32`
deliberately so that a compiler need not insert padding, so a VIG struct is as small
as its members.

A union is the size of its largest member, and every member is at offset 0.

An array of `T` has stride `sizeof(T)`, so `a[i]` is `a + i * sizeof(T)`.

## Memory

Guest memory is one flat byte-addressed space. There is no separate code address
space: a function pointer and a data pointer are numbers in the same range and can
never be equal, so a `void *` holds either without ambiguity.

```
0                code_len          program_len                    memory_size
|  code           |  static data    |  zero-filled  |   free   |  frames  |
|  read-only      |  .data          |  .bss         |          |  ← grow down
```

- **Code** is read-only. A store below `code_len` traps with `WriteToCodeRegion`,
  and the assembler refuses one it can see at assembly time.
- **Static data** comes from `asciiz`, `i8`, `i16` and `i32`. This is `.data`.
- **The zero-filled region** comes from `reserve`. It costs no bytes in the file, so
  a large array is free on disk. This is `.bss`.
- **Frames** grow down from the end of memory. They meet the image and stop with
  `FrameMemoryExhausted`.

The size of memory belongs to the VM and not to the program: `vig` gives 1 MiB by
default and `--memory` changes it. A program carries no statement of what it needs.

### The heap

There is no `malloc` in the VM and no instruction that reports the frame pointer.
Therefore a C runtime **must carve its heap out of `.bss`**:

```asm
heap:
    reserve 65536
heap_end:
```

The free region between the image and the frames cannot be used for a heap, because
nothing tells a program where the frames currently reach. A heap inside `.bss` is
below `program_len`, so the frames can never reach it either.

## Calling convention

A caller pushes the arguments **left to right**, so the first argument is deepest on
the operand stack. Then `call name`, or `push name` and `call_indirect`.

A function that has parameters or locals begins with `enter`, and it must be the
**first instruction of the function**:

```asm
sum:
    enter 2 1        # two parameters, one local
    load_local 0     # the first parameter
    load_local 1     # the second
    add
    store_local 2    # the local
    load_local 2
    ret_val
```

`enter arguments locals` takes the arguments off the operand stack and puts them in
the frame. Therefore:

- **Slots `0 .. arguments-1` are the parameters**, in declaration order.
- **Slots `arguments .. arguments+locals-1` are the locals**, and the compiler
  assigns them.
- **A parameter is an lvalue.** `local_addr` gives its address, which is what makes
  `&x` work for a parameter as well as for a local.
- **A local starts as zero.** The VM clears the local slots on `enter`. A C
  compiler need not rely on this, but it may.

A value wider than four bytes takes as many slots as it needs, and its address comes
from `local_addr` on the first of them. An `int buf[8]` is eight slots.

### Returning

- `ret_val` returns one value: **exactly one** value must be on the operand stack.
- `ret` returns none: the operand stack must be **empty**.

A function must not mix the two. Every return in one function has to be the same
instruction, because a call site works out what the function leaves from the return
instruction it uses. `--check-stack` reports `MixedReturnKinds` for a function that
does mix them, and `UnbalancedReturn` for one that leaves the wrong number.

On return the VM sets the operand stack back to the height the caller had before the
call, less the arguments, plus the returned value. A callee therefore cannot corrupt
its caller by leaving values behind, and a caller needs no knowledge of what the
callee did with its stack.

### Every called function must declare a frame

`enter 0 0` for a function with no parameters and no locals. A function reached by
`call` that does not begin with `enter` cannot be checked — nothing says how many
values it takes — and `--check-stack` reports `UndeclaredCallTarget`. The older
frameless convention, where a function operates directly on the caller's operand
stack, is still valid VIG but is **not** part of this ABI.

## Function pointers

The address of a function is `push name`, which gives its code offset. A call
through one is `call_indirect`, which takes the target off the top of the stack:

```asm
    push 21              # the argument
    push table+4         # the second entry of the table
    load32               # the function pointer
    call_indirect
table:
    i32 add_one, double
```

The target is popped before the call, so the values under it are the arguments and
the callee's `enter` finds them exactly where a direct call would leave them.

A function that only a pointer names is not reachable from the entry point, so the
verifier does not see it when the program loads. The VM verifies it at the first
call and keeps the result. A bad target traps at the call with the error the
verifier would have given.

`--check-stack` cannot follow a `call_indirect`, because no read of the code says
which function it is. The check stops on that path and continues everywhere else.

## Structs by value

The VM has no bulk-copy instruction, and `ret_val` returns one slot. Struct
arguments and struct returns therefore use a **caller-allocated hidden pointer**.

**Passing a struct by value.** The caller allocates a local of the struct's size in
its own frame, copies the struct into it, and passes the address. The callee treats
the parameter as a pointer. The copy belongs to the caller's frame and is dead when
the call returns, so the callee may modify it freely — which is exactly the C
semantics of a by-value parameter.

**Returning a struct.** The caller allocates space for the result in its own frame
and passes its address as a **hidden first parameter**, before the declared ones.
The callee writes the result through that pointer and returns the same pointer with
`ret_val`, so a call expression yields the address of its result.

```c
struct point { int x, y; };
struct point make(int x, int y);
struct point p = make(1, 2);
```

```asm
    local_addr 0         # hidden first parameter: where the result goes
    push 1
    push 2
    call make            # make: enter 3 0
    pop                  # the returned pointer, unused here
```

A struct copy is a load/store loop. A C runtime should provide `memcpy` and the
compiler should call it for anything but the smallest structs.

## Variadic functions

`enter` takes a static argument count, so a variadic callee cannot be told how many
values it received. A `va_list` is therefore **a real array**, and the caller builds
it.

A variadic function's declared parameters are followed by **two synthesised
parameters**:

| Slot | Meaning |
| --- | --- |
| `0 .. n-1` | the declared fixed parameters |
| `n` | `int` — the number of variable arguments |
| `n+1` | pointer to an array of that many slots |

So `int printf(const char *fmt, ...)` is a three-parameter function: `enter 3 l`.

The caller reserves an array of four-byte slots among its own locals, stores each
variable argument into it, and passes the count and the address. Because the subset
is 32-bit and has no floating point, **the default argument promotions make every
variable argument exactly one four-byte slot** — `char` and `short` promote to `int`
and nothing promotes to `double`. A `va_list` is therefore a uniform array, and
`va_arg` is a `load32` and an increment, with no per-type stride.

Here `a` and `b` are the caller's locals 0 and 1, and the caller has reserved locals
2 and 3 to hold the list:

```c
printf("%d %d\n", a, b);
```

```asm
    load_local 0         # a
    local_addr 2
    store32              # list[0] = a
    load_local 1         # b
    local_addr 3
    store32              # list[1] = b

    push fmt             # the fixed parameter
    push 2               # the count
    local_addr 2         # the list
    call printf
    pop                  # printf's result
```

`va_start` is a copy of the two synthesised parameters, `va_arg` reads through the
pointer and advances it, and `va_end` does nothing. A callee that reads past the
count is a fault in the callee; the VM does not check it.

## Foreign calls

`foreign_call` reaches a native library function. The limits are narrow and they are
part of the container format: **at most four arguments**, each `i32`, `u32`, `ptr` or
`cstr`, and a 32-bit integer result.

A `ptr` or `cstr` argument is a byte address in guest memory. The VM turns it into a
host address for the call, so a native function never sees a VIG address. A null
pointer is the value `0`.

**`ptr` may name any byte of memory**, including one in a call frame. Therefore
`&local` is a usable argument and a native function can write into it, which is what
an output parameter is:

```c
struct tm now;
GetSystemTime(&now);      /* the callee fills the caller's frame */
```

```asm
    local_addr 0
    foreign_call GetSystemTime
    pop
```

**`cstr` is the exception.** It is read to its terminator, so it must name a byte of
the program image — the code, the static data or the zero-filled region — with the
terminator inside it. Memory above the image starts as zeros, so every address there
would look like the end of a string and an unterminated one would stop being an
error.

Therefore **a string passed to a foreign function must live in `.data` or `.bss`**,
not in an automatic array. The same limit applies to `print_string`. A C runtime
should give its formatting functions a static output buffer:

```asm
out_buf:
    reserve 1024
```

An automatic `char[]` is fine for everything else — it is only the step that hands a
string to the VM or to a native function that needs a global.

## Starting a program

`enter` outside a call fails with `EnterOutsideCall`. A function with a frame is
therefore always reached by `call`, and `main` cannot be the entry point itself. The
entry point is a stub:

```asm
entry _start
_start:
    call main
    pop              # main's return value; there is no exit code
    halt

main:
    enter 0 0
    ...
    push 0
    ret_val
```

No command-line arguments reach a guest program, so `main` takes none. There is no
exit status: a program stops at `halt`, and what `main` returned is discarded by the
stub.

## The operand stack

The operand stack is scratch space for one expression. Between statements it should
be empty, and a compiler should treat any other state as a bug in itself.

`vigasm --check-stack` works out the height at every reachable instruction and
reports the first place the arithmetic does not add up: `StackUnderflowAt`,
`InconsistentStackDepth`, `UnbalancedReturn`, `MixedReturnKinds`. A compiler should
run with it on. See [OPCODES.md](OPCODES.md#the-stack-check).

The size of the operand stack belongs to the VM — 1024 slots by default, and 256
active calls. Deep recursion ends with `CallStackOverflow` or
`FrameMemoryExhausted`, whichever comes first.

## Summary of what a compiler must not do

- Emit `add`, `sub` or `mul` for unsigned arithmetic. Use the `_wrap` forms.
- Emit a signed comparison, division or shift for an unsigned type.
- Call a function that does not begin with `enter`.
- Mix `ret` and `ret_val` in one function.
- Pass the address of a local as a `cstr` argument, or to `print_string`. A `ptr`
  argument takes one.
- Assume memory above the program image is available; frames are there.
- Leave anything on the operand stack between statements.
