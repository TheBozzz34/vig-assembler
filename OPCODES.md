# VIG Opcode Reference

VIG programs are bytecode. Every instruction begins with a one-byte opcode.
Multi-byte operands are four-byte little-endian values. In assembler source,
labels used by jumps and calls resolve to absolute byte addresses.

`a` is the lower stack value and `b` is the top value. Stack effects use
`before → after`; `—` means the instruction does not change the data stack.

| Byte | Assembly | Operand | Stack effect | Description |
| ---: | --- | --- | --- | --- |
| 0 | `halt` | — | — | Stop execution. |
| 1 | `push value` | signed `i32` | `→ value` | Push a signed 32-bit integer. |
| 2 | `add` | — | `a b → a + b` | Add two values. |
| 3 | `sub` | — | `a b → a - b` | Subtract the top value from the next value. |
| 4 | `print` | — | `a → a` | Print the top value without removing it. |
| 5 | `dup` | — | `a → a a` | Duplicate the top value. |
| 6 | `pop` | — | `a →` | Discard the top value. |
| 7 | `swap` | — | `a b → b a` | Exchange the top two values. |
| 8 | `mul` | — | `a b → a * b` | Multiply two values. |
| 9 | `div` | — | `a b → a / b` | Signed integer division, truncated toward zero. |
| 10 | `mod` | — | `a b → a % b` | Signed remainder. |
| 11 | `eq` | — | `a b → bool` | Push `1` when `a == b`, otherwise `0`. |
| 12 | `ne` | — | `a b → bool` | Push `1` when `a != b`, otherwise `0`. |
| 13 | `lt` | — | `a b → bool` | Push `1` when `a < b`, otherwise `0`. |
| 14 | `lte` | — | `a b → bool` | Push `1` when `a <= b`, otherwise `0`. |
| 15 | `gt` | — | `a b → bool` | Push `1` when `a > b`, otherwise `0`. |
| 16 | `gte` | — | `a b → bool` | Push `1` when `a >= b`, otherwise `0`. |
| 17 | `jmp target` | unsigned `u32` | — | Jump unconditionally to an absolute byte address. |
| 18 | `jmp_zero target` | unsigned `u32` | `condition →` | Jump when `condition` is `0`. |
| 19 | `jmp_not_zero target` | unsigned `u32` | `condition →` | Jump when `condition` is not `0`. |
| 20 | `load address` | unsigned `u32` | `→ data[address]` | Push a value from the data segment. |
| 21 | `store address` | unsigned `u32` | `value →` | Pop a value into the data segment. |
| 22 | `call target` | unsigned `u32` | — | Save the next instruction address and jump to `target`. |
| 23 | `ret` | — | — | Return to the address saved by `call`. |

| 24 | `foreign_call name` | unsigned `u8` import index | `arg1 ... argN -> result` | Call an `extern` declaration. |

| 25 | `print_string` | â€” | `address â†’ address` | Print the NUL-terminated string at a VIG bytecode address. |

## Strings

Use `asciiz` to place a NUL-terminated string in the program, then push its
label and call `print_string`. Keep static data after `halt` so it is not
executed as bytecode.

```asm
push greeting
print_string
pop
halt

greeting:
  asciiz "Hello from VIG!"
```

`print_string` leaves the address on the stack, like integer `print` leaves
its value. It rejects `0`, negative/out-of-range addresses, and strings whose
terminator lies outside the loaded program.

## Foreign functions (Windows x64)

Declare a DLL symbol with `extern` and call its local name with
`foreign_call`:

```asm
extern MessageBoxA user32.dll MessageBoxA ptr cstr cstr u32

push 0          # HWND = NULL
push message
push caption
push 0          # MB_OK
foreign_call MessageBoxA
pop
halt

caption:
  asciiz "VIG"
message:
  asciiz "Hello from VIG"
```

The syntax is `extern local_name dll_name symbol_name [argument_type ...]`.
Imports have zero to four arguments. Types are `i32`, `u32`, `ptr`, and `cstr`.
Arguments are pushed left-to-right and the return value is a 32-bit integer.

`ptr` and `cstr` are VIG bytecode offsets, never native addresses. `0` becomes
`NULL`; `cstr` additionally requires a NUL-terminated byte string. Define one
with `asciiz "text"` after `halt` so execution never reaches it. This first
version supports Windows x64 integer/pointer functions only; not callbacks,
structs, floating point, output buffers, or 64-bit return values.

## Limits and errors

- The data segment contains 256 signed 32-bit slots, so valid data addresses
  are `0` through `255`.
- The data stack has 256 slots. `call` and `ret` use a separate 128-entry call
  stack.
- A jump or call target must point inside the loaded program.
- Arithmetic traps on signed overflow. `div` and `mod` also trap on division by
  zero.
- At most 16 foreign imports and four arguments per import are supported.

## Example

```asm
# Print 42 by calling a small subroutine.
start:
  push 40
  store 0
  call increment
  print
  halt

increment:
  load 0
  push 2
  add
  ret
```
