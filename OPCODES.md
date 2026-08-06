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
| 20 | `load address` | unsigned `u32` | `→ i32 at address` | Push the 32-bit value at a byte address in memory. |
| 21 | `store address` | unsigned `u32` | `value →` | Write 32 bits of `value` to a byte address in memory. Refused if it names the code. |
| 22 | `call target` | unsigned `u32` | — | Save the next instruction address and jump to `target`. |
| 23 | `ret` | — | — | Return to the address saved by `call`. |
| 24 | `foreign_call name` | unsigned `u8` import index | `arg1 ... argN → result` | Call an `extern` declaration. |
| 25 | `print_string` | — | `address → address` | Print the NUL-terminated string at a VIG bytecode address. |
| 26 | `load_at` | — | `address → i32 at address` | The same instruction as `load32`. The older name is kept. |
| 27 | `store_at` | — | `value address →` | The same instruction as `store32`. The older name is kept. |
| 28 | `and` | — | `a b → a & b` | Compute the bitwise AND of two values. |
| 29 | `or` | — | `a b → a \| b` | Compute the bitwise OR of two values. |
| 30 | `xor` | — | `a b → a ^ b` | Compute the bitwise XOR of two values. |
| 31 | `not` | — | `a → ~a` | Invert every bit of a value. |
| 32 | `shl` | — | `a b → a << (b mod 32)` | Shift left by the low five bits of the shift count. |
| 33 | `shr_u` | — | `a b → unsigned(a) >> (b mod 32)` | Shift right logically by the low five bits of the shift count. |
| 34 | `rotl` | — | `a b → rotate_left(a, b mod 32)` | Rotate left by the low five bits of the rotation count. |
| 35 | `add_wrap` | — | `a b → a +% b` | Add modulo 2^32 instead of trapping on overflow. |
| 36 | `read_i32` | — | `→ value` | Read a signed decimal integer from the runtime input stream. |
| 37 | `read_byte` | — | `→ byte` | Read one raw input byte, or push `-1` at end of input. |
| 38 | `print_hex` | — | `a → a` | Print the top value as eight lowercase hexadecimal digits. |
| 39 | `write_byte` | — | `byte →` | Pop one value and write its low byte to the output stream. |
| 40 | `load8_u` | — | `address → u8 at address` | Push the byte at `address`. The upper 24 bits are zero. |
| 41 | `load8_s` | — | `address → i8 at address` | Push the byte at `address`, with its sign extended to 32 bits. |
| 42 | `load16_u` | — | `address → u16 at address` | Push the 16-bit value at `address`. The upper 16 bits are zero. |
| 43 | `load16_s` | — | `address → i16 at address` | Push the 16-bit value at `address`, with its sign extended to 32 bits. |
| 44 | `load32` | — | `address → i32 at address` | Push the 32-bit value at `address`. |
| 45 | `store8` | — | `value address →` | Write the low 8 bits of `value` to `address`. |
| 46 | `store16` | — | `value address →` | Write the low 16 bits of `value` to `address`. |
| 47 | `store32` | — | `value address →` | Write all 32 bits of `value` to `address`. |
| 48 | `enter arguments locals` | two unsigned `u16` | `arg1 ... argN →` | Give the running function a frame and move its arguments into it. |
| 49 | `ret_val` | — | `value → value` | Return one value to the caller and discard the rest of the frame. |
| 50 | `load_local index` | unsigned `u16` frame slot | `→ frame[index]` | Push an argument or a local of the running function. |
| 51 | `store_local index` | unsigned `u16` frame slot | `value →` | Pop a value into an argument or a local of the running function. |
| 52 | `local_addr index` | unsigned `u16` frame slot | `→ address` | Push the memory address of an argument or a local. |
| 53 | `lt_u` | — | `a b → bool` | Push 1 when a < b as unsigned values, otherwise 0. |
| 54 | `lte_u` | — | `a b → bool` | Push 1 when a <= b as unsigned values, otherwise 0. |
| 55 | `gt_u` | — | `a b → bool` | Push 1 when a > b as unsigned values, otherwise 0. |
| 56 | `gte_u` | — | `a b → bool` | Push 1 when a >= b as unsigned values, otherwise 0. |
| 57 | `div_u` | — | `a b → a / b` | Unsigned division. Traps on division by zero. |
| 58 | `mod_u` | — | `a b → a % b` | Unsigned remainder. Traps on division by zero. |
| 59 | `shr_s` | — | `a b → a >> (b mod 32)` | Shift right arithmetically, filling with the sign bit. |
| 60 | `sub_wrap` | — | `a b → a -% b` | Subtract and wrap modulo 2^32 instead of trapping. |
| 61 | `mul_wrap` | — | `a b → a *% b` | Multiply and wrap modulo 2^32 instead of trapping. |
| 62 | `call_indirect` | — | `target →` | Call the code address on the stack. |
| 63 | `jmp_indirect` | — | `target →` | Jump to the code address on the stack, saving no return offset. |
| 64 | `fadd` | — | `a b → a + b` | Add two binary32 values. |
| 65 | `fsub` | — | `a b → a - b` | Subtract the top binary32 value from the next. |
| 66 | `fmul` | — | `a b → a * b` | Multiply two binary32 values. |
| 67 | `fdiv` | — | `a b → a / b` | Divide binary32 values. A zero divisor gives an infinity or a NaN, not a trap. |
| 68 | `fneg` | — | `a → -a` | Negate a binary32 value, which flips its sign bit and nothing else. |
| 69 | `fsqrt` | — | `a → sqrt(a)` | The square root, which IEEE-754 specifies exactly. A negative operand gives a NaN. |
| 70 | `feq` | — | `a b → bool` | Push 1 when a == b as binary32 values, otherwise 0. |
| 71 | `fne` | — | `a b → bool` | Push 1 when a != b as binary32 values, otherwise 0. A NaN is unequal to everything. |
| 72 | `flt` | — | `a b → bool` | Push 1 when a < b as binary32 values, otherwise 0. |
| 73 | `fle` | — | `a b → bool` | Push 1 when a <= b as binary32 values, otherwise 0. |
| 74 | `fgt` | — | `a b → bool` | Push 1 when a > b as binary32 values, otherwise 0. |
| 75 | `fge` | — | `a b → bool` | Push 1 when a >= b as binary32 values, otherwise 0. |
| 76 | `f2i` | — | `a → int` | Truncate a binary32 value toward zero to a signed integer. Traps if it does not fit. |
| 77 | `f2u` | — | `a → int` | Truncate a binary32 value toward zero to an unsigned integer. Traps if it does not fit. |
| 78 | `i2f` | — | `a → float` | Convert a signed integer to binary32, rounding to nearest. |
| 79 | `u2f` | — | `a → float` | Convert an unsigned integer to binary32, rounding to nearest. |

Bitwise instructions operate on the raw two's-complement representation of each
`i32`. Shift and rotation counts use only their low five bits, so all counts are
effectively reduced modulo 32. `shr_u` fills high bits with zero and `shr_s` fills
them with the sign bit, while `shl`, `rotl`, and the wrapping arithmetic retain the
resulting 32-bit pattern on the signed stack.

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

`read_byte` reads input without treating whitespace specially. It pushes a value
from `0` through `255`, or `-1` at end of input. Because EOF is a value rather
than a trap, byte-oriented programs can process streams of unknown length:

```asm
loop:
  read_byte
  dup
  push -1
  eq
  jmp_not_zero done
  # Process the byte left on the stack.
  pop
  jmp loop

done:
  pop
  halt
```

`print_hex` interprets the top `i32` as its raw 32-bit pattern and prints exactly
eight lowercase hexadecimal digits followed by a newline. Like `print`, it does
not remove the value. For example, `push -1` followed by `print_hex` prints
`ffffffff`.

## Indirect data access

`load` and `store` encode their address in the instruction, so it is fixed at
assembly time. That address is a byte address in guest memory, and a label is how a
program names one:

```asm
    push 40
    store counter
    load counter
    print
    halt
counter:
    reserve 4
```

`load_at` and `store_at` take the address from the stack instead, which is what
makes arrays and computed offsets possible: the address can be the result of any
calculation. Each of the two is now the same instruction as `load32` and `store32`,
and the older names are kept so a program that used them needs no change.

For `store_at` the address is on top, above the value, so a write reads as "push
what to store, push where to store it":

```asm
push 7      # value
push 2      # address
store_at    # data[2] = 7

push 2
load_at     # → 7
```

Both instructions fault with `SegmentFault` on a negative address, and on one whose
four-byte access does not fit inside memory. A `store` into the code region is
refused as well: the assembler reports `StoreIntoCodeRegion` when the address is in
the instruction, and the VM traps with `WriteToCodeRegion` when the program
calculated it. `examples\array_sum.vigas` fills and then sums a ten-element array
with computed addresses.

## Byte-addressed memory

`load8_u` through `store32` address the memory of the VM by byte. That memory is
the program image — the code, then the static data — followed by space that starts
as zeros. An address is a plain byte offset into it, so it means the same thing
here as it does to `print_string` or to a `cstr` foreign argument, and `push
label` produces one directly:

```asm
    push greeting
    load8_u         # → 104, the 'h' of "hi"
    halt
greeting:
    asciiz "hi"
```

`load`, `store`, `load_at` and `store_at` address the same memory. There is one
address space: `load 4` and `load32` with 4 on the stack read the same four bytes.
Therefore the address of a global is an ordinary value, and a program can compute
with it. That is what makes a pointer, an array and a structure possible.

### Initialized data

`i8`, `i16` and `i32` write values that the program can read straight away. The
number in the directive is the width of one value, so it pairs with the load of
the same number:

```asm
    push table
    load32          # → 10
    push table+8
    load32          # → 30
    halt
table:
    i32 10, 20, 30
```

A space or a comma separates values, so an array is one line. A value may also be
a label or a label expression, which is how a pointer gets an initial value:

```asm
    push greeting
    load32          # the address of "hi"
    print_string
    halt
message:
    asciiz "hi"
greeting:
    i32 message
```

The permitted range covers both the signed and the unsigned reading of the width,
so `i8 -1` and `i8 255` are the same byte. A value outside both is refused with
`ValueOutOfRange` rather than truncated. What a byte *means* is decided by the
instruction that reads it: `i8 -1` gives `-1` through `load8_s` and `255` through
`load8_u`.

### Reserved data

`reserve` gives a label some zero-filled bytes to work with. Those bytes are a
length in the container header and not bytes of the file, so an array of a thousand
integers costs nothing on disk:

```asm
    push 1000
    push counter
    store32
    push counter
    load32          # → 1000
    halt
counter:
    reserve 4
```

Three rules apply to every one of these instructions:

- **A write cannot reach the code.** A store below the end of the code region
  faults with `WriteToCodeRegion`. The verifier checks that region once before a
  program runs, and a program that could rewrite an instruction would make that
  check meaningless. Reads are not restricted.
- **The width is part of the bound.** An address is a fault unless the whole
  access fits, so `store32` at four bytes from the end of memory faults even
  though the address itself is inside it. A negative address always faults.
- **Alignment does not matter.** `load32` at address 1 is as valid as at address
  4, so a structure can be laid out without a rule from the VM about where a
  field may sit.

A narrow load comes in two forms because the stack holds an i32 and a narrow
value has to fill it somehow. `load8_u` puts zeros in the upper 24 bits and
`load8_s` copies the sign bit into them, which is the difference between
`unsigned char` and `signed char`. A store needs no such pair: it keeps the low
bits and does not ask what they mean.

## Signed and unsigned

A VIG value is 32 bits and nothing on the stack says what those bits mean. Most
instructions do not need to know: an add, a store and a test for equality give the
same answer either way. The instructions where the sign bit changes the result come
in pairs, and the compiler picks the one that matches the type it is working with.

| Signed | Unsigned | Why they differ |
| --- | --- | --- |
| `lt` `lte` `gt` `gte` | `lt_u` `lte_u` `gt_u` `gte_u` | `-1` is the smallest signed value and the largest unsigned one |
| `div` `mod` | `div_u` `mod_u` | `0xffffffff / 2` is `0` signed and `0x7fffffff` unsigned |
| `shr_s` | `shr_u` | the vacated bits take the sign bit or take zeros |

`eq` and `ne` need no such pair, because equal bits are equal whatever they mean.

The two divisions also differ in what they refuse. `div` traps with
`IntegerOverflow` on `minInt / -1`, the one pair whose result an `i32` cannot hold;
the unsigned form has an answer for every pair. Both trap on a zero divisor.

## Overflow

`add`, `sub` and `mul` trap with `IntegerOverflow` when the result does not fit,
which is what a language wants where overflow is a fault. `add_wrap`, `sub_wrap`
and `mul_wrap` give the low 32 bits instead and never trap, which is what unsigned
arithmetic in C is defined to do:

```asm
push 0
push 1
sub_wrap        # → -1, the bits 0xffffffff
```

## Floating point

A floating-point value is one slot holding the bits of an IEEE-754 **binary32**.
The stack says nothing about what a slot means, so the instruction decides,
exactly as it does for a signed and an unsigned integer. `push` puts a float on
the stack by its bit pattern, which is what a compiler emits and what the `i32`
directive writes:

```asm
    push 1075838976     # the bits of 2.5
    push 1082130432     # the bits of 4.0
    fmul                # 10.0
    f2i
    print               # 10
```

There is no `double`. A slot is four bytes, `ret_val` returns one slot, and the
ABI passes every variadic argument as one slot; a 64-bit float would change all
three. See ABI.md.

### These are the instructions that do not trap

Every other arithmetic instruction in VIG faults on a result it cannot give:
`add` traps on overflow, `div` traps on a zero divisor. IEEE-754 has an answer
for all of those, so the floating-point instructions return it instead:

| | |
| --- | --- |
| `1.0 / 0.0` | positive infinity |
| `-1.0 / 0.0` | negative infinity |
| `0.0 / 0.0` | NaN |
| a product too large to hold | infinity |
| a product too small | zero |
| `fsqrt` of a negative | NaN |

Trapping on these would mean this VM inventing a rule the format does not have.

The two conversions to an integer are the exception, because there the format
runs out: `f2i` and `f2u` truncate toward zero as a cast in C does, and a value
the integer cannot hold — a NaN included — traps with `InvalidFloatConversion`.
C leaves that case undefined, and a fault says so more usefully than a number
that means nothing.

### NaN

A NaN compares false against everything, itself included. `fne` is therefore the
only one of the six comparisons that is true for one, which is what C requires of
`!=`. Each comparison leaves the integer 1 or 0, exactly as `lt` and the rest do,
so `jmp_not_zero` reads the answer without knowing which kind of comparison made
it.

### What is deliberately missing

`fsqrt` is here because IEEE-754 specifies the square root exactly: it gives the
same bits on every host, so a program that uses it stays reproducible. `sin`,
`cos`, `exp` and the rest are **not** specified to the last bit, and their
results differ between one platform's maths library and another's. An opcode for
one of those would cost the VM its reproducibility, so they belong in a library
written in C and compiled to bytecode like any other program.

There is no fused multiply-add for the same reason: `fmul` followed by `fadd`
rounds twice, and an instruction that rounded once would give a different answer
depending on whether the host had one.

## Call frames

[ABI.md](ABI.md) says how a C compiler uses what follows: which slot a parameter is
in, how a struct is passed, and what a variadic call looks like.

`call` and `ret` on their own give a subroutine a return address and nothing else. A
function that needs storage asks for it with `enter`:

```asm
entry start
start:
    push 6
    call square       # the argument goes on the operand stack
    print
    halt

square:
    enter 1 0         # one argument, no locals
    load_local 0
    load_local 0
    mul
    ret_val           # → 36
```

`enter arguments locals` takes the arguments off the operand stack and puts them in
the frame, so slot 0 is the first argument and the locals follow. Therefore an
argument and a local are the same kind of thing while the function runs, and
`local_addr` gives the address of either:

```asm
sum_pair:
    enter 2 1
    load_local 0
    load_local 1
    add
    store_local 2     # a local
    local_addr 2      # the address of that local, an ordinary pointer
    load32
    ret_val
```

A local starts at zero. A frame lives in guest memory, so the address of a local is
an ordinary address that `load32`, `store8` or a `cstr` foreign argument can use.
That is what makes a C parameter an lvalue.

Frame memory grows down from the end of memory while the program image sits at the
start. A recursion with no end therefore fails with `FrameMemoryExhausted` when the
two meet, or with `CallStackOverflow` when the number of active calls reaches
`call_stack_size`, whichever comes first.

### Two rules worth knowing

**A frame belongs to a call.** `enter` outside a call fails with
`EnterOutsideCall`, so a function that has locals is reached with `call` and the
entry point of the program is a stub that calls it. A C runtime does the same thing
with `main`.

**`ret` returns the operand stack to the height it had before the call**, less the
arguments that `enter` took. A function that leaves values behind therefore cannot
corrupt its caller. This applies only to a function that called `enter`: without a
declared argument count the VM does not know how many values the function consumed,
and putting them back would be worse than leaving the stack alone. A function with
no frame keeps its own stack in order, as every VIG program did before frames
existed.

Use `ret_val` to return a value and `ret` to return none.

## Indirect calls

`call` names its target in the instruction, so the target is fixed when the program
is assembled. `call_indirect` takes the target off the stack instead, which is what
a function pointer needs. The address of a function is an ordinary value: `push` it,
store it, put it in a table, load it back and call it.

```asm
entry main
main:
    push 21
    push table+4    # the second entry
    load32
    call_indirect   # → double(21)
    print
    halt
add_one:
    enter 1 0
    load_local 0
    push 1
    add
    ret_val
double:
    enter 1 0
    load_local 0
    push 2
    mul
    ret_val
table:
    i32 add_one, double
```

The target is popped before the call, so the values under it are the arguments and
`enter` finds them where it would for a direct call. Everything else — the frame,
`ret_val`, the operand stack — works exactly as it does for `call`.

### When such a function is verified

The verifier starts at the entry point and follows what it reads. No instruction
names `add_one` or `double` above, so that walk reaches neither, and a check at load
time could only reject a program it did not understand. Instead the VM verifies the
function the first time a call goes to it, and keeps the result: a second call to
the same address costs one comparison. The code region is read-only for the whole
run, so the answer is the one a check before the run would have given.

The practical difference is *when* a bad target is reported. A `call_indirect` to an
address whose function does not verify traps at the call, with the same error a load
would have given — `UnknownOpcode`, `ExecutionRunsOffEnd` and the rest. An address
outside the code region, or a negative one, traps with `SegmentFault`, and an
address inside another instruction traps with `MisalignedTarget`.

That last check needs the marks that verification leaves behind, so it applies to a
container. Bare code with no header is never verified, and an indirect call there
decodes from whatever address it was given.

## Jump tables

`jmp_indirect` takes its target off the stack the way `call_indirect` does, and
saves nothing: control leaves and does not come back. Where `call_indirect` reaches
another function, this one reaches a label of the function it is already in, which
is what a `switch` wants — one load and one jump instead of a comparison for every
case.

The table is a row of code addresses in the data region, which `i32` writes:

```asm
    load_local 0        # the index
    push 4
    mul                 # four bytes to an entry
    push table
    add
    load32              # the address of the arm
    jmp_indirect
case_zero:
    push 100
    jmp show
case_one:
    push 200
    jmp show
show:
    print
    ...
table:
    i32 case_zero, case_one
```

**Nothing checks the index.** A table has as many entries as it has, and reading
past the end reads whatever follows it — which the VM will then treat as an
address, and refuse if it does not name an instruction. The bounds test belongs in
the program, before the load, exactly as it does on a real machine.

Everything the previous section says about verifying an indirect target applies
here too: the arms are named only by the table, so the walk at load time reaches
none of them, and each is verified the first time the jump goes there.

`--check-stack` cannot follow a `jmp_indirect` any more than it can follow a
`call_indirect`. It checks the height the jump itself needs and stops on that path,
so an arm reached only through a table is not depth-checked.

## Program layout

An assembled program has three regions: the code, the static data, and the
zero-filled bytes that `reserve` asks for. Instructions go in the first, `asciiz`
strings and `i8`/`i16`/`i32` values in the second, and the VM maps each one
immediately after the one before it. A label's address is therefore its offset in
whichever region it belongs to, plus the length of every earlier region.

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

`ptr` and `cstr` are byte addresses in guest memory, never native addresses: the VM
translates one into a host address for the call. `0` becomes `NULL`.

`ptr` may name **any byte of memory**, including one in a call frame, so a program
can pass the address of a local and a foreign function can write into it. `cstr` is
read to its terminator and must therefore name a byte of the **program image**, with
the terminator inside it — memory above the image is zeros, and every address there
would otherwise look like the end of a string.

This version supports integer and pointer functions only; not callbacks, structs,
floating point, or 64-bit return values.

## Verification

The assembler verifies every program it writes, and the VM verifies every program
it loads. Verification walks the code from the entry point, following each branch,
and rejects a program in which any reachable instruction fails to decode, a jump
or call lands inside another instruction or outside the code, control falls off the
end of the code, or a `foreign_call` names an import that was never declared. Both
report the code offset that failed.

Unreachable bytes in the code region are not an error; they are never executed.

### The stack check

`vigasm --check-stack` asks one more question: does the program keep the operand
stack in the shape its own code expects? It works out the height of the stack at
every reachable instruction and reports the first place the arithmetic does not add
up — an instruction with less on the stack than it takes, two paths that meet at
different heights, or a function that returns a different number of values than its
`ret_val` claims.

```
$ vigasm broken.vigas -o broken.vig --check-stack
Verification failed at code offset 5: StackUnderflowAt
```

This is not about safety. The VM refuses an unsafe program either way, and a
program that fails this check may run perfectly well. It is for a program that a
compiler wrote, where an unbalanced stack is a fault in the compiler that otherwise
shows up as a trap somewhere far from the instruction that caused it.

The check follows a `call` through the frame that the called function declares: the
`enter` says how many arguments it takes, and its return instruction says whether it
leaves a value. Two things it cannot follow:

- **A function with no `enter`.** It does not say how many values it takes, so the
  height after a call to it is unknown. This is `UndeclaredCallTarget`, and it is
  why the check is off by default: the older calling convention is written that way,
  and those programs are correct.
- **`call_indirect`.** The target is a value, so no read of the code says which
  function it is. The check stops on that path and continues everywhere else.

## Limits and errors

- Guest memory is one byte-addressed space: the program image, then zero-filled
  bytes to the end. Every data address is a byte offset into it, whether it came
  from an instruction operand or from the stack, and a negative address always
  faults. The VM rejects an out-of-range `load` or `store` operand at load time and
  checks a computed address as the program runs.
- A value in `i8`, `i16` or `i32` must fit that width read as signed or as
  unsigned, so `i8` takes `-128` through `255`.
- **The size of memory and of the two stacks belongs to the VM and not to the
  program.** `vig` gives 1 MiB of memory, 1024 operand slots and 256 call frames by
  default, and `--memory` changes the first. A program that runs in one VM can
  therefore exhaust another, and an assembled program says nothing about which. The
  ceiling on memory is 2 GiB: a pointer is an `i32` on the operand stack.
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
