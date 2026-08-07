# VIG Assembler

`vigasm` assembles readable VIG source files into the bytecode consumed by the
[`vig`](https://github.com/TheBozzz34/vig) virtual machine. It has no runtime dependency on the VM implementation. Both depend on
[vig-bytecode](https://github.com/TheBozzz34/vig-bytecode), which defines the instruction set, the container
format, and the verifier.

See [OPCODES.md](OPCODES.md) for the complete current instruction reference, and
[ABI.md](ABI.md) for how a C compiler targets VIG: type sizes, the calling
convention, structs, variadics and what is deliberately out of scope.

## Usage

```powershell
zig build run -- examples\load_store_call.vigas -o load_store_call.vig
..\vig\zig-out\bin\vig.exe load_store_call.vig
```

Add `-c` to make a relocatable object for the linker instead of a program. See
[Relocatable objects](#relocatable-objects).

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
how a function pointer is called, and `jmp_indirect` jumps to one without saving a
return offset, which is how a jump table dispatches a `switch`. See
[OPCODES.md](OPCODES.md#indirect-calls) and [jump tables](OPCODES.md#jump-tables).

Instructions whose result depends on the sign of their operands come in pairs:
`lt`/`lt_u` and its three companions, `div`/`div_u`, `mod`/`mod_u`, and
`shr_s`/`shr_u`. `add`, `sub` and `mul` trap on signed overflow, and `add_wrap`,
`sub_wrap` and `mul_wrap` wrap instead. See
[OPCODES.md](OPCODES.md#signed-and-unsigned).

`extern` declares a foreign import and `entry` names the label execution starts
at. Four directives describe data:

| Directive | Writes |
| --- | --- |
| `asciiz "text"` | a NUL-terminated string |
| `i8`, `i16`, `i32` | one or more values of that width, separated by a space or a comma |
| `reserve N` | `N` zero bytes, as a length in the header rather than bytes of the file |

A value may be a number or a label, so `i32 message` is a pointer with an initial
value. Data is assembled into regions of its own, after the code, so it can be
declared anywhere and is never executed. See
[OPCODES.md](OPCODES.md#initialized-data).

## Relocatable objects

`-c` assembles one source into a `.vigo` object for
[`vigld`](https://github.com/TheBozzz34/vig-linker) instead of a program:

```powershell
zig build run -- -c main.vigas -o main.vigo
```

An object is one translation unit. It has no entry point, because which function
starts the program is a decision of the link. Nothing in it has a final address
either: its sections will be placed among the sections of other objects, so every
reference to a name becomes a relocation and the value in the bytes stays zero
until the linker fills it in. Nothing is verified here for the same reason — a
`call` to another object cannot be followed yet. The linker verifies once, after
the last relocation, and that pass covers every byte that will run.

Three directives describe how a name takes part in the link. None of them means
anything in a complete program, so a source that uses one cannot be assembled
without `-c`.

| Directive | Means |
| --- | --- |
| `global name` | this object defines `name` and offers it to every other object |
| `extern_symbol name [function\|object]` | this object uses `name` and something else defines it |
| `common name size [alignment]` | ask the linker for space rather than defining it here |

`global` may come before or after the label it names. The kind on
`extern_symbol` is what the linker checks a reference against — a `call` must
reach a function and a `load` must reach an object — and it defaults to
`function`. `common` is what C's tentative definition (`int counter;` at file
scope, with no initialiser) becomes: several objects may ask for the same name,
and the linker makes one region as large and as strongly aligned as the largest
request, or drops it entirely if some object defines `counter` for real.

Every label is a symbol too: one in the code names a function, one in either data
region names an object. A label the source never marks `global` stays private, so
two objects may each have a `loop:` without collision.

Assembly fails if the resulting program does not verify, for example if a jump
lands inside another instruction, or if control can run off the end of the code
instead of reaching `halt` or `ret`. The failure names the code offset. See
[OPCODES.md](OPCODES.md#verification).

`--check-stack` adds a check that the operand stack has one height at every
instruction, which is what finds an unbalanced expression or a branch whose two arms
leave different things behind. It is off by default because a correct program can
fail it — a function written in the older convention declares no `enter`, and the
check cannot follow a call to one. See
[OPCODES.md](OPCODES.md#the-stack-check).

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
