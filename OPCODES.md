# VIG Opcode Reference

VIG programs are bytecode. Every instruction begins with a one-byte opcode.
Multi-byte operands are four-byte little-endian values. In assembler source,
labels used by jumps and calls resolve to absolute byte addresses.

The instruction set, the operand widths, and the container the assembler writes
are defined once in [vig-bytecode](../vig-bytecode), which the assembler and the
VM share.

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
| 17 | `jmp target` | unsigned `u32` | — | Jump unconditionally to an absolute code offset. |
| 18 | `jmp_zero target` | unsigned `u32` | `condition →` | Jump when `condition` is `0`. |
| 19 | `jmp_not_zero target` | unsigned `u32` | `condition →` | Jump when `condition` is not `0`. |
| 20 | `load address` | unsigned `u32` | `→ data[address]` | Push a value from the data segment. |
| 21 | `store address` | unsigned `u32` | `value →` | Pop a value into the data segment. |
| 22 | `call target` | unsigned `u32` | — | Save the next instruction address and jump to `target`. |
| 23 | `ret` | — | — | Return to the address saved by `call`. |
| 24 | `foreign_call name` | unsigned `u8` import index | `arg1 ... argN → result` | Call an `extern` declaration. |
| 25 | `print_string` | — | `address → address` | Print the NUL-terminated string at a VIG bytecode address. |
| 26 | `load_at` | — | `address → data[address]` | Push a value from the data segment, using an address taken from the stack. |
| 27 | `store_at` | — | `value address →` | Pop a value into the data segment, using an address taken from the stack. |
| 28 | `and` | — | `a b → a & b` | Compute the bitwise AND of two values. |
| 29 | `or` | — | `a b → a \| b` | Compute the bitwise OR of two values. |
| 30 | `xor` | — | `a b → a ^ b` | Compute the bitwise XOR of two values. |
| 31 | `not` | — | `a → ~a` | Invert every bit of a value. |
| 32 | `shl` | — | `a b → a << (b mod 32)` | Shift left by the low five bits of the shift count. |
| 33 | `shr_u` | — | `a b → unsigned(a) >> (b mod 32)` | Shift right logically by the low five bits of the shift count. |
| 34 | `rotl` | — | `a b → rotate_left(a, b mod 32)` | Rotate left by the low five bits of the rotation count. |
| 35 | `add_wrap` | — | `a b → a +% b` | Add modulo 2^32 instead of trapping on overflow. |
| 36 | `read_i32` | — | `→ value` | Read a signed decimal integer from the runtime input stream. |

Bitwise instructions operate on the raw two's-complement representation of each
`i32`. Shift and rotation counts use only their low five bits, so all counts are
effectively reduced modulo 32. `shr_u` fills high bits with zero, while `shl`,
`rotl`, and `add_wrap` retain the resulting 32-bit pattern on the signed stack.

## Runtime input

`read_i32` skips leading whitespace, reads an optional `+` or `-`, and then
reads a decimal `i32`. It flushes program output before waiting, so a prompt
printed immediately beforehand is visible during interactive use:

```asm
push prompt
print_string
pop
read_i32
print
halt

prompt:
  asciiz "Enter a number:"
```

Input may come from the terminal, a pipe, or a redirected file. `read_i32`
traps with `EndOfInput` when no value remains, `InvalidInput` for a malformed
token, and `IntegerOverflow` when the value is outside the signed 32-bit range.

## Indirect data access

`load` and `store` encode their address in the instruction, so it is fixed at
assembly time. `load_at` and `store_at` take the address from the stack instead,
which is what makes arrays and computed offsets possible: the address can be the
result of any calculation.

For `store_at` the address is on top, above the value, so a write reads as "push
what to store, push where to store it":

```asm
push 7      # value
push 2      # address
store_at    # data[2] = 7

push 2
load_at     # → 7
```

Both instructions fault with `SegmentFault` on a negative address or one at or
beyond the end of the data segment. `examples\array_sum.vigas` fills and then
sums a ten-element array with computed addresses.

## Program layout

An assembled program has two regions: the code and the static data. Instructions
go in the first, `asciiz` strings in the second, and the VM maps the data
immediately after the code. A label's address is therefore its offset in
whichever region it belongs to, plus the code length for data labels.

Only the code region is executable. Execution stops at its end, and jump and call
targets must point inside it, a jump to a string address is rejected before the
program runs.

Because the regions are separate, a program's entry point does not have to be its
first instruction. `entry` names the label to start at, which is what lets
subroutines be written above the code that calls them:

```asm
entry main

double:
  push 2
  mul
  ret

main:
  push 21
  call double
  print
  halt
```

Without an `entry` directive execution starts at offset `0`.

## Strings

Use `asciiz` to place a NUL-terminated string in the program, then push its label
and call `print_string`. Strings are collected into the static-data region in
declaration order, wherever they appear in the source, so they cannot be executed
and need not be written after `halt`.

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

`ptr` and `cstr` are offsets into the loaded program, never native addresses. `0`
becomes `NULL`; `cstr` additionally requires a NUL-terminated byte string, which
is what `asciiz` produces. This first version supports Windows x64
integer/pointer functions only; not callbacks, structs, floating point, output
buffers, or 64-bit return values.

## Verification

The assembler verifies every program it writes, and the VM verifies every program
it loads. Verification walks the code from the entry point, following each branch,
and rejects a program in which any reachable instruction fails to decode, a jump
or call lands inside another instruction or outside the code, control falls off the
end of the code, or a `foreign_call` names an import that was never declared. Both
report the code offset that failed.

Unreachable bytes in the code region are not an error; they are never executed.

## Limits and errors

- The data segment contains 256 signed 32-bit slots, so valid data addresses
  are `0` through `255`. This applies to `load_at` and `store_at` too, which
  additionally reject negative addresses rather than wrapping them. The VM
  rejects an out-of-range `load` or `store` address at load time.
- The data stack has 256 slots. `call` and `ret` use a separate 128-entry call
  stack.
- A jump or call target must point inside the code region.
- Arithmetic traps on signed overflow. `div` and `mod` also trap on division by
  zero. `read_i32` also uses `IntegerOverflow` for an out-of-range input value.
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
