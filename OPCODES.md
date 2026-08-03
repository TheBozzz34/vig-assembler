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

## Limits and errors

- The data segment contains 256 signed 32-bit slots, so valid data addresses
  are `0` through `255`.
- The data stack has 256 slots. `call` and `ret` use a separate 128-entry call
  stack.
- A jump or call target must point inside the loaded program.
- Arithmetic traps on signed overflow. `div` and `mod` also trap on division by
  zero.

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
