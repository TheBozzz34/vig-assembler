# VIG Assembler

`vigasm` assembles readable VIG source files into the bytecode consumed by the
[`vig`](../vig) virtual machine. It is intentionally a separate Zig project,
with no runtime dependency on the VM implementation.

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

One instruction or label appears on each line. Labels end in `:` and resolve to
the byte address of the following instruction. `#` and `;` begin comments.

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
`jmp_not_zero`, and `call` accept either a label or an explicit byte address.
