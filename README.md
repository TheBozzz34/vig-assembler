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

Three directives are available: `extern` declares a foreign import, `asciiz`
places a NUL-terminated string in the program's static-data region, and `entry`
names the label execution starts at. Strings are assembled into a region of their
own, after the code, so they can be declared anywhere and are never executed.

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
