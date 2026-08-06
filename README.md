# VIG Assembler

`vigasm` assembles readable VIG source files into the bytecode consumed by the
[`vig`](https://github.com/TheBozzz34/vig) virtual machine. It has no runtime dependency on the VM implementation. Both depend on
[vig-bytecode](https://github.com/TheBozzz34/vig-bytecode), which defines the instruction set, the container
format, and the verifier.

See [OPCODES.md](OPCODES.md) for the complete current instruction reference.

## Usage

```powershell
zig build run -- examples\load_store_call.vigas -o load_store_call.vig
..\vig\zig-out\bin\vig.exe load_store_call.vig
```

The example prints `42` and exercises the latest VIG instructions: `load`,
`store`, `call`, and `ret`.

`examples\get_process_id.vigas` demonstrates a generic Windows DLL import;
`examples\message_box.vigas` calls `user32.dll!MessageBoxA`. See
[OPCODES.md](OPCODES.md#foreign-functions-windows-x64) for the `extern`,
`foreign_call`, and `asciiz` syntax.

`examples\print_string.vigas` demonstrates `asciiz` data and the built-in
`print_string` instruction.

`examples\read_i32.vigas` reads a signed decimal integer at runtime, doubles
it, and prints the result:

```powershell
zig build run -- examples\read_i32.vigas -o read_i32.vig
"21" | ..\vig\zig-out\bin\vig.exe read_i32.vig
```

`examples\md5.vigas` is a complete streaming MD5 implementation written in
VIGasm. It accepts arbitrary binary stdin, performs its own block packing and
padding, and prints the digest as four eight-digit lines. Concatenating the
lines gives the conventional 32-digit digest:

```powershell
zig build run -- examples\md5.vigas -o md5.vig
cmd /c "..\vig\zig-out\bin\vig.exe md5.vig < input.bin"
```

## Foreign-call integration suite

On Windows, assemble and run the non-interactive foreign-call suite with:

```powershell
zig build run -- examples\foreign_calls_positive.vigas -o foreign_calls_positive.vig
..\vig\zig-out\bin\vig.exe foreign_calls_positive.vig
```

It prints each test number (`0` through `6`) followed by `1`. The suite covers
generic resolution from `kernel32.dll` and `user32.dll`, aliases, zero through
four arguments, integer marshalling, and VIG-managed C strings without opening
UI or writing files.

## Source format

One instruction, label, or directive appears on each line. Labels end in `:` and
resolve to the address of whatever follows them. `#` and `;` begin comments.

```asm
loop:
  load 0
  push 1
  sub
  dup
  store 0
  jmp_not_zero loop
  halt
```

`push` accepts a signed 32-bit decimal/base-prefixed value or a label address.
`load` and `store` take unsigned 32-bit data addresses. `jmp`, `jmp_zero`,
`jmp_not_zero`, and `call` accept either a label or an explicit code offset.
`call_indirect` takes no operand and calls the code address on the stack, which is
how a function pointer is called. See
[OPCODES.md](OPCODES.md#indirect-calls).

Instructions whose result depends on the sign of their operands come in pairs:
`lt`/`lt_u` and its three companions, `div`/`div_u`, `mod`/`mod_u`, and
`shr_s`/`shr_u`. `add`, `sub` and `mul` trap on signed overflow, and `add_wrap`,
`sub_wrap` and `mul_wrap` wrap instead. See
[OPCODES.md](OPCODES.md#signed-and-unsigned).

Six directives are available. `extern` declares a foreign import and `entry` names
the label execution starts at. The other four describe data:

| Directive | Writes |
| --- | --- |
| `asciiz "text"` | a NUL-terminated string |
| `i8`, `i16`, `i32` | one or more values of that width, separated by a space or a comma |
| `reserve N` | `N` zero bytes, as a length in the header rather than bytes of the file |

A value may be a number or a label, so `i32 message` is a pointer with an initial
value. Data is assembled into regions of its own, after the code, so it can be
declared anywhere and is never executed. See
[OPCODES.md](OPCODES.md#initialized-data).

Assembly fails if the resulting program does not verify, for example if a jump
lands inside another instruction, or if control can run off the end of the code
instead of reaching `halt` or `ret`. The failure names the code offset. See
[OPCODES.md](OPCODES.md#verification).

`load_at` and `store_at` take no operand and read the data address from the stack
instead, which is how arrays and computed offsets are written. See
[OPCODES.md](OPCODES.md#indirect-data-access) and `examples\array_sum.vigas`,
which fills and sums a ten-element array:

```powershell
zig build run -- examples\array_sum.vigas -o array_sum.vig
..\vig\zig-out\bin\vig.exe array_sum.vig
```

It prints `285`.

`examples\bubble_sort.vigas` sorts a ten-element array in place. Its inner loop
compares `data[j]` against `data[j + 1]` and swaps them, so every access is a
computed address:

```powershell
zig build run -- examples\bubble_sort.vigas -o bubble_sort.vig
..\vig\zig-out\bin\vig.exe bubble_sort.vig
```
